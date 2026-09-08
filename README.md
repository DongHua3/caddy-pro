<h1 align="center">caddy-pro (cad)</h1>

<p align="center">
  <b>极简、轻量、工业级高可靠的 Caddy 自动化反向代理交互式管理系统</b><br>
  为 Linux VPS 量身打造 | AST深度解析、免Nano原位修改、智能HTTPS上游探测、无损启停、Cloudflare DNS-01全自动签发、SSL体检、时光机快照回滚、双模CLI
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License">
  <img src="https://img.shields.io/badge/bash-%3E%3D4.0-brightgreen.svg" alt="Bash">
  <img src="https://img.shields.io/badge/version-v3.1.0-orange.svg" alt="Version">
  <img src="https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu%20%7C%20RHEL%20%7C%20AlmaLinux%20%7C%20Alpine-lightgrey.svg" alt="Platform">
</p>

---

## 🌟 为什么选择 caddy-pro？

传统的反向代理运维通常面临两难：
1. **纯手工改配置（Nginx / Caddy 原生配置文件）**：容易手滑打错语法或括号嵌套，导致整个代理服务雪崩；
2. **重型 Web 面板（如 Nginx Proxy Manager / 宝塔面板）**：后台依赖 Node.js + Python + 数据库，常驻吃掉 **250MB~400MB 物理内存**，对 512M / 1G 低配小鸡极其致命。

**`caddy-pro` 结合了两者的极致优势：**
- ⚡ **零额外常驻内存**：平时纯原生 Caddy 运行（仅 15MB~30MB），管理时秒级唤起轻量 Shell 交互控制台，管理完毕立即退出，0 额外常驻开销！即便是集成了 Cloudflare DNS 插件，也是作为单一静态编译二进制运行，**绝无任何后台常驻进程与内存膨胀**！
- 🛡️ **工业级防崩溃机制**：
  - 增删改查自动保存时间戳快照 (`/etc/caddy/backups/`)，最多保留 15 个版本；
  - 变更前强制执行 `caddy validate` 语法预检；
  - **运行时双重保险**：若重载或重启失败，0.1 秒自动触发安全回滚，核心业务绝不宕机；
  - 手动编辑提供“重新编辑 / 放弃修改 / 保存为草稿”机制，绝不物理擦除用户的心血配置。
- 🌐 **全自动 SSL 证书中心 (v3.1 新增)**：
  - 一键支持 **Cloudflare DNS-01 ACME 自动化**，彻底摆脱 80/443 入站端口限制与 Cloudflare 小黄云拦截，完美契合 NAT 小鸡与中转机/落地机分离架构！
- 🚀 **极速便捷**：自动注册全局命令，终端随手输入 **`cad`** 即可唤出控制台，并全面支持直接命令行操作（`cad list`, `cad status`, `cad doctor`, `cad reload`, `cad backup`, `cad cf`）！

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

## 🖥️ 菜单功能一览 (v3.1.0)

```text
================================================================
           caddy-pro 反向代理交互式管理系统 (v3.1.0)            
       极简、安全、高可靠 | 快捷唤醒指令: cad
================================================================
  1. 查看当前所有反代规则列表
  2. 添加反代规则 (智能探测/支持HTTPS后端)
  3. 交互式修改反代规则 (免开Nano/原位修改)
  4. 启用 / 停用反代规则 (无损状态切换)
  5. 删除已有反代规则
  6. SSL 证书中心 & DNS-01 自动化 (SSL Doctor/Cloudflare)
  7. 快照时光机与安全回滚 (保留15个版本/Diff对比)
  8. 检查配置并平滑重载 Caddy (免重启生效)
  9. 手动编辑 Caddyfile 配置文件 (安全预检+草稿保护)
 10. 查看 Caddy 运行状态与证书日志
 11. 服务运维控制 (重载 / 重启 / 停止 / 启动)
 12. 一键安装 / 更新 Caddy 环境
  0. 退出管理系统
================================================================
服务状态: ● 正在运行 (Active) | 规则统计: 3 启用, 1 停用 | ACME: Cloudflare DNS-01 (已启用)
----------------------------------------------------------------
请输入功能编号 [0-12]: 
```

---

## ✨ 核心重磅特性

| 功能模块 | 亮点特性与架构升级 |
| :--- | :--- |
| ⚡ **Cloudflare DNS-01 ACME 自动化 (v3.1.0 新增)** | **彻底解除 80/443 入站端口限制与 CDN 拦截！** 集成官方 Cloudflare DNS 插件，仅需配置 API Token，全局站点自动切入 DNS-01 挑战。支持泛域名申请、无视入站端口受限（NAT 小鸡/中转链路）、无视 Cloudflare 小黄云边缘代理拦截。**单二进制文件静态集成，0 额外常驻物理内存**！提供一键平滑降级与标准版回退。 |
| **工业级权限中枢与防宕机守护** | 全局 `umask 022`，动态获取并适配 systemd Caddy 守护进程运行用户与属组（`root:group 0644`），消除 `caddy fmt` 导致的权限覆盖与 `permission denied` 错误；支持 SELinux 上下文修复；规则修改与启停采用同目录原子临时文件，配合 `awk` 退出码与非空双重门禁彻底防空灾；菜单 11 服务重启增加非破坏性语法门禁，严禁语法异常中断存量在线业务！ |
| **AST 语法树深度解析** | 彻底弃用老旧行正则，采用花括号深度跟踪（Depth-Tracking）AWK 解析器。完美解析多行复杂嵌套指令（如带 `transport` 的后端配置），修复行首带 `/` 路径被误判丢弃的历史问题。 |
| **统一绝对规则编号** | 在 **查看、修改、启停、删除** 所有操作中保持 100% 绝对一致的规则序号 `[1..N]`，彻底告别旧版菜单规则顺序错乱的问题。 |
| **免 Nano 原位规则修改器 (Menu 3)** | 用户无需进入复杂的文本编辑器，在菜单中直接选择规则编号，即可交互式单项或组合修改 **域名、目标端口/地址、协议与TLS跳过验证、路径路由、启用状态**，外科手术式精准就地更新！ |
| **智能上游探测与原生 HTTPS 后端 (Menu 2)** | 添加规则时智能探测上游端口存活状态与协议类型。针对 3x-ui、Proxmox 等 HTTPS 面板服务，自动建议并配置 `transport http { tls_insecure_skip_verify }`，彻底根除 `ERR_TOO_MANY_REDIRECTS` 循环重定向！ |
| **无损规则启停切换 (Menu 4)** | 采用 `# [cad:disabled] ` 标记前缀注销规则。停用规则时完整保留原有站点的复杂自定义路由、中间件配置与代码段，重新启用时零损失复原。 |
| **SSL Doctor & 网络综合体检 (Menu 6)** | 集成公网双栈（IPv4/IPv6）检测、域名 DNS 解析与本机公网 IP 一致性校验、Cloudflare 小黄云（CDN 代理）阻断预警、80/443 端口冲突检测与一键释放进程；智能识别 DNS-01 模式并跳过非必要告警。 |
| **时光机快照与安全回滚 (Menu 7)** | 增删改查全流程自动生成带时间戳备份（保留最新 15 个版本），提供交互式版本列表、彩色 Diff 差异对比；并重构 `safe_reload`，确保无论在语法校验阶段还是在**运行时重载阶段**出错，均自动无感秒级回滚！ |
| **双模 CLI 命令行支持** | 支持纯命令行无头调用：`cad list`、`cad status`、`cad reload`、`cad doctor [domain]`、`cad backup [note]`、`cad cf [status|set|remove]`，轻松集成自动化脚本与 CI/CD 运维管道。 |
| **安全手动编辑器保留 (Menu 9)** | 面向进阶高阶玩家保留安全手动编辑模式，支持语法预校验、重载测试与草稿自动保存（`Caddyfile.draft.*`），绝不丢失心血配置。 |

---

## ⚡ 双模 CLI 命令行用法

除了进入交互式 TUI 菜单，您可以在任意 Shell 脚本或终端中直接调用快捷子命令：

```bash
# 查看所有反代规则列表 (含状态与协议)
cad list

# 查看 Caddy 运行状态、版本、ACME 引擎与规则统计
cad status

# 执行 Caddyfile 语法安全预检并平滑重载 (出错自动回滚)
cad reload

# 对指定域名执行 SSL Doctor 综合体检 (双栈/DNS/CF小黄云/端口占用)
cad doctor api.yourdomain.com

# 查看 Cloudflare DNS-01 引擎运行状态
cad cf status

# 配置 Cloudflare API Token 并一键开启 DNS-01 验证
cad cf set "your-cloudflare-api-token"

# 移除 Cloudflare 配置 (平滑切回默认 HTTP-01 验证模式)
cad cf remove

# 创建当前配置的时间戳快照备份 (自动维护最新15个版本)
cad backup "升级前手动备份"

# 查看版本信息与帮助
cad -v
cad -h
```

---

## 🛠️ 典型应用场景与最佳实践

### 1. 中转机 (NAT 小鸡/端口映射) + 落地机 (NewAPI) 架构最佳实践

**【架构痛点】**
许多用户使用中转机（如 NAT 小鸡，外部映射端口例如 `10443 -> 443`）加速访问落地 VPS 上的 NewAPI / One API（`:3000`）。
- 若将域名解析至中转机，落地机的 Caddy 默认使用 **HTTP-01 (80端口)** 或 **TLS-ALPN-01 (443端口)** 申请证书；
- 由于流量并没有直连落地机，CA 机构的探测请求全部被中转机挡掉，导致证书签发超时失败，最终抛出：
  ```text
  Connection failed: error sending request for url (https://api1.domain.com:10443/v1)
  无法建立连接 (DNS / 连接 / TLS / 超时)
  ```

**【caddy-pro 优雅解决方案】**
1. **落地机开启 Cloudflare DNS-01**：
   - 落地 VPS 上运行 `cad` 进入 **「菜单 6 ➔ 2」** 安装 Cloudflare 增强版 Caddy；
   - 进入 **「菜单 6 ➔ 3」** 填入 Cloudflare API Token（权限仅需 `Zone - DNS - Edit`）；
   - Caddy 会通过 Cloudflare API 自动写入 DNS TXT 记录进行验证，**完全不需要开放 80/443 入站端口**，证书秒签！
2. **落地机反代 NewAPI**：
   - 运行 `cad` 输入 `2` 添加规则：域名填业务域名（如 `api1.henrytoken.com`），目标端口填 `3000`（NewAPI）。
3. **中转机配置流量转发**：
   - **本地监听**：`443`（NAT 外网端口已映射为 `10443`）；
   - **目标地址 (落地)**：填 `落地机公网IP:443`（或填只解析到落地机 IP 的专用域名如 `direct.domain.com:443`，**切记不要填解析到中转机本身的域名，否则会死循环**）；
   - **PROXY 协议**：普通 HTTP/HTTPS 转发保持关闭即可。
4. **客户端直接访问**：
   - Base URL 设为 `https://api1.henrytoken.com:10443/v1`，全链路完美打通！

---

### 2. 3x-ui / 面板原生 HTTPS 反代 (解决重定向死循环)
针对自签证书或强制开启了 HTTPS 的面板（如 3x-ui 默认监听 2053 或 6123 端口）：
- **旧版痛点**：普通 HTTP 反代会导致面板不断向浏览器发送 `302/307 Location: https://...`，引发浏览器报错 `ERR_TOO_MANY_REDIRECTS`；
- **caddy-pro 解决方案**：添加规则输入目标端口后，系统**智能探测并自动识别 HTTPS 后端**，一键配置跳过自签名证书验证：
  ```caddy
  panel.yourdomain.com {
      reverse_proxy https://127.0.0.1:6123 {
          transport http {
              tls_insecure_skip_verify
          }
      }
  }
  ```

---

### 3. AI 大模型 API 与应用网关 (路径路由)
将公网单一域名根据路径分发至不同本地容器：
- 主站 `api.yourdomain.com` 反代至业务前端；
- 路径 `/v1/*` 原位精确反代至本地 Docker 的 One API / New API（`:3000`）。
- 全自动签发并续签 Let's Encrypt / ZeroSSL 证书，满足 Python SDK 与各开发工具安全调用。

---

### 4. Cloudflare 小黄云无缝穿透
域名开启 Cloudflare CDN（小黄云）后，传统的 HTTP-01 验证请求会被 Cloudflare 边缘节点拦截。
- **有了 caddy-pro v3.1**：开启 Cloudflare DNS-01 后，验证请求直接在 DNS 权威服务器层完成，**永久无视小黄云拦截**，无需手动将域名切为灰色云朵再切回！

---

## 💡 常见问题 (FAQ)

### Q: 安装 Cloudflare 增强版 Caddy 会额外占用服务器内存吗？
**A: 完全不会！0 额外常驻内存开销。**
Caddy 插件是在编译期直接静态打包进单一可执行文件中的（官方 Single Binary 架构），不依赖 Node.js、Python 或任何第三方后台数据库。在运行时，它依然只是原生的单个 Caddy 守护进程（内存开销仅 15MB~30MB 左右）。只有在申请或续订证书的数秒时间内会调用一次 Cloudflare API，平时没有任何常驻进程，低配 512M VPS 也能轻松流畅运行。

---

## 📋 常用系统指令备忘

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

本项目基于 [MIT License](LICENSE) 协议开源，欢迎 Star、Fork 和提交 PR！
