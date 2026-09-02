# 02 · config

← [02 · 旁路由](../README.md)　|　机制说明 → [原理](../principles.md)

mihomo 的配置。**模板进 git，机密不进。**

---

## 文件

| 文件 | git | 说明 |
|---|---|---|
| `config.yaml.tmpl` | ✅ | 配置模板，占位符 `${MIHOMO_SECRET}` `${SUB_URL_A}` |
| `mihomo.env.example` | ✅ | 环境变量模板 |
| `mihomo.local.env` | ❌ | 控制台密码与订阅链接，权限 `600` |
| `providers/` | ❌ | 节点缓存，含服务器地址和密码 |
| `config.yaml` | ❌ | 渲染产物，含上面两者的内容 |

初始化：

```bash
cp mihomo.env.example mihomo.local.env && chmod 600 mihomo.local.env
# 填入 MIHOMO_SECRET（openssl rand -hex 16）与 SUB_URL_A
```

后三项被**两道闸**挡住：本目录 `.gitignore` 挡住提交，[`tools/fleet.sh`](../../tools/) 的 rsync 排除项挡住广播给所有机器。它们只由部署流程定向投递给 `vm-router`。

---

## 部署流程

```
改 config.yaml.tmpl（进 git）
  ↓ 渲染：${...} 换成 mihomo.local.env 里的真值
config.yaml（本地，gitignore，600）
  ↓ scp 定向投递
vm-router:/tmp/
  ↓ sudo install -m 600
/etc/mihomo/config.yaml
  ↓ 🔴 sudo mihomo -t -d /etc/mihomo   校验通过才继续
  ↓ 生效
```

### 🔴 两种生效方式，别用错

| 改了什么 | 怎么生效 |
|---|---|
| 节点、规则、策略组、DNS 规则、geo 设置 | **热重载**，服务不中断 |
| `external-ui`、`external-controller`、监听端口、`ipv6` | **必须 `systemctl restart`** —— 启动时注册，热重载不生效 |

```bash
curl -X PUT -H "Authorization: Bearer <secret>" \
     -d '{"path":"/etc/mihomo/config.yaml"}' \
     http://vm-router:9090/configs
```

热重载成功的判据是 **PID 不变**。开了 DNS 服务之后，`restart` 的几秒会让全家 DNS 中断，所以**能热重载的绝不 restart**。

---

## 远端目录

```
/etc/mihomo/
├── config.yaml        主配置，600
├── providers/         节点缓存，mihomo 自己写
├── ruleset/           规则集缓存
├── ui/                metacubexd 静态文件，158 个文件 8.1 MB
├── geoip.metadb       7.6 MB   IP → 国家
├── GeoSite.dat        4.1 MB   域名分类，cn 类 111,097 条
└── cache.db           fake-ip 映射、selector 选择、会话缓存
```

---

## 配置各段

### 基础

| 配置 | 值 | 为什么 |
|---|---|---|
| `mixed-port` | `7890` | HTTP + SOCKS5 共用，少开一个端口 |
| `allow-lan` | `true` | **旁路由必须开**，否则只有本机能用 |
| `mode` | `rule` | 另有 `global` / `direct`，排障时快速切换，见[原理 · 三种模式](../principles.md#4-三种模式) |
| `external-controller` | `0.0.0.0:9090` | 热重载与面板都靠它 |
| `secret` | 随机 32 位 | 🔴 不设则局域网内任何人都能改配置、看全部连接。验证：不带 `Authorization` 请求应返回 **401** |
| `external-ui` | `/etc/mihomo/ui` | 面板。改了要 restart |

### 🔴 `ipv6: false`

两个作用：

| # | |
|---|---|
| 1 | **拉订阅走 IPv4**，命中机场的 IP 白名单。默认按 RFC 6724 优先 IPv6，会带着 `240e:...` 出去被 403 拒绝 |
| 2 | **DNS 不返回 AAAA**，客户端不会尝试 IPv6 直连绕过代理 —— 分流泄漏从源头消失 |

**副作用**：`DIRECT` 只走 IPv4。实测清华镜像拒绝本地 IPv4 而接受 IPv6，所以设备走旁路由后清华镜像连不上。处理见 [坑 9](../README.md#9--ipv6-false-的真实副作用清华镜像连不上)。

### `profile.store-selected: true`

**默认 `false`** —— 面板上手动选的节点只存在内存，重启回到第一个候选。开这项才写入 `cache.db`。

### Geo 数据库

```yaml
geo-auto-update: true
geo-update-interval: 12
geox-url:
  geoip:   "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat"
  mmdb:    "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"
  geosite: "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"
  asn:     "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb"
```

🔴 **`geox-url` 必须显式配** —— mihomo 默认用 `raw.githubusercontent.com`，国内不可达，会导致进程 fatal 退出。详见[原理 · Geo 数据库](../principles.md#8-geo-数据库)。

按需下载：只有规则实际用到的库才会拉。当前用了 `GEOSITE` + `GEOIP`，所以下了前两个。

### 节点来源

```yaml
proxy-providers:
  airport-a:
    type: http
    url: "${SUB_URL_A}"
    path: ./providers/airport-a.yaml    # 相对 -d 目录
    interval: 86400
    health-check:
      enable: true                      # url-test 组必须有它
      url: https://www.gstatic.com/generate_204
      interval: 300
```

**拉取失败时继续用旧缓存**，只记 warning —— 订阅出问题不会导致 mihomo 起不来。这与"整份 config.yaml 被外部工具覆盖"是完全不同的风险级别。

`type: file` 用于本地节点文件（自建节点、手工维护的列表）。格式判断：

```bash
grep -c '^proxies:' <文件>      # 1 = Clash 格式可直接用，0 = 需转换
```

### 策略组

```yaml
proxy-groups:
  - name: PROXY
    type: select
    proxies: [自动选择, DIRECT]
    use: [airport-a]              # 39 个节点全部列为候选 → 共 41 个

  - name: 自动选择
    type: url-test
    use: [airport-a]
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50                 # 延迟差 50ms 内不切换，避免来回抖动
```

分两层的收益见[原理 · 策略组](../principles.md#2-策略组)：**规则与节点解耦** + **`DIRECT` 作为逃生开关**。

### 规则

```yaml
rules:
  - GEOSITE,cn,DIRECT     # 域名维度，不需解析，快且准
  - GEOIP,CN,DIRECT       # IP 维度兜底，允许解析
  - MATCH,PROXY           # 兜底，必须最后
```

🔴 **`GEOSITE` 必须在 `GEOIP` 前面**，且 **`GEOIP` 不能加 `no-resolve`** —— 加了会导致带域名的连接跳过该规则，国内流量全部落到 `MATCH` 走代理。实测踩过，详见[原理 · 规则](../principles.md#3-规则)。

---

## 演进路线

```
□ TUN + auto-redirect      客户端不用手动设代理
□ DNS fake-ip              TUN 模式下才能用 GEOSITE 规则
□ 精细分流                 YouTube / AI / 流媒体 分别走不同节点
```

三者的机制见[原理](../principles.md)。精细分流的要点：**别手写域名列表**，用 MetaCubeX 的 geosite 规则集 —— YouTube 的视频流走 `googlevideo.com`、缩略图走 `ytimg.com`，手写必漏，表现是"页面能开但视频卡"且查不出原因。
