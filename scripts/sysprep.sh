#!/usr/bin/env bash
#
# sysprep.sh —— 转模板前的去身份化清理
#
# 用途：把一台配置好的 Ubuntu 虚拟机清理成「可以被反复克隆」的状态。
#
# 为什么必须做：
#   克隆机会【原样继承模板里的一切】，包括那些本该每台唯一的东西。
#   不清理会得到一堆"长得一模一样"的机器，然后遇到极难排查的问题：
#
#     /etc/machine-id     两台 MAC 不同的机器拿到【同一个 IP】
#                         （现代 dhclient 用 machine-id 生成 DHCP client-id）
#                         k8s 节点注册互相覆盖，且报错完全不提 machine-id
#     SSH 主机密钥        所有克隆机指纹相同 → SSH 告警 + 中间人风险
#     静态 IP             一开机就 IP 冲突，连都连不进去
#
# 🔴 本脚本是【不可逆】的，执行后这台机器的身份信息就没了。
#    执行前请先在 Proxmox 网页上打一个快照。
#
# 关于顺序（这是最容易踩的坑）：
#   网络改 DHCP 必须在关机【之前】，但【绝不能执行 netplan apply】——
#   apply 会立刻把 IP 从静态切成 DHCP，你的 SSH 连接当场断开，
#   脚本收到 SIGHUP 被杀，后面的关机和 fstrim 全都不会执行。
#   本脚本只写文件 + netplan generate 校验语法，改动在下次开机自然生效。
#
# 用法：
#   ./sysprep.sh                       # 交互确认 → 清理 → 关机
#   ./sysprep.sh --dry-run             # 只打印将要做什么，绝不动手
#   ./sysprep.sh --no-shutdown         # 清理完不关机（自己去 Web 上关）
#   ./sysprep.sh --yes                 # 跳过交互确认
#
# 环境变量：
#   TMPL_HOSTNAME=ubuntu-tmpl          # 模板的通用主机名
#   SKIP_UPGRADE=1                     # 跳过 apt full-upgrade
#   KEEP_STATIC_IP=1                   # 保留静态 IP（极少用，会导致克隆机冲突）
#   ENABLE_PVE_CLOUDINIT=1             # 打开 Proxmox Cloud-Init 支持（见 M5 说明）
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# 全局变量
# ──────────────────────────────────────────────────────────────
readonly TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
readonly TARGET_HOME
readonly TMPL_HOSTNAME="${TMPL_HOSTNAME:-ubuntu-tmpl}"
TS="$(date +%Y%m%d-%H%M%S)"
readonly TS

DRY_RUN=0
NO_SHUTDOWN=0
ASSUME_YES=0
SKIP_UPGRADE="${SKIP_UPGRADE:-0}"
KEEP_STATIC_IP="${KEEP_STATIC_IP:-0}"
ENABLE_PVE_CLOUDINIT="${ENABLE_PVE_CLOUDINIT:-0}"

export DEBIAN_FRONTEND=noninteractive

# ──────────────────────────────────────────────────────────────
# 输出辅助
# ──────────────────────────────────────────────────────────────
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    [warn] %s\033[0m\n' "$*"; }
skip() { printf '\033[0;36m    [skip] %s\033[0m\n' "$*"; }
done_() { printf '\033[0;32m    [ok]   %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m\n  [错误] %s\n\033[0m\n' "$*" >&2; exit 2; }

# dry-run 包装：所有会改变系统状态的命令都必须经过它。
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[0;36m    [dry] %s\033[0m\n' "$*"
  else
    "$@"
  fi
}

# ──────────────────────────────────────────────────────────────
# 参数解析
# ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; NO_SHUTDOWN=1 ;;
    --no-shutdown) NO_SHUTDOWN=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    -h|--help)     sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（可用：--dry-run / --no-shutdown / --yes）" ;;
  esac
  shift
done

# ──────────────────────────────────────────────────────────────
# M0 · 前置检查与确认
# ──────────────────────────────────────────────────────────────
m0_precheck() {
  step "M0 · 前置检查"

  [[ -r /etc/os-release ]] || die "读不到 /etc/os-release，这不是一台标准 Linux"
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "系统是 ${PRETTY_NAME:-未知}，脚本按 Ubuntu 24.04 设计"

  # 虚拟化检测：在物理机上跑 sysprep 几乎肯定是搞错机器了
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  if [[ "$virt" == "none" ]]; then
    warn "🔴 systemd-detect-virt 报告这是【物理机】，不是虚拟机"
    warn "   确认你没有连错机器 —— sysprep 会删掉这台机器的 SSH 主机密钥"
  fi

  sudo -n true 2>/dev/null || warn "sudo 需要密码，后面会提示输入"

  local ips
  ips="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | paste -sd' ' -)"

  echo
  printf '\033[1;33m  即将对这台机器执行【不可逆】的去身份化：\033[0m\n'
  printf '    %-12s %s\n' "主机名"   "$(hostname)"
  printf '    %-12s %s\n' "IP"       "${ips:-无}"
  printf '    %-12s %s\n' "系统"     "${PRETTY_NAME:-?}"
  printf '    %-12s %s\n' "虚拟化"   "$virt"
  printf '    %-12s %s\n' "日常用户" "$TARGET_USER"
  echo
  printf '  将要做：\n'
  printf '    · 清空 machine-id、删除 SSH 主机密钥（并装上首次启动自动重建的兜底服务）\n'
  printf '    · 主机名改为 %s\n' "$TMPL_HOSTNAME"
  if [[ "$KEEP_STATIC_IP" == "1" ]]; then
    printf '    · \033[1;33m保留静态 IP（KEEP_STATIC_IP=1）—— 克隆机会 IP 冲突\033[0m\n'
  else
    printf '    · 网络改回 DHCP（只写文件，不 apply，避免断开 SSH）\n'
  fi
  printf '    · 清空日志、shell 历史、DHCP 租约、apt 缓存、cloud-init 状态\n'
  printf '    · fstrim 把已删除的块还给 LVM-Thin 池\n'
  if [[ $NO_SHUTDOWN -eq 0 ]]; then
    printf '    · \033[1;31m最后自动关机\033[0m\n'
  fi
  echo
  printf '  \033[1;33m确认已经在 Proxmox 网页上打过快照了吗？\033[0m\n'
  echo

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "--dry-run 模式，以下所有操作只打印不执行"
    return 0
  fi

  if [[ "$ASSUME_YES" == "1" ]]; then
    warn "--yes，跳过确认"
    return 0
  fi

  [[ -t 0 ]] || die "非交互环境下必须显式指定 --yes（防止误删）"

  local reply=""
  read -r -p "  输入 sysprep 继续，其他任意键取消：" reply
  [[ "$reply" == "sysprep" ]] || { warn "已取消，未做任何修改"; exit 0; }
}

# ──────────────────────────────────────────────────────────────
# M1 · 转模板前的关键项体检
# ──────────────────────────────────────────────────────────────
# 只查【错了就会让整批克隆机都出问题】的项。
# 完整体检请先跑：./fix-root-residue.sh --check
m1_precheck_quality() {
  step "M1 · 转模板前关键项体检"

  local issues=0

  # ① 日常用户的家目录里不能有 root 属主的文件 —— 会被复制进每一台克隆机
  if [[ -n "$TARGET_HOME" ]] && \
     sudo find "$TARGET_HOME" -maxdepth 3 ! -user "$TARGET_USER" -print -quit 2>/dev/null | grep -q .; then
    warn "$TARGET_HOME 下存在非 $TARGET_USER 属主的文件（root 误跑过脚本？）"
    warn "  建议先修：./fix-root-residue.sh"
    issues=$((issues + 1))
  else
    done_ "家目录属主正常"
  fi

  # ② /root 下不该有用户级工具
  local p leftover=()
  for p in /root/.local/bin/uv /root/.npmrc /root/.nvm; do
    sudo test -e "$p" && leftover+=("$p")
  done
  if [[ ${#leftover[@]} -gt 0 ]]; then
    warn "/root 下有用户级工具残留：${leftover[*]}"
    warn "  这些会被复制进每一台克隆机，建议先跑 ./fix-root-residue.sh"
    issues=$((issues + 1))
  else
    done_ "/root 无用户级工具残留"
  fi

  # ③ SSH 公钥必须在 —— sysprep 会删掉密钥登录之外的所有身份信息，
  #    如果连公钥都没有，克隆机就只能靠 noVNC 加密码进
  if [[ -s "$TARGET_HOME/.ssh/authorized_keys" ]]; then
    done_ "SSH 公钥已就位（$(wc -l < "$TARGET_HOME/.ssh/authorized_keys") 条），故意保留进模板"
  else
    warn "$TARGET_USER 没有 authorized_keys —— 克隆机只能用密码登录"
    issues=$((issues + 1))
  fi

  # ④ sudo 免密
  sudo -n true 2>/dev/null && done_ "sudo 免密生效" || { warn "sudo 免密未生效"; issues=$((issues + 1)); }

  # ⑤ 磁盘是否支持 discard —— 不支持的话 M7 的 fstrim 是空操作
  local root_src disc
  root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  disc="$(lsblk -Dno DISC-MAX "$root_src" 2>/dev/null | head -1 | tr -d ' ' || true)"
  if [[ -n "$disc" && "$disc" != "0B" && "$disc" != "0" ]]; then
    done_ "磁盘支持 discard（DISC-MAX=$disc），fstrim 有效"
  else
    warn "磁盘不支持 discard —— fstrim 不会回收空间"
    warn "  Proxmox 上需要给硬盘勾选「Discard」，并且 SCSI 控制器为 VirtIO SCSI"
  fi

  [[ $issues -eq 0 ]] && done_ "关键项全部正常" || warn "存在 $issues 项问题（不阻断，但建议先处理）"
}

# ──────────────────────────────────────────────────────────────
# M2 · 通用软件补齐
# ──────────────────────────────────────────────────────────────
m2_common_packages() {
  step "M2 · 通用软件补齐"

  if [[ "$SKIP_UPGRADE" == "1" ]]; then
    skip "SKIP_UPGRADE=1，跳过系统更新"
  else
    info "系统更新（模板做好后每台克隆都省一次全量升级）"
    run sudo -E apt-get update -qq
    run sudo -E apt-get full-upgrade -y -qq
  fi

  # 这几个是【每台克隆机都要】的，装进模板省事：
  #   qemu-guest-agent  不装的话 Proxmox 看不到 VM 的 IP、「关机」按钮无响应
  #   cloud-init        以后想用自动化配置的前提
  info "安装 qemu-guest-agent / cloud-init / 常用工具"
  run sudo -E apt-get install -y -qq qemu-guest-agent cloud-init vim curl wget htop
  run sudo systemctl enable qemu-guest-agent
  done_ "通用软件就绪"
}

# ──────────────────────────────────────────────────────────────
# M3 · 主机名通用化
# ──────────────────────────────────────────────────────────────
m3_hostname() {
  step "M3 · 主机名改为通用名"

  local old
  old="$(hostname)"
  if [[ "$old" == "$TMPL_HOSTNAME" ]]; then
    skip "主机名已是 $TMPL_HOSTNAME"
    return 0
  fi

  info "$old → $TMPL_HOSTNAME"
  run sudo hostnamectl set-hostname "$TMPL_HOSTNAME"
  # /etc/hosts 里的旧名字不改的话，克隆机上 sudo 会有几秒的 DNS 解析延迟
  run sudo sed -i "s/\\b${old}\\b/${TMPL_HOSTNAME}/g" /etc/hosts
  done_ "克隆出来一眼就能看出「这台还没改名」"
}

# ──────────────────────────────────────────────────────────────
# M4 · 网络改回 DHCP（只写文件，不 apply）
# ──────────────────────────────────────────────────────────────
m4_network_dhcp() {
  step "M4 · 网络改回 DHCP"

  if [[ "$KEEP_STATIC_IP" == "1" ]]; then
    warn "KEEP_STATIC_IP=1，保留静态 IP"
    warn "  🔴 所有克隆机会拿到同一个地址，第二台开机就冲突"
    return 0
  fi

  # 网卡名优先取「默认路由走的那块」，比按 en* 前缀猜更可靠：
  # 有多块网卡时，前缀匹配可能选中一块没接线的。
  local nic
  nic="$(ip route show default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  [[ -n "$nic" ]] || nic="$(ip -o link show | awk -F': ' '$2 ~ /^(en|eth)/ {print $2; exit}')"
  [[ -n "$nic" ]] || { warn "探测不到网卡名，跳过网络配置"; return 0; }
  info "网卡：$nic"

  # netplan 目录里可能不止一个文件，多个文件同时定义同一块网卡会互相覆盖。
  local nfiles=()
  shopt -s nullglob
  nfiles=(/etc/netplan/*.yaml /etc/netplan/*.yml)
  shopt -u nullglob
  if [[ ${#nfiles[@]} -gt 1 ]]; then
    warn "/etc/netplan 下有 ${#nfiles[@]} 个配置文件，可能互相覆盖："
    printf '          %s\n' "${nfiles[@]}"
    warn "  本脚本只改 50-cloud-init.yaml，其余请自行确认"
  fi

  local target="/etc/netplan/50-cloud-init.yaml"
  if [[ -f "$target" ]]; then
    info "备份原配置 → ${target}.bak-${TS}"
    run sudo cp -a "$target" "${target}.bak-${TS}"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[0;36m    [dry] 写入 %s（dhcp4: true, 网卡 %s）\033[0m\n' "$target" "$nic"
  else
    sudo tee "$target" > /dev/null <<EOF
network:
  version: 2
  ethernets:
    ${nic}:
      dhcp4: true
EOF
    # 权限不是 600 的话 netplan 每次都会打印一行 world-readable 告警
    sudo chmod 600 "$target"
  fi

  # 只 generate 校验语法，【绝不 apply】——
  # apply 会立刻切换 IP，当前 SSH 连接会被断开，脚本随之被杀。
  if run sudo netplan generate; then
    done_ "netplan 语法校验通过（故意不 apply，下次开机生效）"
  else
    die "netplan 语法校验失败，请检查 $target"
  fi
}

# ──────────────────────────────────────────────────────────────
# M5 · 去身份化（核心）
# ──────────────────────────────────────────────────────────────
m5_deidentify() {
  step "M5 · 去身份化"

  # ── ① machine-id ─────────────────────────────────────────
  # 必须 truncate 而不是 rm：systemd 在启动早期就要读这个文件，
  # 文件不存在会导致部分服务启动异常。
  # 「文件存在但内容为空」是 systemd 认识的特殊状态 → 首次启动自动生成新的。
  info "清空 /etc/machine-id（truncate，不是 rm）"
  run sudo truncate -s 0 /etc/machine-id
  run sudo rm -f /var/lib/dbus/machine-id
  run sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
  done_ "machine-id 已清空 —— 这是最关键的一步"

  # ── ② SSH 主机密钥 + 首次启动重建兜底 ────────────────────
  # 🔴 文档里常见的说法是「首次启动会自动重新生成」，但那依赖 cloud-init
  #    恰好正常跑起来。万一没跑，sshd 因为没有主机密钥【起不来】，
  #    克隆机就只能靠 noVNC 抢救。所以这里装一个 systemd 兜底服务。
  info "安装首次启动重建 SSH 主机密钥的兜底服务"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[0;36m    [dry] 写入 /etc/systemd/system/regenerate-ssh-host-keys.service\033[0m\n'
  else
    sudo tee /etc/systemd/system/regenerate-ssh-host-keys.service > /dev/null <<'EOF'
[Unit]
Description=Regenerate SSH host keys if missing (first boot after sysprep)
# 密钥存在时 Condition 不成立，本服务直接跳过 —— 天然幂等，无需自我禁用
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
Before=ssh.service ssh.socket
DefaultDependencies=no
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF
  fi
  run sudo systemctl daemon-reload
  run sudo systemctl enable regenerate-ssh-host-keys.service

  info "删除 SSH 主机密钥"
  run sudo sh -c 'rm -f /etc/ssh/ssh_host_*'
  warn "从现在起【不要重启 sshd】—— 主机密钥已删，重启会导致 SSH 服务起不来"
  done_ "克隆机首次启动会各自生成唯一指纹"

  # ── ③ cloud-init 状态 ────────────────────────────────────
  info "清理 cloud-init 状态"
  run sudo cloud-init clean --logs --seed 2>/dev/null || true

  # 🔴 一个隐藏假设：Ubuntu Server 的 ISO 安装器（subiquity）会写下
  #    datasource_list: [None]，意思是「不要去任何地方找配置」。
  #    这个模板在 Proxmox 上【读不到】Cloud-Init 标签页注入的配置盘 ——
  #    你会发现界面上填了用户名和 IP，开机后一点反应都没有。
  local ds_files ds_none=0 f
  ds_files="$(sudo grep -rls 'datasource_list' /etc/cloud/cloud.cfg.d/ 2>/dev/null || true)"
  if [[ -n "$ds_files" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      sudo grep -Eqs 'datasource_list.*None' "$f" && ds_none=1
    done <<< "$ds_files"
  fi
  if [[ $ds_none -eq 1 ]]; then
    if [[ "$ENABLE_PVE_CLOUDINIT" == "1" ]]; then
      info "打开 Proxmox Cloud-Init 支持（ENABLE_PVE_CLOUDINIT=1）"
      if [[ $DRY_RUN -eq 0 ]]; then
        sudo tee /etc/cloud/cloud.cfg.d/90-pve-datasource.cfg > /dev/null <<'EOF'
# 允许 cloud-init 读取 Proxmox 注入的 ConfigDrive / NoCloud 配置盘。
# 不加这个的话，subiquity 写下的 datasource_list: [None] 会让
# Proxmox 网页 Cloud-Init 标签页里填的内容完全不生效。
datasource_list: [ NoCloud, ConfigDrive, None ]
EOF
      fi
      done_ "已允许 NoCloud / ConfigDrive 数据源"
    else
      warn "检测到 datasource_list 含 None（ISO 安装器写的）："
      printf '%s\n' "$ds_files" | sed 's/^/          /'
      warn "  这意味着 Proxmox 网页「Cloud-Init」标签页填的配置【不会生效】"
      warn "  以后想用它自动配 IP/用户，重跑：ENABLE_PVE_CLOUDINIT=1 ./sysprep.sh"
    fi
  fi

  # ── ④ 其他每台该唯一的状态 ───────────────────────────────
  # random-seed  克隆机继承同一个熵种子，systemd 启动时本会重播一次
  # DHCP 租约    不清的话克隆机会先尝试续租模板那个地址
  info "清理随机种子与 DHCP 租约"
  run sudo rm -f /var/lib/systemd/random-seed
  run sudo sh -c 'rm -f /var/lib/dhcp/* /var/lib/NetworkManager/*.lease' 2>/dev/null || true
  done_ "唯一状态清理完成"
}

# ──────────────────────────────────────────────────────────────
# M6 · 清理（日志 / 缓存 / 历史）
# ──────────────────────────────────────────────────────────────
m6_cleanup() {
  step "M6 · 清理日志与缓存"

  # 顺序不能换：先卸载无用包，再清缓存。
  # 反过来的话，autoremove 会把待卸载包的 deb 又拉回缓存目录。
  info "apt 清理"
  run sudo -E apt-get autoremove --purge -y -qq
  run sudo -E apt-get clean
  # 清掉包索引能省几十 MB，克隆机首次 apt install 前跑一次 apt update 即可
  run sudo sh -c 'rm -rf /var/lib/apt/lists/*'

  info "清空 journal"
  run sudo journalctl --rotate
  run sudo journalctl --vacuum-time=1s

  # 🔴 排除 /var/log/journal：那里是 journald 的二进制文件，
  #    truncate 成 0 会让 journald 报错（上面的 vacuum 已经处理过它们了）。
  info "清空 /var/log 下的文本日志"
  run sudo find /var/log -type f -not -path '/var/log/journal/*' -exec truncate -s 0 {} +

  # shell 历史。脚本是子进程，清不掉调用者当前会话的内存历史，
  # 但 bash 只在【正常 exit】时回写文件，而我们最后是 shutdown（SIGTERM），
  # 所以文件不会被重新写回。
  info "清空 shell 历史"
  run sudo sh -c 'rm -f /root/.bash_history /root/.python_history'
  if [[ -n "$TARGET_HOME" ]]; then
    run sudo sh -c "rm -f '${TARGET_HOME}/.bash_history' '${TARGET_HOME}/.python_history'"
    run sudo sh -c "rm -f '${TARGET_HOME}/.ssh/known_hosts'"
  fi

  info "清空临时目录"
  run sudo sh -c 'rm -rf /tmp/* /var/tmp/*' 2>/dev/null || true

  done_ "清理完成"
}

# ──────────────────────────────────────────────────────────────
# M7 · fstrim
# ──────────────────────────────────────────────────────────────
m7_fstrim() {
  step "M7 · fstrim 回收空间"

  # 必须放在所有删除动作【之后】：fstrim 只把"已删除但底层还占着"的块
  # 还给 LVM-Thin 池。先 trim 后删就白做了。
  #
  # 价值：模板会被克隆很多次。模板本身变小 → 之后每一份完整克隆都跟着变小。
  info "把已删除的块还给 LVM-Thin 池"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[0;36m    [dry] sudo fstrim -av\033[0m\n'
  else
    sudo fstrim -av || warn "fstrim 未完全成功（磁盘可能没开 Discard）"
  fi
  done_ "空间回收完成"
}

# ──────────────────────────────────────────────────────────────
# M8 · 报告与关机
# ──────────────────────────────────────────────────────────────
m8_report() {
  echo
  printf '\033[1;32m════════════════ 去身份化完成 ════════════════\033[0m\n'
  printf '  %-16s %s\n' "主机名"      "$(hostname)"
  printf '  %-16s %s\n' "machine-id"  "$([[ -s /etc/machine-id ]] && echo '🔴 非空（清理未生效）' || echo '空 ✓ 首次启动重新生成')"
  local hk=()
  shopt -s nullglob
  hk=(/etc/ssh/ssh_host_*)
  shopt -u nullglob
  printf '  %-16s %s\n' "SSH 主机密钥" "${#hk[@]} 个（应为 0）"
  printf '  %-16s %s\n' "网络"        "$([[ "$KEEP_STATIC_IP" == "1" ]] && echo '静态（保留）' || echo 'DHCP（下次开机生效）')"
  printf '  %-16s %s\n' "根分区占用"  "$(df -h / | awk 'NR==2{print $3" / "$2}')"
  printf '  %-16s %s\n' "日志占用"    "$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[A-Z]' | head -1 || echo '-')"
  printf '\033[1;32m══════════════════════════════════════════════\033[0m\n'
  echo

  info "关机后在 Proxmox 网页上继续："
  info "  ① 右键这台 VM → 克隆 → VMID 9000 / 名称 tmpl-ubuntu-2404 / 【完整克隆】"
  info "  ② 右键 9000 → 转换成模板（🔴 不可逆）"
  info "  ③ 9000 → 选项 → 保护 → 是（防误删）"
  info "  ④ 本机开机后改回自己的 hostname 和静态 IP，即可作为第一台业务机使用"
  echo
  warn "已删除 SSH 主机密钥，本机重新开机后 SSH 指纹会变，Mac 上需要执行："
  warn "    ssh-keygen -R <这台机器的IP>"
  echo

  if [[ $NO_SHUTDOWN -eq 1 ]]; then
    warn "--no-shutdown / --dry-run：未关机。请自行 sudo shutdown -h now"
    return 0
  fi

  local i
  for i in 10 9 8 7 6 5 4 3 2 1; do
    printf '\r\033[1;31m  %2d 秒后关机（Ctrl+C 取消）\033[0m' "$i"
    sleep 1
  done
  printf '\r\033[1;31m  正在关机…\033[0m                    \n'
  sudo shutdown -h now
}

# ──────────────────────────────────────────────────────────────
main() {
  m0_precheck
  m1_precheck_quality
  m2_common_packages
  m3_hostname
  m4_network_dhcp
  m5_deidentify
  m6_cleanup
  m7_fstrim
  m8_report
}

main "$@"
