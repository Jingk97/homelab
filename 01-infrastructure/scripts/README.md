# 01 · scripts

← [01 · 基础设施](../README.md)

机器生命周期上的四个脚本。全部**幂等**，全部支持 `--dry-run`，退出码有意义。

```
新克隆的机器
   ↓  init-clone.sh        改主机名 + 静态 IP + 按角色加内核参数
   ↓  provision-base.sh    系统基础 + 运维/研发工具 + 语言运行时
   ↓  fix-root-residue.sh  体检（退出码 0/1/2 即验证信号）
   ↓  sysprep.sh           去身份化 → 关机          🔴 不可逆
模板
```

从 Mac 执行：

```bash
./tools/fleet.sh run <目标> -- 01-infrastructure/scripts/<脚本> [参数]
```

---

## 🔴 一律用普通用户执行，脚本会拒绝 root

用户级工具的落点由 `$HOME` 决定，用 root 跑会全部跑偏，**且不报错**：

| 工具 | 用 `jing` | 用 `root` |
|---|---|---|
| `uv` | `~/.local/bin/uv` | `/root/.local/bin/uv` —— `jing` 敲 `uv` 找不到 |
| `npm config` | `~/.npmrc` | `/root/.npmrc` —— registry 还是官方源 |
| `pipx ensurepath` | `~/.bashrc` | `/root/.bashrc` —— PATH 没变 |
| `nvm` | 属主正确 | **位置对但属主变 root**，`nvm install` permission denied |

只有 root 可用的机器：`ALLOW_ROOT=1 ./provision-base.sh`。

一条命令自查：

```bash
sudo ls /root/.local/bin /root/.npmrc 2>/dev/null      # 有输出就是中招了
```

---

## `provision-base.sh` · 通用配置

```bash
./provision-base.sh
PROXY=http://192.168.5.9:6152 ./provision-base.sh   # 需要下载境外资源时
SKIP_MIRROR=1 ./provision-base.sh                   # 全用官方源
SKIP_LANG=1   ./provision-base.sh                   # 跳过语言运行时
```

| 模块 | 内容 |
|---|---|
| M0 | 拒绝 root、系统版本、sudo、代理设置、**GitHub 与镜像站连通性预检** |
| M1 | apt 换阿里云镜像（deb822）+ 全量更新 |
| M2 | 时区 / NTP / DNS 兜底 / **journald 保留 15 天上限 1G** / locale / sudo 免密 |
| M3 | 运维工具：htop btop ncdu mtr tcpdump nmap rsync sysstat smartmontools tmux |
| M4 | 研发工具：git build-essential jq ripgrep fd bat yq |
| M5 | Python：系统 python3 + venv + pipx + **uv** |
| M6 | Go：**动态拉官方最新稳定版**到 `/usr/local/go`，GOPROXY 走 goproxy.cn |
| M7 | Node.js：**nvm** + 最新 LTS，npm 走 npmmirror |
| M8 | 清理 + 版本汇总 |

### 🔴 代理只作用于境外目标

| 目标 | 走代理 |
|---|---|
| apt / pip / npm registry / `golang.google.cn`（国内镜像） | **否，必须直连** |
| GitHub 预检、`yq`、`uv`、`nvm` 本体、`go.dev` 回退 | 是 |

国内镜像走代理会因为**出口 IP 变成境外**被拒：

```
Failed to fetch https://mirrors.aliyun.com/ubuntu/dists/noble/InRelease
403  Forbidden [IP: 192.168.5.100 6152]
```

脚本会**主动 unset 继承来的代理变量**，否则 apt 会继承它们照样踩 403。代理只在本次执行生效，不写入任何持久化配置。

> 🔴 **但反过来不成立：镜像站返回 403 不等于"走了代理"。**
> 2026-09-04 实测：清华 TUNA 拒绝本地这个 IPv4（它接受 IPv6，但光猫的
> IPv6 WAN 已关，所以直连只剩 IPv4），**直连状态下**
> 连镜像站根目录都是 403（返回它自己的"您目前无法访问此页面"页面），
> 而同一时刻旁路由日志明确显示该域名命中 `GeoSite(cn) using DIRECT`，
> 流量根本没经过代理。
>
> **正确的诊断顺序**：① 查旁路由日志确认实际命中哪条规则
> （`journalctl -u mihomo | grep <域名>`）→ ② 横向对比其他镜像站
> （当时阿里云 / 中科大 / cn.archive 全部 200）。
> 不要一看到 403 就归因于代理，会查错方向。

### 🔴 刻意不做的三件事

| 不做 | 原因 |
|---|---|
| 装 Docker | 与 k8s 的 containerd 存在 cgroup driver 冲突 |
| 关 swap | k8s 节点必须关，媒体机 / 开发机保留更好。按角色在克隆后处理 |
| 改 SSH 密码登录 | 模板里禁用密码登录，万一公钥没生效就把自己锁在门外 |

---

## `fix-root-residue.sh` · 体检与修复

```bash
./fix-root-residue.sh              # 扫描 → 确认 → 清理 → 体检
./fix-root-residue.sh --check      # 只体检
./fix-root-residue.sh --dry-run    # 只列清单
```

| 退出码 | 含义 |
|---|---|
| `0` | 体检全部通过 |
| `1` | 存在 FAIL 项 |
| `2` | 参数错误 / 前置检查不通过 |

清理三类残留：**装进 `/root` 的用户级工具**（删）、**属主变 root 的目录**（chown）、`/root/.bashrc` 里被追加的段落（**只提示不改** —— 那里可能有你自己加的东西）。

**删除前一定先打印清单**；交互环境要输入 `yes`；非交互环境不给 `--yes` 就只体检不清理。

**拒绝以 root 执行** —— 那样体检的是 `/root`，恰恰查不出要查的问题。

---

## `sysprep.sh` · 去身份化

```bash
./sysprep.sh --dry-run        # 先空跑
./sysprep.sh                  # 输入 sysprep 确认 → 清理 → 自动关机
./sysprep.sh --no-shutdown
```

| 环境变量 | 作用 |
|---|---|
| `TMPL_HOSTNAME=ubuntu-tmpl` | 模板通用主机名 |
| `SKIP_UPGRADE=1` | 跳过 `apt full-upgrade` |
| `ENABLE_PVE_CLOUDINIT=1` | 允许 cloud-init 读 Proxmox 注入的配置盘 |

### 🔴 顺序陷阱

| 陷阱 | 后果 |
|---|---|
| 先关机再改网络 | 机器已关，没机会改 → 每台克隆机同一个静态 IP，**第二台开机就冲突** |
| 改完执行 `netplan apply` | IP 当场切换，**SSH 断开，脚本被 SIGHUP 杀掉** → 后面的 `fstrim` 和关机全不执行 |

脚本只写文件 + `netplan generate` 校验语法，**绝不 apply**。改动下次开机自然生效。

### 比手工清理多做的四件事

| # | |
|---|---|
| 1 | **SSH 主机密钥重建兜底服务** —— "首次启动会自动重新生成"依赖 cloud-init 恰好跑起来；没跑的话 `sshd` 起不来，只能靠 noVNC 抢救 |
| 2 | **cloud-init 数据源检测** —— ISO 安装器写的 `datasource_list: [None]` 会让 Proxmox 的 Cloud-Init 标签页**填了完全不生效且无报错** |
| 3 | 🔴 **journal 目录直接删除，不靠 `--vacuum`** —— `journalctl --vacuum-time` 只作用于**已归档**文件且是异步的，实测会漏掉一整批。漏掉的后果不只是占空间，更是**去身份化的漏网**：journal 里带着源机器的 `_MACHINE_ID`、历次主机名、IP、SSH 登录记录。文本日志仍用 `truncate` 并排除 `/var/log/journal`（二进制文件截断成 0 会让 journald 报错），journal 目录另行 `rm -rf`，journald 下次启动按新 machine-id 自动重建 |
| 4 | **用户 SSH 私钥检测** —— 按文件内容（首行 `-----BEGIN ... PRIVATE KEY-----`）识别；**只告警不自动删**，因为也可能是故意放的 |

---

## `init-clone.sh` · 克隆后定制

```bash
./init-clone.sh --hostname vm-router --ip 192.168.5.2 --router --apply
```

| 参数 | 说明 |
|---|---|
| `--hostname` `--ip` | 必填 |
| `--cidr` `--gw` `--dns` | 默认 `24` / `<网段>.1` / `223.5.5.5,119.29.29.29` |
| `--router` | 角色：旁路由。额外写 IP 转发与 `rp_filter` 内核参数 |
| `--apply` | 写完立刻应用网络（**异步执行**，SSH 会断但脚本能跑完） |
| `--force` | 跳过"是不是干净克隆机"的检查 |

**先验收后定制**：`machine-id` 非空、SSH 主机密钥是新的、公钥在。不干净说明模板做坏了，这时候改主机名配 IP 毫无意义。

`--router` 写入的三个内核参数：

| 参数 | 不设会怎样 |
|---|---|
| `net.ipv4.ip_forward=1` | 内核直接丢弃转发包，客户端表现为"网关不通" |
| `net.ipv6.conf.all.forwarding=1` | IPv6 流量绕过旁路由 → **"IPv4 走代理、IPv6 直连"的分流泄漏** |
| `net.ipv4.conf.all.rp_filter=0` | 严格模式丢弃 TUN 造成的不对称路径包。**表现是能 ping 通网关但网页全打不开，且日志里毫无线索** |

`--apply` 用 `systemd-run --no-block` 让 `netplan apply` 脱离 SSH 会话执行，避免连接断开时脚本被杀。

---

## 已知的坑

| # | 坑 | 关键信号 / 规避 |
|---|---|---|
| 1 | `nvm ls \| grep 'lts/'` 恒真 | `nvm ls` 会列出 `lts/*` 等**远程别名**，一个版本没装也命中。用 `nvm current` |
| 2 | 变量不能叫 `NVM_VERSION` | `nvm.sh` 内部同名，外层 `readonly` 后报 `local: NVM_VERSION: readonly variable` |
| 3 | `bash -lc` 读不到 nvm | Ubuntu 的 `~/.bashrc` 开头有 `case $- in *i*) ;; *) return;; esac`，**非交互直接 return**。要显式 `source nvm.sh` |
| 4 | `set -e` + `pipefail` 静默终止 | 赋值里的管道失败会让整个赋值返回非 0。`find \| head` 会 SIGPIPE(141)，`cmd \| awk` 中 cmd 不存在会 127。**一律加 `\|\| true`** |
| 5 | `[[ cond ]] && cmd` 作函数最后一句 | 条件不成立时函数返回 1 → `set -e` 终止。**用 `if` 块**。`--dry-run` 测试常恰好让条件成立，掩盖这个 bug |
| 6 | uv 安装路径不固定 | 新版 `~/.local/bin`、旧版 `~/.cargo/bin`。多候选探测 |

四个脚本都装了 ERR trap，把"脚本突然没了"变成 `[中断] 第 N 行执行失败，退出码 X`。

> trap 报的是 **`set -e` 终止的位置**（函数调用点），不一定是根因那一行 —— 函数末尾语句返回非 0 时，错误在调用点才被捕获。这是 bash 的机制限制。

---

### 🔴 journald 的保留策略：文件数上限是隐形的先决条件

早期 `provision-base.sh` 只写了 `SystemMaxUse=500M` + `SystemMaxFiles=10`。journald 的清理是**多个上限取先到者**，文件数这条远比时间和容量先触发 —— 实测一台每天写 28MB 日志的网关只剩**不到 1 天**的记录。

现在的策略是时间 + 容量 + 磁盘保底三条都设，并且 `MaxFileSec=1day`：

```ini
MaxRetentionSec=15day
SystemMaxUse=1G
SystemKeepFree=2G
MaxFileSec=1day          # 🔴 journald 只能整文件删除
SystemMaxFileSize=64M
SystemMaxFiles=100
```

`MaxFileSec` 不是可选项 —— 一个文件若横跨 5 天，`MaxRetentionSec` 得等它**最新**那条也过期才删得掉，实际保留会远超设定值。

---

## 静态检查

```bash
bash -n *.sh
shellcheck -S warning *.sh      # warning 级别零告警
```
