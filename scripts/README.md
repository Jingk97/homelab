# scripts

Homelab 的运维脚本。所有脚本都按**幂等**设计 —— 可以反复执行，不会重复安装或写坏配置。

---

## 脚本清单

按 ① → ② → ③ 的顺序使用。

| 顺序 | 脚本 | 用途 | 适用对象 |
|---|---|---|---|
| **①** | [`provision-base.sh`](provision-base.sh) | 通用配置：系统基础 + 运维工具 + 研发工具 + 语言运行时 | 制作模板前的基础机 |
| **②** | [`fix-root-residue.sh`](fix-root-residue.sh) | 清理"误用 root 跑脚本"的残留，并**重新体检**每一项 | 同上，跑完 ① 之后 |
| **③** | [`sysprep.sh`](sysprep.sh) | **去身份化**：清空 machine-id、重置 SSH 主机密钥、改回 DHCP、fstrim → 关机 | 即将转成模板的机器 |

> ② 和 ③ 都提供 `--dry-run`（只打印不动手），**第一次跑先空跑一遍**。
> ③ 是**不可逆**的，执行前务必在 Proxmox 网页上打快照。

---

## provision-base.sh

### 用法

```bash
# 🔴 必须用普通用户执行，脚本会拒绝 root（详见下方「关于 root」）
curl -fsSLO https://raw.githubusercontent.com/Jingk97/homelab/main/scripts/provision-base.sh
chmod +x provision-base.sh
./provision-base.sh
```

或者仓库已经 clone 下来的话：

```bash
cd homelab/scripts
./provision-base.sh
```

### 🔴 关于 root

**脚本会直接拒绝以 root 执行。** M5/M7 装的是用户级工具，按 `$HOME` 决定落点：

| 工具 | 正常 | root 下 |
|---|---|---|
| `uv` | `~/.local/bin/uv` | `/root/.local/bin/uv` |
| `npm config` | `~/.npmrc` | `/root/.npmrc` |
| `pipx ensurepath` | `~/.bashrc` | `/root/.bashrc` |
| `nvm` | 位置对 | **属主变 root，普通用户用不了** |

这类问题**不会报错**，只会在后来敲命令时"找不到"。用日常账号跑即可 —— 脚本内部需要提权的地方会自己调 `sudo`。

只有 root 可用的机器：`ALLOW_ROOT=1 ./provision-base.sh`。

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


---

## fix-root-residue.sh

### 用法

```bash
./fix-root-residue.sh              # 扫描 → 交互确认 → 清理 → 体检
./fix-root-residue.sh --check      # 只体检，不扫描不清理
./fix-root-residue.sh --dry-run    # 只列清单，绝不动手
./fix-root-residue.sh --yes        # 跳过交互确认（自动化用）
```

### 为什么需要它

`provision-base.sh` 的 M5/M7 装的是**用户级**工具，落点由 `$HOME` 决定。用 root（或 `sudo`）跑会产生两类残留，而且**全程不报错**：

| 类型 | 现象 | 处理 |
|---|---|---|
| **A · 装错地方** | `uv` / `uvx` / `.npmrc` 落到 `/root` 下，日常账号 `command -v uv` 什么也找不到 | 删除 |
| **B · 属主错了** | `nvm` 位置对，但目录属主是 root → 普通用户 `nvm install` 直接 permission denied | `chown` 回日常用户 |
| C · 只提示 | `/root/.bashrc` 被追加了 `NVM_DIR` / `pipx` 段落 | **不自动改**，那里可能有你自己加的东西 |

一条命令判断有没有中招：

```bash
sudo ls /root/.local/bin /root/.npmrc 2>/dev/null
```

### 体检项

| 分组 | 内容 |
|---|---|
| 系统基础 | 系统版本 / 时区 / NTP / **默认 target** / apt 镜像源 / journald 上限 / sudo 免密 / DNS / guest-agent |
| 工具 | 运维工具、研发工具是否齐全，`yq` 是否装上。**`fd` / `bat` 两个名字都认** —— Ubuntu 打包成 `fdfind` / `batcat`，本体在但软链没建成时会明确指出是软链的问题，而不是笼统报"缺" |
| 语言运行时 | `python3` / `pipx` / **`uv`（含"只存在于 /root 下"的专门判断）** / `go` + `GOPROXY` / **`nvm` 目录属主** / `node` / `npm` registry |
| 兜底 | 家目录下有无非日常用户属主的文件；`/root` 下有无残留 |

**退出码就是验证信号**：

| 码 | 含义 |
|---|---|
| `0` | 体检全部通过 |
| `1` | 存在 FAIL 项 |
| `2` | 参数错误 / 前置检查不通过 |

### 安全约束

- **拒绝以 root 执行** —— 那样体检的是 `/root` 而不是日常账号，恰恰查不出要查的问题
- **删除前一定先打印清单**；交互环境下要输入 `yes` 才动手
- 非交互环境（管道执行）下不给 `--yes` 就**只体检不清理**

---

## sysprep.sh

### 用法

```bash
# 🔴 执行前先在 Proxmox 网页上打快照 —— 本脚本不可逆
./sysprep.sh --dry-run        # 先空跑一遍，看清楚会做什么
./sysprep.sh                  # 交互确认（要输入 sysprep）→ 清理 → 自动关机
./sysprep.sh --no-shutdown    # 清理完不关机
```

| 环境变量 | 作用 |
|---|---|
| `TMPL_HOSTNAME=ubuntu-tmpl` | 模板的通用主机名（默认值） |
| `SKIP_UPGRADE=1` | 跳过 `apt full-upgrade` |
| `KEEP_STATIC_IP=1` | 保留静态 IP —— **极少用**，会导致克隆机冲突 |
| `ENABLE_PVE_CLOUDINIT=1` | 允许 cloud-init 读取 Proxmox 注入的配置盘，见下 |

### 🔴 顺序陷阱

去身份化里有两步必须按特定顺序做：

| 陷阱 | 后果 |
|---|---|
| **先关机，再想起来改网络** | 机器已经关了，没机会改 → 每台克隆机都是同一个静态 IP，**第二台开机就冲突** |
| **改完网络执行 `netplan apply`** | IP 立刻切换，**当前 SSH 连接当场断开**，脚本收到 `SIGHUP` 被杀 → 后面的 `fstrim` 和关机**全都不执行** |

脚本只写 netplan 文件 + `netplan generate` 校验语法，**绝不 apply**。改动下次开机自然生效 —— 反正马上要关机，apply 没有任何价值，只有断连的风险。

### 模块

| 模块 | 内容 |
|---|---|
| **M0** | 前置检查 + **不可逆操作确认**（打印主机名 / IP / 虚拟化类型，要求输入 `sysprep`）；检测到物理机会红字告警 |
| **M1** | 转模板前关键项体检：家目录属主、`/root` 残留、**SSH 公钥是否在**、sudo 免密、**用户 SSH 私钥检测**、**磁盘是否支持 discard** |
| **M2** | 通用软件补齐：`full-upgrade` + `qemu-guest-agent` / `cloud-init` / vim curl wget htop |
| **M3** | 主机名改通用名，同步改 `/etc/hosts` |
| **M4** | 网络改回 DHCP：备份 → 写入 → `chmod 600` → **只 generate 不 apply** |
| **M5** | **去身份化核心**：清空 `machine-id`、删 SSH 主机密钥 + 装重建兜底服务、`cloud-init clean`、清随机种子与 DHCP 租约 |
| **M6** | 清理：apt 缓存与包索引、journal、`/var/log` 文本日志、shell 历史、临时目录 |
| **M7** | `fstrim` 把已删除的块还给 LVM-Thin 池 |
| **M8** | 结果报告 + 10 秒倒计时后关机（可 Ctrl+C 取消） |

### 比手工清理多做的四件事

**① SSH 主机密钥的重建兜底**

常见说法是"删掉主机密钥，首次启动会自动重新生成"，但那**依赖 cloud-init 恰好正常跑起来**。万一没跑，`sshd` 因为没有主机密钥**根本起不来**，克隆机只能靠 noVNC 抢救。脚本会装一个 systemd 服务，靠 `ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key` 实现天然幂等 —— 密钥存在时直接跳过，不需要自我禁用。

> ⚠️ 主机密钥删掉之后到关机之前，**不要重启 sshd**。

**② cloud-init 数据源检测**

Ubuntu Server 的 ISO 安装器（subiquity）会写下 `datasource_list: [ None ]`，意思是"不要去任何地方找配置"。结果是 **Proxmox 网页 Cloud-Init 标签页里填的用户名 / IP 完全不生效，而且没有任何报错**。脚本会检测并提示；要打开支持用 `ENABLE_PVE_CLOUDINIT=1`。

**③ 更精确的日志清理**

```bash
# ❌ 会把 journal 的二进制文件也截断成 0，导致 journald 报错
sudo find /var/log -type f -exec truncate -s 0 {} \;

# ✅ 排除 /var/log/journal（已由上一步的 vacuum 处理）
sudo find /var/log -type f -not -path '/var/log/journal/*' -exec truncate -s 0 {} +
```

**④ 用户 SSH 私钥检测（只告警不自动删）**

`~/.ssh/` 下的**私钥**会被原样复制进每一台克隆机 —— 和主机密钥是同一类风险：一份私钥变成 N 份，任何一台被拿下，攻击者就能拿着这把钥匙去它能到的所有地方。

但这**不能由脚本替你决定**，也可能是你**故意**放的（想让每台克隆机开箱就能拉私有仓库）。所以 M1 只做三件事：**列出文件、给出删除命令、在 M8 收尾时再提醒一次**（M1 的告警很容易被后面几百行输出淹掉）。

识别按**文件内容**而不是文件名 —— 叫什么名字都可能是私钥，但私钥第一行一定是 `-----BEGIN ... PRIVATE KEY-----`。

另外，`history -c` 在**非交互脚本里是空操作**（脚本是子进程，清不掉调用者会话的内存历史）。真正有效的是删 `~/.bash_history` 文件 —— bash 只在**正常 exit** 时回写该文件，而脚本最后是 `shutdown`（SIGTERM），所以不会被写回。

---

## 静态检查

三个脚本都通过：

```bash
bash -n *.sh                        # 语法
shellcheck -S warning *.sh          # 静态分析，warning 级别零告警
```
