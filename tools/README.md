# tools · 跨服务运维工具

← [仓库首页](../README.md)

不属于某一步，横向服务于所有机器，因此不编号。

---

## `fleet.sh` —— 批量推送与执行

在 **Mac** 上运行，把整个仓库 rsync 到远端 `~/homelab/`，并按需执行其中的脚本。

```bash
./fleet.sh list                              # 机器清单 + SSH 在线探测
./fleet.sh push [目标...]                     # 只推送
./fleet.sh exec [目标...] -- <命令>            # 远程执行命令
./fleet.sh run  [目标...] -- <脚本路径> [参数]  # 推送后执行，路径相对仓库根
```

**目标**可以是 `hosts.conf` 里的机器名、分组名、`all`，或直接写 IP（用于还没进清单的新机器）。省略目标 = `all`。

| 选项 | 说明 |
|---|---|
| `--user <name>` | SSH 用户，默认 `jing` |
| `--serial` | 串行执行（默认并行） |
| `--dry-run` | fleet 自己空跑：只列出会连哪些机器，**不连接** |

🔴 **`--` 后面的参数原样透传给远端，不会被 fleet 解析**：

```bash
./fleet.sh --dry-run run vm-router -- xxx.sh        # fleet 空跑，不连机器
./fleet.sh run vm-router -- xxx.sh --dry-run        # 真连上去，让【远端脚本】空跑
```

### 为什么是「从 Mac 推」而不是「VM 自己 git clone」

| # | |
|---|---|
| 1 | `raw.githubusercontent.com` 在国内实测不可达（直连和走代理都被重置），VM 上 `curl` 拉脚本这条路走不通 |
| 2 | 私有仓库要在**每台 VM 上放凭证** —— 与"私钥不进模板"的原则冲突 |
| 3 | 推的是本地**当前**版本，改完立刻能测，不用先 commit + push |
| 4 | VM 不需要任何外网连通性，代理挂了照样能维护 |

### 🔴 排除项是安全边界

`push` 会显式排除这几类，它们**不能跟着仓库广播给所有机器**：

```
.git/            版本库
*.local.env      控制台密码等机密，只该留在 Mac 上
providers/       节点文件，含服务器地址和密码
config.yaml      渲染产物，含上面两者的内容
*.bak-*          备份
```

这几类由**各服务自己的部署脚本定向投递**给需要的那一台。

---

## `hosts.conf` —— 机器清单

```
名称        地址            分组（逗号分隔，无空格）
vm-router   192.168.5.2     gateway,longterm
```

`all` 是内置目标，匹配文件里所有机器，不用写进分组列。

🔴 **地址要和 [01 · 网络规划](../01-infrastructure/02-network.md) 的分配表保持一致**，改了两边都要改。

---

## 前置条件

| 条件 | 怎么来的 |
|---|---|
| SSH 免密 | 两台 Mac 的公钥已进模板，克隆机开箱可登 |
| 名字解析 | Mac 的 `/etc/hosts`；`~/.ssh/config` 的 `Host vm-*` 通配提供用户名与密钥 |
| 远端 sudo 免密 | `provision-base.sh` 配置，所以 `ssh xxx 'sudo ...'` 可非交互执行 |

### 🔴 Mac 上是 bash 3.2

Apple 因 GPLv3 停在 2007 年的版本。`fleet.sh` 必须避开 bash 4+ 特性：

| 不能用 | 替代 |
|---|---|
| `declare -A` 关联数组 | 每次重扫 `hosts.conf`，十几台机器性能无所谓 |
| `mapfile` / `readarray` | `while read` |
| `${var,,}` / `${var^^}` | `tr` |

还有一个只在 bash 3.2 出现的坑：**`$VAR` 后面紧跟全角标点时，首字节会被吞进变量名**，报 `unbound variable`。bash 5.2 不受影响，所以只有 Mac 上的脚本会炸。**一律写 `${VAR}`**。

---

## `setup-mac-client.sh` —— 把一台 Mac 配成管理终端

在**要接入的那台 Mac 上**运行（不是 `fleet.sh` 那种远程推送）。写入 `~/.ssh/config` 与 `/etc/hosts` 的 homelab 段，让你能用 `ssh pve` / `ssh vm-dev` 这种短名字直接免密登录。

```bash
./setup-mac-client.sh              # 执行
./setup-mac-client.sh --dry-run    # 只打印将要做什么，不动任何文件
./setup-mac-client.sh --check      # 只跑验证，不修改
./setup-mac-client.sh --key ~/.ssh/id_xxx   # 密钥不叫 id_ed25519 时
```

退出码即验证信号：`0` 全部可达 · `1` 有主机连不上 · `2` 前置检查失败。

### 它做什么、不做什么

| | |
|---|---|
| **做** | 写 `~/.ssh/config`（用户 + 密钥，**不写 HostName**）、写 `/etc/hosts`、验证四台机器能否免密登录 |
| **不做** | 🔴 **不生成也不分发密钥** —— 分发有安全含义，应由你显式 `ssh-copy-id`；不装软件、不改系统设置 |

### 🔴 幂等的实现方式

自己的内容用 `# >>> homelab >>>` / `# <<< homelab <<<` 包住，每次执行**先剔除旧块再写新块**。所以：

- 重复执行不会叠加
- **不碰你自己的其他配置**（比如 `~/.ssh/config` 里的 GitHub 条目）
- 两个文件都先存 `.bak-<时间戳>`

用 `awk` 而不是 `sed -i` 剔除旧块 —— macOS 的 BSD sed 的 `-i` 必须跟备份后缀（写 `-i ''` 才行），和 GNU sed 行为不同，脚本会因机器而异。

### 🔴 为什么 `~/.ssh/config` 里不写 HostName

名字到 IP 的映射**只在 `/etc/hosts` 存一份**。两个文件各存一份地址，改了一处忘另一处是迟早的事。

而 `ssh_config` 是**首次匹配生效**（同一个键先出现的赢），所以脚本按「先按角色定 `User` → 再用一条公共块补密钥」分成三块写，两者互不覆盖。

### 一个踩过的坑：ERR trap 会污染验证输出

脚本用 `set -E` + ERR trap 做失败定位。但**`set -E` 会把 trap 传播进命令替换的子 shell** —— 验证阶段 `if out="$(ssh ...)"` 即使写在条件里，子 shell 里 ssh 的非零退出仍会触发 trap，导致每台连不上的机器都刷一段"[中断] 第 N 行失败"，把真正的结果淹没。

处理：**进入验证阶段就 `trap - ERR`**。那之后"连不上"是有意义的结果，不是错误。
