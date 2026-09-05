#!/usr/bin/env bash
#
# setup-mac-client.sh —— 把一台 Mac 配置成 homelab 的管理终端
#
# 用途：写入 ~/.ssh/config 与 /etc/hosts 的 homelab 段，让你能用
#       `ssh pve` / `ssh vm-dev` 这样的短名字直接免密登录，
#       而不是每次敲 IP 和用户名。
#
# 设计原则：
#   1. 幂等 —— 用 >>> homelab >>> / <<< homelab <<< 标记包住自己的内容，
#      重复执行时先剔除旧块再写新块，不会叠加，也不碰你自己的其他配置
#   2. 只改两个文件 —— 不装任何软件、不改系统设置、不生成密钥
#   3. 先备份 —— 两个文件都存 .bak-<时间戳>，出问题直接 cp 回去
#
# 前提：这台 Mac 的【公钥已经授权在各服务器上】。本脚本不做密钥分发 ——
#      分发是有安全含义的动作，应该由你显式执行 ssh-copy-id。
#      检查方法见 M0 的提示。
#
# 用法：
#   ./setup-mac-client.sh              # 执行
#   ./setup-mac-client.sh --dry-run    # 只打印将要做什么，绝不动手
#   ./setup-mac-client.sh --key ~/.ssh/id_xxx   # 密钥不叫 id_ed25519 时
#   ./setup-mac-client.sh --check      # 只跑验证，不改任何文件
#
# 退出码：0 = 全部成功    1 = 有主机连不上    2 = 前置检查失败
#         ← 机器可判定的验证信号
#
# 🔴 macOS 的 bash 是 3.2（2007 年，因 GPLv3 停留在此版本）：
#    没有关联数组、没有 mapfile。本脚本刻意只用 3.2 兼容语法，
#    这样不依赖用户是否装过 homebrew 的新 bash。
#
set -uo pipefail

# ──────────────────────────────────────────────────────────────
# 失败定位
# ──────────────────────────────────────────────────────────────
# set -e 在函数里触发是【静默】终止的：脚本走到一半突然没了，不打印原因。
# set -E 让 ERR trap 在函数 / 子 shell 里也生效，把"突然没了"变成
# "第 N 行失败，退出码 X"。
_on_err() {
  local rc=$?
  printf '\033[1;31m\n  [中断] 第 %s 行执行失败，退出码 %s\n\033[0m\n' \
    "${BASH_LINENO[0]}" "${rc}" >&2
}
set -E
trap _on_err ERR

# ──────────────────────────────────────────────────────────────
# 全局
# ──────────────────────────────────────────────────────────────
TS="$(date +%Y%m%d-%H%M%S)"
readonly TS
readonly BEGIN_MARK="# >>> homelab >>>"
readonly END_MARK="# <<< homelab <<<"
readonly SSH_CFG="${HOME}/.ssh/config"
readonly HOSTS_FILE="/etc/hosts"

DRY_RUN=0
CHECK_ONLY=0
KEY_PATH="${HOME}/.ssh/id_ed25519"

# 要验证的主机。pve-x99 刻意不放进来 —— 它是【按需开机】的节点，
# 平时关着，连不上属于正常，放进来会让退出码失去意义。
readonly VERIFY_HOSTS="pve vm-router vm-dev vm-media"

# ──────────────────────────────────────────────────────────────
# 输出辅助（与仓库其他脚本保持一致）
# ──────────────────────────────────────────────────────────────
step()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[1;33m    [warn] %s\033[0m\n' "$*"; }
skip()  { printf '\033[0;36m    [skip] %s\033[0m\n' "$*"; }
done_() { printf '\033[0;32m    [ok]   %s\033[0m\n' "$*"; }
dry()   { printf '\033[0;36m    [dry]  %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m\n  [错误] %s\n\033[0m\n' "$*" >&2; exit 2; }

usage() {
  sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ──────────────────────────────────────────────────────────────
# 参数
# ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --check)   CHECK_ONLY=1; shift ;;
    --key)     KEY_PATH="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done
readonly DRY_RUN CHECK_ONLY KEY_PATH

# ──────────────────────────────────────────────────────────────
# 幂等写入：剔除旧的标记块，再追加新块
#
# 🔴 为什么不用 sed -i：macOS 的 sed 是 BSD 版，-i 必须跟一个备份后缀
#    （写 -i '' 才行），和 GNU sed 行为不同，脚本会因机器而异。
#    awk 在两边行为一致。
# ──────────────────────────────────────────────────────────────
strip_block() {
  # $1 = 源文件；输出到 stdout。文件不存在时输出空。
  [[ -f "$1" ]] || return 0
  awk -v b="${BEGIN_MARK}" -v e="${END_MARK}" '
    $0 == b { s = 1 }
    !s      { print }
    $0 == e { s = 0 }
  ' "$1"
}

# ──────────────────────────────────────────────────────────────
# M0 · 前置检查
# ──────────────────────────────────────────────────────────────
m0_precheck() {
  step "M0 · 前置检查"

  [[ "$(uname -s)" == "Darwin" ]] || die "本脚本只适用于 macOS（当前：$(uname -s)）"
  done_ "系统：macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"

  # 🔴 不能用 root 跑：~/.ssh 会落到 /var/root/.ssh，配了等于没配。
  #    需要提权的只有写 /etc/hosts 一处，脚本自己调 sudo。
  [[ "$(id -u)" -ne 0 ]] || die "不要用 sudo 执行整个脚本 —— 需要提权的地方脚本会自己调 sudo"
  done_ "执行用户：$(id -un)"

  if [[ ! -f "${KEY_PATH}" ]]; then
    warn "找不到私钥 ${KEY_PATH}"
    info "  现有密钥："
    ls -1 "${HOME}"/.ssh/*.pub 2>/dev/null | sed 's|^|      |' || info "      （一个都没有）"
    die "用 --key <路径> 指定，或先生成密钥并用 ssh-copy-id 分发"
  fi
  done_ "私钥：${KEY_PATH}"
  if [[ -f "${KEY_PATH}.pub" ]]; then
    info "  指纹：$(ssh-keygen -lf "${KEY_PATH}.pub" | awk '{print $2}')"
  fi
}

# ──────────────────────────────────────────────────────────────
# M1 · ~/.ssh/config
# ──────────────────────────────────────────────────────────────
m1_ssh_config() {
  step "M1 · ~/.ssh/config"

  # ssh_config 是【首次匹配生效】：同一个键先出现的赢。
  # 所以先按角色分别定 User，再用一条公共块补密钥 —— 两者互不覆盖。
  # 这里刻意【不写 HostName】，名字到 IP 的映射统一交给 /etc/hosts，
  # 避免同一份地址在两个文件里各存一份、改了一处忘另一处。
  local block
  block="${BEGIN_MARK}
# 由 tools/setup-mac-client.sh 生成。改这里不如改脚本，否则下次执行会被覆盖。
# 名字→IP 的映射在 /etc/hosts，本段只定用户与密钥。
Host pve pve-x99
    User root

Host vm-*
    User jing

Host vm-* pve pve-x99
    IdentityFile ${KEY_PATH}
    UserKnownHostsFile ~/.ssh/known_hosts_homelab
${END_MARK}"

  local current=""
  [[ -f "${SSH_CFG}" ]] && current="$(cat "${SSH_CFG}")"
  local want
  want="$(strip_block "${SSH_CFG}")
${block}"

  if [[ "${current}" == "${want}" ]]; then
    skip "内容无变化"
    return 0
  fi

  if [[ ${DRY_RUN} -eq 1 ]]; then
    dry "备份 → ${SSH_CFG}.bak-${TS}"
    dry "写入 homelab 段："
    printf '%s\n' "${block}" | sed 's/^/          /'
    return 0
  fi

  mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
  if [[ -f "${SSH_CFG}" ]]; then
    cp -a "${SSH_CFG}" "${SSH_CFG}.bak-${TS}"
    info "已备份 → ${SSH_CFG}.bak-${TS}"
  fi
  printf '%s\n' "${want}" > "${SSH_CFG}"
  chmod 600 "${SSH_CFG}"
  done_ "已写入（$(grep -c '' "${SSH_CFG}") 行）"
}

# ──────────────────────────────────────────────────────────────
# M2 · /etc/hosts
# ──────────────────────────────────────────────────────────────
m2_hosts() {
  step "M2 · /etc/hosts"

  # 🔴 地址必须和 01-infrastructure/02-network.md 的规划表一致，
  #    改了记得两边都改。pve-x99 是按需开机节点，写进来是为了它开机时能直接用。
  local block
  block="${BEGIN_MARK}
# 由 tools/setup-mac-client.sh 生成。地址来源：01-infrastructure/02-network.md
192.168.5.1     zte.home
192.168.5.2     vm-router
192.168.5.8     macmini-wifi
192.168.5.9     macmini
192.168.5.10    pve
192.168.5.11    pve-x99
192.168.5.21    vm-dev
192.168.5.60    vm-media
${END_MARK}"

  local current want
  current="$(cat "${HOSTS_FILE}")"
  want="$(strip_block "${HOSTS_FILE}")
${block}"

  if [[ "${current}" == "${want}" ]]; then
    skip "内容无变化"
    return 0
  fi

  if [[ ${DRY_RUN} -eq 1 ]]; then
    dry "sudo 备份 → ${HOSTS_FILE}.bak-${TS}"
    dry "写入 homelab 段："
    printf '%s\n' "${block}" | sed 's/^/          /'
    return 0
  fi

  info "下面这步需要提权（只改 /etc/hosts 这一个文件）"
  sudo cp -a "${HOSTS_FILE}" "${HOSTS_FILE}.bak-${TS}"
  info "已备份 → ${HOSTS_FILE}.bak-${TS}"

  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "${want}" > "${tmp}"
  # 🔴 用 cat 重定向而不是 mv：mv 会把临时文件的属主和权限带过去，
  #    /etc/hosts 必须保持 root:wheel 644。cat 只改内容，不动 inode 属性。
  sudo sh -c "cat '${tmp}' > '${HOSTS_FILE}'"
  rm -f "${tmp}"

  # macOS 有 DNS 缓存，改完 hosts 不刷新可能几分钟内还解析旧值
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
  done_ "已写入并刷新 DNS 缓存"
}

# ──────────────────────────────────────────────────────────────
# M3 · 验证
# ──────────────────────────────────────────────────────────────
m3_verify() {
  step "M3 · 验证"

  # 🔴 从这里开始关掉 ERR trap。
  #    验证阶段"连不上"是【有意义的结果】而不是错误，本函数也会有意返回 1。
  #    而 set -E 会把 ERR trap 传播进命令替换的子 shell —— 即使
  #    `if out="$(ssh ...)"` 写在条件里，子 shell 里 ssh 的非零退出
  #    仍会触发 trap，导致每台连不上的机器都刷一段"[中断] 第 N 行失败"，
  #    把真正的验证结果淹没掉。
  trap - ERR

  if [[ ${DRY_RUN} -eq 1 ]]; then
    skip "--dry-run，跳过验证"
    return 0
  fi

  info "名字解析："
  local h ip
  for h in ${VERIFY_HOSTS}; do
    ip="$(grep -E "[[:space:]]${h}\$" "${HOSTS_FILE}" | awk '{print $1}' | head -1)"
    printf '      %-12s → %s\n' "${h}" "${ip:-❌ 未解析}"
  done

  info ""
  info "SSH 免密登录："
  local fail=0 out
  for h in ${VERIFY_HOSTS}; do
    printf '      %-12s ' "${h}"
    if out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                  -o ConnectTimeout=6 "${h}" 'hostname' 2>/dev/null)"; then
      printf '\033[0;32m✅ %s\033[0m\n' "${out}"
    else
      printf '\033[1;31m❌ 连不上\033[0m\n'
      fail=$((fail + 1))
    fi
  done

  info ""
  if [[ ${fail} -eq 0 ]]; then
    done_ "全部可达"
    return 0
  fi
  warn "${fail} 台连不上。常见原因："
  info "  · 该机器关机（pve-x99 是按需开机节点，不在本列表内）"
  info "  · 本机公钥没授权到那台机器 → ssh-copy-id -i ${KEY_PATH}.pub <用户>@<IP>"
  info "  · 网络不通 → 先 ping 一下 /etc/hosts 里对应的 IP"
  return 1
}

# ──────────────────────────────────────────────────────────────
# 主流程
# ──────────────────────────────────────────────────────────────
main() {
  printf '\n\033[1;32m═══ homelab · Mac 客户端配置 ═══\033[0m\n'
  [[ ${DRY_RUN}   -eq 1 ]] && warn "--dry-run：不会修改任何文件"
  [[ ${CHECK_ONLY} -eq 1 ]] && warn "--check：只验证，不修改任何文件"

  m0_precheck
  if [[ ${CHECK_ONLY} -eq 0 ]]; then
    m1_ssh_config
    m2_hosts
  else
    skip "M1 / M2 已跳过（--check）"
  fi
  m3_verify
  local rc=$?

  printf '\n'
  if [[ ${DRY_RUN} -eq 1 ]]; then
    # 🔴 干跑模式必须说清"什么都没做"，否则和真跑的结尾长得一样，
    #    容易让人以为已经生效。
    printf '\033[1;33m═══ 干跑结束 —— 未修改任何文件 ═══\033[0m\n'
    info "去掉 --dry-run 再执行一次才会真正写入"
    printf '\n'
    return 0
  fi
  if [[ ${rc} -eq 0 ]]; then
    printf '\033[1;32m═══ 完成 ═══\033[0m\n'
    info "现在可以直接： ssh pve / ssh vm-dev / ssh vm-media"
    info "主机公钥存在 ~/.ssh/known_hosts_homelab（与系统默认分开，"
    info "重装虚拟机后只需清理这一个文件，不影响其他 SSH 目标）"
  else
    printf '\033[1;33m═══ 完成，但有主机连不上（见上）═══\033[0m\n'
  fi
  printf '\n'
  return ${rc}
}

main "$@"
