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

### 节点来源：订阅 + 自建，并存

```yaml
# 手工定义的自建节点，与订阅互不干扰
proxies:
  - name: Trojan-3xUI
    type: trojan
    server: ${SELF_SERVER}
    port: 9444
    password: ${SELF_TROJAN_PASSWORD}
    sni: ${SELF_SERVER}
    udp: true

  - name: VMess-3xUI
    type: vmess
    server: ${SELF_SERVER}
    port: 9445
    uuid: ${SELF_VMESS_UUID}
    alterId: 0            # Surge 的 vmess-aead=true 对应 alterId: 0
    cipher: auto
    tls: true
    servername: ${SELF_SERVER}
    udp: true

# 订阅
proxy-providers:
  airport-a:
    type: http
    url: "${SUB_URL_A}"
    path: ./providers/airport-a.yaml
    interval: 86400
    health-check: { enable: true, url: https://www.gstatic.com/generate_204, interval: 300 }
```

`proxies:`（手工）与 `proxy-providers:`（订阅）**可以并存**。支持的类型还包括 `http` / `socks5` —— **任何一个普通代理都能当节点用**。

Surge → Clash 的字段映射要点：`password=` → `password`、`username=`(vmess) → `uuid`、`vmess-aead=true` → `alterId: 0`、`sni=` → trojan 用 `sni` / vmess 用 `servername`。

> provider 拉取失败时**继续用旧缓存**，只记 warning —— 订阅出问题不会导致 mihomo 起不来。这与"整份 config.yaml 被覆盖"是完全不同的风险级别。

### 策略组：7 个，全部 fallback（除 PROXY）

| 组 | 类型 | 候选链 | 职责 |
|---|---|---|---|
| `自建线路` | `fallback` | Trojan-3xUI → VMess-3xUI | 协议级冗余。**同一台 VPS 两个端口** —— 能防单协议被识别阻断，防不了服务器宕机 |
| **`AI服务`** | `fallback` | 自建线路 → **REJECT** | 🔴 候选里**没有任何订阅节点，也没有 DIRECT** |
| `订阅线路` | `fallback` | 订阅 39 节点 | 按 provider 顺序取第一个健康的 |
| `订阅兜底` | `fallback` | 订阅线路 → 自建线路 → **REJECT** | 订阅全挂转自建，自建也挂就拒绝 |
| **`PROXY`** | `select` | 订阅兜底 / 订阅线路 / 自建线路 / DIRECT / 39 节点 | 通用流量落点，**43 个候选可手动固定** |

#### 🔴 为什么全用 `fallback`，一个 `url-test` 都没有

| 类型 | 切换时机 | 后果 |
|---|---|---|
| `url-test` | **每 300 秒按延迟重选** | 出口 IP 频繁变动 → **触发服务端风控**（验证码变多、要求重新登录） |
| **`fallback`** | **只在当前节点不健康时** | 健康时一直用同一个，**出口 IP 稳定** |

#### 🔴 为什么两条链都以 `REJECT` 收尾，不退回 `DIRECT`

```
REJECT   连接立刻被拒 → 浏览器马上报错 → 你立即知道出问题了
DIRECT   能上网但没代理 → 海外站点变慢/打不开 → 隐性故障，察觉不到
```

同一原则也体现在路由器的**备用 DNS 留空**上：**宁可显性失败，不要隐性劣化**。

#### 🔴 AI 隔离是结构性的

`AI服务` 的候选只有 `[自建线路, REJECT]`。即使规则写错、即使手动误操作，**结构上不可能**把 AI 流量送到订阅节点。

原因：AI 服务对**出口 IP 纯净度**敏感 —— 共享节点上其他用户的行为会连累你的账号，表现为验证码变多、限流、乃至封号。

#### `select` 与 `fallback` 套两层的收益

```
fallback  自动切换，但【不能手动选】
select    能手动选，但【不会自动切换】
```

`PROXY` 用 `select` 且默认指向 `订阅兜底`（fallback）——**默认自动兜底，需要时随时手动固定**。

### 规则

```yaml
rules:
  # ① AI 服务，90 条，最高优先级
  - DOMAIN-SUFFIX,openai.com,AI服务
  - DOMAIN-SUFFIX,chatgpt.com,AI服务
  - DOMAIN-SUFFIX,anthropic.com,AI服务
  - DOMAIN-SUFFIX,claude.ai,AI服务
  ...                                # 共 90 条

  # ② 国内直连
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT

  # ③ 兜底
  - MATCH,PROXY
```

#### AI 规则的来源与范围

| 来源 | 条数 | 说明 |
|---|---|---|
| Surge `rules-main.dconf` 的 ChatGPT / claude 两段 | **59**（原 62 去重 3） | 原样迁移 |
| 补充的常见 AI 服务 | **31** | 见下 |

**故意保留了第三方服务**（`sentry.io` `stripe.com` `intercom.io` `auth0.com` `arkoselabs.com` 等）：

- **验证码与认证域名必须和主域名同出口** —— 不同 IP 会触发风控
- 遥测流量本身很小，隔离的收益不抵拆分的漏配风险

**补充的 31 条**中最关键的是 **`chatgpt.com`** —— 原列表只有 `openai.com`，而 **OpenAI 2024 年已把主站迁到 `chatgpt.com`**。另补 `sora.com`、Google AI（`gemini.google.com` / `aistudio.google.com`）、Copilot、Cursor、Grok、Perplexity、HuggingFace、ElevenLabs 等。

🟡 **国内 AI 刻意不加**（DeepSeek / Kimi / 智谱等）—— 本就该直连，走代理反而慢且可能被风控。

#### 🔴 规则顺序的三条硬约束

| 约束 | 违反的后果 |
|---|---|
| AI 规则在最前 | 被 `GEOSITE,cn` 或 `MATCH` 抢先命中 |
| `GEOSITE` 在 `GEOIP` 前 | HTTP 代理请求携带的是域名，此时还没有 IP。GEOSITE 不需解析，快且准 |
| `MATCH` 必须最后 | 它匹配一切，放前面后续规则全是死代码 |

**`GEOIP` 不能加 `no-resolve`** —— 加了会导致带域名的连接跳过该规则，国内流量全部落到 `MATCH` 走代理。实测踩过：`www.qq.com` 走了日本节点。详见[原理 · 规则](../principles.md#3-规则)。

---

## 演进路线

```
□ TUN + auto-redirect      客户端不用手动设代理
□ DNS fake-ip              TUN 模式下才能用 GEOSITE 规则
□ 精细分流                 YouTube / AI / 流媒体 分别走不同节点
```

三者的机制见[原理](../principles.md)。精细分流的要点：**别手写域名列表**，用 MetaCubeX 的 geosite 规则集 —— YouTube 的视频流走 `googlevideo.com`、缩略图走 `ytimg.com`，手写必漏，表现是"页面能开但视频卡"且查不出原因。
