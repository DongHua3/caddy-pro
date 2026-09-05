# caddy-pro (cad)

<p align="center">
  <img src="https://avatars.githubusercontent.com/u/10706293?s=200&v=4" width="100" height="100" alt="Caddy Logo">
</p>

<p align="center">
  <b>极简、轻量、工业级高可靠的 Caddy 自动化反向代理交互式管理系统</b><br>
  为 Linux VPS 量身打造 | 支持语法预检、配置防丢失安全编辑、全自动 HTTPS、零额外内存常驻
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License">
  <img src="https://img.shields.io/badge/bash-%3E%3D4.0-brightgreen.svg" alt="Bash">
  <img src="https://img.shields.io/badge/version-v2.2.0-orange.svg" alt="Version">
  <img src="https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu%20%7C%20RHEL%20%7C%20AlmaLinux%20%7C%20Alpine-lightgrey.svg" alt="Platform">
</p>

---

## 🌟 为什么选择 caddy-pro？

传统的反向代理运维通常面临两难：
1. **纯手工改配置（Nginx / Caddy 原生配置文件）**：容易手滑打错语法或括号嵌套，导致整个代理服务雪崩；
2. **重型 Web 面板（如 Nginx Proxy Manager）**：后台依赖 Node.js + Python + 数据库，常驻吃掉 **250MB~400MB 物理内存**，对 512M / 768M 低配小鸡极其致命。

**`caddy-pro` 结合了两者的极致优势：**
- ⚡ **零额外常驻内存**：仅在管理时唤起轻量 Shell 交互控制台，平时不占用任何系统常驻资源！
- 🛡️ **工业级防崩溃机制**：
  - 增删改查全量自动备份 (`Caddyfile.bak`)；
  - 变更前强制执行 `caddy validate` 语法预检，**一旦出错 0.1 秒自动回滚**，核心业务绝不宕机；
  - 手动编辑提供“重新编辑 / 放弃修改 / 保存为草稿”机制，**绝不物理擦除用户的心血配置**。
- 🚀 **极速便捷**：自动注册全局命令，终端随手输入 **`cad`** 即可唤出控制台！

---

## 🚀 一键安装与使用

以 `root` 用户登录 Linux VPS，在终端中直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DongHua3/caddy-pro/main/cad.sh)
```

> **快捷指令**：安装后会自动注册到全局路径 `/usr/local/bin/cad`。以后在终端任意目录下，只需输入：
> ```bash
> cad
> ```
> 即可秒级唤出交互式管理控制台！

---

## 🖥️ 菜单功能一览

```text
================================================================
           caddy-pro 反向代理交互式管理系统 (v2.2.0)            
       极简、安全、高可靠 | 快捷唤醒指令: cad
================================================================
  1. 查看当前所有反代规则列表
  2. 添加反代规则 (域名 -> 本地端口/目标服务)
  3. 删除已有反代规则
  4. 手动编辑 Caddyfile 配置文件 (安全预检)
  5. 检查配置并平滑重载 Caddy (免重启生效)
  6. 查看 Caddy 运行状态与 SSL 证书日志
  7. 重启 / 启动 / 停止 Caddy 服务
  8. 一键安装 / 更新 Caddy 环境
  0. 退出管理系统
================================================================
服务状态: ● 正在运行 (Active) | Caddy: 已安装
----------------------------------------------------------------
请输入功能编号 [0-8]: 
```

---

## ✨ 核心特性

| 功能模块 | 亮点特性 |
| :--- | :--- |
| **全生态多发行版支持** | 智能适配 Debian、Ubuntu、CentOS Stream、RHEL 8/9、AlmaLinux、Rocky Linux 与 Alpine Linux。 |
| **管道防死循环机制** | 独家集成 `ensure_tty` 终端重定向保护，完美杜绝 `curl \| bash` 模式下输入流耗尽引发的刷屏暴死。 |
| **规则字面量精准解析** | 规则增删均采用纯字面量字符串算法，彻底免疫正则元字符（如泛域名 `*.domain.com`、点号 `.`）造成的误判误删。 |
| **嵌套花括号深度追踪** | 删除规则时引入自动深度计数器，无论是单行反代还是包含多指令的复杂块，均能干净剔除，不留语法残渣。 |
| **配置防丢失编辑安全** | 类似 `visudo` 的临时文件安全编辑流，语法检查失败时支持随时修正或保存为带时间戳的草稿。 |
| **全自动 HTTPS** | Caddy 原生向 Let's Encrypt / ZeroSSL 申请免费证书，自动开启 HTTP/2 与 HTTP/3，到期静默续签。 |

---

## 🛠️ 典型应用场景

1. **AI 大模型生态网关**：将 `api.yourdomain.com` 一键反代至本地 Docker 的 `New API`（`:3000`），全自动启用 HTTPS 满足 Cursor / Python SDK 安全要求。
2. **翻墙/节点面板加密**：将 `3x.yourdomain.com` 一键反代至 `3x-ui`（`:2053`），彻底解决面板明文 HTTP 传输密码的安全隐患。
3. **Web 服务聚合**：博客（Halo/WordPress）、内网穿透（FRP）、网盘（Alist）一站式域名反代管理。

---

## 📋 常用手动指令备忘

除了使用 `cad` 交互式菜单外，您也可以使用标准指令进行日常运维：

```bash
# 启动 / 停止 / 重启
systemctl start caddy
systemctl stop caddy
systemctl restart caddy

# 平滑重载配置 (不中断当前连接)
systemctl reload caddy

# 实时查看最新证书与访问日志
journalctl -u caddy -f
```

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 协议开源，欢迎 Star、Fork 和提交 PR！
