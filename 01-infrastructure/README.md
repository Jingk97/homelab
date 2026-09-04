# 01 · 基础设施

← [仓库首页](../README.md)　|　下一步 → [02 · 旁路由](../02-gateway/)

从裸机到一台**可反复克隆的虚拟机模板**。这是地基，只做一次；后续每个服务都从这里产出的模板 `9000` 克隆。

---

## 文档

| # | 文档 | 内容 | 什么时候看 |
|---|---|---|---|
| **01** | [Proxmox VE 安装](01-proxmox-install.md) | ISO 校验 → 启动盘 → BIOS → 安装向导 → 换源 → 验收 | 装机前 |
| **02** | [网络规划](02-network.md) | 网段选型 → 地址分配 → 路由器配置 → 各类设备固定 IP | **装机前定方案**，装完做配置 |
| **03** | [Proxmox 核心概念](03-proxmox-concepts.md) | VM vs LXC → 存储分层 → 网桥模型 → 虚拟机硬件模型 → 术语 | **建虚拟机前必读** |
| **04** | [虚拟机与模板化](04-vm-template.md) | 创建向导逐项 → Ubuntu 安装 → 通用配置 → 去身份化 → 转模板 → 克隆 | 建第一台虚拟机时 |
| **05** | [数据盘接入与共享](05-storage.md) | 认盘（SMR 判定）→ 分区 → 格式化参数 → fstab → **virtio-fs 给虚拟机** → PVE 存储池 | 给宿主机**加第二块盘**时 |

> **01 和 02 有交叉**：安装向导要先定好 IP 和主机名，而那部分规划在 02。第一次操作先读 02 的第 1–2 节定地址方案，再回 01 开始装。

---

## 脚本

见 [`scripts/`](scripts/)。四个脚本按机器的生命周期顺序使用：

```
新克隆的机器
   ↓  init-clone.sh        改主机名 + 配静态 IP + 按角色加内核参数
   ↓  provision-base.sh    系统基础 + 工具链 + 语言运行时
   ↓  fix-root-residue.sh  体检（退出码即验证信号）
   ↓  sysprep.sh           去身份化 → 关机 → 转模板     🔴 不可逆
模板
```

全部幂等，都支持 `--dry-run`。从 Mac 用 [`tools/fleet.sh`](../tools/) 推送执行：

```bash
./tools/fleet.sh run vm-router -- 01-infrastructure/scripts/fix-root-residue.sh --check
```

---

## 产物

| 产物 | 位置 | 说明 |
|---|---|---|
| **模板 `9000`** | `pve` → `tmpl-ubuntu-2404` | Ubuntu 24.04，含完整工具链，已去身份化并开启保护 |
| 地址规划表 | [02-network.md](02-network.md) | 所有服务分配地址的依据 |
| 身份约定 | [04-vm-template.md](04-vm-template.md) | PVE 用 `root`，虚拟机用 `jing` + sudo 免密 |

**验收标准**：从模板克隆一台，`machine-id` 与其他机器不同、SSH 主机密钥是新生成的、公钥可直接登录。
