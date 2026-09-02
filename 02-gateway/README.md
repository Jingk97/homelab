# 02 · 旁路由

← [仓库首页](../README.md)　|　上一步 ← [01 · 基础设施](../01-infrastructure/)

| 文档 | 内容 |
|---|---|
| **本文** | 部署记录 · 运维 · 踩坑 |
| [**原理**](principles.md) | 策略组 / 规则 / mode / TUN / fake-ip / Geo 数据库的机制 |
| [**配置**](config/) | 策略组结构 · AI 规则 · 各段取舍依据 · 机密管理 |

> **状态**：🚧 已完成安装、订阅接入、AI 独立线路、分流验证；TUN / DNS / 全局切换未做

---

## 这台机器

| 项 | 值 |
|---|---|
| 机器 | `vm-router` @ `192.168.5.2`，VMID `102` |
| 规格 | 1 核 / 1 GB / 50 GB（thin，实占约 5 GB） |
| 自启 | `onboot=1`，`startup order=1,up=30`（第一批启动，其他机器依赖网络） |
| 软件 | mihomo（Clash.Meta 内核）v1.19.30 |
| 面板 | metacubexd v1.273.0 @ `http://vm-router:9090/ui` |

它做两件事：**出站分流**（海外走代理、国内直连）与**入站回家**（在外面访问家里服务）。合在一台机器上 —— 两者都是网络层工作，且从外面回家后还想用分流，同一台机器上是一条路由规则，分两台要做策略路由。

---

## 流量路由逻辑

```mermaid
flowchart TD
    C["客户端流量"] --> R["规则表<br/>顺序匹配，第一条命中即停"]
    R --> R1{"① 是 AI 域名吗<br/>90 条规则，最高优先级"}
    R1 -->|"是"| AI["AI服务 · fallback"]
    R1 -->|"否"| R2{"② 是国内吗<br/>GEOSITE,cn / GEOIP,CN"}
    R2 -->|"是"| D["DIRECT<br/>家里电信 IP 直连"]
    R2 -->|"否"| R3["③ MATCH 兜底"]
    R3 --> P["PROXY · select<br/>43 个候选"]

    AI --> A1{"自建线路健康"}
    A1 -->|"是"| SELF["自建线路 · fallback"]
    A1 -->|"否"| RJ1["REJECT<br/>连接立刻被拒"]

    P -->|"默认"| SF["订阅兜底 · fallback"]
    P -.->|"面板可手动固定"| MAN["39 节点 / 自建线路 / DIRECT"]

    SF --> S1{"订阅线路健康"}
    S1 -->|"是"| SUB["订阅线路 · fallback<br/>39 节点按顺序取第一个健康的"]
    S1 -->|"否"| S2{"自建线路健康"}
    S2 -->|"是"| SELF
    S2 -->|"否"| RJ2["REJECT"]

    SELF --> T1{"Trojan 健康"}
    T1 -->|"是"| TN["Trojan-3xUI :9444"]
    T1 -->|"否"| VN["VMess-3xUI :9445"]

    AI -.->|"🔴 结构上不可能连到"| SUB
```

### 三条降级链

```
AI 域名   →  自建线路(Trojan → VMess)  →  REJECT
其余流量  →  订阅线路(39 节点顺序切)   →  自建线路(Trojan → VMess)  →  REJECT
国内域名  →  DIRECT
```

### 两个贯穿全局的设计决定

| 决定 | 理由 |
|---|---|
| **全部用 `fallback`，一个 `url-test` 都没有** | `url-test` 每 300 秒按延迟重选，**出口 IP 频繁变动会触发服务端风控**。`fallback` 只在当前节点不健康时才切，健康时 IP 稳定 |
| **两条链都以 `REJECT` 收尾，不退回 `DIRECT`** | `REJECT` 让连接**立刻被拒**，故障马上可见；退回 `DIRECT` 会变成"能上网但没代理"的**隐性故障**，察觉不到 |

### AI 隔离是结构性的，不是靠规则约束

`AI服务` 的候选只有 `[自建线路, REJECT]` —— **没有任何订阅节点，也没有 `DIRECT`**。即使规则写错、即使手动误操作，也不可能把 AI 流量送到订阅节点上。

原因：AI 服务对**出口 IP 纯净度**敏感。共享节点上的其他用户行为会连累你的账号，表现为验证码变多、限流、乃至封号。

---

## 渐进式上线

```mermaid
flowchart TD
    A["① 装二进制 + 目录"] --> B["② 最小配置试跑<br/>全 DIRECT，不接管流量"]
    B --> C["③ systemd unit<br/>开机自启 + 崩溃自愈"]
    C --> D["④ Web 面板"]
    D --> E["⑤ 接入订阅<br/>验证节点与分流"]
    E --> F["⑥ TUN + auto-redirect<br/>只把一台设备网关指过来"]
    F --> G["⑦ DNS 服务<br/>那台设备 DNS 也指过来"]
    G --> H["⑧ 观察数天"]
    H --> I["⑨ 路由器 DHCP 全局切换"]
    I --> J["⑩ 断电演练"]
    A -.->|"①-⑤ 对家里零影响"| B
    F -.->|"⑥-⑧ 只影响自己那台"| G
```

**①–⑤ 已完成，对家里其他人零影响** —— 没开 TUN、不占 53 端口，只有手动配了代理的客户端会走。

---

## 选型

| | |
|---|---|
| **mihomo** 而不是 sing-box | YAML 能写注释、可进 git；面板能**实时看域名命中哪条规则**；排查就是 `systemctl` + `journalctl` |
| **mihomo** 而不是 OpenWrt | OpenWrt 的价值在拨号 / Wi-Fi / VLAN / QoS —— 这些都在光猫上，一个都用不到 |
| **VM** 而不是 LXC | TUN + 大量 nftables 规则，非特权 LXC 权限问题多，特权 LXC 又失去隔离意义 |

### 🔴 下载不带微架构后缀的包

```
mihomo-linux-amd64-v1.19.30.gz              ← 用这个
mihomo-linux-amd64-v3-v1.19.30.gz           ← 需要 AVX2
mihomo-linux-amd64-compatible-v1.19.30.gz   ← 给很老的 CPU
```

`v1`/`v2`/`v3` 是 GOAMD64 微架构等级。mihomo 瓶颈在网络 I/O 和加解密，加解密走 AES-NI 各等级都有，优化收益几乎为零；而 v3 二进制在不支持 AVX2 的机器上直接 `SIGILL` 崩溃。

---

## 部署记录

### 前置：机器怎么来的

```bash
./tools/fleet.sh run <克隆机临时IP> -- 01-infrastructure/scripts/init-clone.sh \
    --hostname vm-router --ip 192.168.5.2 --router --apply
```

`--router` 写入的三个内核参数及后果见 [01 · scripts](../01-infrastructure/scripts/)。

### 下载渠道实测

```
github.com                            直连 200
release-assets.githubusercontent.com  直连 200      ← Release 文件实际存放处
raw.githubusercontent.com             直连和走代理都被重置
```

版本不写死：

```bash
curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name"'
```

### 安装

```bash
# Mac → vm-router
scp /tmp/mihomo-linux-amd64-v1.19.30.gz vm-router:~/

# vm-router
gunzip -t ~/mihomo-linux-amd64-v1.19.30.gz && echo "压缩包完好"
sha256sum ~/mihomo-linux-amd64-v1.19.30.gz            # 与 Mac 比对
gunzip -f ~/mihomo-linux-amd64-v1.19.30.gz
sudo install -m 0755 ~/mihomo-linux-amd64-v1.19.30 /usr/local/bin/mihomo
rm -f ~/mihomo-linux-amd64-v1.19.30
mihomo -v
sudo mkdir -p /etc/mihomo/{ui,providers,ruleset}
```

```
Mihomo Meta v1.19.30 linux amd64 with go1.26.6
Use tags: with_gvisor          ← 带 gvisor 网络栈，TUN 的 stack: mixed 需要它
```

> **用 `install` 不用 `cp` + `chmod`**：一步完成复制+权限，且**先写临时文件再原子替换** —— 覆盖正在运行的二进制不会写坏。升级时这个特性是关键。

### systemd

```ini
[Unit]
After=network-online.target nss-lookup.target
Wants=network-online.target
# 🔴 重启风暴保护，见坑 5
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=always
RestartSec=3
LimitNOFILE=1048576          # 代理并发连接多，默认 1024 远不够
```

自愈已实测：`sudo pkill -x mihomo` 后 3 秒自动拉起，PID 变化确认是新进程。

### Web 面板

```bash
curl -sfL -o /tmp/ui.tgz \
  https://github.com/MetaCubeX/metacubexd/releases/download/v1.273.0/compressed-dist.tgz
sudo rm -rf /etc/mihomo/ui && sudo mkdir -p /etc/mihomo/ui
sudo tar -xzf /tmp/ui.tgz -C /etc/mihomo/ui
```

配置加 `external-ui: /etc/mihomo/ui`，**必须 `systemctl restart`** —— `external-ui` 在启动时注册静态路由，热重载不生效。

🔴 **面板显示的"IP"是浏览器自己查的，反映的是浏览器所在机器**，不是服务器。判断服务器出口必须在服务器上 `curl -x http://127.0.0.1:7890 ...`。

### 接入订阅

订阅链接写进 `config/mihomo.local.env`（gitignore，权限 600），模板里用 `${SUB_URL_A}` 占位。详见 [`config/`](config/)。

---

## 验收

### 五层体检

| 层 | 查什么 | 命令 |
|---|---|---|
| L1 | 服务在不在 | `systemctl is-active/is-enabled mihomo`、**`NRestarts`** |
| L2 | 端口在不在 | `sudo ss -lntp \| grep -E ':(7890\|9090)'` |
| L3 | 配置对不对 | `sudo mihomo -t -d /etc/mihomo` |
| L4 | API 与鉴权 | 带密码返回版本 / 不带密码 **401** / 面板 200 |
| L5 | 🔴 **代理链路** | **在服务器上** `curl -x http://127.0.0.1:7890 ...` |

**L5 是面板给不了的**，也是唯一能证明代理真的在工作的检查。

### 实测结果

```
策略组
  AI服务     fallback   自建线路 → REJECT
  自建线路   fallback   Trojan-3xUI(726ms) → VMess-3xUI(1433ms)
  订阅线路   fallback   39 节点按顺序
  订阅兜底   fallback   订阅线路 → 自建线路 → REJECT
  PROXY     select     43 候选，默认订阅兜底

连接链路实测
  huggingface.co      DomainSuffix    AI服务 <- 自建线路 <- Trojan-3xUI
  www.youtube.com     Match           PROXY <- 订阅兜底 <- 订阅线路 <- 香港01
  mirrors.aliyun.com                  DIRECT
  api.openai.com      HTTP 401        OpenAI 正常响应，请求确实到达

出口 IP
  国内域名   myip.ipip.net 经代理 → 36.106.203.193 中国天津电信   走 DIRECT
  海外域名   ipinfo.io    经代理 → 185.220.238.132 JP/Tokyo      走节点
```

> `chatgpt.com` / `claude.ai` 用 `curl` 测会返回 **403** —— 那是 Cloudflare 的机器人挑战要求浏览器指纹，不是链路问题。浏览器访问正常。

---

## 坑

### 1 · macOS TCC 让 `scp` 读不了 `~/Downloads`

```
scp: open local ".../mihomo-....gz": Operation not permitted
```

**不是 Unix 权限问题。** macOS 对 `~/Downloads`、`~/Documents`、`~/Desktop` 做了内核级保护（TCC）。

| 信号 | 含义 |
|---|---|
| `ls -l` 显示你是属主、权限正常 | Unix 权限够 |
| 目录权限位末尾有 `+`（`drwx------+`） | 带 ACL —— TCC 标记 |
| 🔴 报 **`Operation not permitted`(EPERM)** 而非 `Permission denied`(EACCES) | **判断是不是 TCC 的关键信号**。看到 EPERM 查隐私权限，别去 `chmod` |

```bash
cp ~/Downloads/xxx /tmp/          # 一次性绕开
# 永久：系统设置 → 隐私与安全性 → 文件与文件夹 → 终端 → 下载文件夹
#       🔴 改完必须 Cmd+Q 完全退出终端 —— TCC 权限在进程启动时确定
```

### 2 · `sudo` 只作用于它所在的那一侧

```bash
sudo scp file vm-router:~/        # 绝对不要
```

`sudo scp` 让 scp 以 **Mac 的 root** 运行，`HOME` 变 `/var/root`：读不到 `~/.ssh/config` 的 `Host vm-*`、读不到私钥、会尝试 `root@vm-router`。

| 问自己 | 答案 |
|---|---|
| 要读 `~/.ssh/` 吗？（`ssh`/`scp`/`rsync`/`git`） | **绝不加 sudo** |
| 要写系统目录吗？ | 加 sudo，**只在目标机器上加** |

另外 **`scp` 不能直接写需要 root 的目录** —— 远端 scp 进程以登录用户身份运行。必须"先传家目录，再 `sudo install`"。

### 3 · `pkill -f` 会杀掉自己

```bash
sudo pkill -f 'mihomo -d'         # SSH 立刻断开，退出码 255
```

`-f` 匹配**完整命令行**，而执行脚本的远端 bash 进程命令行里正好含 `mihomo -d /etc/mihomo`。

```bash
sudo pkill -x mihomo              # -x 精确匹配进程名
```

**通用教训**：`pkill -f` 的模式串不要包含当前脚本命令行里出现过的内容。

### 4 · 🔴 mihomo 默认的 Geo 数据源在国内不可达

```
GEOIP 规则需要 country.mmdb
  ↓ mihomo 默认从 raw.githubusercontent.com 下载
  ↓ 该域名直连和走代理都被重置
can't download MMDB: context deadline exceeded
  ↓ Parse config error → 进程 fatal 退出
```

必须显式配 `geox-url`。实测下载速度：

```
cdn.jsdelivr.net        1.8 MB/s   4.3s      ✅ 选它
testingcf.jsdelivr.net  572 KB/s   13.4s
GitHub Release          27 KB/s    30s 只拉到 10%
raw.githubusercontent   完全不通
```

### 5 · 🔴 `Restart=always` + 配置错误 = 无限重启，而 `is-active` 显示 `active`

```
起来 → fatal 退出 → 3 秒后重启 → 起来 → fatal ...
systemctl is-active 抓拍时经常正好是 active   ← 状态具有欺骗性
```

加重启风暴保护，**让故障暴露而不是被掩盖**：

```ini
StartLimitIntervalSec=300
StartLimitBurst=5      # 300 秒内失败 5 次就停止重试，进入 failed
```

### 6 · 管道会吞掉退出码

```bash
sudo mihomo -t -d /etc/mihomo 2>&1 | tail -1     # set -e 拿到的是 tail 的退出码，永远 0
```

结果是校验失败了脚本还继续往下 restart。**判断成败必须直接看命令本身的退出码**：

```bash
if sudo mihomo -t -d /etc/mihomo > /tmp/t.log 2>&1; then ok; else cat /tmp/t.log; exit 1; fi
```

### 7 · 🔴 IPv6 优先导致订阅被 403

机场对订阅链接做 IP 鉴权，白名单加的是 IPv4。而 Linux 按 **RFC 6724** 默认优先 IPv6：

```
默认（走 IPv6）  403 AUTH_FAIL
强制 IPv4        200 ✅          ← 白名单其实生效了
```

**Happy Eyeballs 救不了** —— 它只处理"IPv6 连不上"，而这里 TCP + TLS 都成功了，403 是应用层返回的。

**改 `/etc/gai.conf` 也没用** —— mihomo 是 Go 写的，用 Go 自己的解析器，不读 `gai.conf`。

解法是配置里一行：

```yaml
ipv6: false
```

副作用是正收益：**DNS 不返回 AAAA，客户端不会走 IPv6 直连绕过代理**，分流泄漏从源头消失。

### 8 · `GEOIP,CN,DIRECT,no-resolve` 让国内流量全走了代理

实测 `www.qq.com` 命中 `Match` 经日本节点。根因与正确写法见 [原理 · 规则](principles.md#3-规则)。

### 9 · `ipv6: false` 的真实副作用：清华镜像连不上

```
清华镜像  强制 IPv4  →  403        你家的 IPv4 被清华拒绝
          强制 IPv6  →  200
阿里云    强制 IPv4  →  200
中科大    强制 IPv4  →  200
```

之前 `provision-base.sh` 那次 403 曾被归因为"走代理出口变境外"，**实际可能一直是这个 IPv4 被拒**。

`ipv6: false` 让 `DIRECT` 只走 IPv4，所以设备走旁路由后清华镜像会连不上。

| 方案 | 取舍 |
|---|---|
| **apt 源换阿里云/中科大** | 最简单，实测都 200。**推荐** |
| 打开 `ipv6: true` | 重新引入 IPv6 分流泄漏风险 |
| 加规则让清华走代理 | 清华拒绝境外 IP，更不通 |

---

## 待办

```
□ apt 源从清华换到阿里云/中科大
□ ⑥ TUN + auto-redirect
□ ⑦ DNS（fake-ip + fake-ip-filter）
□ ⑧ 观察数天
□ ⑨ 路由器 DHCP 全局切换（网关与 DNS 都指向 .2，备用 DNS 留空）
     🔴 切换前先把 DHCP 租期从 604800 秒（7天）改成 7200 秒
□ ⑩ 断电演练
□ healthcheck.sh：把五层体检做成退出码信号
```
