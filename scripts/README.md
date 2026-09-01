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
| `SKIP_MIRROR=1` | 跳过国内镜像源配置（apt / pip / npm / GOPROXY），全部用官方源 |
| `SKIP_LANG=1` | 跳过语言运行时（Python 工具链 / Go / Node.js），只做系统配置和工具 |

```bash
SKIP_MIRROR=1 ./provision-base.sh
SKIP_LANG=1   ./provision-base.sh
```

### 做了什么

详见 [`docs/04-vm-template.md`](../docs/04-vm-template.md#5-模板通用配置脚本) 中的完整说明。简要：

| 模块 | 内容 |
|---|---|
| **M0** | 前置检查：拒绝 root 直跑、确认系统版本、确认 sudo 可用 |
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

反复执行是安全的：

- apt 源：已是镜像源则跳过；首次替换会备份原文件为 `ubuntu.sources.bak-<时间戳>`
- Go：比对已安装版本与官方最新版，相同则跳过
- nvm / uv：检测已安装则跳过
- 配置文件：全部用独立的 drop-in 文件（`*.conf.d/`），不修改主配置
- `~/.bashrc`：检测到已有 `NVM_DIR` 则不重复追加

### 网络失败的降级行为

`yq`、`uv`、`nvm`、`Go` 这四项依赖外网下载。任何一项失败**只跳过该项并告警**，不会中断整个脚本 —— 其余配置照常完成，失败项可事后手动补装。
