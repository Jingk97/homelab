# 02 · config

← [02 · 旁路由](../README.md)

mihomo 的配置。**模板进 git，机密不进。**

---

## 文件

| 文件 | git | 说明 |
|---|---|---|
| `config.yaml.tmpl` | ✅ | 配置模板，占位符 `${MIHOMO_SECRET}` |
| `mihomo.env.example` | ✅ | 环境变量模板 |
| `mihomo.local.env` | ❌ | 真实的控制台密码与版本号，权限 `600` |
| `providers/` | ❌ | 节点文件，含服务器地址和密码 |
| `config.yaml` | ❌ | 渲染产物，含上面两者的内容 |

初始化：

```bash
cp mihomo.env.example mihomo.local.env
chmod 600 mihomo.local.env
sed -i '' "s|<openssl.*>|$(openssl rand -hex 16)|" mihomo.local.env
```

后三项同时被本目录 `.gitignore` 和 [`tools/fleet.sh`](../../tools/) 的 rsync 排除项挡住 —— **两道闸**：git 挡住提交，fleet 挡住广播给所有机器。它们只由部署脚本定向投递给 `vm-router`。

---

## 远端目录

```
/etc/mihomo/
├── config.yaml       主配置，权限 600
├── providers/        节点文件
├── ruleset/          规则集缓存
├── ui/               Web 面板静态文件
└── cache.db          fake-ip 映射与会话缓存，运行时自动生成
```

---

## 当前配置各段

| 段 | 值 | 为什么 |
|---|---|---|
| `mixed-port: 7890` | HTTP + SOCKS5 共用 | 少开一个端口 |
| `allow-lan: true` | 允许局域网连入 | **旁路由必须开**，否则只有本机能用 |
| `mode: rule` | 按规则分流 | 另有 `global`（全部走代理）/ `direct`（全部直连），用于排障时快速切换 |
| `external-controller: 0.0.0.0:9090` | 控制接口 | **热重载与 Web 面板都靠它** |
| `secret` | 控制台密码 | 🔴 不设则局域网内任何人都能改配置、看全部连接 |

验证 `secret` 生效：不带 `Authorization` 头请求应返回 **401**。

---

## 演进路线

### ③ 节点：`proxy-providers` 用 `type: file`

节点来自本地文件而非订阅链接，所以用 `type: file` 而不是 `type: http`：

```yaml
proxy-providers:
  机场A:
    type: file
    path: ./providers/a.yaml
```

🔴 **先确认格式**：Surge 和 Clash 的节点写法完全不同。

```bash
grep -c '^proxies:' <文件>      # 1 = Clash 格式可直接用；0 = Surge 格式需转换
```

### ③ 分流：三层结构

```
proxies / proxy-providers     节点（单个服务器）
        ↓
proxy-groups                  策略组（一组节点 + 怎么选）
        ↓
rules                         规则（什么流量 → 哪个策略组）
```

**规则指向策略组而不是节点** —— 这层间接让你换节点时不用动规则。

| 策略组类型 | 行为 | 适合 |
|---|---|---|
| `select` | 手动选 | 想自己掌控的分组 |
| `url-test` | 自动选延迟最低 | 日常上网 |
| `fallback` | 按顺序，前面不通用后面 | **节点层的故障转移** |
| `load-balance` | 多节点分摊 | 大流量下载 |

不同流量走不同出口：

```yaml
rules:
  # 🔴 顺序匹配，第一条命中即停，细的写前面
  - RULE-SET,youtube,落地A
  - RULE-SET,google,落地B
  - GEOIP,CN,DIRECT
  - MATCH,落地B          # 兜底，必须最后
```

🔴 **别手写域名列表**。YouTube 的视频流走 `googlevideo.com`、缩略图走 `ytimg.com`、登录走 `accounts.google.com` —— 只写 `youtube.com` 的话**页面能开但视频卡，且查不出原因**。用 MetaCubeX 的 geosite 规则集，边角域名都收全了且持续更新。

### ⑥ TUN

```yaml
tun:
  enable: true
  stack: mixed          # TCP 走内核栈（快），UDP 走 gvisor（兼容）
  auto-route: true      # 自动接管本机路由表
  auto-redirect: true   # 🔴 自动写 nftables，劫持【转发流量】
```

🔴 **`auto-redirect` 是旁路由能成立的关键**。别的机器把网关指过来，那些流量对 mihomo 是**"转发"而不是"本机发出"**，`auto-route` 管不到。没有它就得手写 nftables + 策略路由。

这也是 [`init-clone.sh --router`](../../01-infrastructure/scripts/) 提前关掉 `rp_filter` 的原因 —— TUN 会制造不对称路径。

### ⑦ DNS：fake-ip，不做兜底

```yaml
dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:              # 🔴 这些【不做】fake-ip
    - '*.lan'
    - '+.home'                 # 光猫的 zte.home
    - 'vm-*'
    - 'pve*'
  nameserver: [223.5.5.5, 119.29.29.29]
  proxy-server-nameserver: [223.5.5.5]   # 解析代理服务器自身域名，必须直连
```

**fake-ip 机制**：海外域名不做真实解析，直接返回 `198.18.x.x` 假地址；客户端往假地址发包进 TUN，mihomo 反查回域名，把**域名**交给代理出口解析。**海外域名全程不在国内解析，从根本上绕开污染。**

`fake-ip-filter` 是为了避免内网设备被假地址化 —— 未过滤时 `ping zte.home` 会解析到 `198.18.4.51`。

**不做兜底**（刻意的选择）：

```
路由器 DNS      = 192.168.5.2
路由器备用 DNS  = 留空
```

| | 后果 |
|---|---|
| 填备用 DNS | mihomo 挂了 → 客户端悄悄用公共 DNS → **能上网但分流失效**，海外站点变慢，**察觉不到** |
| 留空 | mihomo 挂了 → DNS 立刻全失败 → **30 秒内就知道** |

⚠️ 代价：**mihomo 重启的几秒内全家 DNS 中断**。所以改配置必须用**热重载**，不能 `systemctl restart`：

```bash
curl -X PUT -H "Authorization: Bearer <secret>" \
     http://vm-router:9090/configs -d '{"path":"/etc/mihomo/config.yaml"}'
```

---

## 自愈分层

| 层 | 故障 | 频率 | 对策 | 恢复 |
|---|---|---|---|---|
| **L0 配置** | 订阅更新拉到坏配置 | **最常见** | `mihomo -t -d` 校验通过才替换，否则保留旧配置并告警 | 不发生 |
| **L1 进程** | mihomo 崩溃 | 常见 | systemd `Restart=always` `RestartSec=3` | 3 秒 |
| **L2 虚拟机** | VM 卡死 / 被误关 | 偶尔 | 宿主机看门狗：`qm status` 为 stopped 就 `qm start` | 30–90 秒 |
| **L3 宿主机** | PVE 崩 / 重启 | 罕见 | `onboot=1` + `startup order=1,up=30` | 2–3 分钟 |
| **L4 断电** | 停电 | 罕见 | BIOS「断电后恢复 = 电源开启」 | 来电后 2–3 分钟 |

**明确不做**：keepalived 降级备机。既然要求"挂了就挂了、不要悄悄降级"，它的核心价值（降级可用）就没了；而真正的双活热备要处理配置同步，且两台都在同一宿主机上防不了 L3。等 X99 节点上线，把第二台放到另一台物理机才有意义。

---

## 逃生通道

**路由器管理页永远可达** —— `192.168.5.1` 与设备同网段，二层直连，**不经过网关**。所以哪怕旁路由死透：

```
1. 手机连家里 Wi-Fi
2. 浏览器打开 http://192.168.5.1
3. DHCP 设置里把网关和 DNS 都改回 192.168.5.1
4. 设备关掉再打开 Wi-Fi
```

🔴 建议打印一张贴在路由器上 —— 你可能正在上班，家里人要能自救。

⚠️ 光猫当前 DHCP 租期是 **604800 秒（7 天）**，意味着改回配置后常开设备最坏 **3.5 天**才生效。**改成 7200 秒（2 小时）**，恢复窗口缩到 1 小时。这是零风险改动，切全局之前必须先做。
