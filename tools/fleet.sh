#!/usr/bin/env bash
#
# fleet.sh —— 在 Mac 上批量操作家里的虚拟机
#
# 用途：把仓库里的脚本推送到多台 VM 并执行，或直接在多台机器上跑命令。
#
# 为什么是「从 Mac 推」而不是「VM 自己 git clone」：
#   1. raw.githubusercontent.com 在国内网络实测不可达（直连和走代理都被重置），
#      VM 上 curl 拉脚本这条路走不通
#   2. 私有仓库要在【每台 VM 上放凭证】—— 和"私钥不进模板"的原则冲突
#   3. 推的是你本地【当前】版本，改完立刻能测，不用先 commit + push
#   4. VM 不需要任何外网连通性，代理挂了照样能维护
#
# 用法：
#   ./fleet.sh list                              列出机器清单与在线状态
#   ./fleet.sh push [目标...]                     把【整个仓库】推送到远端 ~/homelab/
#   ./fleet.sh exec [目标...] -- <命令>            在目标上执行命令
#   ./fleet.sh run  [目标...] -- <脚本路径> [参数]  推送后执行；路径相对仓库根
#
# 目标可以是：hosts.conf 里的机器名 / 分组名 / all / 直接写 IP
#   省略目标 = all
#
# 例：
#   ./fleet.sh list
#   ./fleet.sh exec -- 'uptime'
#   ./fleet.sh exec vm-router -- 'sudo systemctl status mihomo'
#   ./fleet.sh run 192.168.5.123 -- 01-infrastructure/scripts/init-clone.sh \
#                                       --hostname vm-router --ip 192.168.5.2 --router
#   ./fleet.sh run all -- 01-infrastructure/scripts/fix-root-residue.sh --check
#
# 选项：
#   --user <name>   SSH 用户，默认 jing
#   --serial        串行执行（默认并行）
#   --dry-run       fleet 自己空跑：只列出会连哪些机器，【不连接】
#
# 🔴 -- 后面的参数【原样透传】给远端，不会被 fleet 解析。所以：
#      ./fleet.sh --dry-run run vm-router -- init-clone.sh ...   fleet 空跑，不连机器
#      ./fleet.sh run vm-router -- init-clone.sh ... --dry-run   真的连上去，让【远端脚本】空跑
#
# 注意：本脚本要在 Mac 上运行，且 Mac 只有 bash 3.2 —— 不能用关联数组 / mapfile。
#
set -uo pipefail

# ──────────────────────────────────────────────────────────────
# 全局
# ──────────────────────────────────────────────────────────────
# 本脚本在 tools/ 下，仓库根是它的上一级
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly HOSTS_FILE="${REPO_ROOT}/tools/hosts.conf"
readonly REMOTE_DIR="homelab"

SSH_USER="${FLEET_USER:-jing}"
SERIAL=0
DRY_RUN=0

readonly SSH_OPTS="-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

step()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '\033[1;33m    [warn] %s\033[0m\n' "$*"; }
die()   { printf '\033[1;31m\n  [错误] %s\n\033[0m\n' "$*" >&2; exit 2; }
usage() { sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ──────────────────────────────────────────────────────────────
# 清单解析
# ──────────────────────────────────────────────────────────────
# hosts.conf 每行：  名称  地址  分组1,分组2
# 以 # 开头和空行忽略。
#
# bash 3.2 没有关联数组，所以不做 name→addr 的哈希表，
# 每次需要时重新扫一遍文件 —— 家里十几台机器，性能完全无所谓。
read_hosts() {
  [[ -f "$HOSTS_FILE" ]] || die "找不到清单文件 $HOSTS_FILE"
  grep -vE '^[[:space:]]*(#|$)' "$HOSTS_FILE"
}

# 把目标参数解析成 "名称 地址" 的行。
# 目标可以是机器名、分组名、all，或者直接是一个 IP（用于还没进清单的新机器）。
resolve_targets() {
  local out="" t name addr groups matched
  if [[ $# -eq 0 ]]; then set -- all; fi

  for t in "$@"; do
    # 直接给 IP 的情况：不查清单，原样使用
    if [[ "$t" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      out="${out}${t} ${t}"$'\n'
      continue
    fi
    matched=0
    while read -r name addr groups; do
      [[ -n "$name" ]] || continue
      if [[ "$t" == "all" || "$t" == "$name" ]] \
         || printf '%s' ",${groups}," | grep -q ",${t},"; then
        out="${out}${name} ${addr}"$'\n'
        matched=1
      fi
    done <<< "$(read_hosts)"
    [[ $matched -eq 1 ]] || die "目标 '$t' 在 $HOSTS_FILE 里找不到（也不是合法 IP）"
  done

  # 去重，保持顺序
  printf '%s' "$out" | awk 'NF && !seen[$0]++'
}

# ──────────────────────────────────────────────────────────────
# 并行执行框架
# ──────────────────────────────────────────────────────────────
# 每台机器的输出先写到临时文件，全部结束后按顺序打印 ——
# 否则并行输出会交错成一团看不懂。
FAILED_HOSTS=""
OK_COUNT=0
FAIL_COUNT=0

fan_out() {
  local targets="$1"; shift
  local worker="$1"; shift        # 函数名，参数为 (name addr 其余...)

  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/fleet.XXXXXX")" || die "创建临时目录失败"

  local name addr i=0
  local names=()

  while read -r name addr; do
    [[ -n "$name" ]] || continue
    names[$i]="$name $addr"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '\033[0;36m    [dry] %s (%s)\033[0m\n' "$name" "$addr"
      echo 0 > "${tmpdir}/${i}.rc"; : > "${tmpdir}/${i}.out"
    elif [[ $SERIAL -eq 1 ]]; then
      "$worker" "$name" "$addr" "$@" > "${tmpdir}/${i}.out" 2>&1
      echo $? > "${tmpdir}/${i}.rc"
    else
      (
        "$worker" "$name" "$addr" "$@" > "${tmpdir}/${i}.out" 2>&1
        echo $? > "${tmpdir}/${i}.rc"
      ) &
    fi
    i=$((i + 1))
  done <<< "$targets"

  [[ $SERIAL -eq 0 && $DRY_RUN -eq 0 ]] && wait

  local n=0 rc
  while [[ $n -lt $i ]]; do
    set -- ${names[$n]}
    name="$1"; addr="$2"
    rc="$(cat "${tmpdir}/${n}.rc" 2>/dev/null || echo 1)"
    if [[ "$rc" == "0" ]]; then
      printf '\n\033[0;32m── %s (%s) ── ✓\033[0m\n' "$name" "$addr"
      OK_COUNT=$((OK_COUNT + 1))
    else
      printf '\n\033[1;31m── %s (%s) ── ✗ 退出码 %s\033[0m\n' "$name" "$addr" "$rc"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_HOSTS="${FAILED_HOSTS}${name} "
    fi
    sed 's/^/  /' "${tmpdir}/${n}.out" 2>/dev/null
    n=$((n + 1))
  done

  rm -rf "$tmpdir"
}

summary() {
  echo
  if [[ $FAIL_COUNT -eq 0 ]]; then
    printf '\033[1;32m════ 全部成功：%d 台 ════\033[0m\n' "$OK_COUNT"
  else
    printf '\033[1;31m════ 成功 %d 台，失败 %d 台 ════\033[0m\n' "$OK_COUNT" "$FAIL_COUNT"
    printf '  失败：%s\n' "$FAILED_HOSTS"
  fi
  [[ $FAIL_COUNT -eq 0 ]]
}

# ──────────────────────────────────────────────────────────────
# worker：具体动作
# ──────────────────────────────────────────────────────────────
w_push() {
  local name="$1" addr="$2"
  # -a 保权限（脚本的可执行位）；--delete 让远端和本地严格一致，
  # 避免删掉的脚本还留在机器上被误用。
  #
  # 🔴 排除项是【安全边界】，不是优化：
  #    *.local.env  控制台密码等机密，只该留在 Mac 上
  #    providers/   节点文件，含服务器地址和密码
  #    config.yaml  渲染产物，含上面两者的内容
  #    这三类由各服务自己的部署脚本【定向】投递到需要的那一台，
  #    不能跟着仓库广播给所有机器。
  rsync -a --delete \
        -e "ssh ${SSH_OPTS}" \
        --exclude '.git' \
        --exclude '*.bak-*' \
        --exclude '*.local.env' \
        --exclude 'providers/' \
        --exclude 'config.yaml' \
        "${REPO_ROOT}/" "${SSH_USER}@${addr}:~/${REMOTE_DIR}/" \
    && echo "已同步仓库 → ~/${REMOTE_DIR}/"
}

w_exec() {
  local name="$1" addr="$2"; shift 2
  # shellcheck disable=SC2029  # 命令要在【远端】展开，这里就是要传字符串过去
  ssh ${SSH_OPTS} "${SSH_USER}@${addr}" "$*"
}

w_run() {
  local name="$1" addr="$2"; shift 2
  local script="$1"; shift
  w_push "$name" "$addr" > /dev/null || return 1
  # 脚本路径相对仓库根，例如 01-infrastructure/scripts/sysprep.sh
  # shellcheck disable=SC2029
  ssh ${SSH_OPTS} "${SSH_USER}@${addr}" "cd ~/${REMOTE_DIR} && ./${script} $*"
}

w_ping() {
  local name="$1" addr="$2"
  if ssh ${SSH_OPTS} "${SSH_USER}@${addr}" 'echo "$(hostname)  $(uptime -p 2>/dev/null || uptime)"' 2>/dev/null; then
    return 0
  fi
  echo "SSH 不通"
  return 1
}

# ──────────────────────────────────────────────────────────────
# 参数解析
# ──────────────────────────────────────────────────────────────
[[ $# -gt 0 ]] || usage

# 🔴 必须【先】按第一个 -- 把命令行切成两半，再解析 fleet 自己的选项。
#    否则 `run host -- script.sh --dry-run` 里那个 --dry-run 会被 fleet 自己
#    吃掉（fleet 也有同名选项），结果只打印一行 [dry] 而根本没连上远端 ——
#    这个坑在真机测试时踩到了。
#
#    分工：--  左边 = fleet 自己的选项、子命令、目标
#          --  右边 = 【原样透传】给远端的命令或脚本参数
LEFT=()
PAYLOAD=()
seen_sep=0
for a in "$@"; do
  if [[ $seen_sep -eq 0 && "$a" == "--" ]]; then seen_sep=1; continue; fi
  if [[ $seen_sep -eq 0 ]]; then LEFT+=("$a"); else PAYLOAD+=("$a"); fi
done

set -- ${LEFT[@]+"${LEFT[@]}"}
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)    SSH_USER="${2:-}"; shift 2 ;;
    --serial)  SERIAL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *)         ARGS+=("$1"); shift ;;
  esac
done

[[ ${#ARGS[@]} -gt 0 ]] || usage
SUBCMD="${ARGS[0]}"
# bash 3.2 下对空数组做 ${arr[@]:1} 会因 set -u 报错，先判长度
TARGETS=()
if [[ ${#ARGS[@]} -gt 1 ]]; then
  TARGETS=("${ARGS[@]:1}")
fi

# ──────────────────────────────────────────────────────────────
main() {
  local list
  case "$SUBCMD" in
    list)
      step "机器清单（${HOSTS_FILE}）"
      printf '  %-14s %-16s %s\n' "名称" "地址" "分组"
      printf '  %-14s %-16s %s\n' "────" "────" "────"
      while read -r n a g; do
        [[ -n "$n" ]] || continue
        printf '  %-14s %-16s %s\n' "$n" "$a" "$g"
      done <<< "$(read_hosts)"
      step "在线状态（SSH 探测）"
      list="$(resolve_targets all)"
      fan_out "$list" w_ping
      summary
      ;;

    push)
      list="$(resolve_targets ${TARGETS[@]+"${TARGETS[@]}"})"
      step "推送仓库 → ~/${REMOTE_DIR}/"
      fan_out "$list" w_push
      summary
      ;;

    exec)
      [[ ${#PAYLOAD[@]} -gt 0 ]] || die "exec 需要在 -- 之后给出命令"
      list="$(resolve_targets ${TARGETS[@]+"${TARGETS[@]}"})"
      step "执行：${PAYLOAD[*]}"
      fan_out "$list" w_exec "${PAYLOAD[@]}"
      summary
      ;;

    run)
      [[ ${#PAYLOAD[@]} -gt 0 ]] || die "run 需要在 -- 之后给出脚本名"
      [[ -f "${REPO_ROOT}/${PAYLOAD[0]}" ]] || die "仓库里没有 ${PAYLOAD[0]}（路径相对仓库根）"
      list="$(resolve_targets ${TARGETS[@]+"${TARGETS[@]}"})"
      step "推送并执行：${PAYLOAD[*]}"
      warn "如果脚本会切换 IP（如 init-clone.sh --apply），SSH 会断开，"
      warn "  退出码 255 属于预期，不代表失败"
      fan_out "$list" w_run "${PAYLOAD[@]}"
      summary
      ;;

    *) die "未知子命令：${SUBCMD}（可用：list / push / exec / run）" ;;
  esac
}

main
