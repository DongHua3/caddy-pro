#!/usr/bin/env bash
# ==============================================================================
#  项目名称: caddy-pro (快捷指令: cad)
#  版权所有: (c) 2026 DongHua3
#  开源协议: MIT (SPDX-License-Identifier: MIT)
#  项目定位: 极简、轻量、高可靠的 Caddy 反向代理交互式管理系统
#  核心特性: 语法预检、自动回滚、增删改查、SSL状态监控、平滑重载
# ==============================================================================

CADDY_FILE="/etc/caddy/Caddyfile"
CADDY_BAK="/etc/caddy/Caddyfile.bak"
INSTALL_PATH="/usr/local/bin/cad"
VERSION="2.2.0"

# 终端色彩定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
PLAIN='\033[0m'
BOLD='\033[1m'

# 终端退出恢复色彩
trap 'echo -e "${PLAIN}"' EXIT INT TERM

# 0. 终端输入重定向保护 (解决 curl | bash 管道执行导致 STDIN 耗尽死循环)
ensure_tty() {
    if [ ! -t 0 ]; then
        if [ -c /dev/tty ]; then
            exec < /dev/tty
        else
            echo -e "${RED}[错误] 当前环境无可用交互式终端 (TTY)，无法运行交互菜单！${PLAIN}"
            exit 1
        fi
    fi
}

# 1. 权限检查
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误] 请以 root 权限运行此脚本！(sudo cad)${PLAIN}"
        exit 1
    fi
}

# 2. 环境初始化检查
init_env() {
    if [ ! -d "/etc/caddy" ]; then
        mkdir -p /etc/caddy
        chmod 755 /etc/caddy
    fi
    if [ ! -f "$CADDY_FILE" ]; then
        touch "$CADDY_FILE"
        chmod 644 "$CADDY_FILE"
    fi
}

# 3. 检查 Caddy 是否已安装门禁
ensure_caddy_installed() {
    if ! command -v caddy > /dev/null 2>&1; then
        echo -e "${RED}[错误] 系统尚未安装 Caddy 环境！请先在主菜单选择 [8] 进行一键安装。${PLAIN}"
        pause
        return 1
    fi
    return 0
}

# 4. 自动注册全局快捷指令 cad (兼顾本地文件与远程管道下载)
setup_shortcut() {
    local script_file
    script_file=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null)
    [ -d "/usr/local/bin" ] || mkdir -p /usr/local/bin

    if [ -f "$script_file" ]; then
        if [ "$script_file" != "$INSTALL_PATH" ]; then
            cp -f "$script_file" "$INSTALL_PATH"
            chmod +x "$INSTALL_PATH"
        fi
    else
        # 远程管道运行场景: 从 GitHub 拉取自身完成永久注册
        local repo_url="https://raw.githubusercontent.com/DongHua3/caddy-pro/main/cad.sh"
        if curl -fsSL "$repo_url" -o "$INSTALL_PATH" 2>/dev/null; then
            chmod +x "$INSTALL_PATH"
        fi
    fi
}

# 5. Caddy 一键安装模块 (支持 Debian/Ubuntu/RHEL/CentOS/AlmaLinux/Alpine)
install_caddy() {
    clear
    echo -e "${BLUE}====================================================${PLAIN}"
    echo -e "${GREEN}             一键安装 / 升级 Caddy 环境              ${PLAIN}"
    echo -e "${BLUE}====================================================${PLAIN}"
    
    if command -v caddy > /dev/null 2>&1; then
        echo -e "${YELLOW}检测到系统已安装 Caddy (${GREEN}$(caddy version | awk '{print $1}')${YELLOW})。${PLAIN}"
        read -p "是否重新安装 / 覆盖更新? (y/n): " reinstall
        if [[ "$reinstall" != "y" && "$reinstall" != "Y" ]]; then
            return
        fi
    fi

    echo -e "${BLUE}[1/3] 正在检测系统架构并安装必要依赖...${PLAIN}"
    if [ -f /etc/debian_version ]; then
        apt update
        apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
        echo -e "${BLUE}[2/3] 配置 Caddy 官方 APT 源...${PLAIN}"
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
        chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
        chmod o+r /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
        apt update
        echo -e "${BLUE}[3/3] 安装 Caddy 主程序...${PLAIN}"
        apt install -y caddy
    elif [ -f /etc/redhat-release ]; then
        if command -v dnf > /dev/null 2>&1; then
            dnf install -y 'dnf-command(copr)' curl || dnf install -y dnf-plugins-core curl
            dnf copr enable -y @caddy/caddy
            dnf install -y caddy
        else
            yum install -y yum-plugin-copr curl
            yum copr enable -y @caddy/caddy
            yum install -y caddy
        fi
    elif [ -f /etc/alpine-release ]; then
        apk update && apk add caddy curl
    else
        echo -e "${RED}[错误] 未识别的 Linux 发行版，请参考 Caddy 官方文档手动安装！${PLAIN}"
        pause
        return 1
    fi

    if command -v caddy > /dev/null 2>&1; then
        systemctl enable caddy > /dev/null 2>&1
        systemctl restart caddy > /dev/null 2>&1
        echo -e "\n${GREEN}✓ Caddy 安装成功并已设置开机自启！版本: $(caddy version | awk '{print $1}')${PLAIN}"
    else
        echo -e "\n${RED}✗ Caddy 安装失败，请检查网络或软件源！${PLAIN}"
    fi
    pause
}

# 6. 安全重载与语法验证回滚机制
safe_reload() {
    echo -e "${BLUE}正在执行 Caddyfile 语法安全预检...${PLAIN}"
    if caddy validate --config "$CADDY_FILE" > /dev/null 2>&1; then
        caddy fmt --overwrite "$CADDY_FILE" > /dev/null 2>&1
        if systemctl is-active --quiet caddy; then
            if systemctl reload caddy; then
                echo -e "${GREEN}✓ 语法验证通过，配置已平滑重载生效！${PLAIN}"
                return 0
            else
                echo -e "${RED}✗ 配置重载失败，请通过菜单 [6] 查看系统日志！${PLAIN}"
                return 1
            fi
        else
            echo -e "${YELLOW}提示: Caddy 服务当前处于停止状态，正在为您启动服务...${PLAIN}"
            if systemctl restart caddy; then
                echo -e "${GREEN}✓ Caddy 服务已成功启动生效！${PLAIN}"
                return 0
            else
                echo -e "${RED}✗ Caddy 启动失败，请检查端口冲突或系统日志！${PLAIN}"
                return 1
            fi
        fi
    else
        echo -e "${RED}✗ 配置文件语法错误！详细错误诊断如下：${PLAIN}"
        caddy validate --config "$CADDY_FILE"
        if [ -f "$CADDY_BAK" ]; then
            echo -e "${YELLOW}正在自动回滚到上一次正常运行的配置文件备份...${PLAIN}"
            cp -f "$CADDY_BAK" "$CADDY_FILE"
            if systemctl is-active --quiet caddy; then
                systemctl reload caddy > /dev/null 2>&1
            fi
            echo -e "${GREEN}✓ 已成功回滚至最近正常配置，现有业务未受任何中断！${PLAIN}"
        fi
        return 1
    fi
}

pause() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# 7. 纯 Bash 状态机提取并美化展示当前所有反代规则
list_rules() {
    echo -e "\n${YELLOW}======================== 当前已配置的反代规则列表 ========================${PLAIN}"
    if [ ! -s "$CADDY_FILE" ]; then
        echo -e "  ${YELLOW}暂无任何反代规则。输入 [2] 可一键添加！${PLAIN}"
        return
    fi

    printf "%-6s | %-32s | %-24s\n" "[序号]" "外部访问域名 (Domain)" "本地代理目标 (Upstream)"
    echo "--------------------------------------------------------------------------------"

    local count=0
    local cur_domain=""
    local re_domain='^[[:space:]]*([^#/([:space:]][^{]*)\{[[:space:]]*$'
    local re_proxy='^[[:space:]]*reverse_proxy[[:space:]]+(.*)$'

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*[#/] ]] && continue

        if [[ "$line" =~ $re_domain ]]; then
            cur_domain="${BASH_REMATCH[1]}"
            cur_domain="${cur_domain#"${cur_domain%%[![:space:]]*}"}"
            cur_domain="${cur_domain%"${cur_domain##*[![:space:]]}"}"
        elif [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ ]]; then
            cur_domain=""
        elif [[ -n "$cur_domain" ]] && [[ "$line" =~ $re_proxy ]]; then
            local rest="${BASH_REMATCH[1]}"
            rest="${rest%%\{*}"
            rest="${rest%"${rest##*[![:space:]]}"}"
            
            read -ra tokens <<< "$rest"
            if [[ "${tokens[0]}" =~ ^[/@] ]] && [ ${#tokens[@]} -ge 2 ]; then
                tokens=("${tokens[@]:1}")
            fi
            local target="${tokens[*]}"

            count=$((count+1))
            printf "%-6s | %-32s | %-24s\n" "[$count]" "$cur_domain" "$target"
        fi
    done < "$CADDY_FILE"

    if [ "$count" -eq 0 ]; then
        echo -e "  ${YELLOW}未检测到标准反代规则，以下为原始 Caddyfile 内容：${PLAIN}"
        cat "$CADDY_FILE"
    fi
}

# 8. 添加规则 (带字面量精准查重与端口格式校验)
add_rule() {
    ensure_caddy_installed || return 1
    echo -e "\n${YELLOW}--- 快捷添加反代规则 ---${PLAIN}"
    read -p "请输入外部访问域名 (例如 api.yourdomain.com): " new_domain
    new_domain=$(echo "$new_domain" | tr -d '[:space:]')

    if [ -z "$new_domain" ]; then
        echo -e "${RED}[错误] 域名不能为空！${PLAIN}"
        pause
        return
    fi

    # 纯字面量查重，绝不受正则元字符（如点号、星号）干扰
    local exists
    exists=$(awk -v check="$new_domain" '
    {
        line = $0
        sub(/^[ \t]+/, "", line)
        if (index(line, check) == 1) {
            rest = substr(line, length(check) + 1)
            if (rest ~ /^[ \t]*\{/) { found = 1; exit 0 }
        }
    }
    END { if (found) print "1" }
    ' "$CADDY_FILE")

    if [ "$exists" == "1" ]; then
        echo -e "${RED}[错误] 域名 [${new_domain}] 已存在于配置中，无法重复添加！${PLAIN}"
        pause
        return
    fi

    read -p "请输入目标本地端口或完整地址 (例如 3000 或 127.0.0.1:3000): " new_target
    new_target=$(echo "$new_target" | tr -d '[:space:]')

    if [ -z "$new_target" ]; then
        echo -e "${RED}[错误] 目标地址/端口不能为空！${PLAIN}"
        pause
        return
    fi

    # 纯端口自动补充回环地址
    if [[ "$new_target" =~ ^[0-9]+$ ]]; then
        if [ "$new_target" -lt 1 ] || [ "$new_target" -gt 65535 ]; then
            echo -e "${RED}[错误] 端口范围必须在 1-65535 之间！${PLAIN}"
            pause
            return
        fi
        new_target="127.0.0.1:$new_target"
    fi

    cp -f "$CADDY_FILE" "$CADDY_BAK"
    cat << RULE >> "$CADDY_FILE"

$new_domain {
    reverse_proxy $new_target
}
RULE

    safe_reload
    pause
}

# 9. 删除规则 (字面量深度匹配 + 嵌套花括号括号计数器，防止误删与配置断裂)
del_rule() {
    ensure_caddy_installed || return 1
    echo -e "\n${YELLOW}--- 删除已有反代规则 ---${PLAIN}"
    
    mapfile -t domains < <(awk '
    BEGIN { in_block = 0; depth = 0 }
    {
        if ($0 ~ /^[ \t]*[#/]/) next
        if (!in_block) {
            if ($0 ~ /^[ \t]*\{/) { in_block = 1; depth = 1; next }
            if ($0 ~ /\{[ \t]*$/) {
                line = $0
                sub(/^[ \t]+/, "", line)
                sub(/[ \t]*\{[ \t]*$/, "", line)
                if (line !~ /^\(/ && length(line) > 0) {
                    print line
                    in_block = 1
                    depth = 1
                }
            }
        } else {
            depth += gsub(/\{/, "{") - gsub(/\}/, "}")
            if (depth <= 0) { in_block = 0; depth = 0 }
        }
    }' "$CADDY_FILE")

    if [ ${#domains[@]} -eq 0 ]; then
        echo -e "${YELLOW}当前没有任何可删除的反代规则。${PLAIN}"
        pause
        return
    fi

    echo "当前已生效的域名列表："
    for i in "${!domains[@]}"; do
        echo -e "  [${GREEN}$((i+1))${PLAIN}] ${domains[$i]}"
    done

    read -p "请输入要删除的规则序号 [1-${#domains[@]}], 输入 0 取消: " del_index
    if [[ "$del_index" =~ ^[0-9]+$ ]] && [ "$del_index" -ge 1 ] && [ "$del_index" -le ${#domains[@]} ]; then
        local target_del="${domains[$((del_index-1))]}"
        read -p "确认彻底删除 [$target_del] 的反向代理配置吗? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            cp -f "$CADDY_FILE" "$CADDY_BAK"
            awk -v del_target="$target_del" '
            BEGIN { in_block = 0; depth = 0 }
            {
                if (!in_block) {
                    line = $0
                    sub(/^[ \t]+/, "", line)
                    if (index(line, del_target) == 1) {
                        remainder = substr(line, length(del_target) + 1)
                        if (remainder ~ /^[ \t]*\{/) {
                            in_block = 1
                        }
                    }
                }
                if (in_block) {
                    depth += gsub(/\{/, "{") - gsub(/\}/, "}")
                    if (depth <= 0) {
                        in_block = 0
                        depth = 0
                    }
                    next
                }
                print $0
            }' "$CADDY_FILE" > "${CADDY_FILE}.tmp" && mv -f "${CADDY_FILE}.tmp" "$CADDY_FILE"
            
            echo -e "${GREEN}已成功删除 [$target_del]！${PLAIN}"
            safe_reload
        else
            echo "操作已取消。"
        fi
    fi
    pause
}

# 10. 安全手动编辑 (临时文件 + 语法预检，语法错误绝不擦除用户手写成果)
edit_caddyfile() {
    ensure_caddy_installed || return 1
    local tmp_file
    tmp_file=$(mktemp /tmp/caddyfile.XXXXXX) || { echo -e "${RED}无法创建临时工作文件！${PLAIN}"; pause; return 1; }
    cp -f "$CADDY_FILE" "$tmp_file"
    
    local editor="${EDITOR:-${VISUAL:-nano}}"
    command -v "$editor" >/dev/null 2>&1 || editor=vim
    command -v "$editor" >/dev/null 2>&1 || editor=vi

    while true; do
        "$editor" "$tmp_file"
        if caddy validate --config "$tmp_file" >/dev/null 2>&1; then
            cp -f "$CADDY_FILE" "$CADDY_BAK"
            cp -f "$tmp_file" "$CADDY_FILE"
            chmod 644 "$CADDY_FILE"
            caddy fmt --overwrite "$CADDY_FILE" >/dev/null 2>&1
            if systemctl is-active --quiet caddy; then
                systemctl reload caddy && echo -e "${GREEN}✓ 语法验证通过，配置已保存并平滑重载！${PLAIN}"
            else
                echo -e "${YELLOW}✓ 语法验证通过，配置已更新！(当前 Caddy 处于停止状态)${PLAIN}"
            fi
            break
        else
            echo -e "\n${RED}✗ 配置文件语法校验失败！错误诊断详情如下：${PLAIN}"
            caddy validate --config "$tmp_file"
            echo ""
            read -p "请选择: [E]重新编辑修正 / [A]放弃修改 / [S]保存为草稿后退出 [E/a/s]: " edit_choice
            case "${edit_choice,,}" in
                a)
                    echo -e "${YELLOW}已放弃本次修改，原配置文件保持不变。${PLAIN}"
                    break
                    ;;
                s)
                    local draft="/etc/caddy/Caddyfile.draft.$(date +%s)"
                    cp -f "$tmp_file" "$draft"
                    echo -e "${YELLOW}草稿已保存在: $draft，原配置未做修改。${PLAIN}"
                    break
                    ;;
                *)
                    continue
                    ;;
            esac
        fi
    done
    rm -f "$tmp_file"
    pause
}

# 11. 查看日志
view_logs() {
    echo -e "\n${YELLOW}====================== Caddy 实时运行与 SSL 证书日志 (最新 40 行) ======================${PLAIN}"
    journalctl -u caddy -n 40 --no-pager
    pause
}

# 12. 主菜单循环
main_menu() {
    check_root
    ensure_tty
    init_env
    setup_shortcut

    while true; do
        clear
        echo -e "${BLUE}================================================================${PLAIN}"
        echo -e "${GREEN}${BOLD}           caddy-pro 反向代理交互式管理系统 (v${VERSION})            ${PLAIN}"
        echo -e "       极简、安全、高可靠 | 快捷唤醒指令: ${GREEN}${BOLD}cad${PLAIN}"
        echo -e "${BLUE}================================================================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 查看当前所有反代规则列表"
        echo -e "  ${GREEN}2.${PLAIN} 添加反代规则 (域名 -> 本地端口/目标服务)"
        echo -e "  ${GREEN}3.${PLAIN} 删除已有反代规则"
        echo -e "  ${GREEN}4.${PLAIN} 手动编辑 Caddyfile 配置文件 (安全预检)"
        echo -e "  ${GREEN}5.${PLAIN} 检查配置并平滑重载 Caddy (免重启生效)"
        echo -e "  ${GREEN}6.${PLAIN} 查看 Caddy 运行状态与 SSL 证书日志"
        echo -e "  ${GREEN}7.${PLAIN} 重启 / 启动 / 停止 Caddy 服务"
        echo -e "  ${GREEN}8.${PLAIN} 一键安装 / 更新 Caddy 环境"
        echo -e "  ${GREEN}0.${PLAIN} 退出管理系统"
        echo -e "${BLUE}================================================================${PLAIN}"

        if command -v caddy > /dev/null 2>&1; then
            if systemctl is-active --quiet caddy; then
                echo -e "服务状态: ${GREEN}● 正在运行 (Active)${PLAIN} | Caddy: ${GREEN}已安装${PLAIN}"
            else
                echo -e "服务状态: ${RED}● 已停止 (Inactive)${PLAIN} | Caddy: ${GREEN}已安装${PLAIN}"
            fi
        else
            echo -e "服务状态: ${RED}● Caddy 未安装 (输入 8 可一键安装)${PLAIN}"
        fi
        echo -e "${BLUE}----------------------------------------------------------------${PLAIN}"

        read -p "请输入功能编号 [0-8]: " num
        case $num in
            1)
                list_rules
                pause
                ;;
            2)
                add_rule
                ;;
            3)
                del_rule
                ;;
            4)
                edit_caddyfile
                ;;
            5)
                ensure_caddy_installed && safe_reload
                pause
                ;;
            6)
                view_logs
                ;;
            7)
                echo -e "\n${YELLOW}请选择服务动作：1. 重启  2. 停止  3. 启动${PLAIN}"
                read -p "输入选项 [1-3]: " s_opt
                case $s_opt in
                    1) systemctl restart caddy && echo -e "${GREEN}Caddy 重启成功！${PLAIN}" ;;
                    2) systemctl stop caddy && echo -e "${YELLOW}Caddy 已停止！${PLAIN}" ;;
                    3) systemctl start caddy && echo -e "${GREEN}Caddy 启动成功！${PLAIN}" ;;
                    *) echo "无效操作。" ;;
                esac
                pause
                ;;
            8)
                install_caddy
                ;;
            0)
                clear
                exit 0
                ;;
            *)
                echo -e "${RED}输入无效，请重新选择！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# 启动执行
main_menu "$@"
