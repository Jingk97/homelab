#!/usr/bin/env bash
#
# provision-base.sh —— Ubuntu 24.04 LTS 模板通用配置脚本
#
# 用途：给「刚装完系统」的 Ubuntu Server 打底，装上所有克隆机都需要的
#       系统配置、运维工具、研发工具和语言运行时。
#
# 设计原则：
#   1. 幂等 —— 可反复执行；配置文件内容无变化时【不重启服务】
#   2. 通用 —— 只装【每台机器都要】的东西，业务软件一律不进
#   3. 不做破坏性决策 —— 不装 Docker、不关 swap、不动 SSH 密码登录
#      （这三项按机器角色在克隆后单独处理，详见 docs/04-vm-template.md）
#
# 用法：
#   ./provision-base.sh                                   # 全量执行
#   PROXY=http://192.168.5.9:6152 ./provision-base.sh      # 需要下载境外资源时
#   SKIP_MIRROR=1 ./provision-base.sh                     # 跳过国内镜像源配置
#   SKIP_LANG=1   ./provision-base.sh                     # 跳过语言运行时
#
# 关于代理：
#   代理【只作用于境外目标】（GitHub / astral.sh / go.dev），
#   国内镜像（清华 / golang.google.cn / npmmirror）一律直连。
#   把国内源也塞进代理会导致镜像站返回 403 —— 因为出口 IP 变成了境外。
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# 全局变量
# ──────────────────────────────────────────────────────────────
readonly MIRROR_HOST="mirrors.tuna.tsinghua.edu.cn"
readonly TARGET_USER="${SUDO_USER:-$(id -un)}"
readonly TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
readonly NVM_VERSION="v0.40.3"
readonly TS="$(date +%Y%m%d-%H%M%S)"

SKIP_MIRROR="${SKIP_MIRROR:-0}"
SKIP_LANG="${SKIP_LANG:-0}"

# ── 代理处理 ──────────────────────────────────────────────────
# 关键设计：代理【不做全局导出】，只在访问境外目标的那几条命令上临时施加。
#
# 原因：国内镜像（清华 / golang.google.cn / npmmirror）走代理时，
#       出口 IP 变成境外，镜像站会返回 403 Forbidden 直接失败。
#
# 如果调用者在环境里已经 export 过代理，这里把它【收编】进 PROXY_URL，
# 然后从全局环境中清除 —— 否则 apt 会继承那些变量，照样踩 403。
PROXY_URL="${PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}"
PROXY_INHERITED=0
[[ -z "${PROXY:-}" && -n "$PROXY_URL" ]] && PROXY_INHERITED=1
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY
readonly PROXY_URL PROXY_INHERITED

export DEBIAN_FRONTEND=noninteractive

# ──────────────────────────────────────────────────────────────
# 输出辅助
# ──────────────────────────────────────────────────────────────
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    [warn] %s\033[0m\n' "$*"; }
skip() { printf '\033[0;36m    [skip] %s\033[0m\n' "$*"; }

# 只对【境外目标】临时施加代理执行一条命令。
# 变量只在这一条命令的环境里存在，不影响其他任何操作。
with_proxy() {
  if [[ -n "$PROXY_URL" ]]; then
    http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" \
    HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" "$@"
  else
    "$@"
  fi
}

# 幂等写入：内容有变化才写盘并返回 0；无变化返回 1。
# 调用方据此决定要不要重启服务 —— 避免每次执行都无谓地重启系统服务。
write_if_changed() {
  local dst="$1" content="$2"
  if [[ -f "$dst" ]] && [[ "$(sudo cat "$dst" 2>/dev/null)" == "$content" ]]; then
    return 1
  fi
  sudo mkdir -p "$(dirname "$dst")"
  printf '%s\n' "$content" | sudo tee "$dst" > /dev/null
  return 0
}

# ──────────────────────────────────────────────────────────────
# M0 · 前置检查
# ──────────────────────────────────────────────────────────────
m0_precheck() {
  step "M0 · 前置检查"

  # 1. 必须是普通用户 + sudo，不能直接 root 跑
  #    原因：nvm / uv 装在用户目录，用 root 跑会装到 /root 下，普通用户用不了
  if [[ $EUID -eq 0 && -z "${SUDO_USER:-}" ]]; then
    warn "检测到以 root 直接运行。"
    warn "nvm 和 uv 会装到 /root 下，普通用户将无法使用。"
    warn "建议改用：普通用户执行 ./provision-base.sh"
    read -rp "    仍要继续？[y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
  fi

  # 2. 系统信息
  . /etc/os-release
  info "系统    ：$PRETTY_NAME"
  info "内核    ：$(uname -r)"
  info "目标用户：$TARGET_USER ($TARGET_HOME)"
  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "本脚本针对 Ubuntu 编写，当前系统是 ${ID:-unknown}，部分步骤可能失败。"
  fi

  # 3. 确认能 sudo
  sudo -n true 2>/dev/null || sudo true

  # 4. 代理状态
  if [[ -n "$PROXY_URL" ]]; then
    info "代理    ：${PROXY_URL}（仅用于境外目标，国内镜像直连）"
    [[ "$PROXY_INHERITED" == "1" ]] && \
      info "          （从环境变量继承，已从全局环境清除以免影响 apt）"
  else
    info "代理    ：未设置"
  fi

  # 5. 国内镜像连通性 —— 这些必须【直连】能通，走代理反而会 403
  info "检测国内镜像连通性（直连）…"
  if curl -fsS --connect-timeout 8 -o /dev/null "https://${MIRROR_HOST}/" 2>/dev/null; then
    info "清华镜像：可达 ✓"
  else
    warn "清华镜像直连不通 —— apt / pip / node 下载会失败"
    warn "检查一下机器的 DNS 和网关配置是否正常"
  fi

  # 6. 境外连通性预检 —— 提前告知，而不是跑到一半才失败
  #    这三项依赖 GitHub / astral.sh：yq、uv、nvm
  info "检测境外连通性（${PROXY_URL:+经代理}${PROXY_URL:-直连}）…"
  if with_proxy curl -fsS --connect-timeout 8 -o /dev/null https://github.com 2>/dev/null; then
    info "GitHub  ：可达 ✓"
  else
    warn "GitHub 不可达 —— yq / uv / nvm 三项将安装失败（其余模块不受影响）"
    warn "建议先设代理再重跑："
    warn "    PROXY=http://<代理IP>:<端口> ./provision-base.sh"
    warn "或用 SKIP_LANG=1 先跳过语言运行时，事后单独补装"
    echo
    read -rp "    仍要继续？[Y/n] " ans
    [[ -z "$ans" || "$ans" == "y" || "$ans" == "Y" ]] || exit 1
  fi
}

# ──────────────────────────────────────────────────────────────
# M1 · apt 镜像源 + 系统更新
# ──────────────────────────────────────────────────────────────
m1_apt() {
  step "M1 · apt 源与系统更新"

  . /etc/os-release
  local codename="${VERSION_CODENAME}"
  local src="/etc/apt/sources.list.d/ubuntu.sources"

  if [[ "$SKIP_MIRROR" == "1" ]]; then
    skip "SKIP_MIRROR=1，保持官方 apt 源"
  elif grep -q "$MIRROR_HOST" "$src" 2>/dev/null; then
    skip "apt 源已是清华镜像"
  else
    info "切换 apt 源到清华镜像（deb822 格式，Ubuntu 24.04+ 标准）"
    [[ -f "$src" ]] && sudo cp "$src" "${src}.bak-${TS}" && info "原文件备份为 ${src}.bak-${TS}"
    sudo tee "$src" > /dev/null <<EOF
Types: deb
URIs: https://${MIRROR_HOST}/ubuntu/
Suites: ${codename} ${codename}-updates ${codename}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://${MIRROR_HOST}/ubuntu/
Suites: ${codename}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  fi

  info "apt update"
  sudo -E apt-get update -qq
  info "apt full-upgrade（可能需要几分钟）"
  sudo -E apt-get full-upgrade -y -qq
}

# ──────────────────────────────────────────────────────────────
# M2 · 系统基础配置
# ──────────────────────────────────────────────────────────────
m2_system() {
  step "M2 · 系统基础配置"

  # ── 时区 ──────────────────────────────────────────────
  if [[ "$(timedatectl show -p Timezone --value)" == "Asia/Shanghai" ]]; then
    skip "时区已是 Asia/Shanghai"
  else
    info "设置时区 Asia/Shanghai"
    sudo timedatectl set-timezone Asia/Shanghai
  fi

  # ── NTP 时钟对齐 ──────────────────────────────────────
  # 顺序说明：先写配置再重启服务，否则重启的是旧配置
  if write_if_changed /etc/systemd/timesyncd.conf.d/10-cn-ntp.conf \
"[Time]
NTP=ntp.aliyun.com ntp1.aliyun.com ntp2.aliyun.com
FallbackNTP=cn.pool.ntp.org ntp.ubuntu.com"; then
    info "NTP 配置已更新（阿里云 + 国内 pool），重启 systemd-timesyncd"
    sudo timedatectl set-ntp true
    sudo systemctl restart systemd-timesyncd
  else
    skip "NTP 配置无变化"
  fi

  # ── DNS ───────────────────────────────────────────────
  # 说明：这里设的是【全局兜底】DNS。DHCP / netplan 下发的 DNS 优先级更高，
  #       所以不会覆盖你在路由器或 netplan 上的设置。
  if write_if_changed /etc/systemd/resolved.conf.d/10-cn-dns.conf \
"[Resolve]
DNS=223.5.5.5 119.29.29.29
FallbackDNS=180.76.76.76 114.114.114.114"; then
    info "DNS 兜底配置已更新，重启 systemd-resolved"
    sudo systemctl restart systemd-resolved
  else
    skip "DNS 配置无变化"
  fi

  # ── journald 日志限制 ─────────────────────────────────
  # 默认无上限，长期运行能吃掉几个 GB。小磁盘虚拟机必须限。
  if write_if_changed /etc/systemd/journald.conf.d/10-size-limit.conf \
"[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
SystemMaxFiles=10"; then
    info "journald 上限设为 500M，重启 systemd-journald"
    sudo systemctl restart systemd-journald
  else
    skip "journald 配置无变化"
  fi

  # ── locale ────────────────────────────────────────────
  # 系统 locale 保持英文：日志和报错是英文，搜索引擎能搜到。
  # 同时生成中文 locale，保证中文文件名、网页显示正常。
  sudo -E apt-get install -y -qq locales
  if locale -a 2>/dev/null | grep -qi '^zh_CN.utf8$' && \
     locale -a 2>/dev/null | grep -qi '^en_US.utf8$'; then
    skip "locale 已生成（en_US.UTF-8 / zh_CN.UTF-8）"
  else
    info "生成 locale（系统英文 + 中文支持）"
    sudo locale-gen en_US.UTF-8 zh_CN.UTF-8 > /dev/null
    sudo update-locale LANG=en_US.UTF-8
  fi

  # ── sudo 免密 ─────────────────────────────────────────
  local sudoers_file="/etc/sudoers.d/90-${TARGET_USER}-nopasswd"
  if write_if_changed "$sudoers_file" "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL"; then
    sudo chmod 440 "$sudoers_file"
    # 校验语法：写坏 sudoers 会导致完全无法提权，必须验
    if sudo visudo -c -f "$sudoers_file" > /dev/null 2>&1; then
      info "已配置 ${TARGET_USER} 的 sudo 免密"
    else
      warn "sudoers 语法校验失败，已移除该文件"
      sudo rm -f "$sudoers_file"
    fi
  else
    skip "sudo 免密已配置"
  fi
}

# ──────────────────────────────────────────────────────────────
# M3 · 运维工具
# ──────────────────────────────────────────────────────────────
m3_ops_tools() {
  step "M3 · 运维工具"
  sudo -E apt-get install -y -qq \
    htop btop ncdu tree lsof \
    net-tools iproute2 dnsutils traceroute mtr-tiny tcpdump nmap \
    rsync unzip zip p7zip-full \
    sysstat smartmontools \
    tmux screen vim \
    ca-certificates gnupg apt-transport-https \
    software-properties-common
  info "htop btop ncdu tree lsof / net-tools dnsutils mtr tcpdump nmap / rsync sysstat smartmontools tmux vim"
}

# ──────────────────────────────────────────────────────────────
# M4 · 研发工具
# ──────────────────────────────────────────────────────────────
m4_dev_tools() {
  step "M4 · 研发工具"
  sudo -E apt-get install -y -qq \
    git build-essential pkg-config \
    jq ripgrep fd-find bat \
    bash-completion

  # Ubuntu 打包时改了名（避免和别的包冲突），建软链恢复常用命令名
  sudo mkdir -p /usr/local/bin
  [[ -x /usr/bin/batcat ]] && sudo ln -sf /usr/bin/batcat /usr/local/bin/bat
  [[ -x /usr/bin/fdfind ]] && sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd

  # yq 不在 Ubuntu 仓库里，从 GitHub 拉二进制
  # 注意 sudo -E：sudo 默认清空环境变量，不加 -E 代理设置传不进去
  if command -v yq > /dev/null 2>&1; then
    skip "yq 已安装（$(yq --version 2>/dev/null | awk '{print $NF}')）"
  else
    info "安装 yq（GitHub，走代理）"
    # 先以【普通用户】下载到 /tmp 再 install 到系统目录：
    # 这样代理变量不用穿过 sudo，避开 sudo 的环境清空问题
    if with_proxy curl -fsSL --connect-timeout 20 \
         https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
         -o /tmp/yq_linux_amd64; then
      sudo install -m 0755 /tmp/yq_linux_amd64 /usr/local/bin/yq
      rm -f /tmp/yq_linux_amd64
    else
      warn "yq 下载失败（GitHub 不可达？），跳过。可事后手动装。"
      rm -f /tmp/yq_linux_amd64
    fi
  fi

  info "git build-essential jq ripgrep(rg) fd bat yq"
}

# ──────────────────────────────────────────────────────────────
# M5 · Python
# ──────────────────────────────────────────────────────────────
m5_python() {
  step "M5 · Python 工具链"

  # Ubuntu 24.04 起有 PEP 668 保护，禁止 pip 直接装进系统 Python。
  # 所以：系统 Python 只跑系统脚本，开发用 uv / pipx 隔离。
  sudo -E apt-get install -y -qq python3 python3-venv python3-pip pipx
  pipx ensurepath > /dev/null 2>&1 || true

  if [[ "$SKIP_MIRROR" == "1" ]]; then
    skip "SKIP_MIRROR=1，pip 保持官方源"
  elif write_if_changed /etc/pip.conf \
"[global]
index-url = https://${MIRROR_HOST}/pypi/web/simple
trusted-host = ${MIRROR_HOST}"; then
    info "pip 已切换到清华源"
  else
    skip "pip 源无变化"
  fi

  # uv：Astral 的 Python 包/版本管理器，比 pip 快一到两个数量级，
  #     能自己下载并管理多个 Python 版本，不污染系统 Python。
  if command -v uv > /dev/null 2>&1 || [[ -x "${TARGET_HOME}/.local/bin/uv" ]]; then
    skip "uv 已安装"
  else
    info "安装 uv（astral.sh + GitHub，走代理）"
    # 用子 shell 限定代理作用域：安装脚本内部还会再下载二进制，
    # 所以代理必须对整个管道生效，但不能泄漏到后续步骤
    if [[ -n "$PROXY_URL" ]]; then
      ( export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
        curl -LsSf --connect-timeout 20 https://astral.sh/uv/install.sh | sh ) \
        || warn "uv 安装失败，可事后手动装"
    else
      curl -LsSf --connect-timeout 20 https://astral.sh/uv/install.sh | sh \
        || warn "uv 安装失败（网络问题），可事后手动装"
    fi
  fi
}

# ──────────────────────────────────────────────────────────────
# M6 · Go
# ──────────────────────────────────────────────────────────────
m6_golang() {
  step "M6 · Go"

  # 不写死版本号：从官方接口拉当前最新稳定版，脚本永远不用改。
  # golang.google.cn 是 Go 官方的中国站点，国内可直连；失败回退 go.dev。
  # golang.google.cn 是 Go 官方中国站点 —— 【直连】，不能走代理
  local want
  want="$(curl -fsSL --connect-timeout 15 'https://golang.google.cn/VERSION?m=text' 2>/dev/null | head -1 || true)"
  # 只有中国站点不通时才回退 go.dev，那时才需要代理
  [[ -z "$want" ]] && want="$(with_proxy curl -fsSL --connect-timeout 15 'https://go.dev/VERSION?m=text' 2>/dev/null | head -1 || true)"
  if [[ -z "$want" ]]; then
    warn "无法获取 Go 最新版本号（网络问题），跳过 Go 安装"
    return 0
  fi

  local have=""
  [[ -x /usr/local/go/bin/go ]] && have="$(/usr/local/go/bin/go version | awk '{print $3}')"

  if [[ "$have" == "$want" ]]; then
    skip "Go 已是最新稳定版 $have"
  else
    info "安装 Go $want（当前：${have:-未安装}）"
    local tgz="/tmp/${want}.linux-amd64.tar.gz"
    # 同样：中国站点直连，失败才用代理回退 go.dev
    if ! curl -fsSL --connect-timeout 30 "https://golang.google.cn/dl/${want}.linux-amd64.tar.gz" -o "$tgz"; then
      warn "golang.google.cn 下载失败，回退 go.dev（走代理）"
      with_proxy curl -fsSL --connect-timeout 30 "https://go.dev/dl/${want}.linux-amd64.tar.gz" -o "$tgz" \
        || { warn "Go 下载失败，跳过"; rm -f "$tgz"; return 0; }
    fi
    # 顺序说明：必须先删旧目录再解压，Go 官方明确要求。
    # 不删直接覆盖会让新旧版本文件混在一起，出现极难排查的编译错误。
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$tgz"
    rm -f "$tgz"
  fi

  # 环境变量写到 /etc/profile.d，对所有用户生效
  local goproxy_line='export GOPROXY=https://proxy.golang.org,direct'
  local gosumdb_line='export GOSUMDB=sum.golang.org'
  if [[ "$SKIP_MIRROR" != "1" ]]; then
    goproxy_line='export GOPROXY=https://goproxy.cn,direct'
    gosumdb_line='export GOSUMDB=sum.golang.google.cn'
  fi
  if write_if_changed /etc/profile.d/golang.sh \
"export GOROOT=/usr/local/go
export GOPATH=\$HOME/go
export PATH=\$PATH:\$GOROOT/bin:\$GOPATH/bin
${goproxy_line}
${gosumdb_line}"; then
    sudo chmod 644 /etc/profile.d/golang.sh
    info "Go 环境变量已写入 /etc/profile.d/golang.sh"
  else
    skip "Go 环境变量无变化"
  fi
}

# ──────────────────────────────────────────────────────────────
# M7 · Node.js
# ──────────────────────────────────────────────────────────────
m7_nodejs() {
  step "M7 · Node.js（nvm + 最新 LTS）"

  local nvm_dir="${TARGET_HOME}/.nvm"

  if [[ -s "${nvm_dir}/nvm.sh" ]]; then
    skip "nvm 已安装于 ${nvm_dir}"
  else
    info "安装 nvm ${NVM_VERSION}（GitHub，走代理）"
    # git clone 而不是 install.sh：报错更清楚，且方便以后切版本。
    # git 会读取 http_proxy / https_proxy，with_proxy 把它们只喂给这一条命令。
    if ! with_proxy git clone --depth 1 --branch "$NVM_VERSION" \
           https://github.com/nvm-sh/nvm.git "$nvm_dir" 2>/dev/null; then
      warn "nvm 下载失败（GitHub 不可达？），跳过 Node.js 安装"
      warn "可事后手动执行："
      warn "    git clone --depth 1 --branch ${NVM_VERSION} https://github.com/nvm-sh/nvm.git ~/.nvm"
      return 0
    fi
  fi

  # 写入 shell 初始化（幂等：检测到已有 NVM_DIR 则不重复追加）
  local rc="${TARGET_HOME}/.bashrc"
  if grep -q 'NVM_DIR' "$rc" 2>/dev/null; then
    skip "~/.bashrc 已包含 nvm 初始化"
  else
    info "写入 nvm 初始化到 ~/.bashrc"
    cat >> "$rc" <<'EOF'

# ── nvm ──────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF
  fi

  # 在当前 shell 加载 nvm
  export NVM_DIR="$nvm_dir"
  # shellcheck disable=SC1090,SC1091
  . "${nvm_dir}/nvm.sh"

  if [[ "$SKIP_MIRROR" != "1" ]]; then
    # Node 二进制从清华镜像下载 —— 【直连】，此处不能有代理变量
    export NVM_NODEJS_ORG_MIRROR="https://${MIRROR_HOST}/nodejs-release/"
  fi

  # 幂等判断用 nvm current，不能用 `nvm ls | grep lts/`：
  # 即使一个版本都没装，nvm ls 也会列出 lts/* 等【远程别名】，
  # grep 会误判成"已安装"从而跳过安装。
  local cur
  cur="$(nvm current 2>/dev/null || echo none)"
  if [[ "$cur" == v* ]]; then
    skip "Node 已安装：$cur"
  else
    info "安装最新 LTS 版 Node.js"
    nvm install --lts
    nvm alias default 'lts/*'
  fi

  if [[ "$SKIP_MIRROR" != "1" ]] && command -v npm > /dev/null 2>&1; then
    if [[ "$(npm config get registry 2>/dev/null)" == "https://registry.npmmirror.com/" ]]; then
      skip "npm 源已是 npmmirror"
    else
      info "配置 npm 使用 npmmirror"
      npm config set registry https://registry.npmmirror.com
    fi
  fi
}

# ──────────────────────────────────────────────────────────────
# M8 · 收尾与版本汇总
# ──────────────────────────────────────────────────────────────
m8_summary() {
  step "M8 · 清理与版本汇总"

  sudo -E apt-get autoremove -y -qq
  sudo -E apt-get clean

  echo
  printf '\033[1;32m════════════════════ 安装结果 ════════════════════\033[0m\n'
  printf '  %-14s %s\n' "系统"      "$(. /etc/os-release && echo "$PRETTY_NAME")"
  printf '  %-14s %s\n' "内核"      "$(uname -r)"
  printf '  %-14s %s\n' "时区"      "$(timedatectl show -p Timezone --value)"
  printf '  %-14s %s\n' "NTP 同步"  "$(timedatectl show -p NTPSynchronized --value)"
  printf '  %-14s %s\n' "默认target" "$(systemctl get-default)"
  printf '  %-14s %s\n' "日志占用"  "$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | head -1 || echo '-')"
  echo   "  ────────────────────────────────────────────────"
  printf '  %-14s %s\n' "git"      "$(git --version 2>/dev/null | awk '{print $3}' || echo '-')"
  printf '  %-14s %s\n' "yq"       "$(yq --version 2>/dev/null | awk '{print $NF}' || echo '- 未装')"
  printf '  %-14s %s\n' "python3"  "$(python3 --version 2>/dev/null | awk '{print $2}' || echo '-')"
  printf '  %-14s %s\n' "pipx"     "$(pipx --version 2>/dev/null || echo '-')"
  printf '  %-14s %s\n' "uv"       "$("${TARGET_HOME}/.local/bin/uv" --version 2>/dev/null | awk '{print $2}' || echo '- 未装')"
  printf '  %-14s %s\n' "go"       "$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || echo '- 未装')"
  if [[ -s "${TARGET_HOME}/.nvm/nvm.sh" ]]; then
    export NVM_DIR="${TARGET_HOME}/.nvm"
    # shellcheck disable=SC1090,SC1091
    . "${NVM_DIR}/nvm.sh"
    printf '  %-14s %s\n' "node"   "$(node --version 2>/dev/null || echo '- 未装')"
    printf '  %-14s %s\n' "npm"    "$(npm --version 2>/dev/null || echo '-')"
  else
    printf '  %-14s %s\n' "node"   "- 未装"
  fi
  printf '\033[1;32m═════════════════════════════════════════════════\033[0m\n'
  echo
  info "重新登录，或执行：source ~/.bashrc && source /etc/profile.d/golang.sh"
  echo
  warn "本脚本【不做】以下三件事，请按机器角色在克隆后单独处理："
  warn "  1. 不装 Docker —— 与 k8s 的 containerd 存在 cgroup driver 冲突"
  warn "  2. 不关 swap  —— k8s 节点需要关，其他角色保留更好"
  warn "  3. 不改 SSH 密码登录 —— 避免公钥未生效时把自己锁在门外"
  if [[ -n "$PROXY_URL" ]]; then
    echo
    info "本次代理 ${PROXY_URL} 仅用于 GitHub / astral.sh 等境外目标，"
    info "国内镜像全程直连。代理未写入任何持久化配置。"
  fi
}

# ──────────────────────────────────────────────────────────────
main() {
  m0_precheck
  m1_apt
  m2_system
  m3_ops_tools
  m4_dev_tools
  if [[ "$SKIP_LANG" == "1" ]]; then
    step "M5–M7 · 语言运行时"
    skip "SKIP_LANG=1，跳过 Python / Go / Node.js"
  else
    m5_python
    m6_golang
    m7_nodejs
  fi
  m8_summary
}

main "$@"
