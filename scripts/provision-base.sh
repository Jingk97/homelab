#!/usr/bin/env bash
#
# provision-base.sh —— Ubuntu 24.04 LTS 模板通用配置脚本
#
# 用途：给「刚装完系统」的 Ubuntu Server 打底，装上所有克隆机都需要的
#       系统配置、运维工具、研发工具和语言运行时。
#
# 设计原则：
#   1. 幂等 —— 可以反复执行，不会重复安装或写坏配置
#   2. 通用 —— 只装【每台机器都要】的东西，业务软件一律不进
#   3. 不做破坏性决策 —— 不装 Docker、不关 swap、不动 SSH 密码登录
#      （这三项按机器角色在克隆后单独处理，详见 docs/04-vm-template.md）
#
# 用法：
#   chmod +x provision-base.sh
#   ./provision-base.sh                 # 全量执行
#   SKIP_MIRROR=1 ./provision-base.sh   # 跳过国内镜像源配置
#   SKIP_LANG=1   ./provision-base.sh   # 跳过语言运行时（Python/Go/Node）
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

export DEBIAN_FRONTEND=noninteractive

# ──────────────────────────────────────────────────────────────
# 输出辅助
# ──────────────────────────────────────────────────────────────
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    [warn] %s\033[0m\n' "$*"; }
skip() { printf '\033[0;36m    [skip] %s\033[0m\n' "$*"; }

# ──────────────────────────────────────────────────────────────
# M0 · 前置检查
# ──────────────────────────────────────────────────────────────
m0_precheck() {
  step "M0 · 前置检查"

  # 1. 必须是普通用户 + sudo，不能直接 root 跑
  #    原因：nvm / uv 装在用户目录，用 root 跑会装到 /root 下，克隆后普通用户用不了
  if [[ $EUID -eq 0 && -z "${SUDO_USER:-}" ]]; then
    warn "检测到以 root 直接运行。"
    warn "nvm 和 uv 会装到 /root 下，普通用户将无法使用。"
    warn "建议改用：普通用户执行 ./provision-base.sh"
    read -rp "    仍要继续？[y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
  fi

  # 2. 确认系统
  . /etc/os-release
  info "系统：$PRETTY_NAME"
  info "内核：$(uname -r)"
  info "目标用户：$TARGET_USER ($TARGET_HOME)"
  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "本脚本针对 Ubuntu 编写，当前系统是 ${ID:-unknown}，部分步骤可能失败。"
  fi

  # 3. 确认能 sudo
  sudo -n true 2>/dev/null || sudo true
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
    [[ -f "$src" ]] && sudo cp "$src" "${src}.bak-${TS}"
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
    info "原文件已备份为 ${src}.bak-${TS}"
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
  # 顺序说明：必须先写配置再重启服务，否则重启的是旧配置
  info "配置 NTP（阿里云 + 国内 pool）"
  sudo mkdir -p /etc/systemd/timesyncd.conf.d
  sudo tee /etc/systemd/timesyncd.conf.d/10-cn-ntp.conf > /dev/null <<'EOF'
[Time]
NTP=ntp.aliyun.com ntp1.aliyun.com ntp2.aliyun.com
FallbackNTP=cn.pool.ntp.org ntp.ubuntu.com
EOF
  sudo timedatectl set-ntp true
  sudo systemctl restart systemd-timesyncd

  # ── DNS ───────────────────────────────────────────────
  # 说明：这里设的是【全局兜底】DNS。DHCP 下发的 DNS 优先级更高，
  #       所以不会覆盖你在 netplan / 路由器上的设置。
  info "配置 DNS 兜底（阿里 + 腾讯）"
  sudo mkdir -p /etc/systemd/resolved.conf.d
  sudo tee /etc/systemd/resolved.conf.d/10-cn-dns.conf > /dev/null <<'EOF'
[Resolve]
DNS=223.5.5.5 119.29.29.29
FallbackDNS=180.76.76.76 114.114.114.114
EOF
  sudo systemctl restart systemd-resolved

  # ── journald 日志限制 ─────────────────────────────────
  # 默认无上限，长期运行能吃掉几个 GB。小磁盘的虚拟机必须限。
  info "限制 journald 日志总量为 500M"
  sudo mkdir -p /etc/systemd/journald.conf.d
  sudo tee /etc/systemd/journald.conf.d/10-size-limit.conf > /dev/null <<'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
SystemMaxFiles=10
EOF
  sudo systemctl restart systemd-journald

  # ── locale ────────────────────────────────────────────
  # 系统 locale 保持英文：日志和报错是英文，搜索引擎能搜到。
  # 同时生成中文 locale，保证中文文件名、网页显示正常。
  info "生成 locale（系统英文 + 中文支持）"
  sudo -E apt-get install -y -qq locales
  sudo locale-gen en_US.UTF-8 zh_CN.UTF-8 > /dev/null
  sudo update-locale LANG=en_US.UTF-8

  # ── sudo 免密 ─────────────────────────────────────────
  local sudoers_file="/etc/sudoers.d/90-${TARGET_USER}-nopasswd"
  info "配置 ${TARGET_USER} 的 sudo 免密"
  echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee "$sudoers_file" > /dev/null
  sudo chmod 440 "$sudoers_file"
  # 校验语法，写坏 sudoers 会导致完全无法提权
  if ! sudo visudo -c -f "$sudoers_file" > /dev/null; then
    warn "sudoers 语法校验失败，已移除该文件"
    sudo rm -f "$sudoers_file"
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
  info "已安装：htop btop ncdu tree lsof net-tools dnsutils mtr tcpdump nmap rsync sysstat smartmontools tmux vim"
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

  # Ubuntu 打包时改了名（和别的包冲突），建软链恢复常用命令名
  sudo mkdir -p /usr/local/bin
  [[ -x /usr/bin/batcat ]] && sudo ln -sf /usr/bin/batcat /usr/local/bin/bat
  [[ -x /usr/bin/fdfind ]] && sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd

  # yq 不在 Ubuntu 仓库里，从 GitHub 拉二进制（失败不阻塞整个脚本）
  if command -v yq > /dev/null; then
    skip "yq 已安装"
  else
    info "安装 yq"
    if sudo curl -fsSL --connect-timeout 15 \
         https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
         -o /usr/local/bin/yq; then
      sudo chmod +x /usr/local/bin/yq
    else
      warn "yq 下载失败（可能是网络问题），跳过。可稍后手动装。"
      sudo rm -f /usr/local/bin/yq
    fi
  fi

  info "已安装：git build-essential jq ripgrep(rg) fd bat yq"
}

# ──────────────────────────────────────────────────────────────
# M5 · Python
# ──────────────────────────────────────────────────────────────
m5_python() {
  step "M5 · Python 工具链"

  # Ubuntu 24.04 起有 PEP 668 保护，禁止 pip 直接装进系统 Python。
  # 所以：系统 Python 只用来跑系统脚本，开发用 uv / pipx 隔离。
  sudo -E apt-get install -y -qq python3 python3-venv python3-pip pipx
  # pipx 装的命令行工具需要 ~/.local/bin 在 PATH 里
  pipx ensurepath > /dev/null 2>&1 || true

  if [[ "$SKIP_MIRROR" != "1" ]]; then
    info "配置 pip 使用清华源"
    sudo mkdir -p /etc
    sudo tee /etc/pip.conf > /dev/null <<EOF
[global]
index-url = https://${MIRROR_HOST}/pypi/web/simple
trusted-host = ${MIRROR_HOST}
EOF
  fi

  # uv：Astral 的 Python 包/版本管理器，比 pip 快一到两个数量级，
  #     可以自己下载并管理多个 Python 版本，不污染系统 Python。
  if command -v uv > /dev/null || [[ -x "${TARGET_HOME}/.local/bin/uv" ]]; then
    skip "uv 已安装"
  else
    info "安装 uv"
    curl -LsSf --connect-timeout 15 https://astral.sh/uv/install.sh | sh \
      || warn "uv 安装失败（网络问题），可稍后手动装"
  fi
}

# ──────────────────────────────────────────────────────────────
# M6 · Go
# ──────────────────────────────────────────────────────────────
m6_golang() {
  step "M6 · Go"

  # 不写死版本号：从官方接口拉当前最新稳定版。
  # 用 golang.google.cn（Go 官方的中国站点），国内可直连。
  local want
  want="$(curl -fsSL --connect-timeout 15 'https://golang.google.cn/VERSION?m=text' 2>/dev/null | head -1 || true)"
  if [[ -z "$want" ]]; then
    want="$(curl -fsSL --connect-timeout 15 'https://go.dev/VERSION?m=text' 2>/dev/null | head -1 || true)"
  fi
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
    curl -fsSL --connect-timeout 30 \
      "https://golang.google.cn/dl/${want}.linux-amd64.tar.gz" -o "$tgz" \
      || curl -fsSL --connect-timeout 30 \
         "https://go.dev/dl/${want}.linux-amd64.tar.gz" -o "$tgz"
    # 顺序说明：必须先删旧目录再解压，Go 官方明确要求，
    # 否则新旧版本文件混在一起会出现难以排查的编译错误
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$tgz"
    rm -f "$tgz"
  fi

  # 环境变量写到 /etc/profile.d，对所有用户生效
  info "写入 Go 环境变量到 /etc/profile.d/golang.sh"
  local goproxy_line='export GOPROXY=https://proxy.golang.org,direct'
  local gosumdb_line='export GOSUMDB=sum.golang.org'
  if [[ "$SKIP_MIRROR" != "1" ]]; then
    goproxy_line='export GOPROXY=https://goproxy.cn,direct'
    gosumdb_line='export GOSUMDB=sum.golang.google.cn'
  fi
  sudo tee /etc/profile.d/golang.sh > /dev/null <<EOF
export GOROOT=/usr/local/go
export GOPATH=\$HOME/go
export PATH=\$PATH:\$GOROOT/bin:\$GOPATH/bin
${goproxy_line}
${gosumdb_line}
EOF
  sudo chmod 644 /etc/profile.d/golang.sh
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
    info "安装 nvm ${NVM_VERSION}"
    # 用 git clone 而不是 install.sh：install.sh 也是从 GitHub 拉，
    # 但 clone 失败时报错更清楚，且方便以后切版本
    if ! git clone --depth 1 --branch "$NVM_VERSION" \
           https://github.com/nvm-sh/nvm.git "$nvm_dir" 2>/dev/null; then
      warn "nvm 下载失败（GitHub 可能不通），跳过 Node.js 安装"
      warn "可稍后手动执行：git clone --depth 1 --branch ${NVM_VERSION} https://github.com/nvm-sh/nvm.git ~/.nvm"
      return 0
    fi
  fi

  # 写入 shell 初始化（幂等：先删掉旧的同名块再追加）
  local rc="${TARGET_HOME}/.bashrc"
  if ! grep -q 'NVM_DIR' "$rc" 2>/dev/null; then
    info "写入 nvm 初始化到 ~/.bashrc"
    cat >> "$rc" <<'EOF'

# ── nvm ──────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF
  fi

  # 在当前 shell 里加载 nvm 并装 LTS
  export NVM_DIR="$nvm_dir"
  # shellcheck disable=SC1090
  . "${nvm_dir}/nvm.sh"

  if [[ "$SKIP_MIRROR" != "1" ]]; then
    # 让 nvm 从国内镜像下载 Node 二进制
    export NVM_NODEJS_ORG_MIRROR="https://${MIRROR_HOST}/nodejs-release/"
  fi

  if nvm ls --no-colors 2>/dev/null | grep -q 'lts/'; then
    skip "已安装 LTS 版本 Node"
  else
    info "安装最新 LTS 版 Node.js"
    nvm install --lts
    nvm alias default 'lts/*'
  fi

  if [[ "$SKIP_MIRROR" != "1" ]]; then
    info "配置 npm 使用 npmmirror"
    npm config set registry https://registry.npmmirror.com
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
  printf '  %-14s %s\n' "系统"     "$(. /etc/os-release && echo "$PRETTY_NAME")"
  printf '  %-14s %s\n' "内核"     "$(uname -r)"
  printf '  %-14s %s\n' "时区"     "$(timedatectl show -p Timezone --value)"
  printf '  %-14s %s\n' "NTP 同步" "$(timedatectl show -p NTPSynchronized --value)"
  printf '  %-14s %s\n' "默认target" "$(systemctl get-default)"
  echo   "  ────────────────────────────────────────────────"
  printf '  %-14s %s\n' "git"     "$(git --version 2>/dev/null | awk '{print $3}' || echo '-')"
  printf '  %-14s %s\n' "python3" "$(python3 --version 2>/dev/null | awk '{print $2}' || echo '-')"
  printf '  %-14s %s\n' "pipx"    "$(pipx --version 2>/dev/null || echo '-')"
  printf '  %-14s %s\n' "uv"      "$("${TARGET_HOME}/.local/bin/uv" --version 2>/dev/null | awk '{print $2}' || echo '-')"
  printf '  %-14s %s\n' "go"      "$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || echo '-')"
  if [[ -s "${TARGET_HOME}/.nvm/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    export NVM_DIR="${TARGET_HOME}/.nvm"; . "${NVM_DIR}/nvm.sh"
    printf '  %-14s %s\n' "node"  "$(node --version 2>/dev/null || echo '-')"
    printf '  %-14s %s\n' "npm"   "$(npm --version 2>/dev/null || echo '-')"
  fi
  printf '\033[1;32m═════════════════════════════════════════════════\033[0m\n'
  echo
  info "重新登录或执行 'source ~/.bashrc && source /etc/profile.d/golang.sh' 后生效"
  echo
  warn "本脚本【不做】以下三件事，请按机器角色在克隆后单独处理："
  warn "  1. 不装 Docker —— 与 k8s 的 containerd 存在 cgroup driver 冲突"
  warn "  2. 不关 swap  —— k8s 节点需要关，其他角色保留更好"
  warn "  3. 不改 SSH 密码登录 —— 避免公钥未生效时把自己锁在门外"
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
