<div align="center">

# 🚀 caddy-pro (`cad`)

### 极简 · 极速 · 工业级高可靠的 Caddy 反向代理交互式运维系统

*为现代 Linux VPS、NAT 小鸡、中转落地架构与 AI 开发者量身打造*

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
[![Bash: >=4.0](https://img.shields.io/badge/Bash-%3E%3D4.0-4EAA25.svg?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Release: v3.2.0](https://img.shields.io/badge/Version-v3.2.0-orange.svg?style=flat-square)](https://github.com/DongHua3/caddy-pro/releases)
[![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu%20%7C%20RHEL%20%7C%20CentOS%20%7C%20Alpine-lightgrey.svg?style=flat-square&logo=linux&logoColor=white)](#)
[![Zero Memory Overhead](https://img.shields.io/badge/Memory%20Overhead-0%20MB-brightgreen.svg?style=flat-square)](#-为什么选择-caddy-pro)
[![Cloudflare DNS-01 Ready](https://img.shields.io/badge/ACME-Cloudflare%20DNS--01-F38020.svg?style=flat-square&logo=cloudflare&logoColor=white)](#-典型实战场景与最佳实践)
[![AI Streaming Ready](https://img.shields.io/badge/AI%20Gateway-SSE%20Optimized-9cf.svg?style=flat-square)](#2-ai-大模型-api-网关-cliproxyapi--one-api--newapi-专属流式加速)
[![Safe HTTP/3 Ready](https://img.shields.io/badge/HTTP%2F3-Safe%20QUIC%20Probe-green.svg?style=flat-square)](#3-受控-http3-quic--udp-443-智能强探针)

<p align="center">
  <a href="#-一键安装与使用">快速开始</a> •
  <a href="#-为什么选择-caddy-pro">核心优势</a> •
  <a href="#-控制台界面全景">控制台概览</a> •
  <a href="#-核心重磅特性">重磅特性</a> •
  <a href="#-典型实战场景与最佳实践">最佳实践</a> •
  <a href="#-双模-cli-指令速查">CLI 速查</a>
</p>

</div>

---

## 🌟 为什么选择 caddy-pro？

在 Linux 服务器上配置反向代理时，传统的两大主流方案往往让开发者陷入两难：

1. **纯手工编写 Nginx / Caddy 配置文件**：
   - 语法严格，括号嵌套复杂，一处手滑打错标点就会导致整台服务器所有业务瞬间雪崩；
   - 规则启停依赖手动注释整块，不仅容易丢配置，多行嵌套的 `transport`、SSL 策略极难维护。
2. **重型 Web 面板（如 Nginx Proxy Manager、宝塔面板、1Panel）**：
   - 依赖 Node.js + Python + MySQL/SQLite 常驻后台，**白白吞掉 250MB ~ 400MB 物理内存**；
   - 面对 512MB / 1GB 内存的低配小鸡或轻量落地机，极其容易触发 OOM 宕机。

---

### 📊 核心能力全面横向评测

| 核心指标 / 能力维度 | 手工编辑 Caddyfile | Nginx Proxy Manager (NPM) | 宝塔 / 1Panel 面板 | **caddy-pro (`cad`)** |
| :--- | :---: | :---: | :---: | :---: |
| **平时常驻内存占用** | 0 MB (仅Caddy本体) | 250MB ~ 380MB 🚨 | 300MB ~ 500MB 🚨 | **⚡ 0 MB (仅Caddy原生15MB)** |
| **配置上手门槛** | 高（需精通语法） | 低（Web 图形化） | 低（Web 图形化） | **🎯 极低（极速 TUI / CLI 双模）** |
| **防崩溃与安全回滚** | 无（语法错直接挂） | 较弱（偶见重载失败） | 一般（手动备份） | **🛡️ 毫秒级自动预检与秒级回滚** |
| **无 80/443 端口自动签发** | 极其繁琐 | 需手动配 DNS 插件 | 需安装复杂扩展 | **🌐 Cloudflare DNS-01 一键自动化** |
| **CF 小黄云穿透签证书** | 会被边缘节点拦截 | 需先切灰色云朵 | 需频繁手动切换 | **⚡ 永久无感穿透，无需关代理** |
| **AI 大模型流式专属优化** | 需深入配置缓冲区 | 不支持快捷优化 | 需手动修改模板 | **🤖 一键注入 SSE 零缓冲 + 300s/600s保活** |
| **HTTP/3 安全避让与防冲突** | 容易与 Hy2 争端口 | 默认全局监听易冲突 | 需手动改配置 | **🚀 前置 UDP 443 物理强探针，100% 避让** |
| **复合多路由共存保护** | 易误改其他行 | 路由配置繁琐 | 规则修改受限 | **🧩 AST 深度解析，智能共存** |
| **并发修改防错位** | 无并发锁 | 数据库加锁 | 依赖面板事务 | **🔒 Linux 底层 `flock` 文件排他锁** |

---

## 🚀 一键安装与使用

以 `root` 用户登录 Linux VPS，在终端复制执行以下单行命令即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/DongHua3/caddy-pro/main/cad.sh)
```

> 💡 **全局快捷指令**：安装后系统会自动注册 `/usr/local/bin/cad`。以后在终端任意目录下，只需输入：
> ```bash
> cad
> ```
> 即可秒级唤出极速交互式控制台！

---

## 🖥️ 控制台界面全景 (v3.2.0)

```text
================================================================
           caddy-pro 反向代理交互式管理系统 (v3.2.0)            
       极简、安全、高可靠 | 快捷唤醒指令: cad
================================================================
  1. 查看当前所有反代规则列表 (含 AI流式 与 H3 标识)
  2. 添加反代规则 (智能探测/HTTPS后端/AI流式/安全H3)
  3. 交互式修改反代规则 (免开Nano/原位修改/复合路由保护)
  4. 启用 / 停用反代规则 (无损状态切换/保留自定义块)
  5. 删除已有反代规则 (带非空防灾校验)
  6. SSL 证书中心 & DNS-01 自动化 (SSL Doctor/Cloudflare)
  7. 快照时光机与安全回滚 (保留15个版本/彩色Diff对比)
  8. 检查配置并平滑重载 Caddy (免重启生效/带预检)
  9. 手动编辑 Caddyfile 配置文件 (安全预检+草稿自动保护)
 10. 查看 Caddy 运行状态与证书日志 (实时追踪最新40行)
 11. 服务运维控制 (重载 / 重启 / 停止 / 启动)
 12. 一键安装 / 更新 Caddy 环境 (官方标准版 / CF增强版)
 13. 一键卸载与环境清理 (三模式: 仅脚本 / 归档卸载 / 强力粉碎)
  0. 退出管理系统
================================================================
服务状态: ● 正在运行 (Active) | 规则统计: 3 启用, 1 停用 | ACME: Cloudflare DNS-01 (已启用)
----------------------------------------------------------------
请输入功能编号 [0-13]: 
```

---

## ✨ 核心重磅特性剖析

### 1. 🤖 AI 大模型流式 API 网关专属优化 (v3.2 新增)
针对自建或反代 **`cliproxyapi`**、**One API**、**NewAPI** 等大模型中转服务的痛点量身打造：
- **实时打字机零缓冲 (`flush_interval -1`)**：彻底解除 Caddy 的默认响应缓冲，让每一块 SSE token 即刻推送到客户端，消除“积攒一段字突然吐出”的打字机卡顿。
- **思考模型双阶长保活 (`300s / 600s`)**：首包等待 300 秒（从容应对 Claude 3.7 Thinking、OpenAI o1/o3-mini 的深度推理），读取长连接保活 600 秒（10 分钟超长上下文生成不中断），彻底告别 `504 Gateway Timeout`。

### 2. 🚀 受控 HTTP/3 (QUIC / UDP 443) 智能强探针 (v3.2 新增)
针对同时部署 **Hysteria 2 (hy2)**、**3x-ui** 节点代理的 VPS 深度优化：
- **受控开启，告别粗暴默认**：HTTP/3 默认保持关闭，仅在用户显式开启时介入。
- **UDP 443 物理占用强探针**：开启前自动识别 Linux UDP `UNCONN` 状态与双栈 IPv4/IPv6，捕获占用进程与 PID。若检测到 Hysteria 2 / 3x-ui 正在独占 UDP 443，**系统自动拦截并告警，坚决不抢端口，100% 保护代理节点稳定**；仅在端口空闲时安全开启并注入 `Alt-Svc` 引导头。
- **防火墙与安全组联动感知**：开启成功后主动给出友好指引，提醒放行云安全组与本地防火墙 UDP 443 端口。

### 3. 🌐 Cloudflare DNS-01 ACME 全自动引擎
- **彻底告别 80/443 入站端口束缚**：国内中转机端口映射（如 `10443 -> 443`）或 NAT 小鸡没有公网 80 端口时，传统的 HTTP-01 证书申请必定失败。`caddy-pro` 集成官方 Cloudflare 插件，通过权威 DNS TXT 记录自动签发合规证书！
- **无视 Cloudflare 小黄云边缘拦截**：域名开启 CDN（小黄云）代理模式，无需来回切换灰色云朵，永久全自动签发与续订。
- **单静态二进制无常驻开销**：从官方 Build API 动态构建单一执行程序，绝不常驻后台消耗额外内存。

### 4. 🛡️ 工业级防崩溃流水线与时光机回滚
`caddy-pro` 执行任何配置变更均严格遵循五阶段安全流水线：
$$\text{排版规范先行} \longrightarrow \text{统一权限收拢} \longrightarrow \text{真实身份穿透测读} \longrightarrow \text{静态语法校验} \longrightarrow \text{运行时安全重载+失败毫秒回滚}$$
- **时光机快照库 (`/etc/caddy/backups/`)**：每次增删改查自动保存时间戳快照（自动滚动维护最新 15 个版本），支持交互式彩色 `Diff` 差异对比，支持一键毫秒级无感回滚。
- **草稿箱保护机制**：手动编辑若发生语法错，自动保存为 `Caddyfile.draft.*`，绝不粗暴清空用户的心血配置。

### 5. 🧩 基于花括号深度跟踪的 AWK AST 解析器
- **花括号深度跟踪（Depth-Tracking）**：彻底告别简陋的单行正则，完美兼容多行嵌套指令（如 `transport http { ... }`）。
- **复合反代路由共存保护**：当单站点内配置了多个路径的分流代理（例如 `/api/*` 指向后端 A，`/*` 指向前端 B），就地原位修改主代理时，其余次级路由**100% 完整原样保留**。
- **无损启停机制**：采用 `# [cad:disabled]` 前缀注销规则，停用规则时完整保留站点内自定义 header 重写、鉴权与特殊配置，再次启用时零损失复原。

### 6. 🔒 Linux 底层权限中枢与单实例排他锁
- **解决经典 DAC Bypass 假阳性**：root 环境下 `test -r` 永远为真，脚本通过切换至 Caddy 守护进程真实用户（`caddy` 用户）进行只读穿透测试，消除由权限缺失引发的隐蔽宕机。
- **单实例文件排他锁 (`flock`)**：自动在系统全局获取互斥文件锁，避免多终端会话或后台脚本并发修改导致配置行号错乱。
- **管道安装防截断**：严密防御 `bash <(curl ...)` 下的伪文件描述符，下载先校验大小再原子替换，杜绝快捷指令落盘为 0 字节。
- **安全细节收敛**：兼顾 RHEL/CentOS 系统的 SELinux 标签修复，自动 `apt-mark hold` 锁包防止系统升级冲刷插件，设置 `cap_net_bind_service` 低端口绑定能力。

---

## 🛠️ 典型实战场景与最佳实践

### 1. 中转机 (NAT 小鸡/端口映射) + 落地机 (NewAPI / One API) 架构

```text
国内客户端 (Cursor / VSCode / 浏览器)
    │
    ▼ [高速优化线路，晚高峰 0 丢包]
中转机 / 流量转发入口 (NAT 外网映射端口 10443 -> 443)
    │
    ▼ [跨境高速互联]
落地机 VPS (运行 NewAPI / One API :3000 + caddy-pro)
    │  ⚡ 借助 cad 开启 Cloudflare DNS-01 验证，彻底绕过入站端口限制，秒获合法泛域名证书！
    ▼
OpenAI / Anthropic / Google 官方大模型 API
```

* **落地机配置**：
  1. 运行 `cad` 进入 **「菜单 6 ➔ 2」** 安装 Cloudflare 增强版 Caddy；
  2. 进入 **「菜单 6 ➔ 3」** 填入你的 Cloudflare API Token（权限仅需 `Zone - DNS - Edit`）；
  3. 输入 `2` 添加反代：外部域名填业务域名（如 `api.yourdomain.com`），端口填 `3000`。
* **中转机配置**：
  - 本地监听端口：`443`（NAT 外网端口已映射为 `10443`）；
  - 目标地址（落地）：填 `落地机公网IP:443`；
  - PROXY 协议：关闭。
* **客户端调用**：
  - Base URL 设为 `https://api.yourdomain.com:10443/v1`，全链路丝滑打通！

---

### 2. AI 大模型 API 网关 (cliproxyapi / One API / NewAPI) 专属流式加速

* **痛点**：普通反代默认具有响应缓存，导致 LLM 生成的 token 积攒一定大小后才批量吐出，打字机卡顿严重；且长思考模型极易触发 504 Gateway Timeout。
* **caddy-pro 解决方案**：
  添加规则或原位修改中开启 **`⚡ AI 流式优化`**，自动生成高性能网关配置：
  ```caddy
  api.yourdomain.com {
      reverse_proxy 127.0.0.1:8000 {
          # 实时刷新缓冲区，保障 SSE 打字机流式输出零延迟
          flush_interval -1
          transport http {
              # 300s 首包思考 + 600s 长代码生成保活
              response_header_timeout 300s
              read_timeout 600s
          }
      }
  }
  ```

---

### 3. 3x-ui / 面板原生 HTTPS 反代 (根除重定向死循环)

针对自带自签证书或强制开启了 HTTPS 的面板（如 3x-ui、Proxmox、1Panel）：
* **旧版痛点**：普通 HTTP 反代会导致面板不断向浏览器发送 `302/307 Location: https://...`，引发浏览器报错 `ERR_TOO_MANY_REDIRECTS`；
* **caddy-pro 解决方案**：添加规则输入端口后，系统**智能嗅探上游协议**，一键配置自签名证书信任：
  ```caddy
  panel.yourdomain.com {
      reverse_proxy https://127.0.0.1:2053 {
          transport http {
              tls_insecure_skip_verify
          }
      }
  }
  ```

---

### 4. Cloudflare 小黄云无缝穿透

域名开启 Cloudflare CDN（小黄云）后，传统的 HTTP-01 验证请求会被 Cloudflare 边缘节点代理拦截。
* **使用 caddy-pro**：开启 Cloudflare DNS-01 后，验证请求直接在 DNS 权威服务器层由 TXT 记录完成，**永久无视小黄云拦截**，无需手动将域名切为灰色云朵再切回！

---

### 5. Hysteria 2 (hy2) 与 Caddy HTTP/3 安全协同指南

* **背景**：同一台 VPS 上的 `UDP 443` 端口同一时刻只能被一个服务独占。
* **最佳实践**：
  1. 若您的 3x-ui / Hysteria 2 节点监听了自定义端口（如 `10443`、`4433` 或端口跳跃范围），UDP 443 处于空闲状态，您可以在 `cad` 中放心开启 HTTP/3，享受 QUIC 极速连接；
  2. 若您的 Hy2 节点独占了 `UDP 443`，`cad` 的**智能强探针会自动拦截并拒绝开启 HTTP/3**，彻底杜绝端口冲突，守护您的代理节点 100% 稳定运行。

---

## ⚡ 双模 CLI 指令速查

除了进入交互式 TUI 菜单，您可以在任意 Shell 脚本或终端中直接调用快捷子命令：

```bash
# 查看所有反代规则列表 (含运行状态、协议、AI流式与H3标识)
cad list

# 查看 Caddy 运行状态、版本、ACME 引擎与规则统计
cad status

# 执行 Caddyfile 语法安全预检并平滑重载 (出错自动毫秒回滚)
cad reload

# 对指定域名执行 SSL Doctor 综合体检 (双栈/DNS/CF小黄云/端口占用)
cad doctor api.yourdomain.com

# 查看 Cloudflare DNS-01 引擎运行状态
cad cf status

# 配置 Cloudflare API Token 并一键开启全局 DNS-01 验证
cad cf set "your-cloudflare-api-token"

# 移除 Cloudflare 配置 (平滑切回默认 HTTP-01 验证模式)
cad cf remove

# 创建当前配置的时间戳快照备份 (最多滚动保留15个版本)
cad backup "大版本升级前手动快照"

# 一键卸载与环境清理 (支持交互式三模式 / --script-only / --archive / --purge)
cad uninstall

# 查看版本信息与命令帮助
cad -v
cad -h
```

---

## 💡 常见问题 (FAQ)

### Q1: 安装 Cloudflare 增强版 Caddy 会额外占用服务器内存吗？
**A: 完全不会！0 额外常驻物理内存。**  
Caddy 插件是在编译期直接静态打包进单一可执行文件中的（官方 Single Binary 架构），不依赖 Node.js、Python 或任何第三方后台数据库。在运行时，它依然只是原生的单个 Caddy 守护进程（内存开销仅 15MB~30MB 左右）。只有在申请或续订证书的数秒时间内会调用一次 Cloudflare API，平时没有任何常驻进程，低配 512M VPS 也能轻松流畅运行。

### Q2: 为什么提示端口 80/443 被占用？
**A: 脚本内置两阶段平滑释放机制。**  
系统运行 `cad doctor` 或在菜单 6 诊断时会检测端口冲突，明确列出占用进程及其启动命令（如 Apache/Nginx/Docker）。确认一键释放时，系统会先发送 `SIGTERM` 允许进程优雅关闭刷新数据，等待 1 秒后若仍未释放才发送 `SIGKILL`，保障数据安全。

---

## 📋 常用系统原生指令备忘

```bash
# 启动 / 停止 / 重启 Caddy 服务
systemctl start caddy
systemctl stop caddy
systemctl restart caddy

# 平滑重载配置 (不断流)
systemctl reload caddy

# 实时追踪证书签发与访问日志
journalctl -u caddy -f
```

---

## 📄 开源许可证

本项目基于 [MIT License](LICENSE) 协议开源。欢迎 Star、Fork 和提交 PR！
