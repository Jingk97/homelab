# scripts

Homelab 的运维脚本。所有脚本都按**幂等**设计 —— 可以反复执行，不会重复安装或写坏配置。

---

## 脚本清单

| 脚本 | 用途 | 适用对象 |
|---|---|---|
| [`provision-base.sh`](provision-base.sh) | Ubuntu 24.04 模板通用配置：系统基础 + 运维工具 + 研发工具 + 语言运行时 | 制作模板前的基础机 |

---

## provision-base.sh

### 用法

```bash
# 在目标机器上（用普通用户，不要用 root）
curl -fsSLO https://raw.githubusercontent.com/Jingk97/homelab/main/scripts/provision-base.sh
chmod +x provision-base.sh
./provision-base.sh
```

或者仓库已经 clone 下来的话：

```bash
cd homelab/scripts
./provision-base.sh
```

### 可选开关

| 环境变量 | 作用 |
|---|---|
| **`PROXY`** | 境外目标走代理。**只施加于 GitHub / astral.sh / go.dev**，国内镜像仍直连 |
| `SKIP_MIRROR=1` | 跳过国内镜像源配置（apt / pip / npm / GOPROXY），全部用官方源 |
| `SKIP_LANG=1` | 跳过语言运行时（Python 工具链 / Go / Node.js），只做系统配置和工具 |

```bash
PROXY=http://192.168.5.9:6152 ./provision-base.sh
SKIP_MIRROR=1 ./provision-base.sh
SKIP_LANG=1   ./provision-base.sh
```

### 🔴 关于代理：只作用于境外目标

**代理不做全局导出**，只在访问境外目标的那几条命令上临时施加。

| 目标 | 走代理？ |
|---|---|
| apt（清华镜像） | 🔴 **直连** |
| pip（清华镜像） | 🔴 直连 |
| npm registry / Node 二进制（npmmirror / 清华） | 🔴 直连 |
| Go 版本查询与 tarball（`golang.google.cn`） | 🔴 直连 |
| **M0 GitHub 预检** | 🟢 走代理 |
| **M4 yq**（`github.com/mikefarah/yq`） | 🟢 走代理 |
| **M5 uv**（`astral.sh` → GitHub） | 🟢 走代理 |
| **M7 nvm 本体**（`github.com/nvm-sh/nvm.git`） | 🟢 走代理 |
| M6 Go 回退源（`go.dev`） | 🟢 仅回退时走代理 |

> #### 🔴 为什么国内镜像不能走代理
>
> ```
> Failed to fetch https://mirrors.tuna.tsinghua.edu.cn/ubuntu/dists/noble/InRelease
> 403  Forbidden [IP: 192.168.5.100 6152]
> ```
>
> 走代理后**出口 IP 变成境外**，镜像站直接拒绝。国内镜像必须直连。

**脚本会主动清除继承来的代理变量。** 如果你在 shell 里 `export https_proxy=...` 之后再跑脚本，脚本会把它收编成内部的 `PROXY_URL`，然后**从全局环境中 unset** —— 否则 apt 会继承那些变量，照样踩 403。

**M0 会做两项连通性预检**：

1. 清华镜像**直连**是否可达（不通说明 DNS/网关有问题）
2. GitHub 是否可达（经代理或直连），不通则告警并让你选择是否继续

代理只在本次执行生效，**不写入任何持久化配置**。

### 做了什么

详见 [`docs/04-vm-template.md`](../docs/04-vm-template.md#5-模板通用配置脚本) 中的完整说明。简要：

| 模块 | 内容 |
|---|---|
| **M0** | 前置检查：拒绝 root 直跑、确认系统版本、确认 sudo、**显示代理设置、预检 GitHub 连通性** |
| **M1** | apt 源切清华镜像（deb822 格式）+ 系统全量更新 |
| **M2** | 时区 / NTP 国内源 / DNS 兜底 / journald 限 500M / locale / sudo 免密 |
| **M3** | 运维工具：htop btop ncdu mtr tcpdump nmap rsync sysstat smartmontools tmux… |
| **M4** | 研发工具：git build-essential jq ripgrep fd bat yq |
| **M5** | Python：系统 python3 + venv + pipx + **uv**，pip 走清华源 |
| **M6** | Go：**动态拉官方最新稳定版**到 `/usr/local/go`，GOPROXY 走 goproxy.cn |
| **M7** | Node.js：**nvm** + 最新 LTS，npm 走 npmmirror |
| **M8** | 清理 apt 缓存 + 打印版本汇总 |

### 🔴 脚本刻意不做的三件事

| 不做 | 原因 |
|---|---|
| **不装 Docker** | 与 k8s 的 containerd 存在 cgroup driver 冲突，是经典排查陷阱。需要 Docker 的机器克隆后单独装 |
| **不关 swap** | k8s 节点必须关（kubelet 拒绝启动），但媒体机 / 开发机保留 swap 更好。按角色在克隆后处理 |
| **不改 SSH 密码登录** | 模板里禁用密码登录，万一克隆后公钥没生效就会把自己锁在门外 |

### 幂等性

反复执行是安全的，而且**不会做无谓的重启**：

| 项 | 幂等方式 |
|---|---|
| apt 源 | 已是镜像源则跳过；首次替换会备份为 `ubuntu.sources.bak-<时间戳>` |
| **系统配置** | 用 `write_if_changed` 比对内容，**只有内容真的变了才写盘并重启对应服务** |
| 配置文件位置 | 全部写成独立 drop-in（`*.conf.d/`），**不修改主配置文件** |
| Go | 比对已安装版本与官方最新版，相同则跳过 |
| **Node** | 用 `nvm current` 判断，**不能用 `nvm ls \| grep lts/`** —— 见下 |
| uv / yq | 检测命令是否已存在 |
| `~/.bashrc` | 检测到已有 `NVM_DIR` 则不重复追加 |
| locale | 检测 `locale -a` 里是否已有目标 locale |
| npm registry | 比对当前值，已是 npmmirror 则跳过 |

> **`nvm ls | grep lts/` 是个陷阱**：即使一个 Node 版本都没装，`nvm ls` 也会列出 `lts/*`、`lts/argon` 等**远程别名**，grep 一定命中，会被误判成"已安装"从而跳过安装。必须用 `nvm current`（未安装时返回 `none`/`N/A`）。

### 网络失败的降级行为

`yq`、`uv`、`nvm`、`Go` 这四项依赖外网下载。任何一项失败**只跳过该项并告警**，不会中断整个脚本 —— 其余配置照常完成，失败项可事后手动补装。

其中两项有兜底路径：

| 项 | 主路径 | 兜底 |
|---|---|---|
| **uv** | `astral.sh/uv/install.sh` | GitHub Releases 预编译二进制 → `~/.local/bin/` |

> 🟡 **uv 的安装路径不固定**：不同版本的官方脚本落点不一样（新版 `~/.local/bin`、旧版 `~/.cargo/bin`）。脚本用 `uv_path()` 依次探测 `~/.local/bin`、`~/.cargo/bin`、`~/.uv/bin`、`/usr/local/bin`，再回落到 `command -v`，避免"明明装好了却报未安装"。
| **Go** | `golang.google.cn`（直连） | `go.dev`（走代理） |

### 🔴 已知的变量命名约束

管 nvm 版本的变量**不能叫 `NVM_VERSION`** —— `nvm.sh` 内部也用这个名字，外层 `readonly` 之后加载 nvm 会报 `local: NVM_VERSION: readonly variable`。脚本里用的是 `NVM_TAG`。
