#!/usr/bin/env bash
#
# fix-root-residue.sh —— 修复「误用 root 执行 provision-base.sh」留下的残留，并重新体检
#
# 背景：
#   provision-base.sh 的 M5/M7 装的是【用户级】工具，落点由 $HOME 决定。
#   以 root（或 sudo）执行时会出现两类残留：
#
#     类型 A · 装错了地方   uv / uvx / .npmrc 落到 /root 下，日常用户根本看不到
#     类型 B · 装对了地方但属主错了
#                           nvm 用脚本里显式拼的 $TARGET_HOME 路径，
#                           sudo 执行时目录建在 /home/xxx 下但【属主是 root】，
#                           普通用户没有写权限，nvm install 会失败
#
#   这两类都【不会报错】，只会在你后来敲命令时"找不到"或"permission denied"。
#
# 本脚本做三件事：
#   ① 扫描  —— 列出所有残留，【只报告不删】
#   ② 清理  —— 确认后才动手；删除前逐条打印
#   ③ 体检  —— 清理完重新验证 provision-base.sh 应该装好的每一项是否正常
#
# 用法：
#   ./fix-root-residue.sh              # 扫描 → 交互确认 → 清理 → 体检
#   ./fix-root-residue.sh --check      # 【只体检】，不扫描不清理
#   ./fix-root-residue.sh --dry-run    # 只扫描并列清单，绝不动手
#   ./fix-root-residue.sh --yes        # 跳过交互确认（用于自动化）
#
# 退出码（可作为机器可判定的验证信号）：
#   0  体检全部通过
#   1  体检存在 FAIL 项
#   2  参数错误 / 前置检查不通过
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# 全局变量
# ──────────────────────────────────────────────────────────────
# 体检的对象是【日常使用的那个普通账号】，不是当前执行者。
# 以 jing 直接执行时两者相同；被 sudo 调起时取 SUDO_USER。
readonly TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)"
readonly TARGET_HOME

MODE="fix"          # fix | check | dry-run
ASSUME_YES=0

PASS_N=0
FAIL_N=0
WARN_N=0
FAILED_ITEMS=()

# ──────────────────────────────────────────────────────────────
# 输出辅助（与 provision-base.sh 保持一致的风格）
# ──────────────────────────────────────────────────────────────
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    [warn] %s\033[0m\n' "$*"; }
skip() { printf '\033[0;36m    [skip] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m\n  [错误] %s\n\033[0m\n' "$*" >&2; exit 2; }

# 体检三态。注意用赋值形式自增：
#   (( N++ )) 在 N 为 0 时整体返回 1，set -e 下会直接终止脚本。
ok()   { printf '  \033[0;32m[ ✓ ]\033[0m %-24s %s\n' "$1" "${2:-}"; PASS_N=$((PASS_N + 1)); }
bad()  { printf '  \033[1;31m[ ✗ ]\033[0m %-24s %s\n' "$1" "${2:-}"; FAIL_N=$((FAIL_N + 1)); FAILED_ITEMS+=("$1 —— ${2:-}"); }
soso() { printf '  \033[1;33m[ ! ]\033[0m %-24s %s\n' "$1" "${2:-}"; WARN_N=$((WARN_N + 1)); }

# 以目标用户身份执行命令，并【显式】加载 nvm / go / uv 的环境。
#
# 🔴 为什么不能用 `bash -lc` 靠登录流程自动加载：
#   provision-base.sh 把 nvm 初始化【追加在 ~/.bashrc 里】，
#   而 Ubuntu 默认的 ~/.bashrc 开头第一段就是：
#
#       case $- in *i*) ;; *) return;; esac    # 非交互 shell 直接 return
#
#   `bash -lc` 是【非交互】的，执行到这一行就返回了，后面的 nvm 初始化
#   永远读不到 —— 结果是明明装好的 node 被误判成"没有可用版本"。
#   （go 没这个问题，它在 /etc/profile.d/ 里，login shell 能读到。）
#
#   所以这里不指望登录流程，逐项显式加载。
as_user() {
  sudo -u "$TARGET_USER" -H bash -c '
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    [ -r /etc/profile.d/golang.sh ] && . /etc/profile.d/golang.sh
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    eval "$1"' _ "$1" 2>/dev/null
}

# 探测 uv 实际位置。不同版本官方安装脚本落点不同，
# 只认一个路径会误判成"未安装"（与 provision-base.sh 的 uv_path 同逻辑）。
uv_path_of() {
  local home="$1" c
  for c in "${home}/.local/bin/uv" "${home}/.cargo/bin/uv" \
           "${home}/.uv/bin/uv" /usr/local/bin/uv; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# ──────────────────────────────────────────────────────────────
# 参数解析
# ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   MODE="check"   ;;
    --dry-run) MODE="dry-run" ;;
    --yes|-y)  ASSUME_YES=1   ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（可用：--check / --dry-run / --yes）" ;;
  esac
  shift
done

# ──────────────────────────────────────────────────────────────
# M0 · 前置检查
# ──────────────────────────────────────────────────────────────
m0_precheck() {
  step "M0 · 前置检查"

  # 以 root 执行时 TARGET_USER 会变成 root，那就成了"用 root 体检 root"，
  # 完全查不出问题 —— 恰恰是本脚本要修的那个错误本身。
  if [[ "$TARGET_USER" == "root" ]]; then
    die "$(cat <<'EOM'
不能以 root 身份体检 —— 那样检查的是 /root 而不是日常账号。

  正确用法（用你日常使用的那个账号）：
      su - jing
      cd homelab/scripts && ./fix-root-residue.sh

  确实要指定账号：TARGET_USER=jing ./fix-root-residue.sh
EOM
)"
  fi

  [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] \
    || die "找不到用户 $TARGET_USER 的家目录"

  if ! sudo -n true 2>/dev/null; then
    warn "sudo 需要密码 —— 后面会提示输入（provision-base.sh 本应配好免密，这本身是个体检项）"
  fi

  info "体检对象   $TARGET_USER ($TARGET_HOME)"
  info "运行模式   $MODE"
  info "主机名     $(hostname)"
}

# ──────────────────────────────────────────────────────────────
# M1 · 扫描残留（只报告，不动手）
# ──────────────────────────────────────────────────────────────
# 全局：待清理清单。元素格式 "动作|路径|说明"
RESIDUE=()

m1_scan() {
  step "M1 · 扫描 root 残留"

  local p

  # ── 类型 A：用户级工具被装进了 /root ──────────────────────
  for p in /root/.local/bin/uv /root/.local/bin/uvx \
           /root/.local/share/uv /root/.local/bin/pipx \
           /root/.npmrc /root/.nvm; do
    if sudo test -e "$p"; then
      RESIDUE+=("rm|$p|用户级工具被装进 root 家目录，日常账号用不到")
    fi
  done

  # ── 类型 B：装在正确位置但属主是 root ────────────────────
  # 只要目录里存在【任意一个】非目标用户属主的文件，整棵树就要改属主。
  for p in "$TARGET_HOME/.nvm" "$TARGET_HOME/.local" "$TARGET_HOME/.npm" \
           "$TARGET_HOME/.cache" "$TARGET_HOME/.config"; do
    [[ -e "$p" ]] || continue
    if sudo find "$p" ! -user "$TARGET_USER" -print -quit 2>/dev/null | grep -q .; then
      # 注意 || true：find 碰到不可读目录会返回非 0，
      # set -o pipefail 下整个赋值随之失败，会直接杀掉脚本
      local n
      n="$(sudo find "$p" ! -user "$TARGET_USER" 2>/dev/null | wc -l || true)"
      RESIDUE+=("chown|$p|存在 $n 个非 $TARGET_USER 属主的文件，普通用户无写权限")
    fi
  done

  # ── 类型 C：只提示不处理 ──────────────────────────────────
  # /root/.bashrc 里可能被追加了 NVM_DIR / pipx 段落。
  # 不自动改别人的 rc 文件 —— 那里可能还有你自己加的东西，误删代价高。
  if sudo grep -qs 'NVM_DIR\|pipx' /root/.bashrc 2>/dev/null; then
    warn "/root/.bashrc 里被追加过 NVM_DIR / pipx 初始化段落"
    warn "  无害（root 下本来也用不上），如需彻底干净请手动编辑"
  fi

  if [[ ${#RESIDUE[@]} -eq 0 ]]; then
    skip "没有发现残留"
    return 0
  fi

  echo
  printf '\033[1;33m  发现 %d 项残留：\033[0m\n' "${#RESIDUE[@]}"
  local item action path desc
  for item in "${RESIDUE[@]}"; do
    IFS='|' read -r action path desc <<< "$item"
    case "$action" in
      rm)    printf '    \033[1;31m删除\033[0m  %-34s %s\n' "$path" "$desc" ;;
      chown) printf '    \033[1;33m改属主\033[0m %-33s %s\n' "$path" "$desc" ;;
    esac
  done
}

# ──────────────────────────────────────────────────────────────
# M2 · 清理（先确认，后动手）
# ──────────────────────────────────────────────────────────────
m2_clean() {
  step "M2 · 清理残留"

  # 模块头无论如何都打印：输出里突然少一个 M2 会让人以为脚本挂了
  if [[ ${#RESIDUE[@]} -eq 0 ]]; then
    skip "无残留可清理"
    return 0
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    skip "--dry-run，仅列清单不执行"
    return 0
  fi

  # 删除前必须确认。非交互环境（管道执行）下强制要求 --yes，
  # 否则宁可什么都不做也不擅自删东西。
  if [[ "$ASSUME_YES" != "1" ]]; then
    if [[ ! -t 0 ]]; then
      warn "非交互环境且未指定 --yes，跳过清理（只做体检）"
      return 0
    fi
    local reply=""
    read -r -p "  确认执行上述清理？输入 yes 继续：" reply
    if [[ "$reply" != "yes" ]]; then
      warn "已取消，未做任何修改"
      return 0
    fi
  fi

  local item action path desc
  for item in "${RESIDUE[@]}"; do
    IFS='|' read -r action path desc <<< "$item"
    case "$action" in
      rm)
        info "删除 $path"
        sudo rm -rf "$path"
        ;;
      chown)
        info "改属主 $path → ${TARGET_USER}:${TARGET_USER}"
        sudo chown -R "${TARGET_USER}:${TARGET_USER}" "$path"
        ;;
    esac
  done

  info "清理完成，共处理 ${#RESIDUE[@]} 项"
}

# ──────────────────────────────────────────────────────────────
# M3 · 体检 · 系统基础
# ──────────────────────────────────────────────────────────────
m3_check_system() {
  step "M3 · 体检 · 系统基础"

  local v
  v="$(. /etc/os-release && echo "$PRETTY_NAME")"
  case "$v" in
    *24.04*) ok "系统版本" "$v" ;;
    *)       soso "系统版本" "$v（脚本按 24.04 设计）" ;;
  esac

  v="$(timedatectl show -p Timezone --value)"
  [[ "$v" == "Asia/Shanghai" ]] && ok "时区" "$v" || bad "时区" "$v（应为 Asia/Shanghai）"

  v="$(timedatectl show -p NTPSynchronized --value)"
  [[ "$v" == "yes" ]] && ok "NTP 时间同步" "yes" || soso "NTP 时间同步" "$v（刚开机可能还没同步上）"

  # 默认 target 必须是 multi-user：graphical 会拉起 Xorg 白占内存。
  v="$(systemctl get-default)"
  [[ "$v" == "multi-user.target" ]] && ok "默认 target" "$v" || bad "默认 target" "$v（应为 multi-user.target）"

  # apt 源：PVE 9 / Ubuntu 24.04 用 deb822 格式的 .sources，不是老的 .list
  if grep -qs 'mirrors\.tuna\.tsinghua\.edu\.cn' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null; then
    ok "apt 镜像源" "清华 (deb822)"
  elif grep -rqs 'tuna\|ustc\|aliyun' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    ok "apt 镜像源" "国内镜像"
  else
    soso "apt 镜像源" "未使用国内镜像（SKIP_MIRROR=1 跑过？）"
  fi

  # journald 上限：不限制的话日志能吃掉几个 G
  if grep -rqs 'SystemMaxUse' /etc/systemd/journald.conf.d/ 2>/dev/null; then
    ok "journald 上限" "$(grep -rhs 'SystemMaxUse' /etc/systemd/journald.conf.d/ | head -1)"
  else
    bad "journald 上限" "未配置"
  fi
  info "    └─ 当前日志占用 $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[A-Z]' | head -1 || echo '?')"

  # sudo 免密
  if sudo -n true 2>/dev/null; then
    ok "sudo 免密" "生效"
  else
    bad "sudo 免密" "未生效（/etc/sudoers.d/ 里的规则没写对？）"
  fi

  # DNS 分两层看：
  #   配置层  provision-base.sh 写的 systemd-resolved drop-in 还在不在
  #   运行时  resolvectl 实际生效的服务器地址
  # 只查 `resolvectl status | grep 'DNS Servers'` 不可靠 —— 不同版本的输出
  # 措辞不一样（Current DNS Server / DNS Servers / 按 Link 分段），容易误报。
  local dns_file="/etc/systemd/resolved.conf.d/10-cn-dns.conf"
  [[ -f "$dns_file" ]] && ok "DNS 兜底配置" "$(grep -m1 '^DNS=' "$dns_file" 2>/dev/null || echo "$dns_file")" \
    || bad "DNS 兜底配置" "缺 $dns_file"

  local dns_rt
  dns_rt="$( { resolvectl dns 2>/dev/null; resolvectl status 2>/dev/null; } \
             | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | paste -sd' ' - || true)"
  [[ -n "$dns_rt" ]] && ok "DNS 运行时" "$dns_rt" \
    || soso "DNS 运行时" "resolvectl 读不到（这台机器没用 systemd-resolved？）"

  # QEMU guest agent：不装的话 Proxmox 看不到 IP、「关机」按钮无响应
  if systemctl is-enabled --quiet qemu-guest-agent 2>/dev/null; then
    ok "qemu-guest-agent" "已启用"
  else
    soso "qemu-guest-agent" "未启用（sysprep.sh 会装）"
  fi
}

# ──────────────────────────────────────────────────────────────
# M4 · 体检 · 工具链
# ──────────────────────────────────────────────────────────────
m4_check_tools() {
  step "M4 · 体检 · 运维 / 研发工具"

  local missing=() c
  for c in htop btop ncdu mtr tcpdump nmap rsync iostat smartctl tmux; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] && ok "运维工具" "齐全" \
    || soso "运维工具" "缺 ${missing[*]}"

  missing=()
  for c in git jq rg yq gcc make; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done

  # fd 和 bat 在 Ubuntu 里被改名成 fdfind / batcat（避免和别的包冲突），
  # provision-base.sh 的 M4 会建软链恢复常用名。两个名字都认：
  # 本体在但软链没建成时，要说清是【软链】的问题，而不是笼统报"缺"
  local pair short real
  for pair in fd:fdfind bat:batcat; do
    short="${pair%%:*}"; real="${pair##*:}"
    if command -v "$short" >/dev/null 2>&1; then
      :
    elif command -v "$real" >/dev/null 2>&1; then
      soso "$short 命令名" "本体 $real 已装，但 /usr/local/bin/$short 软链没建成"
    else
      missing+=("$short")
    fi
  done

  [[ ${#missing[@]} -eq 0 ]] && ok "研发工具" "齐全" \
    || soso "研发工具" "缺 ${missing[*]}"

  command -v yq >/dev/null 2>&1 \
    && ok "yq" "$(yq --version 2>/dev/null | awk '{print $NF}')" \
    || bad "yq" "未安装（M4 下载失败？）"
}

# ──────────────────────────────────────────────────────────────
# M5 · 体检 · 语言运行时（重点：必须在目标用户名下，且属主正确）
# ──────────────────────────────────────────────────────────────
m5_check_lang() {
  step "M5 · 体检 · 语言运行时"

  # ── Python ────────────────────────────────────────────────
  # || true 不能省：python3 不存在时返回 127，pipefail 会让赋值失败并终止脚本，
  # 结果就是下面这条"未安装"的 FAIL 永远走不到 —— 该报错的时候反而崩了
  local v
  v="$(python3 --version 2>/dev/null | awk '{print $2}' || true)"
  [[ -n "$v" ]] && ok "python3" "$v" || bad "python3" "未安装"

  if as_user 'command -v pipx' >/dev/null; then
    ok "pipx" "$(as_user 'pipx --version' || echo '?')"
  else
    bad "pipx" "$TARGET_USER 的 PATH 里没有 pipx"
  fi

  # 🔴 这一项就是 root 误跑的直接症状：
  #    uv 装到了 /root/.local/bin，日常账号 command -v uv 什么也找不到。
  local up uv_ver
  if up="$(uv_path_of "$TARGET_HOME")"; then
    uv_ver="$("$up" --version 2>/dev/null | awk '{print $2}' || true)"
    ok "uv" "${uv_ver:-版本读取失败} ($up)"
  elif sudo test -x /root/.local/bin/uv; then
    bad "uv" "🔴 只存在于 /root/.local/bin —— 正是 root 误跑的残留"
  else
    bad "uv" "未安装"
  fi

  # ── Go ────────────────────────────────────────────────────
  if [[ -x /usr/local/go/bin/go ]]; then
    ok "go" "$(/usr/local/go/bin/go version | awk '{print $3}')"
    [[ -f /etc/profile.d/golang.sh ]] \
      && ok "go 环境变量" "/etc/profile.d/golang.sh" \
      || bad "go 环境变量" "缺 /etc/profile.d/golang.sh，登录后 PATH 里没有 go"
    # GOPROXY 走国内镜像，否则 go mod download 会卡到超时
    if as_user 'go env GOPROXY' 2>/dev/null | grep -qs 'goproxy.cn'; then
      ok "GOPROXY" "goproxy.cn"
    else
      soso "GOPROXY" "$(as_user 'go env GOPROXY' 2>/dev/null || echo '读不到')"
    fi
  else
    bad "go" "未安装"
  fi

  # ── Node.js ───────────────────────────────────────────────
  # 属主检查放在版本检查【之前】：属主错了的话 nvm 命令本身可能还能跑，
  # 但 nvm install 会 permission denied —— 属于"看着正常实际坏了"。
  if [[ -d "$TARGET_HOME/.nvm" ]]; then
    if sudo find "$TARGET_HOME/.nvm" ! -user "$TARGET_USER" -print -quit 2>/dev/null | grep -q .; then
      bad "nvm 目录属主" "🔴 ~/.nvm 下存在 root 属主文件，nvm install 会失败"
    else
      ok "nvm 目录属主" "$TARGET_USER"
    fi
    # 直接看 nvm 的版本目录，比依赖 shell 初始化可靠 ——
    # 这样能把"根本没装"和"装了但 shell 里加载不到"区分开，
    # 两者的修法完全不同（前者重跑 provision，后者查 ~/.bashrc）
    local nvm_installed
    nvm_installed="$(ls -1 "$TARGET_HOME/.nvm/versions/node" 2>/dev/null | tr '\n' ' ' || true)"
    v="$(as_user 'node --version' || true)"
    if [[ -n "$v" ]]; then
      ok "node" "$v"
    elif [[ -n "$nvm_installed" ]]; then
      bad "node" "已装 ${nvm_installed% }，但 $TARGET_USER 的 shell 里加载不到（查 ~/.bashrc 的 nvm 段）"
    else
      bad "node" "nvm 已装但一个 Node 版本都没有"
    fi
    v="$(as_user 'npm --version' || true)"
    [[ -n "$v" ]] && ok "npm" "$v" || soso "npm" "读不到版本"
    if as_user 'npm config get registry' 2>/dev/null | grep -qs 'npmmirror'; then
      ok "npm registry" "npmmirror"
    else
      soso "npm registry" "$(as_user 'npm config get registry' 2>/dev/null || echo '读不到')"
    fi
  else
    bad "nvm" "未安装于 $TARGET_HOME/.nvm"
  fi

  # ── 家目录属主兜底检查 ────────────────────────────────────
  # 🔴 || true 是必须的：head -5 读够就退出，find 会吃到 SIGPIPE 返回 141，
  #    pipefail 下整个赋值失败 → set -e 杀掉脚本。而触发条件恰好是
  #    "root 属主文件超过 5 个"，也就是最需要报错的那种情况
  local dirty
  dirty="$(sudo find "$TARGET_HOME" -maxdepth 3 ! -user "$TARGET_USER" 2>/dev/null | head -5 || true)"
  if [[ -n "$dirty" ]]; then
    bad "家目录属主" "仍存在非 $TARGET_USER 属主的文件"
    printf '%s\n' "$dirty" | sed 's/^/          /'
  else
    ok "家目录属主" "$TARGET_HOME 下全部属于 $TARGET_USER"
  fi

  # ── /root 残留兜底检查 ────────────────────────────────────
  local leftover=()
  local p
  for p in /root/.local/bin/uv /root/.local/bin/uvx /root/.npmrc /root/.nvm; do
    sudo test -e "$p" && leftover+=("$p")
  done
  [[ ${#leftover[@]} -eq 0 ]] && ok "/root 无残留" "" \
    || bad "/root 残留" "${leftover[*]}"
}

# ──────────────────────────────────────────────────────────────
# M6 · 汇总
# ──────────────────────────────────────────────────────────────
m6_summary() {
  echo
  if [[ $FAIL_N -eq 0 ]]; then
    printf '\033[1;32m════════════════════ 体检通过 ════════════════════\033[0m\n'
  else
    printf '\033[1;31m════════════════════ 体检未通过 ══════════════════\033[0m\n'
  fi
  printf '  通过 \033[0;32m%d\033[0m    告警 \033[1;33m%d\033[0m    失败 \033[1;31m%d\033[0m\n' \
    "$PASS_N" "$WARN_N" "$FAIL_N"

  if [[ $FAIL_N -gt 0 ]]; then
    echo
    printf '  \033[1;31m失败项：\033[0m\n'
    local f
    for f in "${FAILED_ITEMS[@]}"; do
      printf '    · %s\n' "$f"
    done
    echo
    info "多数失败项可以用普通用户重跑 provision-base.sh 修复："
    info "    cd homelab/scripts && ./provision-base.sh"
  fi
  printf '\033[1;3%dm═════════════════════════════════════════════════\033[0m\n' \
    "$([[ $FAIL_N -eq 0 ]] && echo 2 || echo 1)"
  echo

  if [[ $FAIL_N -eq 0 ]]; then
    info "下一步：转模板前执行去身份化 → ./sysprep.sh"
  fi

  [[ $FAIL_N -eq 0 ]]
}

# ──────────────────────────────────────────────────────────────
main() {
  m0_precheck
  if [[ "$MODE" != "check" ]]; then
    m1_scan
    m2_clean
  else
    skip "--check 模式，跳过扫描与清理"
  fi
  m3_check_system
  m4_check_tools
  m5_check_lang
  m6_summary
}

main "$@"
