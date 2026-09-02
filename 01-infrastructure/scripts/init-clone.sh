#!/usr/bin/env bash
#
# init-clone.sh —— 从模板克隆出来的机器，一键完成身份定制
#
# 用途：把一台刚从模板克隆出来的机器（hostname 是 ubuntu-tmpl、网络是 DHCP）
#       定制成规划表里的某一台：改主机名、配静态 IP、按角色加内核参数。
#
# 设计原则：
#   1. 幂等 —— 反复执行安全，已经是目标状态就跳过
#   2. 先验收后定制 —— 定制前先确认这台克隆机的身份是干净的
#      （machine-id 非空、主机密钥是新的、公钥在），
#      不干净就说明模板有问题，这时候定制毫无意义
#   3. 默认不 apply 网络 —— netplan apply 会当场断开 SSH，
#      脚本随之被 SIGHUP 杀掉。要么显式 --apply（异步执行），要么重启生效
#
# 用法：
#   ./init-clone.sh --hostname vm-router --ip 192.168.5.2 --router
#   ./init-clone.sh --hostname vm-media  --ip 192.168.5.60
#   ./init-clone.sh --hostname vm-router --ip 192.168.5.2 --dry-run
#
# 参数：
#   --hostname <name>   目标主机名（必填）
#   --ip <addr>         目标静态 IP，不带掩码（必填）
#   --cidr <n>          掩码位数，默认 24
#   --gw <addr>         网关，默认 <网段>.1
#   --dns <a,b>         DNS，默认 223.5.5.5,119.29.29.29
#   --router            角色：旁路由。额外写 IP 转发与 rp_filter 内核参数
#   --apply             写完立刻应用网络（异步执行，SSH 会断）
#   --force             跳过"这是不是一台干净克隆机"的检查
#   --dry-run           只打印将要做什么，绝不动手
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# 失败定位
# ──────────────────────────────────────────────────────────────
# set -e 在函数里触发时是【静默】终止的：脚本走到一半突然没了，
# 不打印任何原因，排查时只能靠二分注释。
# set -E 让 ERR trap 在函数 / 子 shell / 命令替换里也生效，
# 配合下面这行就能把"突然没了"变成"第 N 行失败，退出码 X"。
_on_err() {
  local rc=$?
  # BASH_LINENO[0] 是【调用方】的行号，也就是真正出错那一行；
  # 在函数里用 $LINENO 只会得到本函数自己的行号，没有意义。
  printf '\033[1;31m\n  [中断] 第 %s 行执行失败，退出码 %s\n\033[0m\n' \
    "${BASH_LINENO[0]}" "$rc" >&2
}
set -E
trap _on_err ERR

# ──────────────────────────────────────────────────────────────
# 全局变量
# ──────────────────────────────────────────────────────────────
TARGET_HOSTNAME=""
TARGET_IP=""
CIDR=24
GATEWAY=""
DNS="223.5.5.5,119.29.29.29"
ROLE_ROUTER=0
DO_APPLY=0
FORCE=0
DRY_RUN=0

TS="$(date +%Y%m%d-%H%M%S)"
readonly TS
readonly NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"
# 模板里的通用主机名。克隆机没改过名的话就是这个。
readonly TMPL_HOSTNAME="ubuntu-tmpl"

# ──────────────────────────────────────────────────────────────
# 输出辅助（与仓库其他脚本保持一致）
# ──────────────────────────────────────────────────────────────
step()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[1;33m    [warn] %s\033[0m\n' "$*"; }
skip()  { printf '\033[0;36m    [skip] %s\033[0m\n' "$*"; }
done_() { printf '\033[0;32m    [ok]   %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m\n  [错误] %s\n\033[0m\n' "$*" >&2; exit 2; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[0;36m    [dry] %s\033[0m\n' "$*"
  else
    "$@"
  fi
}

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ──────────────────────────────────────────────────────────────
# 参数解析
# ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) TARGET_HOSTNAME="${2:-}"; shift 2 ;;
    --ip)       TARGET_IP="${2:-}";       shift 2 ;;
    --cidr)     CIDR="${2:-}";            shift 2 ;;
    --gw)       GATEWAY="${2:-}";         shift 2 ;;
    --dns)      DNS="${2:-}";             shift 2 ;;
    --router)   ROLE_ROUTER=1;            shift   ;;
    --apply)    DO_APPLY=1;               shift   ;;
    --force)    FORCE=1;                  shift   ;;
    --dry-run)  DRY_RUN=1;                shift   ;;
    -h|--help)  usage ;;
    *) die "未知参数：$1（-h 看用法）" ;;
  esac
done

[[ -n "$TARGET_HOSTNAME" ]] || die "缺少 --hostname"
[[ -n "$TARGET_IP" ]]       || die "缺少 --ip"

# 校验 IP 格式，避免把一个错地址写进 netplan 之后连不上
[[ "$TARGET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "IP 格式不对：$TARGET_IP"
# 主机名只允许字母数字和连字符 —— 带下划线或中文会让 systemd 和 DNS 出奇怪问题
[[ "$TARGET_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] \
  || die "主机名不合法：${TARGET_HOSTNAME}（只允许字母数字和连字符，不能以连字符开头结尾）"

# 网关默认取同网段的 .1
[[ -n "$GATEWAY" ]] || GATEWAY="${TARGET_IP%.*}.1"

# ──────────────────────────────────────────────────────────────
# M0 · 前置检查
# ──────────────────────────────────────────────────────────────
m0_precheck() {
  step "M0 · 前置检查"

  [[ $EUID -ne 0 ]] || die "不要用 root 执行 —— 需要提权的地方脚本会自己调 sudo"
  sudo -n true 2>/dev/null || warn "sudo 需要密码，后面会提示输入"

  local nic
  nic="$(ip route show default 2>/dev/null | awk '{print $5}' | head -1 || true)"
  [[ -n "$nic" ]] || nic="$(ip -o link show | awk -F': ' '$2 ~ /^(en|eth)/ {print $2; exit}' || true)"
  [[ -n "$nic" ]] || die "探测不到网卡"
  NIC="$nic"; readonly NIC

  local cur_ip
  cur_ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^192\.168\.' | head -1 || true)"

  info "当前主机名   $(hostname)"
  info "当前 IP      ${cur_ip:-无}"
  info "网卡         $NIC"
  echo
  info "目标主机名   $TARGET_HOSTNAME"
  info "目标 IP      ${TARGET_IP}/${CIDR}"
  info "网关         $GATEWAY"
  info "DNS          $DNS"
  info "角色         $([[ $ROLE_ROUTER -eq 1 ]] && echo '旁路由（额外配置内核转发）' || echo '普通机器')"

  # 🔴 这里必须用 if 而不是 `[[ ... ]] && warn ...`：
  #    后者在条件不成立时返回 1，而它是函数的【最后一条语句】，
  #    函数就返回 1，set -e 会当场终止整个脚本 ——
  #    而且因为 --dry-run 时条件成立、返回 0，空跑测试完全发现不了。
  if [[ $DRY_RUN -eq 1 ]]; then
    warn "--dry-run 模式，以下所有操作只打印不执行"
  fi
}

# ──────────────────────────────────────────────────────────────
# M1 · 克隆机身份验收
# ──────────────────────────────────────────────────────────────
# 🔴 定制之前必须先确认这台机器的身份是【干净且唯一】的。
#    如果 machine-id 是空的、或者主机密钥还是模板那份，
#    说明模板做坏了 —— 这时候改主机名配 IP 毫无意义，
#    机器投产之后才会以极难排查的方式出问题（见 docs/04 §6.2）。
m1_verify_clone() {
  step "M1 · 克隆机身份验收"

  local issues=0

  # ① 是不是一台没定制过的克隆机
  if [[ "$(hostname)" == "$TMPL_HOSTNAME" ]]; then
    done_ "主机名是 $TMPL_HOSTNAME —— 确认是刚克隆、未定制的机器"
  elif [[ "$(hostname)" == "$TARGET_HOSTNAME" ]]; then
    skip "主机名已经是 $TARGET_HOSTNAME —— 本脚本重复执行，继续（幂等）"
  else
    warn "主机名是 $(hostname)，既不是模板名也不是目标名"
    if [[ $FORCE -ne 1 ]]; then
      die "$(printf '这台机器可能不是刚克隆出来的。\n  确认无误请加 --force；否则检查你连的是不是正确的机器。')"
    fi
    warn "--force，继续"
  fi

  # ② machine-id 必须非空 —— 空的说明 systemd 没能重新生成
  local mid
  mid="$(cat /etc/machine-id 2>/dev/null || true)"
  if [[ -n "$mid" && ${#mid} -ge 32 ]]; then
    done_ "machine-id 已生成  $mid"
    info "      └─ 🔴 请自行确认它和其他机器不同（各机应唯一）"
  else
    warn "machine-id 为空或异常 —— 去身份化后 systemd 没能重新生成"
    warn "  修复：sudo systemd-machine-id-setup && sudo reboot"
    issues=$((issues + 1))
  fi

  # ③ SSH 主机密钥必须存在且是本机新生成的
  local hk=()
  shopt -s nullglob
  hk=(/etc/ssh/ssh_host_*_key)
  shopt -u nullglob
  if [[ ${#hk[@]} -ge 3 ]]; then
    done_ "SSH 主机密钥 ${#hk[@]} 个，生成于 $(stat -c %y "${hk[0]}" | cut -d' ' -f1)"
  else
    warn "SSH 主机密钥只有 ${#hk[@]} 个（应有 3 个：rsa/ecdsa/ed25519）"
    warn "  修复：sudo ssh-keygen -A && sudo systemctl restart ssh"
    issues=$((issues + 1))
  fi

  # ④ 公钥必须在 —— 没有的话改完 IP 就可能进不来了
  local ak="$HOME/.ssh/authorized_keys"
  if [[ -s "$ak" ]]; then
    done_ "SSH 公钥 $(grep -c . "$ak") 条"
  else
    warn "没有 authorized_keys —— 改完 IP 后只能用密码从 noVNC 进"
    issues=$((issues + 1))
  fi

  [[ $issues -eq 0 ]] && done_ "身份验收通过" \
    || warn "存在 $issues 项问题（不阻断，但建议先处理）"
}

# ──────────────────────────────────────────────────────────────
# M2 · 主机名
# ──────────────────────────────────────────────────────────────
m2_hostname() {
  step "M2 · 主机名"

  local old
  old="$(hostname)"
  if [[ "$old" == "$TARGET_HOSTNAME" ]]; then
    skip "已经是 $TARGET_HOSTNAME"
    return 0
  fi

  info "$old → $TARGET_HOSTNAME"
  run sudo hostnamectl set-hostname "$TARGET_HOSTNAME"
  # /etc/hosts 里的 127.0.1.1 那行不同步改的话，
  # sudo 每次都要去解析当前主机名、解析失败、等超时 —— 表现为 sudo 卡几秒
  run sudo sed -i "s/\\b${old}\\b/${TARGET_HOSTNAME}/g" /etc/hosts
  done_ "主机名与 /etc/hosts 已同步"
}

# ──────────────────────────────────────────────────────────────
# M3 · 静态 IP
# ──────────────────────────────────────────────────────────────
m3_network() {
  step "M3 · 静态 IP"

  local dns_yaml
  dns_yaml="$(printf '%s' "$DNS" | tr ',' '\n' | sed 's/^/          - /')"

  local desired
  desired="network:
  version: 2
  ethernets:
    ${NIC}:
      dhcp4: false
      addresses: [${TARGET_IP}/${CIDR}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
${dns_yaml}"

  # 幂等：内容没变就不写、不备份、不 apply
  if [[ -f "$NETPLAN_FILE" ]] && [[ "$(sudo cat "$NETPLAN_FILE" 2>/dev/null)" == "$desired" ]]; then
    skip "netplan 配置无变化"
    return 0
  fi

  if [[ -f "$NETPLAN_FILE" ]]; then
    info "备份原配置 → ${NETPLAN_FILE}.bak-${TS}"
    run sudo cp -a "$NETPLAN_FILE" "${NETPLAN_FILE}.bak-${TS}"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf '\033[0;36m    [dry] 写入 %s：\033[0m\n' "$NETPLAN_FILE"
    printf '%s\n' "$desired" | sed 's/^/          /'
  else
    printf '%s\n' "$desired" | sudo tee "$NETPLAN_FILE" > /dev/null
    # 权限不是 600 的话 netplan 每次都会打印 world-readable 告警
    sudo chmod 600 "$NETPLAN_FILE"
  fi

  # generate 只校验语法并生成后端配置，不切换网络
  if run sudo netplan generate; then
    done_ "netplan 语法校验通过"
  else
    die "netplan 语法校验失败，原配置已备份在 ${NETPLAN_FILE}.bak-${TS}"
  fi
}

# ──────────────────────────────────────────────────────────────
# M4 · 旁路由角色：内核转发参数
# ──────────────────────────────────────────────────────────────
m4_router_sysctl() {
  [[ $ROLE_ROUTER -eq 1 ]] || return 0
  step "M4 · 旁路由内核参数"

  local f="/etc/sysctl.d/99-router.conf"
  local desired='# 由 init-clone.sh --router 写入
# 1. 开启 IPv4 转发：允许本机转发【不是发给自己】的包。
#    不开的话内核直接丢弃，客户端表现为"网关不通"。
net.ipv4.ip_forward = 1

# 2. IPv6 同样开启 —— 家里有公网 IPv6，不开会让 IPv6 流量绕过旁路由，
#    出现"IPv4 走代理、IPv6 直连"的分流泄漏。
net.ipv6.conf.all.forwarding = 1

# 3. 关闭反向路径过滤（rp_filter）。
#    严格模式会丢弃"从 A 网卡进、按路由表本该从 B 网卡出"的包，
#    而透明代理的 TUN 模式恰恰会制造这种不对称路径。
#    不关的表现是：能 ping 通网关，但什么网页都打不开，且日志里毫无线索
#    （包在内核里就被静默丢了）。
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0'

  if [[ -f "$f" ]] && [[ "$(sudo cat "$f" 2>/dev/null)" == "$desired" ]]; then
    skip "内核参数无变化"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '\033[0;36m    [dry] 写入 %s\033[0m\n' "$f"
    else
      printf '%s\n' "$desired" | sudo tee "$f" > /dev/null
      sudo sysctl --system > /dev/null
    fi
    done_ "已写入 $f 并生效"
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    info "当前值："
    printf '      ip_forward=%s  ipv6.forwarding=%s  rp_filter=%s\n' \
      "$(sysctl -n net.ipv4.ip_forward)" \
      "$(sysctl -n net.ipv6.conf.all.forwarding)" \
      "$(sysctl -n net.ipv4.conf.all.rp_filter)"
  fi
}

# ──────────────────────────────────────────────────────────────
# M5 · 应用网络与收尾
# ──────────────────────────────────────────────────────────────
m5_apply() {
  step "M5 · 收尾"

  echo
  printf '\033[1;32m════════════════ 定制完成 ════════════════\033[0m\n'
  printf '  %-14s %s\n' "主机名"   "$(hostname)"
  printf '  %-14s %s\n' "目标 IP"  "${TARGET_IP}/${CIDR}"
  printf '  %-14s %s\n' "网关"     "$GATEWAY"
  printf '  %-14s %s\n' "machine-id" "$(cat /etc/machine-id 2>/dev/null || echo '?')"
  printf '\033[1;32m═════════════════════════════════════════\033[0m\n'
  echo

  if [[ $DRY_RUN -eq 1 ]]; then
    warn "--dry-run：什么都没做"
    return 0
  fi

  if [[ $DO_APPLY -eq 1 ]]; then
    warn "即将应用网络配置 —— 【当前 SSH 连接会断开】，这是正常的"
    warn "  重连用：ssh ${SUDO_USER:-$(id -un)}@${TARGET_IP}"
    echo
    # 🔴 必须让 netplan apply 脱离当前 SSH 会话执行。
    #    直接跑的话，IP 一切换连接就断，脚本收到 SIGHUP 被杀，
    #    apply 可能只执行到一半，机器落在一个两不靠的状态。
    #    systemd-run 把它放进一个独立的临时 unit，与 SSH 会话无关。
    sudo systemd-run --collect --no-block \
         --unit="netplan-apply-${TS}" \
         --description="apply netplan from init-clone.sh" \
         netplan apply
    info "已提交异步应用，约 3 秒后生效"
  else
    info "网络配置已写入但【未应用】。二选一："
    info "    立即应用（SSH 会断）：sudo netplan apply"
    info "    或重启生效：          sudo reboot"
    echo
    info "生效后从 Mac 验证：ssh ${SUDO_USER:-$(id -un)}@${TARGET_IP} hostname"
  fi
}

# ──────────────────────────────────────────────────────────────
main() {
  m0_precheck
  m1_verify_clone
  m2_hostname
  m3_network
  m4_router_sysctl
  m5_apply
}

main "$@"
