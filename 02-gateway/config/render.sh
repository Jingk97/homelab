#!/usr/bin/env bash
#
# render.sh —— 把 config.yaml.tmpl 里的 ${...} 占位符换成 mihomo.local.env 的真值
#
#   用法    ./render.sh           渲染出 config.yaml（权限 600）
#           ./render.sh --check   只校验不写文件
#
#   退出码  0 = 成功    1 = 失败      ← 机器可判定的验证信号
#
# 🔴 为什么不用 envsubst：
#   1. macOS 不自带（属于 gettext 包），脚本会因机器而异，Mac 上直接跑不了
#   2. 不带参数的 envsubst 会替换【所有】 $xxx —— 配置里任何一个裸 $ 都可能被误伤
#   这里显式列出允许替换的变量名，替换范围可控。
#
# 🔴 为什么替换用 python 而不是 sed：
#   订阅链接含 ?&= /，Trojan 密码可能含 / & \ —— 这些在 sed 的替换串里
#   全是元字符，会被解释掉或直接报错。python 的 str.replace 是字面替换，无转义问题。

set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIR
readonly TMPL="${DIR}/config.yaml.tmpl"
readonly ENVF="${DIR}/mihomo.local.env"
readonly OUT="${DIR}/config.yaml"

# 允许替换的变量白名单。新增占位符时必须同步加到这里，否则 M3 会拦下来。
readonly VARS="MIHOMO_SECRET MIHOMO_VERSION SUB_URL_A SELF_SERVER SELF_SERVER_IP SELF_TROJAN_PASSWORD SELF_VMESS_UUID"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

_on_err() { echo "❌ 第 ${BASH_LINENO[0]} 行附近失败（set -e 触发）" >&2; }
trap _on_err ERR

ok()  { printf '  ✅ %s\n' "$1"; }
bad() { printf '  ❌ %s\n' "$1" >&2; }

# ── M0 · 前置检查 ────────────────────────────────────────
echo "── M0 · 前置检查"
[[ -f "${TMPL}" ]] || { bad "找不到模板 ${TMPL}"; exit 1; }
[[ -f "${ENVF}" ]] || { bad "找不到 ${ENVF}（从 mihomo.env.example 复制一份并填值）"; exit 1; }
ok "模板与机密文件都在"

# 机密文件权限必须是 600 —— 它含订阅链接和密码
perm="$(stat -f '%Lp' "${ENVF}" 2>/dev/null || stat -c '%a' "${ENVF}" 2>/dev/null || echo '?')"
if [[ "${perm}" != "600" ]]; then
  bad "${ENVF} 权限是 ${perm}，应为 600 —— 执行 chmod 600 后重试"
  exit 1
fi
ok "机密文件权限 600"

# ── M1 · 载入变量 ────────────────────────────────────────
# set -a 让后续赋值自动 export，python 才能从 os.environ 读到。
echo "── M1 · 载入变量"
set -a
# shellcheck source=/dev/null
. "${ENVF}"
set +a

missing=""
for v in ${VARS}; do
  # 🔴 用间接展开取值；set -u 下未定义变量会直接终止脚本，
  #    所以先用 ${!v+x} 判断"是否已定义"，再取值。
  if [[ -z "${!v+x}" || -z "${!v}" ]]; then
    missing="${missing} ${v}"
  fi
done
if [[ -n "${missing}" ]]; then
  bad "以下变量在 ${ENVF} 里缺失或为空：${missing# }"
  exit 1
fi
ok "$(echo ${VARS} | wc -w | tr -d ' ') 个变量全部就位"

# ── M2 · 替换 ────────────────────────────────────────────
echo "── M2 · 替换占位符"
# 🔴 这里的环境变量【不能】直接叫 VARS / TMPL：
#    它们在本脚本里是 readonly，而 `VAR=值 命令` 这种命令前缀赋值
#    对 readonly 变量会报 "readonly variable" 并且【不把变量传给子进程】，
#    python 那边收到的是 KeyError，报错信息还指不到真正原因。
rendered="$(_RV="${VARS}" _RT="${TMPL}" python3 <<'PY'
import os, sys, pathlib
s = pathlib.Path(os.environ["_RT"]).read_text(encoding="utf-8")
for name in os.environ["_RV"].split():
    s = s.replace("${%s}" % name, os.environ[name])
sys.stdout.write(s)
PY
)"
ok "已替换白名单内的 $(echo ${VARS} | wc -w | tr -d ' ') 个占位符"

# ── M3 · 校验：不能有漏网的占位符 ─────────────────────────
# 漏一个 ${XXX} 出去，mihomo 会把它当字面量吃下去 —— 比如 server 变成
# 字符串 "${SELF_SERVER}"，启动不报错，但连不上，排查起来极其费劲。
echo "── M3 · 校验"
leftover="$(printf '%s' "${rendered}" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | sort -u || true)"
if [[ -n "${leftover}" ]]; then
  bad "还有未替换的占位符（把它们加进脚本顶部的 VARS 白名单）："
  printf '%s\n' "${leftover}" | sed 's/^/       /' >&2
  exit 1
fi
ok "无残留占位符"

# ── M4 · 落盘 ────────────────────────────────────────────
if [[ ${CHECK_ONLY} -eq 1 ]]; then
  echo "── M4 · --check 模式，不写文件"
  echo "✅ 校验通过"
  exit 0
fi

echo "── M4 · 写入"
# 先 umask 再写，避免文件在 chmod 之前有一瞬间是 644 —— 那一瞬间机密是可读的
( umask 077; printf '%s' "${rendered}" > "${OUT}" )
chmod 600 "${OUT}"
ok "${OUT}  $(wc -l < "${OUT}" | tr -d ' ') 行  权限 600"
echo "✅ 渲染完成"
