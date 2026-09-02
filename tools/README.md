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
