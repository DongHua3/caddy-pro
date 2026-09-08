#!/usr/bin/env bash
# ==============================================================================
#  项目名称: caddy-pro (快捷指令: cad)
#  版本编号: v3.1.0
#  版权所有: (c) 2026 DongHua3
#  开源协议: MIT (SPDX-License-Identifier: MIT)
#  项目定位: 极简、轻量、高可靠的 Caddy 反向代理交互式管理系统
#  核心特性: AST深度解析、免Nano原位修改、智能HTTPS上游探测、无损启停、
#            SSL Doctor网络体检、时光机快照回滚、双模CLI
# ==============================================================================

# 全局文件权限掩码声明 (确保默认生成文件为 0644，目录为 0755)
umask 022

CADDY_FILE="${CADDY_FILE:-/etc/caddy/Caddyfile}"
CADDY_BAK="${CADDY_BAK:-/etc/caddy/Caddyfile.bak}"
BACKUP_DIR="${BACKUP_DIR:-/etc/caddy/backups}"
MAX_BACKUPS="${MAX_BACKUPS:-15}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/cad}"
VERSION="3.1.0"

# 终端色彩定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
PLAIN='\033[0m'
BOLD='\033[1m'

# 全局规则解析数组 (统一索引 1..RULE_TOTAL)
declare -a RULE_STATUS=()
declare -a RULE_START=()
declare -a RULE_END=()
declare -a RULE_DOMAIN=()
declare -a RULE_TARGET=()
declare -a RULE_PROTO=()
declare -a RULE_PATH=()
declare -a RULE_TLS_SKIP=()
declare -i RULE_TOTAL=0

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

# 2. 获取 Caddy 守护进程实际运行用户与属组
get_caddy_user_group() {
    local run_user=""
    local run_group=""

    if command -v systemctl >/dev/null 2>&1; then
        run_user=$(systemctl show -p User --value caddy 2>/dev/null | tr -d '[:space:]')
        run_group=$(systemctl show -p Group --value caddy 2>/dev/null | tr -d '[:space:]')
    fi

    # 若 systemd 单元未显式指定 User，检测系统中是否存在 caddy 用户，默认兜底为 root
    if [ -z "$run_user" ]; then
        if id caddy >/dev/null 2>&1; then
            run_user="caddy"
        else
            run_user="root"
        fi
    fi

    # 校验用户在系统中的真实存在性
    if ! id "$run_user" >/dev/null 2>&1; then
        run_user="root"
    fi

    # 若未指定 Group，优先提取运行用户主组或检测 caddy 组，默认兜底为 root
    if [ -z "$run_group" ]; then
        if [ "$run_user" != "root" ] && id -gn "$run_user" >/dev/null 2>&1; then
            run_group=$(id -gn "$run_user" 2>/dev/null | tr -d '[:space:]')
        elif getent group caddy >/dev/null 2>&1 || ( [ -f /etc/group ] && grep -q -E '^caddy:' /etc/group 2>/dev/null ); then
            run_group="caddy"
        else
            run_group="root"
        fi
    fi

    # 校验属组名称在系统中的真实存在性，不存在则安全降级为 root 组
    local grp_ok=0
    if command -v getent >/dev/null 2>&1; then
        getent group "$run_group" >/dev/null 2>&1 && grp_ok=1
    fi
    if [ "$grp_ok" -eq 0 ] && [ -f /etc/group ]; then
        grep -q -E "^${run_group}:" /etc/group 2>/dev/null && grp_ok=1
    fi
    if [ "$grp_ok" -eq 0 ]; then
        run_group="root"
    fi

    echo "${run_user}:${run_group}"
}

# 3. 统一权限中枢 (动态计算真实父目录755 / 属主属组0644 / SELinux标签修复)
ensure_caddyfile_perms() {
    local target="${1:-$CADDY_FILE}"
    local parent_dir
    parent_dir="$(dirname "$target")"

    # 动态计算真实父目录并确保 755 权限
    if [ ! -d "$parent_dir" ]; then
        mkdir -p "$parent_dir" 2>/dev/null || true
    fi
    chmod 755 "$parent_dir" 2>/dev/null || true

    # 若目标为软链接，同步保障真实目标父目录的 755 穿透权限
    local real_target="$target"
    if [ -L "$target" ]; then
        real_target=$(realpath "$target" 2>/dev/null || readlink -f "$target" 2>/dev/null || echo "$target")
        local real_parent_dir
        real_parent_dir="$(dirname "$real_target")"
        if [ -d "$real_parent_dir" ]; then
            chmod 755 "$real_parent_dir" 2>/dev/null || true
        fi
    fi

    # 若文件不存在或为空则初始化标准配置 (确保具备非空内容以供快照备份与回滚)
    if [ ! -e "$target" ]; then
        echo "# caddy-pro" > "$target" 2>/dev/null || touch "$target" 2>/dev/null || true
    fi

    if [ -e "$target" ]; then
        local ug run_group
        ug=$(get_caddy_user_group)
        run_group="${ug##*:}"

        # 权限优先赋予 root:group 0644 (确保守护进程始终可读且 root 独占写权限)
        if [ -n "$run_group" ] && [ "$run_group" != "root" ]; then
            chown "root:${run_group}" "$target" 2>/dev/null || chown root:root "$target" 2>/dev/null || true
        else
            chown root:root "$target" 2>/dev/null || true
        fi

        chmod 644 "$target" 2>/dev/null || true

        # 修复 RHEL/CentOS/Rocky 下 SELinux tmp_t 标签穿透导致的访问拒绝
        restorecon -F "$target" 2>/dev/null || true
        if [ "$real_target" != "$target" ] && [ -e "$real_target" ]; then
            restorecon -F "$real_target" 2>/dev/null || true
        fi
    fi
}

# 4. 消除 root 校验假阳性：对 Caddy 运行用户进行只读穿透测试
check_caddy_readable() {
    local target="${1:-$CADDY_FILE}"
    [ -e "$target" ] || return 1

    local ug run_user
    ug=$(get_caddy_user_group)
    run_user="${ug%%:*}"

    # 若运行用户为空或为 root，直接以当前权限判定
    if [ -z "$run_user" ] || [ "$run_user" = "root" ]; then
        [ -r "$target" ]
        return $?
    fi

    # 以 Caddy 实际运行用户身份进行只读穿透探测 (绕开 root 的 DAC bypass 假阳性)
    if id "$run_user" >/dev/null 2>&1; then
        if command -v su >/dev/null 2>&1; then
            su -s /bin/sh "$run_user" -c "test -r '$target'" >/dev/null 2>&1
            return $?
        elif command -v runuser >/dev/null 2>&1; then
            runuser -u "$run_user" -s /bin/sh -- test -r "$target" >/dev/null 2>&1
            return $?
        fi
    fi

    [ -r "$target" ]
    return $?
}

# 5. 环境初始化检查
init_env() {
    local target_dir
    target_dir="$(dirname "$CADDY_FILE")"
    if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir" 2>/dev/null || true
    fi
    chmod 755 "$target_dir" 2>/dev/null || true

    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    fi
    chmod 700 "$BACKUP_DIR" 2>/dev/null || true

    # 若 Caddyfile 不存在或为空，注入合法占位注释保障首次添加规则时的回滚基线
    if [ ! -s "$CADDY_FILE" ]; then
        echo "# caddy-pro" > "$CADDY_FILE" 2>/dev/null || true
    fi
    ensure_caddyfile_perms "$CADDY_FILE"

    # 初始化备份配置基线
    if [ ! -s "$CADDY_BAK" ]; then
        cp -f "$CADDY_FILE" "$CADDY_BAK" 2>/dev/null || true
        ensure_caddyfile_perms "$CADDY_BAK"
    fi

    # 清理历史异常中断可能残留的同目录临时文件
    find "$target_dir" -maxdepth 1 -name '.cad_tmp.*' -delete 2>/dev/null || true
    find "$target_dir" -maxdepth 1 -name '.cad_edit.*' -delete 2>/dev/null || true
}

# 3. 检查 Caddy 是否已安装门禁
ensure_caddy_installed() {
    if ! command -v caddy > /dev/null 2>&1; then
        echo -e "${RED}[错误] 系统尚未安装 Caddy 环境！请先在主菜单选择 [12] 进行一键安装。${PLAIN}"
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
        local repo_url="https://raw.githubusercontent.com/DongHua3/caddy-pro/main/cad.sh"
        if curl -fsSL "$repo_url" -o "$INSTALL_PATH" 2>/dev/null; then
            chmod +x "$INSTALL_PATH"
        fi
    fi
}

# 5. 时光机快照自动备份与版本修剪 (最多保留 15 个版本)
create_backup() {
    local note="${1:-自动快照}"
    local ts
    ts=$(date +"%Y%m%d_%H%M%S")
    mkdir -p "$BACKUP_DIR" 2>/dev/null

    if [ -f "$CADDY_FILE" ] && [ -s "$CADDY_FILE" ]; then
        local target_bak="${BACKUP_DIR}/Caddyfile_${ts}"
        if [ -f "$target_bak" ]; then
            local c_seq=1
            while [ -f "${target_bak}_${c_seq}" ]; do
                c_seq=$((c_seq + 1))
            done
            target_bak="${target_bak}_${c_seq}"
        fi

        cp -f "$CADDY_FILE" "$target_bak"
        echo "$note" > "${target_bak}.note"
        cp -f "$CADDY_FILE" "$CADDY_BAK"

        # 修剪历史版本至最多 MAX_BACKUPS 个
        local backups=()
        mapfile -t backups < <(ls -1t "${BACKUP_DIR}"/Caddyfile_* 2>/dev/null | grep -v '\.note$')
        if [ ${#backups[@]} -gt $MAX_BACKUPS ]; then
            for ((b_i = MAX_BACKUPS; b_i < ${#backups[@]}; b_i++)); do
                rm -f "${backups[$b_i]}" "${backups[$b_i]}.note" 2>/dev/null
            done
        fi
    fi
}

# 6. 安全重载与语法验证回滚机制 (排版规范 -> 统一赋权 -> 穿透测读 -> 静态预检 -> 运行时防中断重载)
safe_reload() {
    ensure_caddy_installed || return 1
    echo -e "${BLUE}正在执行 Caddyfile 语法安全预检...${PLAIN}"

    # 时序 1: 格式化排版先行落盘
    caddy fmt --overwrite "$CADDY_FILE" > /dev/null 2>&1 || true

    # 时序 2: 统一收口赋权 (目录 755 / 文件 644 / root:group / SELinux 标签)
    ensure_caddyfile_perms "$CADDY_FILE"

    # 时序 3: 消除 root 假阳性：对 Caddy 运行用户进行只读穿透测试
    if ! check_caddy_readable "$CADDY_FILE"; then
        local ug run_user
        ug=$(get_caddy_user_group)
        run_user="${ug%%:*}"
        echo -e "${RED}✗ 权限穿透校验失败: Caddy 运行用户 [${run_user}] 无法读取配置文件 [${CADDY_FILE}]！${PLAIN}"
        if [ -f "$CADDY_BAK" ] && [ -s "$CADDY_BAK" ]; then
            echo -e "${YELLOW}正在尝试回滚至上一次正常运行的备份配置...${PLAIN}"
            cp -f "$CADDY_BAK" "$CADDY_FILE"
            ensure_caddyfile_perms "$CADDY_FILE"
            if systemctl is-active --quiet caddy 2>/dev/null; then
                if systemctl reload caddy > /dev/null 2>&1 || systemctl restart caddy > /dev/null 2>&1; then
                    echo -e "${GREEN}✓ 已安全回滚至上一备份配置并恢复服务。${PLAIN}"
                else
                    echo -e "${RED}✗ 严重: 权限异常导致回滚重载/重启依然失败！Caddy 服务状态异常！${PLAIN}"
                    systemctl status caddy --no-pager 2>/dev/null
                    journalctl -u caddy -n 30 --no-pager 2>/dev/null
                    return 1
                fi
            else
                echo -e "${YELLOW}提示: 配置已成功回滚至备份，但 Caddy 服务当前处于停止状态。${PLAIN}"
            fi
        else
            echo -e "${RED}[错误] 未找到可用的有效备份配置 ($CADDY_BAK)，无法执行回滚！${PLAIN}"
        fi
        return 1
    fi

    # 时序 4: 静态语法预检 (严格校验已排版且赋权的落盘配置文件)
    if ! caddy validate --config "$CADDY_FILE" > /dev/null 2>&1; then
        echo -e "${RED}✗ 配置文件语法校验未通过！错误诊断信息如下：${PLAIN}"
        caddy validate --config "$CADDY_FILE"
        if [ -f "$CADDY_BAK" ] && [ -s "$CADDY_BAK" ]; then
            echo -e "${YELLOW}正在自动回滚至上一次正常运行的配置...${PLAIN}"
            cp -f "$CADDY_BAK" "$CADDY_FILE"
            caddy fmt --overwrite "$CADDY_FILE" > /dev/null 2>&1 || true
            ensure_caddyfile_perms "$CADDY_FILE"
            if systemctl is-active --quiet caddy 2>/dev/null; then
                if systemctl reload caddy > /dev/null 2>&1 || systemctl restart caddy > /dev/null 2>&1; then
                    echo -e "${GREEN}✓ 已成功自动回滚，现有代理业务未受任何中断！${PLAIN}"
                else
                    echo -e "${RED}✗ 严重: 自动回滚重载/重启依然失败！Caddy 服务状态异常！${PLAIN}"
                    systemctl status caddy --no-pager 2>/dev/null
                    journalctl -u caddy -n 30 --no-pager 2>/dev/null
                    return 1
                fi
            else
                echo -e "${YELLOW}提示: 配置已成功回滚至备份，但 Caddy 服务当前处于停止状态。${PLAIN}"
            fi
        else
            echo -e "${RED}[错误] 未找到可用的有效备份配置 ($CADDY_BAK)，无法自动回滚！${PLAIN}"
        fi
        return 1
    fi

    # 时序 5: 运行时重载 / 启动验证与防中断回滚
    if systemctl is-active --quiet caddy 2>/dev/null; then
        if systemctl reload caddy; then
            echo -e "${GREEN}✓ 语法验证通过，配置已平滑重载生效！${PLAIN}"
            cp -f "$CADDY_FILE" "$CADDY_BAK" 2>/dev/null || true
            ensure_caddyfile_perms "$CADDY_BAK"
            return 0
        else
            echo -e "${RED}✗ Caddy 运行时平滑重载失败！详细运行日志如下：${PLAIN}"
            journalctl -u caddy -n 30 --no-pager 2>/dev/null
            if [ -f "$CADDY_BAK" ] && [ -s "$CADDY_BAK" ]; then
                echo -e "${YELLOW}正在紧急执行安全回滚以恢复原有正常配置...${PLAIN}"
                cp -f "$CADDY_BAK" "$CADDY_FILE"
                ensure_caddyfile_perms "$CADDY_FILE"
                if systemctl reload caddy > /dev/null 2>&1 || systemctl restart caddy > /dev/null 2>&1; then
                    echo -e "${GREEN}✓ 已安全回滚至上一稳定状态，已解除潜在服务中断！${PLAIN}"
                else
                    echo -e "${RED}✗ 严重: 紧急回滚重载/重启依然失败！Caddy 处于异常状态！${PLAIN}"
                    systemctl status caddy --no-pager 2>/dev/null
                    journalctl -u caddy -n 30 --no-pager 2>/dev/null
                    return 1
                fi
            else
                echo -e "${RED}[错误] 未找到可用的有效备份配置 ($CADDY_BAK)，无法执行回滚！${PLAIN}"
            fi
            return 1
        fi
    else
        echo -e "${YELLOW}提示: Caddy 服务当前处于停止状态，正在为您启动服务...${PLAIN}"
        if systemctl restart caddy; then
            echo -e "${GREEN}✓ Caddy 服务已成功启动生效！${PLAIN}"
            cp -f "$CADDY_FILE" "$CADDY_BAK" 2>/dev/null || true
            ensure_caddyfile_perms "$CADDY_BAK"
            return 0
        else
            echo -e "${RED}✗ Caddy 启动运行时失败！详细系统日志如下：${PLAIN}"
            journalctl -u caddy -n 30 --no-pager 2>/dev/null
            if [ -f "$CADDY_BAK" ] && [ -s "$CADDY_BAK" ]; then
                echo -e "${YELLOW}正在撤销导致启动失败的配置变更...${PLAIN}"
                cp -f "$CADDY_BAK" "$CADDY_FILE"
                ensure_caddyfile_perms "$CADDY_FILE"
                if systemctl restart caddy > /dev/null 2>&1; then
                    echo -e "${GREEN}✓ 已恢复原配置并成功启动 Caddy！${PLAIN}"
                else
                    echo -e "${RED}✗ 严重: 恢复原配置后启动 Caddy 依然失败！${PLAIN}"
                    systemctl status caddy --no-pager 2>/dev/null
                    journalctl -u caddy -n 30 --no-pager 2>/dev/null
                    return 1
                fi
            else
                echo -e "${RED}[错误] 未找到可用的有效备份配置 ($CADDY_BAK)，无法执行回滚！${PLAIN}"
            fi
            return 1
        fi
    fi
}

pause() {
    echo ""
    read -n 1 -s -r -p "按任意键继续..."
    echo ""
}

# 7. 基于花括号深度跟踪的 AWK AST 解析器 (精准捕获多行嵌套、支持无损停用标记、统一规则编号)
parse_caddyfile() {
    local target_file="$1"
    awk '
    function count_char(str, ch,   c, i, L) {
        c = 0; L = length(str)
        for (i = 1; i <= L; i++) {
            if (substr(str, i, 1) == ch) c++
        }
        return c
    }

    BEGIN {
        in_block = 0
        depth = 0
        rule_count = 0
    }

    {
        raw_line = $0
        line = raw_line
        sub(/^[ \t]+/, "", line)

        is_dis = 0
        if (line ~ /^#[ \t]*\[cad:disabled\]/) {
            is_dis = 1
            sub(/^#[ \t]*\[cad:disabled\][ \t]*/, "", line)
        }

        # 剥离行内注释以精确统计花括号深度
        eff_line = line
        if (eff_line ~ /^[ \t]*(#|\/\/)/) {
            eff_line = ""
        } else {
            sub(/[ \t]+#.*$/, "", eff_line)
            sub(/[ \t]+\/\/.*$/, "", eff_line)
        }

        if (depth == 0) {
            # 站点块起始行判定：必须以 { 结尾，且排除全局块 "{" 与代码片段 "(...)"
            if (eff_line ~ /\{[ \t]*$/) {
                if (eff_line ~ /^[({]/) {
                    in_site = 0
                    open_c = count_char(eff_line, "{")
                    close_c = count_char(eff_line, "}")
                    depth = open_c - close_c
                    next
                }

                header = eff_line
                sub(/[ \t]*\{[ \t]*$/, "", header)
                sub(/^[ \t]+/, "", header)
                sub(/[ \t]+$/, "", header)

                if (length(header) > 0) {
                    in_site = 1
                    rule_start = NR
                    rule_status = is_dis ? "disabled" : "active"
                    rule_domain = header
                    rule_target = ""
                    rule_proto = "http"
                    rule_path = ""
                    rule_tls_skip = 0

                    open_c = count_char(eff_line, "{")
                    close_c = count_char(eff_line, "}")
                    depth = open_c - close_c
                    next
                }
            }
        } else {
            open_c = count_char(eff_line, "{")
            close_c = count_char(eff_line, "}")

            if (in_site) {
                # 解析 reverse_proxy 目标、协议与路径匹配
                if (eff_line ~ /^[ \t]*reverse_proxy/) {
                    rp = eff_line
                    sub(/^[ \t]*reverse_proxy[ \t]+/, "", rp)
                    sub(/[ \t]*\{.*$/, "", rp)
                    sub(/[ \t]+$/, "", rp)

                    n_tok = split(rp, tokens, /[ \t]+/)
                    tok_idx = 1
                    if (n_tok >= 2 && tokens[1] ~ /^(\/|@)/) {
                        rule_path = tokens[1]
                        tok_idx = 2
                    }
                    if (tok_idx <= n_tok) {
                        raw_tgt = tokens[tok_idx]
                        if (raw_tgt ~ /^https:\/\//) {
                            rule_proto = "https"
                            sub(/^https:\/\//, "", raw_tgt)
                            rule_target = raw_tgt
                        } else if (raw_tgt ~ /^http:\/\//) {
                            rule_proto = "http"
                            sub(/^http:\/\//, "", raw_tgt)
                            rule_target = raw_tgt
                        } else {
                            rule_target = raw_tgt
                        }
                    }
                }

                if (eff_line ~ /tls_insecure_skip_verify/) {
                    rule_tls_skip = 1
                }
            }

            depth += (open_c - close_c)
            if (depth <= 0) {
                if (in_site) {
                    rule_end = NR
                    rule_count++
                    printf("%d|%s|%d|%d|%s|%s|%s|%s|%d\n", rule_count, rule_status, rule_start, rule_end, rule_domain, rule_target, rule_proto, rule_path, rule_tls_skip)
                }
                in_site = 0
                depth = 0
            }
        }
    }
    ' "$target_file"
}

# 8. 统一规则加载器 (为查看/修改/启停/删除提供 100% 绝对一致的索引映射)
load_rules() {
    RULE_STATUS=()
    RULE_START=()
    RULE_END=()
    RULE_DOMAIN=()
    RULE_TARGET=()
    RULE_PROTO=()
    RULE_PATH=()
    RULE_TLS_SKIP=()
    RULE_TOTAL=0

    [ -s "$CADDY_FILE" ] || return 0

    local idx status s_line e_line domain target proto path tls_skip
    while IFS='|' read -r idx status s_line e_line domain target proto path tls_skip; do
        [ -z "$idx" ] && continue
        RULE_STATUS[idx]="$status"
        RULE_START[idx]="$s_line"
        RULE_END[idx]="$e_line"
        RULE_DOMAIN[idx]="$domain"
        RULE_TARGET[idx]="$target"
        RULE_PROTO[idx]="$proto"
        RULE_PATH[idx]="$path"
        RULE_TLS_SKIP[idx]="$tls_skip"
        RULE_TOTAL=$idx
    done < <(parse_caddyfile "$CADDY_FILE")
}

# 菜单 1: 查看当前所有反代规则列表
list_rules() {
    load_rules
    echo -e "\n${YELLOW}======================== 当前已配置的反代规则列表 ========================${PLAIN}"
    if [ "$RULE_TOTAL" -eq 0 ]; then
        echo -e "  ${YELLOW}暂无任何反代规则。输入 [2] 可一键快捷添加！${PLAIN}"
        return
    fi

    printf "%-6s | %-12s | %-32s | %-26s | %-12s\n" "[序号]" "运行状态" "外部访问域名 (Domain)" "代理目标 (Upstream)" "路径路由"
    echo "------------------------------------------------------------------------------------------------------"

    for ((i = 1; i <= RULE_TOTAL; i++)); do
        local st_tag="● 启用"
        local st_str="${GREEN}${st_tag}${PLAIN}"
        if [ "${RULE_STATUS[i]}" == "disabled" ]; then
            st_tag="○ 停用"
            st_str="${RED}${st_tag}${PLAIN}"
        fi

        local p_info="${RULE_PROTO[i]^^}"
        if [ "${RULE_PROTO[i]}" == "https" ] && [ "${RULE_TLS_SKIP[i]}" -eq 1 ]; then
            p_info="HTTPS (TLS Skip)"
        fi

        local tgt_display="${RULE_TARGET[i]:-(自定义/无代理)}"
        [ -n "${RULE_TARGET[i]}" ] && tgt_display="${RULE_TARGET[i]} (${p_info})"
        local path_display="${RULE_PATH[i]:-(全部)}"

        printf "%-6s | %b | %-32s | %-26s | %-12s\n" "[$i]" "${st_str}  " "${RULE_DOMAIN[i]}" "$tgt_display" "$path_display"
    done
    echo "------------------------------------------------------------------------------------------------------"
    echo -e "统计: 共 ${BOLD}${RULE_TOTAL}${PLAIN} 条规则。"
}

# 菜单 2: 快捷添加反代规则 (智能探测上游 + 原生 HTTPS 后端支持)
add_rule() {
    ensure_caddy_installed || return 1
    echo -e "\n${YELLOW}--- 快捷添加反代规则 (智能探测/支持HTTPS后端) ---${PLAIN}"
    read -p "请输入外部访问域名 (例如 api.yourdomain.com): " new_domain
    new_domain=$(echo "$new_domain" | tr -d '[:space:]')
    new_domain="${new_domain%/}"
    new_domain="${new_domain#https://}"
    new_domain="${new_domain#http://}"

    if [ -z "$new_domain" ]; then
        echo -e "${RED}[错误] 域名不能为空！${PLAIN}"
        pause
        return
    fi

    # 查重检测
    load_rules
    for ((i = 1; i <= RULE_TOTAL; i++)); do
        if [ "${RULE_DOMAIN[i]}" == "$new_domain" ]; then
            echo -e "${RED}[错误] 域名 [${new_domain}] 已存在于配置中，无法重复添加！${PLAIN}"
            pause
            return
        fi
    done

    read -p "请输入目标本地端口或完整地址 (例如 8080 或 127.0.0.1:8080): " new_target
    new_target=$(echo "$new_target" | tr -d '[:space:]')

    if [ -z "$new_target" ]; then
        echo -e "${RED}[错误] 目标地址/端口不能为空！${PLAIN}"
        pause
        return
    fi

    if [[ "$new_target" =~ ^:[0-9]+$ ]]; then
        new_target="127.0.0.1${new_target}"
    elif [[ "$new_target" =~ ^[0-9]+$ ]]; then
        if [ "$new_target" -lt 1 ] || [ "$new_target" -gt 65535 ]; then
            echo -e "${RED}[错误] 端口范围必须在 1-65535 之间！${PLAIN}"
            pause
            return
        fi
        new_target="127.0.0.1:$new_target"
    fi

    local probe_raw="$new_target"
    probe_raw="${probe_raw#http://}"
    probe_raw="${probe_raw#https://}"
    local probe_host="127.0.0.1"
    local probe_port="80"
    if [[ "$probe_raw" == *:* ]]; then
        probe_host="${probe_raw%:*}"
        probe_port="${probe_raw##*:}"
    else
        probe_host="$probe_raw"
        probe_port="80"
    fi
    [ -z "$probe_host" ] && probe_host="127.0.0.1"

    local detected_proto="http"
    local detected_tls_skip=0

    echo -e "\n${BLUE}正在对目标后端服务 (${probe_host}:${probe_port}) 进行智能协议探测...${PLAIN}"
    local probe_res_https
    probe_res_https=$(curl -sk -m 2 -o /dev/null -w "%{http_code}" "https://${probe_host}:${probe_port}" 2>/dev/null || echo "000")
    local probe_res_http
    probe_res_http=$(curl -s -m 2 -o /dev/null -w "%{http_code}" "http://${probe_host}:${probe_port}" 2>/dev/null || echo "000")
    local probe_err_http
    probe_err_http=$(curl -s -m 2 "http://${probe_host}:${probe_port}" 2>&1 | head -n 5)
    local probe_loc_http
    probe_loc_http=$(curl -sI -m 2 "http://${probe_host}:${probe_port}" 2>/dev/null | grep -iE '^location:[[:space:]]*https://' || true)

    if [[ "$probe_err_http" =~ "HTTPS" || "$probe_err_http" =~ "HTTP request to an HTTPS server" || "$probe_err_http" =~ "The plain HTTP request was sent to HTTPS port" ]] || \
       [ -n "$probe_loc_http" ] || \
       { [ "$probe_res_https" != "000" ] && [ "$probe_res_http" == "000" -o "$probe_res_http" == "400" ]; }; then
        echo -e "${YELLOW}⚡ [智能探测] 检测到上游服务要求 HTTPS 协议 (常见于 3x-ui / 面板服务)！${PLAIN}"
        echo -e "${YELLOW}⚡ 自动建议: 启用 HTTPS 反代并跳过自签名证书校验，防止 ERR_TOO_MANY_REDIRECTS 循环重定向！${PLAIN}"
        detected_proto="https"
        detected_tls_skip=1
    elif [ "$probe_res_http" != "000" ]; then
        echo -e "${GREEN}✓ [智能探测] 检测到上游服务正常响应 HTTP 协议 (HTTP状态码: ${probe_res_http})${PLAIN}"
        detected_proto="http"
        detected_tls_skip=0
    else
        echo -e "${BLUE}ℹ [智能探测] 目标端口未检测到活动响应 (服务可能未启动或位于容器中)${PLAIN}"
        detected_proto="http"
        detected_tls_skip=0
    fi

    echo -e "\n请确认后端协议模式："
    echo -e "  1. HTTP (普通明文反代)"
    echo -e "  2. HTTPS + 开启自签名证书信任 (tls_insecure_skip_verify, 推荐 3x-ui/面板)"
    echo -e "  3. HTTPS (严格证书校验)"
    local default_choice="1"
    [ "$detected_proto" == "https" ] && default_choice="2"
    read -p "请输入选项 [1-3] (回车默认: ${default_choice}): " proto_choice
    proto_choice="${proto_choice:-$default_choice}"

    local final_proto="http"
    local final_tls_skip=0
    case "$proto_choice" in
        2)
            final_proto="https"
            final_tls_skip=1
            ;;
        3)
            final_proto="https"
            final_tls_skip=0
            ;;
        *)
            final_proto="http"
            final_tls_skip=0
            ;;
    esac

    read -p "请输入路径路由匹配规则 (例如 /api/*, 直接回车代理整站): " new_path
    new_path=$(echo "$new_path" | tr -d '[:space:]')
    if [ -n "$new_path" ] && [[ "$new_path" != /* && "$new_path" != @* ]]; then
        new_path="/$new_path"
    fi

    create_backup "添加规则前备份: ${new_domain}"

    local p_arg=""
    [ -n "$new_path" ] && p_arg="${new_path} "

    local tgt_url="$probe_raw"
    [ "$final_proto" == "https" ] && tgt_url="https://${probe_raw}"

    if [ "$final_proto" == "https" ] && [ "$final_tls_skip" -eq 1 ]; then
        cat << RULE >> "$CADDY_FILE"

$new_domain {
    reverse_proxy ${p_arg}${tgt_url} {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
RULE
    else
        cat << RULE >> "$CADDY_FILE"

$new_domain {
    reverse_proxy ${p_arg}${tgt_url}
}
RULE
    fi

    ensure_caddyfile_perms "$CADDY_FILE"
    if safe_reload; then
        echo -e "\n${GREEN}✓ 规则 [${new_domain}] 添加成功并已生效！${PLAIN}"
    else
        echo -e "\n${RED}✗ 规则 [${new_domain}] 添加生效失败，已自动回滚。${PLAIN}"
    fi
    pause
}

# 辅助: 外科手术式就地更新规则块 (精准替换指定字段并完整保留块内其他自定义指令)
update_rule_block() {
    local target_file="$1"
    local s_line="$2"
    local e_line="$3"
    local new_domain="$4"
    local new_target="$5"
    local new_proto="$6"
    local new_path="$7"
    local new_tls_skip="$8"
    local new_status="$9"

    local p_arg=""
    [ -n "$new_path" ] && p_arg="${new_path} "
    local tgt_url="$new_target"
    [ "$new_proto" == "https" ] && tgt_url="https://${new_target}"

    local rp_content=""
    if [ -n "$new_target" ]; then
        if [ "$new_proto" == "https" ] && [ "$new_tls_skip" -eq 1 ]; then
            rp_content=$(printf "    reverse_proxy %s%s {\n        transport http {\n            tls_insecure_skip_verify\n        }\n    }" "$p_arg" "$tgt_url")
        else
            rp_content=$(printf "    reverse_proxy %s%s" "$p_arg" "$tgt_url")
        fi
    fi

    local target_dir
    target_dir="$(dirname "$target_file")"
    [ -d "$target_dir" ] || mkdir -p "$target_dir" 2>/dev/null || true

    local rp_file
    rp_file=$(mktemp "${target_dir}/.cad_tmp.rp.XXXXXX") || { echo -e "${RED}[错误] 无法创建临时规则文件！${PLAIN}"; return 1; }
    echo "$rp_content" > "$rp_file"

    local out_file
    out_file=$(mktemp "${target_dir}/.cad_tmp.out.XXXXXX") || { rm -f "$rp_file"; echo -e "${RED}[错误] 无法创建临时输出文件！${PLAIN}"; return 1; }

    awk -v s="$s_line" -v e="$e_line" \
        -v nd="$new_domain" \
        -v nstatus="$new_status" \
        -v rfile="$rp_file" '
    function print_line(txt) {
        if (nstatus == "disabled") {
            print "# [cad:disabled] " txt
        } else {
            print txt
        }
    }

    BEGIN {
        in_rp = 0
        rp_depth = 0
        rp_replaced = 0
    }

    {
        if (NR < s || NR > e) {
            print $0
            next
        }

        raw = $0
        line = raw
        sub(/^[ \t]*#[ \t]*\[cad:disabled\][ \t]?/, "", line)

        if (NR == s) {
            print_line(nd " {")
            next
        }

        if (NR == e) {
            if (!rp_replaced) {
                while ((getline rline < rfile) > 0) {
                    if (length(rline) > 0) print_line(rline)
                }
                close(rfile)
                rp_replaced = 1
            }
            print_line("}")
            next
        }

        # Inside block [s+1, e-1]
        if (!in_rp && line ~ /^[ \t]*reverse_proxy/) {
            in_rp = 1
            rp_depth = 0
            if (line ~ /\{[ \t]*$/) {
                rp_depth = 1
            }
            if (!rp_replaced) {
                while ((getline rline < rfile) > 0) {
                    if (length(rline) > 0) print_line(rline)
                }
                close(rfile)
                rp_replaced = 1
            }
            if (rp_depth == 0) {
                in_rp = 0
            }
            next
        }

        if (in_rp) {
            open_c = 0; close_c = 0
            for (i = 1; i <= length(line); i++) {
                ch = substr(line, i, 1)
                if (ch == "{") open_c++
                if (ch == "}") close_c++
            }
            rp_depth += (open_c - close_c)
            if (rp_depth <= 0) {
                in_rp = 0
            }
            next
        }

        # All other directives preserved as-is
        print_line(line)
    }
    ' "$target_file" > "$out_file"
    local awk_status=$?

    rm -f "$rp_file"

    # 防灾校验：严格非空与执行状态检查，严禁空配置或转换异常覆盖生产文件
    if [ $awk_status -eq 0 ] && [ -s "$out_file" ]; then
        mv -f "$out_file" "$target_file"
        ensure_caddyfile_perms "$target_file"
        return 0
    else
        echo -e "${RED}[错误] 配置生成异常 (转换失败或输出文件为空)，已拦截写入以防破坏生产配置！${PLAIN}"
        rm -f "$out_file"
        return 1
    fi
}

# 菜单 3: 交互式原位修改反代规则 (Zero-Nano In-Place Modifier)
edit_rule_inplace() {
    ensure_caddy_installed || return 1
    load_rules
    if [ "$RULE_TOTAL" -eq 0 ]; then
        echo -e "${YELLOW}当前暂无可修改的反代规则。${PLAIN}"
        pause
        return
    fi

    echo -e "\n${YELLOW}====================== 交互式原位修改反代规则 ======================${PLAIN}"
    printf "%-6s | %-12s | %-32s | %-24s\n" "[序号]" "状态" "外部访问域名 (Domain)" "代理目标 (Upstream)"
    echo "--------------------------------------------------------------------------------"
    for ((i = 1; i <= RULE_TOTAL; i++)); do
        local st_str="${GREEN}● 启用${PLAIN}"
        [ "${RULE_STATUS[i]}" == "disabled" ] && st_str="${RED}○ 停用${PLAIN}"
        local p_str="${RULE_PROTO[i]^^}"
        [ "${RULE_TLS_SKIP[i]}" -eq 1 ] && p_str="${p_str} (TLS Skip)"
        local tgt_str="${RULE_TARGET[i]:-(自定义/无代理)}"
        [ -n "${RULE_TARGET[i]}" ] && tgt_str="${RULE_TARGET[i]} (${p_str})"
        printf "%-6s | %-21b | %-32s | %-24s\n" "[$i]" "$st_str" "${RULE_DOMAIN[i]}" "$tgt_str"
    done
    echo "--------------------------------------------------------------------------------"

    read -p "请输入要修改的规则序号 [1-$RULE_TOTAL], 输入 0 返回: " sel_idx
    if ! [[ "$sel_idx" =~ ^[0-9]+$ ]] || [ "$sel_idx" -lt 1 ] || [ "$sel_idx" -gt "$RULE_TOTAL" ]; then
        return
    fi

    local cur_domain="${RULE_DOMAIN[sel_idx]}"
    local cur_target="${RULE_TARGET[sel_idx]}"
    local cur_proto="${RULE_PROTO[sel_idx]}"
    local cur_path="${RULE_PATH[sel_idx]}"
    local cur_tls_skip="${RULE_TLS_SKIP[sel_idx]}"
    local cur_status="${RULE_STATUS[sel_idx]}"
    local start_line="${RULE_START[sel_idx]}"
    local end_line="${RULE_END[sel_idx]}"

    local modified=0

    while true; do
        clear
        echo -e "${BLUE}================================================================${PLAIN}"
        echo -e "${GREEN}${BOLD}           正在修改规则 [${sel_idx}] 配置详情 (免Nano原位修改)            ${PLAIN}"
        echo -e "${BLUE}================================================================${PLAIN}"
        local st_display="${GREEN}● 启用 (Active)${PLAIN}"
        [ "$cur_status" == "disabled" ] && st_display="${RED}○ 停用 (Disabled)${PLAIN}"

        local proto_display="${GREEN}${cur_proto^^}${PLAIN}"
        if [ "$cur_proto" == "https" ]; then
            if [ "$cur_tls_skip" -eq 1 ]; then
                proto_display="${YELLOW}HTTPS (跳过自签证书验证 tls_insecure_skip_verify)${PLAIN}"
            else
                proto_display="${GREEN}HTTPS (严格证书验证)${PLAIN}"
            fi
        fi

        echo -e "  [1] 外部域名 (Domain)        : ${BOLD}${cur_domain}${PLAIN}"
        echo -e "  [2] 代理目标 (Target)        : ${BOLD}${cur_target}${PLAIN}"
        echo -e "  [3] 协议与TLS (Protocol/TLS) : ${proto_display}"
        echo -e "  [4] 路径路由 (Path Matcher)  : ${BOLD}${cur_path:-(全部流量)}${PLAIN}"
        echo -e "  [5] 规则状态 (Status)        : ${st_display}"
        echo -e "  [6] 保存修改并应用生效"
        echo -e "  [0] 放弃修改并返回"
        echo -e "${BLUE}================================================================${PLAIN}"
        [ "$modified" -eq 1 ] && echo -e "${YELLOW}提示: 配置已产生变动，请选择 [6] 保存以生效。${PLAIN}"

        read -p "请输入修改项编号 [0-6]: " opt
        case "$opt" in
            1)
                echo -e "\n当前域名: ${GREEN}${cur_domain}${PLAIN}"
                read -p "请输入新的域名: " new_d
                new_d=$(echo "$new_d" | tr -d '[:space:]')
                new_d="${new_d%/}"
                new_d="${new_d#https://}"
                new_d="${new_d#http://}"
                if [ -n "$new_d" ] && [ "$new_d" != "$cur_domain" ]; then
                    local dup=0
                    for ((k = 1; k <= RULE_TOTAL; k++)); do
                        if [ "$k" -ne "$sel_idx" ] && [ "${RULE_DOMAIN[k]}" == "$new_d" ]; then
                            dup=1
                            break
                        fi
                    done
                    if [ "$dup" -eq 1 ]; then
                        echo -e "${RED}[错误] 域名 [${new_d}] 已在其他规则中使用！${PLAIN}"
                        sleep 1.5
                    else
                        cur_domain="$new_d"
                        modified=1
                    fi
                fi
                ;;
            2)
                echo -e "\n当前代理目标: ${GREEN}${cur_target}${PLAIN}"
                read -p "请输入新的目标地址/端口 (例如 8080 或 127.0.0.1:8080): " new_t
                new_t=$(echo "$new_t" | tr -d '[:space:]')
                if [ -n "$new_t" ]; then
                    if [[ "$new_t" =~ ^:[0-9]+$ ]]; then
                        new_t="127.0.0.1${new_t}"
                    elif [[ "$new_t" =~ ^[0-9]+$ ]]; then
                        if [ "$new_t" -lt 1 ] || [ "$new_t" -gt 65535 ]; then
                            echo -e "${RED}[错误] 端口范围必须在 1-65535 之间！${PLAIN}"
                            sleep 1.5
                            continue
                        fi
                        new_t="127.0.0.1:${new_t}"
                    fi
                    if [[ "$new_t" =~ ^https:// ]]; then
                        new_t="${new_t#https://}"
                        cur_proto="https"
                    elif [[ "$new_t" =~ ^http:// ]]; then
                        new_t="${new_t#http://}"
                        cur_proto="http"
                    fi
                    cur_target="$new_t"
                    modified=1
                fi
                ;;
            3)
                echo -e "\n当前协议: ${cur_proto^^}, TLS跳过验证: ${cur_tls_skip}"
                echo -e "  1. HTTP (标准明文)"
                echo -e "  2. HTTPS + 开启跳过自签名证书校验 (tls_insecure_skip_verify, 推荐 3x-ui/面板)"
                echo -e "  3. HTTPS + 严格证书校验"
                read -p "请选择协议模式 [1-3]: " p_choice
                case "$p_choice" in
                    1)
                        cur_proto="http"
                        cur_tls_skip=0
                        modified=1
                        ;;
                    2)
                        cur_proto="https"
                        cur_tls_skip=1
                        modified=1
                        ;;
                    3)
                        cur_proto="https"
                        cur_tls_skip=0
                        modified=1
                        ;;
                esac
                ;;
            4)
                echo -e "\n当前路径路由: ${cur_path:-(全部流量)}"
                read -p "请输入路径匹配规则 (例如 /api/*, 直接回车代理全部流量): " new_p
                new_p=$(echo "$new_p" | tr -d '[:space:]')
                if [ -n "$new_p" ] && [[ "$new_p" != /* && "$new_p" != @* ]]; then
                    new_p="/$new_p"
                fi
                cur_path="$new_p"
                modified=1
                ;;
            5)
                if [ "$cur_status" == "active" ]; then
                    cur_status="disabled"
                else
                    cur_status="active"
                fi
                modified=1
                ;;
            6)
                create_backup "修改规则前备份: ${cur_domain}"
                update_rule_block "$CADDY_FILE" "$start_line" "$end_line" \
                    "$cur_domain" "$cur_target" "$cur_proto" "$cur_path" "$cur_tls_skip" "$cur_status"

                if safe_reload; then
                    echo -e "\n${GREEN}✓ 规则 [${cur_domain}] 已成功就地修改并生效！${PLAIN}"
                else
                    echo -e "\n${RED}✗ 修改更新失败，已自动回滚。${PLAIN}"
                fi
                pause
                break
                ;;
            0)
                echo -e "${YELLOW}已放弃本次修改，原配置未做任何变动。${PLAIN}"
                sleep 1
                break
                ;;
            *)
                echo -e "${RED}输入无效，请重新选择！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# 菜单 4: 启用 / 停用反代规则 (无损切换，保护自定义复杂配置)
toggle_rule() {
    ensure_caddy_installed || return 1
    load_rules
    if [ "$RULE_TOTAL" -eq 0 ]; then
        echo -e "${YELLOW}当前暂无任何反代规则。${PLAIN}"
        pause
        return
    fi

    echo -e "\n${YELLOW}====================== 启用 / 停用反代规则 ======================${PLAIN}"
    printf "%-6s | %-12s | %-32s | %-24s\n" "[序号]" "当前状态" "外部访问域名 (Domain)" "代理目标 (Upstream)"
    echo "--------------------------------------------------------------------------------"
    for ((i = 1; i <= RULE_TOTAL; i++)); do
        local st_str="${GREEN}● 启用${PLAIN}"
        [ "${RULE_STATUS[i]}" == "disabled" ] && st_str="${RED}○ 停用${PLAIN}"
        local tgt_str="${RULE_TARGET[i]:-(自定义/无代理)}"
        printf "%-6s | %-21b | %-32s | %-24s\n" "[$i]" "$st_str" "${RULE_DOMAIN[i]}" "$tgt_str"
    done
    echo "--------------------------------------------------------------------------------"

    read -p "请输入要切换状态的规则序号 [1-$RULE_TOTAL], 输入 0 取消: " tog_idx
    if ! [[ "$tog_idx" =~ ^[0-9]+$ ]] || [ "$tog_idx" -lt 1 ] || [ "$tog_idx" -gt "$RULE_TOTAL" ]; then
        return
    fi

    local target_domain="${RULE_DOMAIN[tog_idx]}"
    local cur_status="${RULE_STATUS[tog_idx]}"
    local s_line="${RULE_START[tog_idx]}"
    local e_line="${RULE_END[tog_idx]}"

    if [ "$cur_status" == "active" ]; then
        read -p "确认停用规则 [$target_domain] 吗? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            create_backup "停用规则: ${target_domain}"
            local target_dir
            target_dir="$(dirname "$CADDY_FILE")"
            local out_file
            out_file=$(mktemp "${target_dir}/.cad_tmp.XXXXXX") || { echo -e "${RED}[错误] 无法创建临时文件！${PLAIN}"; pause; return 1; }

            awk -v s="$s_line" -v e="$e_line" '
            NR >= s && NR <= e {
                if ($0 !~ /^[ \t]*#[ \t]*\[cad:disabled\]/) {
                    print "# [cad:disabled] " $0
                    next
                }
            }
            { print $0 }
            ' "$CADDY_FILE" > "$out_file"
            local awk_status=$?

            # 防灾校验：严格非空与执行状态检查
            if [ $awk_status -eq 0 ] && [ -s "$out_file" ]; then
                mv -f "$out_file" "$CADDY_FILE"
                ensure_caddyfile_perms "$CADDY_FILE"
                if safe_reload; then
                    echo -e "\n${GREEN}✓ 规则 [$target_domain] 已设置为停用状态！${PLAIN}"
                else
                    echo -e "\n${RED}✗ 停用规则生效失败，已自动回滚。${PLAIN}"
                fi
            else
                echo -e "${RED}[错误] 停用规则异常 (生成文件为空或转换失败)，已拦截写入以保护生产配置！${PLAIN}"
                rm -f "$out_file"
            fi
        fi
    else
        read -p "确认重新启用规则 [$target_domain] 吗? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            create_backup "启用规则: ${target_domain}"
            local target_dir
            target_dir="$(dirname "$CADDY_FILE")"
            local out_file
            out_file=$(mktemp "${target_dir}/.cad_tmp.XXXXXX") || { echo -e "${RED}[错误] 无法创建临时文件！${PLAIN}"; pause; return 1; }

            awk -v s="$s_line" -v e="$e_line" '
            NR >= s && NR <= e {
                line = $0
                sub(/^[ \t]*#[ \t]*\[cad:disabled\][ \t]?/, "", line)
                print line
                next
            }
            { print $0 }
            ' "$CADDY_FILE" > "$out_file"
            local awk_status=$?

            # 防灾校验：严格非空与执行状态检查
            if [ $awk_status -eq 0 ] && [ -s "$out_file" ]; then
                mv -f "$out_file" "$CADDY_FILE"
                ensure_caddyfile_perms "$CADDY_FILE"
                if safe_reload; then
                    echo -e "\n${GREEN}✓ 规则 [$target_domain] 已重新启用！${PLAIN}"
                else
                    echo -e "\n${RED}✗ 启用规则生效失败，已自动回滚。${PLAIN}"
                fi
            else
                echo -e "${RED}[错误] 启用规则异常 (生成文件为空或转换失败)，已拦截写入以保护生产配置！${PLAIN}"
                rm -f "$out_file"
            fi
        fi
    fi
    pause
}

# 菜单 5: 删除已有反代规则
del_rule() {
    ensure_caddy_installed || return 1
    load_rules
    if [ "$RULE_TOTAL" -eq 0 ]; then
        echo -e "${YELLOW}当前没有任何可删除的反代规则。${PLAIN}"
        pause
        return
    fi

    echo -e "\n${YELLOW}======================== 删除已有反代规则 ========================${PLAIN}"
    printf "%-6s | %-12s | %-32s | %-24s\n" "[序号]" "当前状态" "外部访问域名 (Domain)" "代理目标 (Upstream)"
    echo "--------------------------------------------------------------------------------"
    for ((i = 1; i <= RULE_TOTAL; i++)); do
        local st_str="${GREEN}● 启用${PLAIN}"
        [ "${RULE_STATUS[i]}" == "disabled" ] && st_str="${RED}○ 停用${PLAIN}"
        local tgt_str="${RULE_TARGET[i]:-(自定义/无代理)}"
        printf "%-6s | %-21b | %-32s | %-24s\n" "[$i]" "$st_str" "${RULE_DOMAIN[i]}" "$tgt_str"
    done
    echo "--------------------------------------------------------------------------------"

    read -p "请输入要删除的规则序号 [1-$RULE_TOTAL], 输入 0 取消: " del_idx
    if ! [[ "$del_idx" =~ ^[0-9]+$ ]] || [ "$del_idx" -lt 1 ] || [ "$del_idx" -gt "$RULE_TOTAL" ]; then
        return
    fi

    local target_del="${RULE_DOMAIN[del_idx]}"
    local s_line="${RULE_START[del_idx]}"
    local e_line="${RULE_END[del_idx]}"

    read -p "确认彻底删除 [$target_del] 的反向代理配置吗? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        create_backup "删除规则: ${target_del}"
        local target_dir
        target_dir="$(dirname "$CADDY_FILE")"
        local out_file
        out_file=$(mktemp "${target_dir}/.cad_tmp.XXXXXX") || { echo -e "${RED}[错误] 无法创建临时文件！${PLAIN}"; pause; return 1; }

        awk -v s="$s_line" -v e="$e_line" '
        NR >= s && NR <= e { next }
        { print $0 }
        ' "$CADDY_FILE" > "$out_file"
        local awk_status=$?

        # 若删除的是唯一规则导致输出为空或仅剩空白字符，写入标准占位注释以防空文件
        if [ "$RULE_TOTAL" -eq 1 ] && ! grep -q '[^[:space:]]' "$out_file" 2>/dev/null; then
            echo "# caddy-pro" > "$out_file"
        fi

        # 防灾校验：严格非空与执行状态检查
        if [ $awk_status -eq 0 ] && [ -s "$out_file" ]; then
            mv -f "$out_file" "$CADDY_FILE"
            ensure_caddyfile_perms "$CADDY_FILE"
            if safe_reload; then
                echo -e "\n${GREEN}✓ 已成功删除 [$target_del]！${PLAIN}"
            else
                echo -e "\n${RED}✗ 删除规则生效失败，已自动回滚。${PLAIN}"
            fi
        else
            echo -e "${RED}[错误] 删除规则异常 (生成文件为空或转换失败)，已拦截写入以保护生产配置！${PLAIN}"
            rm -f "$out_file"
        fi
    else
        echo "操作已取消。"
    fi
    pause
}

# 辅助: 检测是否处于 Cloudflare 官方 IPv4 网段
is_cloudflare_ip() {
    local ip="$1"
    local cf_prefixes=(
        "173.245." "103.21." "103.22." "103.31." "141.101."
        "108.162." "190.93." "188.114." "197.234." "198.41."
        "162.158." "162.159." "104.16." "104.17." "104.18." "104.19."
        "104.20." "104.21." "104.22." "104.23." "104.24."
        "104.25." "104.26." "104.27." "104.28." "172.64."
        "172.65." "172.66." "172.67." "172.68." "172.69."
        "172.70." "172.71." "131.0.72." "131.0.73." "131.0.74." "131.0.75."
    )
    for p in "${cf_prefixes[@]}"; do
        if [[ "$ip" == "$p"* ]]; then
            return 0
        fi
    done
    return 1
}

# 辅助: 域名 DNS 查询函数 (支持 dig, getent, 与 DoH 兜底)
resolve_dns_a() {
    local domain="$1"
    local ip=""
    if command -v dig > /dev/null 2>&1; then
        ip=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)
        [ -z "$ip" ] && ip=$(dig +short @"1.1.1.1" "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)
        [ -z "$ip" ] && ip=$(dig +short @"8.8.8.8" "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)
    fi
    if [ -z "$ip" ] && command -v getent > /dev/null 2>&1; then
        ip=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9.]+$' | head -n 1)
    fi
    if [ -z "$ip" ] && command -v nslookup > /dev/null 2>&1; then
        ip=$(nslookup "$domain" 2>/dev/null | awk '/^Address: / { print $2 }' | grep -E '^[0-9.]+$' | head -n 1)
    fi
    if [ -z "$ip" ]; then
        local doh
        doh=$(curl -s --connect-timeout 3 -H "accept: application/dns-json" "https://1.1.1.1/dns-query?name=${domain}&type=A" 2>/dev/null)
        ip=$(echo "$doh" | grep -oE '"data":"[0-9.]+"' | cut -d'"' -f4 | head -n 1)
    fi
    echo "$ip"
}

resolve_dns_aaaa() {
    local domain="$1"
    local ip6=""
    if command -v dig > /dev/null 2>&1; then
        ip6=$(dig +short "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | head -n 1)
        [ -z "$ip6" ] && ip6=$(dig +short @"1.1.1.1" "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' | head -n 1)
    fi
    if [ -z "$ip6" ] && command -v getent > /dev/null 2>&1; then
        ip6=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9a-fA-F:]+$' | grep ':' | head -n 1)
    fi
    if [ -z "$ip6" ]; then
        local doh
        doh=$(curl -s --connect-timeout 3 -H "accept: application/dns-json" "https://1.1.1.1/dns-query?name=${domain}&type=AAAA" 2>/dev/null)
        ip6=$(echo "$doh" | grep -oE '"data":"[0-9a-fA-F:]+"' | cut -d'"' -f4 | head -n 1)
    fi
    echo "$ip6"
}

# 辅助: 端口 80 / 443 冲突检测与一键清理
check_port_conflicts() {
    local conflicts=()
    local pids=()

    if command -v ss > /dev/null 2>&1; then
        local raw
        raw=$(ss -tlpn '( sport = :80 or sport = :443 )' 2>/dev/null | grep -v "caddy" | grep "LISTEN")
        if [ -n "$raw" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                local port="80/443"
                [[ "$line" =~ :80[[:space:]] ]] && port="80"
                [[ "$line" =~ :443[[:space:]] ]] && port="443"

                local proc_info="未知进程"
                if [[ "$line" =~ users:\(\(\"?([^,\"]+)\"?,pid=([0-9]+) ]]; then
                    local pname="${BASH_REMATCH[1]}"
                    local ppid="${BASH_REMATCH[2]}"
                    proc_info="${pname} (PID: ${ppid})"
                    pids+=("$ppid")
                fi
                conflicts+=("端口 ${port}: ${proc_info}")
            done <<< "$raw"
        fi
    elif command -v netstat > /dev/null 2>&1; then
        local raw
        raw=$(netstat -tlpn 2>/dev/null | grep -E ':(80|443)[[:space:]]' | grep -v "caddy" | grep "LISTEN")
        if [ -n "$raw" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                local port="80/443"
                [[ "$line" =~ :80[[:space:]] ]] && port="80"
                [[ "$line" =~ :443[[:space:]] ]] && port="443"
                local pinfo
                pinfo=$(echo "$line" | awk '{print $7}')
                local ppid="${pinfo%/*}"
                [ -n "$ppid" ] && pids+=("$ppid")
                conflicts+=("端口 ${port}: ${pinfo}")
            done <<< "$raw"
        fi
    elif command -v lsof > /dev/null 2>&1; then
        local raw
        raw=$(lsof -i :80 -i :443 -sTCP:LISTEN -P -n 2>/dev/null | grep -v "caddy" | sed 1d)
        if [ -n "$raw" ]; then
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                local pname ppid port
                pname=$(echo "$line" | awk '{print $1}')
                ppid=$(echo "$line" | awk '{print $2}')
                port="80/443"
                [[ "$line" =~ :80 ]] && port="80"
                [[ "$line" =~ :443 ]] && port="443"
                [ -n "$ppid" ] && pids+=("$ppid")
                conflicts+=("端口 ${port}: ${pname} (PID: ${ppid})")
            done <<< "$raw"
        fi
    fi

    if [ ${#conflicts[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠️  检测到以下外部进程正占用 Web 核心端口 (80/443)：${PLAIN}"
        for c in "${conflicts[@]}"; do
            echo -e "  - ${RED}${c}${PLAIN}"
        done
        echo -e "${YELLOW}提示: 80/443 端口被占用会导致 Caddy 无法启动或 ACME 证书签发中断！${PLAIN}"
        read -p "是否一键停止冲突服务并释放端口? (y/n): " kill_opt
        if [[ "$kill_opt" == "y" || "$kill_opt" == "Y" ]]; then
            echo -e "${BLUE}正在停止冲突服务并释放端口...${PLAIN}"
            systemctl stop nginx 2>/dev/null
            systemctl disable nginx 2>/dev/null
            systemctl stop apache2 2>/dev/null
            systemctl disable apache2 2>/dev/null
            systemctl stop httpd 2>/dev/null
            systemctl disable httpd 2>/dev/null
            for pid in "${pids[@]}"; do
                if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
                    kill -9 "$pid" 2>/dev/null
                fi
            done
            sleep 1
            echo -e "${GREEN}✓ 端口释放操作已执行完毕！${PLAIN}"
        fi
    else
        echo -e "${GREEN}✓ 端口 80 与 443 状态健康 (未检测到第三方服务冲突)。${PLAIN}"
    fi
}

# 核心诊断逻辑: 运行 SSL Doctor
run_ssl_doctor() {
    local target_domain="$1"
    echo -e "${BLUE}====================== SSL Doctor & 网络综合诊断 ======================${PLAIN}"

    # 1. 双栈 (Dual-Stack) 本机公网 IP 检测
    echo -e "${YELLOW}[1/4] 本机双栈公网 IP 诊断:${PLAIN}"
    local server_v4=""
    for ip_url in "https://api.ipify.org" "https://ip.sb" "https://icanhazip.com" "https://ifconfig.me/ip"; do
        local res
        res=$(curl -4s -m 3 "$ip_url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$res" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            server_v4="$res"
            break
        fi
    done

    local server_v6=""
    for ip6_url in "https://api6.ipify.org" "https://ip.sb" "https://icanhazip.com"; do
        local res6
        res6=$(curl -6s -m 3 "$ip6_url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$res6" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$res6" == *:* ]]; then
            server_v6="$res6"
            break
        fi
    done

    echo -e "  - 本机公网 IPv4: ${BOLD}${server_v4:-未分配 / 超时}${PLAIN}"
    echo -e "  - 本机公网 IPv6: ${BOLD}${server_v6:-未分配 / 超时}${PLAIN}"

    # 2. 针对指定域名的 DNS 解析及与 VPS 公网 IP 比对
    if [ -n "$target_domain" ]; then
        echo -e "\n${YELLOW}[2/4] 域名 DNS 解析一致性检查 [${target_domain}]:${PLAIN}"
        local dns_v4
        dns_v4=$(resolve_dns_a "$target_domain")
        local dns_v6
        dns_v6=$(resolve_dns_aaaa "$target_domain")

        echo -e "  - 域名 A 记录 (IPv4)   : ${BOLD}${dns_v4:-未查询到解析}${PLAIN}"
        echo -e "  - 域名 AAAA 记录 (IPv6): ${BOLD}${dns_v6:-未配置}${PLAIN}"

        if [ -n "$dns_v4" ] && [ -n "$server_v4" ]; then
            if [ "$dns_v4" == "$server_v4" ]; then
                echo -e "  ${GREEN}✓ IPv4 DNS 解析与本机公网 IP 一致！Let's Encrypt / ZeroSSL 验证可直接通过。${PLAIN}"
            else
                echo -e "  ${RED}✗ 域名解析 IP ($dns_v4) 与本机 IP ($server_v4) 不匹配！${PLAIN}"
                if is_cf_dns_active; then
                    echo -e "  ${GREEN}⚡ [DNS-01 引擎生效中] 检测到已激活 Cloudflare DNS-01 验证！即使域名解析至中转机/NAT小鸡，证书亦可通过 DNS TXT 记录直签，无需直连本机！${PLAIN}"
                else
                    echo -e "  ${YELLOW}建议: 请检查 DNS 服务商控制台的 A 记录设置，或等待 DNS 缓存生效。${PLAIN}"
                    echo -e "  ${BLUE}💡 若这是中转机/NAT小鸡架构，推荐进入「菜单 6」开启 Cloudflare DNS-01 验证，彻底解除 IP 必须直连本机的限制！${PLAIN}"
                fi
            fi
        else
            echo -e "  ${YELLOW}ℹ 无法完成完整匹配比对 (DNS 或本机 IP 缺失)。${PLAIN}"
        fi

        # 3. Cloudflare 小黄云 (CDN 代理) 检测
        echo -e "\n${YELLOW}[3/4] CDN / 代理状态检测:${PLAIN}"
        local is_cf=0
        if [ -n "$dns_v4" ] && is_cloudflare_ip "$dns_v4"; then
            is_cf=1
        fi
        if [ -n "$dns_v6" ] && [[ "$dns_v6" == 2606:4700:* || "$dns_v6" == 2803:f800:* || "$dns_v6" == 2a06:98c0:* ]]; then
            is_cf=1
        fi
        local cf_hdr
        cf_hdr=$(curl -sI -m 2 "http://${target_domain}" 2>/dev/null | grep -iE 'server: cloudflare|cf-ray:' || true)
        [ -n "$cf_hdr" ] && is_cf=1

        if [ "$is_cf" -eq 1 ]; then
            echo -e "  ${YELLOW}⚠️  检测到该域名开启了 Cloudflare 小黄云 (CDN 代理模式)！${PLAIN}"
            if is_cf_dns_active; then
                echo -e "  ${GREEN}✓ [DNS-01 引擎已就绪] 已检测到生效中的 Cloudflare DNS-01 验证！${PLAIN}"
                echo -e "  ${GREEN}  即便开启小黄云代理模式，亦可无视边缘拦截正常完成证书签发与自动续期，无需切为灰色云朵！${PLAIN}"
            else
                echo -e "  ${BLUE}【SSL 证书签发避坑指南】${PLAIN}"
                echo -e "  1. 开启小黄云后，HTTP-01 验证请求会被 Cloudflare 边缘节点代理拦截；"
                echo -e "  2. 传统做法: 在 Cloudflare 面板将该记录临时切为 '仅限 DNS (灰色云朵)'，待证书签发成功后再开启小黄云；"
                echo -e "  3. 并在 Cloudflare 控制台中将 SSL/TLS 加密模式设置为 'Full' (完全) 或 'Strict' (严格)；"
                echo -e "  4. ${GREEN}${BOLD}终极方案${PLAIN}: 使用「菜单 6」一键配置 Cloudflare DNS-01，零手动操作、永久无视小黄云拦截！"
            fi
        else
            echo -e "  ${GREEN}✓ 未检测到 Cloudflare CDN 代理拦截，外部请求直连本服务器。${PLAIN}"
        fi
    else
        echo -e "\n${YELLOW}[2/4] 未指定检测域名，跳过 DNS 解析一致性比对。${PLAIN}"
        echo -e "\n${YELLOW}[3/4] 跳过 CDN 代理状态检测。${PLAIN}"
    fi

    # 4. 端口 80 / 443 冲突检测
    echo -e "\n${YELLOW}[4/4] Web 核心端口 (80/443) 冲突检测:${PLAIN}"
    check_port_conflicts
    if is_cf_dns_active; then
        echo -e "  ${GREEN}ℹ [提示] 当前处于 Cloudflare DNS-01 模式，证书申请与续期完全不依赖 80/443 入站端口连接。${PLAIN}"
    fi
    echo -e "${BLUE}=======================================================================${PLAIN}"
}

# 菜单 6: SSL 证书体检与网络诊断
ssl_doctor() {
    clear
    echo -e "${BLUE}================================================================${PLAIN}"
    echo -e "${GREEN}${BOLD}             SSL 证书体检与网络诊断 (SSL Doctor)                ${PLAIN}"
    echo -e "${BLUE}================================================================${PLAIN}"

    load_rules
    local check_domain="$1"
    if [ -z "$check_domain" ]; then
        if [ "$RULE_TOTAL" -gt 0 ]; then
            echo "请选择要诊断的已有域名，或手动输入其他域名："
            for ((i = 1; i <= RULE_TOTAL; i++)); do
                echo -e "  [${GREEN}$i${PLAIN}] ${RULE_DOMAIN[i]}"
            done
            echo -e "  [${GREEN}C${PLAIN}] 手动输入自定义外部域名"
            echo -e "  [${GREEN}0${PLAIN}] 返回主菜单"
            read -p "请输入选项: " d_opt
            if [ "$d_opt" == "0" ]; then
                return
            elif [[ "$d_opt" =~ ^[0-9]+$ ]] && [ "$d_opt" -ge 1 ] && [ "$d_opt" -le "$RULE_TOTAL" ]; then
                check_domain="${RULE_DOMAIN[d_opt]}"
            else
                read -p "请输入需要诊断的完整域名: " check_domain
            fi
        else
            read -p "请输入需要诊断的完整域名 (输入 0 返回): " check_domain
            [ "$check_domain" == "0" ] && return
        fi
    fi

    check_domain=$(echo "$check_domain" | tr -d '[:space:]')
    run_ssl_doctor "$check_domain"
    pause
}

# ==============================================================================
#  Cloudflare DNS-01 ACME 自动化引擎模块 (v3.1.0 核心扩展)
# ==============================================================================

# 检测 Caddy 二进制适用的 CPU 架构标识
detect_caddy_arch() {
    local m
    m=$(uname -m)
    case "$m" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l|armhf)   echo "arm" ;;
        riscv64)        echo "riscv64" ;;
        s390x)          echo "s390x" ;;
        *)              echo "amd64" ;;
    esac
}

# 检查当前 Caddy 是否集成了 Cloudflare DNS 插件模块
has_cf_dns_module() {
    command -v caddy >/dev/null 2>&1 || return 1
    caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'
}

# 从 Caddyfile 全局配置块中解析已配置的 Cloudflare API Token
get_cf_dns_token() {
    [ ! -f "$CADDY_FILE" ] && return 1
    awk '
    function count_char(str, ch,   c, i, L) {
        c = 0; L = length(str)
        for (i = 1; i <= L; i++) if (substr(str, i, 1) == ch) c++
        return c
    }
    BEGIN { in_global = 0; depth = 0; token = "" }
    {
        raw = $0
        line = raw
        sub(/^[ \t]+/, "", line)
        if (depth == 0) {
            if (line ~ /^\{/) {
                in_global = 1
                open_c = count_char(line, "{")
                close_c = count_char(line, "}")
                depth = open_c - close_c
                if (line ~ /acme_dns[ \t]+cloudflare/) {
                    t = line
                    sub(/.*acme_dns[ \t]+cloudflare[ \t]+/, "", t)
                    sub(/[ \t\}].*$/, "", t)
                    token = t
                }
                if (depth <= 0) in_global = 0
            }
        } else if (in_global) {
            open_c = count_char(line, "{")
            close_c = count_char(line, "}")
            depth += (open_c - close_c)
            if (line ~ /acme_dns[ \t]+cloudflare/) {
                t = line
                sub(/^[ \t]*acme_dns[ \t]+cloudflare[ \t]+/, "", t)
                sub(/[ \t\}].*$/, "", t)
                token = t
            }
            if (depth <= 0) in_global = 0
        }
    }
    END {
        if (token != "") {
            gsub(/["\047\r]/, "", token)
            print token
            exit 0
        }
        exit 1
    }
    ' "$CADDY_FILE"
}

# 判断 Caddyfile 中是否配置了 Cloudflare Token
has_cf_dns_token() {
    local t
    t=$(get_cf_dns_token 2>/dev/null)
    [ -n "$t" ]
}

# 判断 Cloudflare DNS-01 ACME 引擎是否处于完全就绪并生效状态
is_cf_dns_active() {
    has_cf_dns_module && has_cf_dns_token
}

# 写入或就地更新 Caddyfile 全局配置块中的 Cloudflare API Token
apply_cf_dns_token() {
    local target_file="$1"
    local token="$2"
    local target_dir
    target_dir=$(dirname "$target_file")
    local tmp_file
    tmp_file=$(mktemp "${target_dir}/.cad_tmp.XXXXXX" 2>/dev/null) || tmp_file="${target_file}.tmp.$$"

    local has_global
    has_global=$(awk '
    BEGIN { found = 0; depth = 0 }
    {
        line = $0
        sub(/^[ \t]+/, "", line)
        if (depth == 0) {
            if (line ~ /^\{/) {
                found = 1
                exit 0
            } else if (line ~ /^[a-zA-Z0-9_.*:-]+.*\{/) {
                exit 1
            }
        }
    }
    END { if (!found) exit 1 }
    ' "$target_file" && echo "1" || echo "0")

    if [ "$has_global" == "1" ]; then
        awk -v token="$token" '
        function count_char(str, ch,   c, i, L) {
            c = 0; L = length(str)
            for (i = 1; i <= L; i++) if (substr(str, i, 1) == ch) c++
            return c
        }
        BEGIN { in_global = 0; depth = 0; replaced = 0 }
        {
            raw = $0
            line = raw
            sub(/^[ \t]+/, "", line)
            if (depth == 0 && !replaced) {
                if (line ~ /^\{/) {
                    in_global = 1
                    open_c = count_char(line, "{")
                    close_c = count_char(line, "}")
                    depth = open_c - close_c
                    if (depth <= 0) {
                        print "{\n    acme_dns cloudflare " token "\n}"
                        replaced = 1
                        in_global = 0
                        next
                    }
                    print raw
                    next
                }
            } else if (in_global) {
                open_c = count_char(line, "{")
                close_c = count_char(line, "}")
                depth += (open_c - close_c)
                if (line ~ /^[ \t]*acme_dns[ \t]+cloudflare/) {
                    print "    acme_dns cloudflare " token
                    replaced = 1
                    next
                }
                if (depth <= 0) {
                    if (!replaced) {
                        print "    acme_dns cloudflare " token
                        replaced = 1
                    }
                    in_global = 0
                    print raw
                    next
                }
            }
            print raw
        }
        ' "$target_file" > "$tmp_file"
    else
        {
            echo -e "{\n    acme_dns cloudflare ${token}\n}\n"
            cat "$target_file"
        } > "$tmp_file"
    fi

    if [ -s "$tmp_file" ]; then
        mv -f "$tmp_file" "$target_file"
        return 0
    else
        rm -f "$tmp_file"
        return 1
    fi
}

# 彻底移除 Caddyfile 全局配置块中的 Cloudflare DNS-01 指令 (自动修剪空全局块)
remove_cf_dns_token() {
    local target_file="$1"
    local target_dir
    target_dir=$(dirname "$target_file")
    local tmp_file
    tmp_file=$(mktemp "${target_dir}/.cad_tmp.XXXXXX" 2>/dev/null) || tmp_file="${target_file}.tmp.$$"

    awk '
    function count_char(str, ch,   c, i, L) {
        c = 0; L = length(str)
        for (i = 1; i <= L; i++) if (substr(str, i, 1) == ch) c++
        return c
    }
    BEGIN { in_global = 0; depth = 0; g_lines_cnt = 0; g_other_cnt = 0 }
    {
        raw = $0
        line = raw
        sub(/^[ \t]+/, "", line)
        if (depth == 0) {
            if (line ~ /^\{/) {
                in_global = 1
                open_c = count_char(line, "{")
                close_c = count_char(line, "}")
                depth = open_c - close_c
                g_lines[0] = raw
                g_lines_cnt = 1
                g_other_cnt = 0
                if (line ~ /acme_dns[ \t]+cloudflare/) {
                    # 忽略
                } else if (line !~ /^\{[ \t]*$/) {
                    g_other_cnt++
                }
                if (depth <= 0) {
                    in_global = 0
                }
                next
            }
        } else if (in_global) {
            open_c = count_char(line, "{")
            close_c = count_char(line, "}")
            depth += (open_c - close_c)
            if (line ~ /^[ \t]*acme_dns[ \t]+cloudflare/) {
                # 忽略此行
            } else {
                g_lines[g_lines_cnt++] = raw
                if (depth > 0 && line !~ /^[ \t]*$/ && line !~ /^[ \t]*#/) {
                    g_other_cnt++
                }
            }
            if (depth <= 0) {
                if (g_other_cnt > 0) {
                    for (i = 0; i < g_lines_cnt; i++) {
                        print g_lines[i]
                    }
                }
                in_global = 0
            }
            next
        }
        print raw
    }
    ' "$target_file" > "$tmp_file"

    if [ -f "$tmp_file" ]; then
        mv -f "$tmp_file" "$target_file"
        return 0
    fi
    return 1
}

# 安装 / 升级为包含 Cloudflare DNS-01 模块的增强版 Caddy
install_caddy_cf() {
    clear
    echo -e "${BLUE}====================================================${PLAIN}"
    echo -e "${GREEN}    安装 / 升级 Cloudflare 增强版 Caddy (集成 DNS-01)    ${PLAIN}"
    echo -e "${BLUE}====================================================${PLAIN}"
    echo -e "说明: 增强版包含官方 caddy-dns/cloudflare 插件，单静态二进制无常驻内存开销。"
    echo -e "支持: 泛域名证书申请、无入站端口 (NAT小鸡) 签发、穿透 Cloudflare 小黄云。\n"

    # 确保基础运行环境与 systemd 配置完备 (若全新机器未曾安装 Caddy)
    if ! command -v caddy >/dev/null 2>&1 && [ ! -f /lib/systemd/system/caddy.service ] && [ ! -f /etc/systemd/system/caddy.service ]; then
        echo -e "${BLUE}检测到系统未安装 Caddy 基础环境，正在配置系统依赖与 systemd 服务...${PLAIN}"
        if [ -f /etc/debian_version ]; then
            apt update >/dev/null 2>&1
            apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg >/dev/null 2>&1
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes >/dev/null 2>&1 || true
            chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null 2>&1 || true
            chmod o+r /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
            apt update >/dev/null 2>&1
            apt install -y caddy >/dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            if command -v dnf > /dev/null 2>&1; then
                (dnf install -y 'dnf-command(copr)' curl || dnf install -y dnf-plugins-core curl) >/dev/null 2>&1
                dnf copr enable -y @caddy/caddy >/dev/null 2>&1
                dnf install -y caddy >/dev/null 2>&1
            fi
        fi
    fi

    local arch
    arch=$(detect_caddy_arch)
    echo -e "${BLUE}[1/4] 检测到系统架构: ${GREEN}${arch}${PLAIN}"

    local download_url="https://caddyserver.com/api/download?os=linux&arch=${arch}&p=github.com%2Fcaddy-dns%2Fcloudflare"
    local tmp_bin
    tmp_bin=$(mktemp "/tmp/caddy_cf.XXXXXX" 2>/dev/null) || tmp_bin="/tmp/caddy_cf_$$"

    echo -e "${BLUE}[2/4] 正在从 Caddy 官方构建 API 下载增强版程序...${PLAIN}"
    echo -e "下载地址: ${download_url}"
    if ! curl -fSL --retry 3 --connect-timeout 20 --max-time 180 "$download_url" -o "$tmp_bin"; then
        echo -e "${RED}✗ 下载失败！请检查 VPS 对 caddyserver.com 的网络连接。${PLAIN}"
        rm -f "$tmp_bin"
        pause
        return 1
    fi

    echo -e "${BLUE}[3/4] 验证程序完整性与插件模块...${PLAIN}"
    chmod +x "$tmp_bin"
    if ! "$tmp_bin" version >/dev/null 2>&1; then
        echo -e "${RED}✗ 下载的文件不是有效的 Caddy 二进制程序！${PLAIN}"
        rm -f "$tmp_bin"
        pause
        return 1
    fi

    if ! "$tmp_bin" list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then
        echo -e "${RED}✗ 程序验证失败: 未检测到 dns.providers.cloudflare 模块！${PLAIN}"
        rm -f "$tmp_bin"
        pause
        return 1
    fi
    echo -e "${GREEN}✓ 模块验证通过: dns.providers.cloudflare 已就绪！${PLAIN}"

    echo -e "${BLUE}[4/4] 安装二进制文件并设置系统服务权限...${PLAIN}"
    local target_bin
    target_bin=$(command -v caddy 2>/dev/null || echo "/usr/bin/caddy")
    [ -z "$target_bin" ] && target_bin="/usr/bin/caddy"

    # 备份原有标准二进制
    if [ -f "$target_bin" ] && [ ! -f "${target_bin}.standard_bak" ]; then
        cp -f "$target_bin" "${target_bin}.standard_bak" 2>/dev/null || true
    fi

    # 原子替换以绕过运行中文件的 ETXTBSY 锁
    mv -f "$tmp_bin" "$target_bin"
    chmod 755 "$target_bin"
    chown root:root "$target_bin" 2>/dev/null || true
    setcap cap_net_bind_service=+ep "$target_bin" 2>/dev/null || true

    # 若系统存在 apt-mark 则锁定版本，防止 apt upgrade 覆盖增强版
    if command -v apt-mark >/dev/null 2>&1; then
        apt-mark hold caddy >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ 已锁定 APT 软件源中的 caddy 软件包，防止系统常规更新覆盖增强版。${PLAIN}"
    fi

    init_env
    ensure_caddyfile_perms "$CADDY_FILE"
    systemctl enable caddy >/dev/null 2>&1 || true
    systemctl restart caddy >/dev/null 2>&1 || true

    local new_ver
    new_ver=$("$target_bin" version 2>/dev/null | awk '{print $1}')
    echo -e "\n${GREEN}✓ Cloudflare 增强版 Caddy 已成功安装并就绪！${PLAIN}"
    echo -e "当前主程序版本: ${BOLD}${new_ver}${PLAIN} (含 dns.providers.cloudflare 插件)"
    pause
    return 0
}

# 恢复为系统官方标准版 Caddy (移除 DNS-01 插件)
switch_caddy_standard() {
    clear
    echo -e "${BLUE}====================================================${PLAIN}"
    echo -e "${GREEN}               恢复为官方标准版 Caddy                ${PLAIN}"
    echo -e "${BLUE}====================================================${PLAIN}"
    echo -e "${YELLOW}提示: 恢复为官方标准版将移除 Cloudflare DNS-01 插件。${PLAIN}"
    read -p "确定要恢复为官方标准版吗? (y/n): " confirm_sw
    if [[ "$confirm_sw" != "y" && "$confirm_sw" != "Y" ]]; then
        return
    fi

    if has_cf_dns_token; then
        echo -e "${YELLOW}检测到当前配置中包含 Cloudflare DNS-01 Token。${PLAIN}"
        read -p "是否同时清理 Caddyfile 中的 acme_dns 规则? (y/n): " clean_token
        if [[ "$clean_token" == "y" || "$clean_token" == "Y" ]]; then
            remove_cf_dns_token "$CADDY_FILE"
            ensure_caddyfile_perms "$CADDY_FILE"
        fi
    fi

    local target_bin
    target_bin=$(command -v caddy 2>/dev/null || echo "/usr/bin/caddy")
    [ -z "$target_bin" ] && target_bin="/usr/bin/caddy"

    if [ -f "${target_bin}.standard_bak" ]; then
        echo -e "${BLUE}正在从本地标准版备份恢复...${PLAIN}"
        cp -f "${target_bin}.standard_bak" "$target_bin"
        chmod 755 "$target_bin"
        chown root:root "$target_bin" 2>/dev/null || true
        setcap cap_net_bind_service=+ep "$target_bin" 2>/dev/null || true
    else
        echo -e "${BLUE}正在重新安装系统标准版软件包...${PLAIN}"
        if command -v apt-mark >/dev/null 2>&1; then
            apt-mark unhold caddy >/dev/null 2>&1 || true
            apt update >/dev/null 2>&1
            apt install --reinstall -y caddy >/dev/null 2>&1
        elif [ -f /etc/redhat-release ]; then
            (dnf reinstall -y caddy 2>/dev/null || yum reinstall -y caddy 2>/dev/null)
        else
            local arch
            arch=$(detect_caddy_arch)
            curl -fSL "https://caddyserver.com/api/download?os=linux&arch=${arch}" -o "$target_bin" 2>/dev/null
            chmod 755 "$target_bin"
            setcap cap_net_bind_service=+ep "$target_bin" 2>/dev/null || true
        fi
    fi

    if command -v apt-mark >/dev/null 2>&1; then
        apt-mark unhold caddy >/dev/null 2>&1 || true
    fi

    ensure_caddyfile_perms "$CADDY_FILE"
    systemctl restart caddy >/dev/null 2>&1 || true
    echo -e "\n${GREEN}✓ 已恢复为官方标准版 Caddy！${PLAIN}"
    pause
}

# 交互式配置 Cloudflare API Token
configure_cf_dns_token() {
    clear
    echo -e "${BLUE}================================================================${PLAIN}"
    echo -e "${GREEN}${BOLD}           配置 / 更新 Cloudflare DNS-01 API Token              ${PLAIN}"
    echo -e "${BLUE}================================================================${PLAIN}"

    if ! has_cf_dns_module; then
        echo -e "${YELLOW}⚠️  检测到当前 Caddy 尚未集成 Cloudflare DNS 模块！${PLAIN}"
        echo -e "启用 DNS-01 验证前，必须使用包含 dns.providers.cloudflare 的增强版程序。"
        read -p "是否立即自动下载并升级为 Cloudflare 增强版 Caddy? (y/n): " do_install_cf
        if [[ "$do_install_cf" == "y" || "$do_install_cf" == "Y" ]]; then
            if ! install_caddy_cf; then
                return 1
            fi
        else
            echo -e "${YELLOW}已取消操作。未安装增强版前无法启用 DNS-01 规则。${PLAIN}"
            pause
            return 1
        fi
    fi

    echo -e "\n${BLUE}【Cloudflare API Token 获取指引】${PLAIN}"
    echo -e "  1. 登录 Cloudflare 控制台: https://dash.cloudflare.com/profile/api-tokens"
    echo -e "  2. 点击「创建令牌」(Create Token) ➔ 选择「使用模板: 编辑区域 DNS」(Edit zone DNS)"
    echo -e "  3. 权限要求: ${BOLD}区域 - DNS - 编辑${PLAIN} (Zone - DNS - Edit)"
    echo -e "  4. 区域资源: ${BOLD}包括 - 所有区域${PLAIN} (All zones) 或 指定所需托管域名"
    echo -e "  5. 创建完成后复制 Token (注意: 绝非 Global API Key，保障主账号安全)\n"

    local old_token
    old_token=$(get_cf_dns_token 2>/dev/null || true)
    if [ -n "$old_token" ]; then
        local mask_old="${old_token:0:4}****${old_token: -4}"
        echo -e "当前已配置 Token: ${YELLOW}${mask_old}${PLAIN}"
        read -p "请输入新的 Cloudflare API Token (回车保持原样): " input_token
        input_token=$(echo "$input_token" | tr -d '[:space:]')
        if [ -z "$input_token" ]; then
            echo -e "${YELLOW}未做任何修改。${PLAIN}"
            pause
            return 0
        fi
    else
        read -p "请输入 Cloudflare API Token: " input_token
        input_token=$(echo "$input_token" | tr -d '[:space:]')
        if [ -z "$input_token" ]; then
            echo -e "${RED}[错误] Token 不能为空！${PLAIN}"
            pause
            return 1
        fi
    fi

    create_backup "配置 Cloudflare DNS-01 Token 前备份"
    if apply_cf_dns_token "$CADDY_FILE" "$input_token"; then
        ensure_caddyfile_perms "$CADDY_FILE"
        if safe_reload; then
            echo -e "\n${GREEN}✓ Cloudflare DNS-01 验证引擎已成功激活并平滑生效！${PLAIN}"
            echo -e "${BLUE}💡 所有通过 Caddy 管理的站点在申请/续期证书时，将全自动通过 Cloudflare DNS 验证。${PLAIN}"
            echo -e "${BLUE}💡 无需开放 80/443 入站端口，彻底穿透 Cloudflare 小黄云代理与 NAT 限制！${PLAIN}"
        else
            echo -e "\n${RED}✗ 配置重载失败，已自动回滚。请检查 Token 是否有效或语法是否合规！${PLAIN}"
        fi
    else
        echo -e "\n${RED}✗ 写入 Cloudflare 配置失败！${PLAIN}"
    fi
    pause
}

# 交互式移除 Cloudflare DNS-01 配置
disable_cf_dns_token() {
    clear
    echo -e "${BLUE}================================================================${PLAIN}"
    echo -e "${GREEN}${BOLD}           移除 Cloudflare DNS-01 验证配置                     ${PLAIN}"
    echo -e "${BLUE}================================================================${PLAIN}"

    if ! has_cf_dns_token; then
        echo -e "${YELLOW}当前配置中未设置 Cloudflare DNS-01 Token，无需移除。${PLAIN}"
        pause
        return 0
    fi

    echo -e "${YELLOW}移除后，Caddy 将切回默认的 HTTP-01 验证模式 (需要直连 80/443 端口且不能被 CDN 拦截)。${PLAIN}"
    read -p "确认移除 Cloudflare DNS-01 验证配置吗? (y/n): " confirm_del
    if [[ "$confirm_del" != "y" && "$confirm_del" != "Y" ]]; then
        return 0
    fi

    create_backup "移除 Cloudflare DNS-01 配置前备份"
    if remove_cf_dns_token "$CADDY_FILE"; then
        ensure_caddyfile_perms "$CADDY_FILE"
        if safe_reload; then
            echo -e "\n${GREEN}✓ 已成功移除 Cloudflare DNS-01 配置，恢复为默认 HTTP-01 验证模式。${PLAIN}"
        else
            echo -e "\n${RED}✗ 配置重载失败，已自动回滚。${PLAIN}"
        fi
    else
        echo -e "\n${RED}✗ 移除配置失败！${PLAIN}"
    fi
    pause
}

# 菜单 6: SSL 证书中心 & DNS-01 自动化管理
ssl_center_menu() {
    while true; do
        clear
        echo -e "${BLUE}================================================================${PLAIN}"
        echo -e "${GREEN}${BOLD}             SSL 证书中心 & ACME DNS-01 自动化管理              ${PLAIN}"
        echo -e "${BLUE}================================================================${PLAIN}"

        local ed_str="${YELLOW}官方标准版 (未集成 DNS-01 插件)${PLAIN}"
        if has_cf_dns_module; then
            ed_str="${GREEN}Cloudflare 增强版 (已集成 DNS-01 插件)${PLAIN}"
        fi
        echo -e "当前 Caddy 版本 : ${ed_str}"

        local tok_str="${YELLOW}未配置 (默认 HTTP-01 验证)${PLAIN}"
        if is_cf_dns_active; then
            local t
            t=$(get_cf_dns_token)
            local mask_t="${t:0:4}****${t: -4}"
            tok_str="${GREEN}已激活 (Cloudflare DNS-01, Token: ${mask_t})${PLAIN}"
        elif has_cf_dns_token; then
            tok_str="${RED}Token 已配置但缺失 Cloudflare 插件${PLAIN}"
        elif has_cf_dns_module; then
            tok_str="${YELLOW}插件已就绪, 待配置 Token${PLAIN}"
        fi
        echo -e "DNS-01 引擎状态 : ${tok_str}"
        echo -e "${BLUE}----------------------------------------------------------------${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} SSL Doctor 证书体检与网络综合诊断 (全链路排错)"
        echo -e "  ${GREEN}2.${PLAIN} 安装 / 升级 Cloudflare 增强版 Caddy (集成 DNS-01 模块)"
        echo -e "  ${GREEN}3.${PLAIN} 配置 / 更新 Cloudflare API Token (开启全自动 DNS-01)"
        echo -e "  ${GREEN}4.${PLAIN} 移除 Cloudflare DNS-01 配置 (切回默认 HTTP-01 验证)"
        echo -e "  ${GREEN}5.${PLAIN} 恢复为官方标准版 Caddy (移除 DNS-01 插件)"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        echo -e "${BLUE}================================================================${PLAIN}"

        read -p "请输入功能编号 [0-5]: " sc_num
        case "$sc_num" in
            1)
                ssl_doctor
                ;;
            2)
                install_caddy_cf
                ;;
            3)
                configure_cf_dns_token
                ;;
            4)
                disable_cf_dns_token
                ;;
            5)
                switch_caddy_standard
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}输入无效，请重新选择！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

# CLI 模式: Cloudflare 状态展示
cli_cf_status() {
    echo -e "${BLUE}================== Cloudflare DNS-01 引擎状态 ==================${PLAIN}"
    if has_cf_dns_module; then
        echo -e "Caddy 插件模块: ${GREEN}已安装 (dns.providers.cloudflare)${PLAIN}"
    else
        echo -e "Caddy 插件模块: ${RED}未安装 (当前为官方标准版)${PLAIN}"
    fi

    if has_cf_dns_token; then
        local t
        t=$(get_cf_dns_token)
        local mask_t="${t:0:4}****${t: -4}"
        echo -e "API Token 配置: ${GREEN}已配置${PLAIN} (${mask_t})"
    else
        echo -e "API Token 配置: ${YELLOW}未配置${PLAIN}"
    fi

    if is_cf_dns_active; then
        echo -e "综合运行状态  : ${GREEN}● DNS-01 引擎已就绪并生效${PLAIN}"
        echo -e "特性说明      : 支持泛域名申请、无视入站端口受限、无视 Cloudflare 小黄云拦截"
    else
        echo -e "综合运行状态  : ${YELLOW}○ 未生效 (使用默认 HTTP-01 / TLS-ALPN-01 模式)${PLAIN}"
    fi
    echo -e "${BLUE}================================================================${PLAIN}"
}

# CLI 模式: 快捷设置 Token
cli_cf_set() {
    local token="$1"
    token=$(echo "$token" | tr -d '[:space:]')
    if [ -z "$token" ]; then
        echo -e "${RED}[错误] 请提供有效的 Cloudflare API Token！用法: cad cf set <TOKEN>${PLAIN}"
        exit 1
    fi
    if ! has_cf_dns_module; then
        echo -e "${RED}[错误] 当前 Caddy 尚未集成 Cloudflare DNS 模块！${PLAIN}"
        echo -e "${YELLOW}请先运行 'cad' 进入菜单 6 安装 Cloudflare 增强版 Caddy。${PLAIN}"
        exit 1
    fi
    create_backup "CLI 设置 Cloudflare Token"
    if apply_cf_dns_token "$CADDY_FILE" "$token"; then
        ensure_caddyfile_perms "$CADDY_FILE"
        if safe_reload; then
            echo -e "${GREEN}✓ Cloudflare API Token 已成功配置，DNS-01 引擎已就绪！${PLAIN}"
            exit 0
        else
            echo -e "${RED}✗ 配置更新后重载失败，已自动回滚。${PLAIN}"
            exit 1
        fi
    else
        echo -e "${RED}✗ 写入配置失败！${PLAIN}"
        exit 1
    fi
}

# CLI 模式: 快捷移除 Token
cli_cf_remove() {
    if ! has_cf_dns_token; then
        echo -e "${YELLOW}当前配置中未发现 Cloudflare DNS-01 Token。${PLAIN}"
        exit 0
    fi
    create_backup "CLI 移除 Cloudflare Token"
    if remove_cf_dns_token "$CADDY_FILE"; then
        ensure_caddyfile_perms "$CADDY_FILE"
        if safe_reload; then
            echo -e "${GREEN}✓ 已移除 Cloudflare DNS-01 配置，切回默认 HTTP-01 验证模式。${PLAIN}"
            exit 0
        else
            echo -e "${RED}✗ 移除后重载失败，已自动回滚。${PLAIN}"
            exit 1
        fi
    else
        echo -e "${RED}✗ 移除配置失败！${PLAIN}"
        exit 1
    fi
}

# 菜单 7: 快照时光机与安全回滚 (Snapshot Time-Machine)
snapshot_time_machine() {
    while true; do
        clear
        echo -e "${BLUE}================================================================${PLAIN}"
        echo -e "${GREEN}${BOLD}            快照时光机与安全回滚 (Snapshot Time-Machine)         ${PLAIN}"
        echo -e "          自动保存增删改历史快照 | 一键 Diff 对比 | 极速回滚      "
        echo -e "${BLUE}================================================================${PLAIN}"
        echo -e "  ${GREEN}1.${PLAIN} 查看历史快照列表并安全回滚"
        echo -e "  ${GREEN}2.${PLAIN} 手动创建当前配置快照"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        echo -e "${BLUE}================================================================${PLAIN}"

        read -p "请输入选项 [0-2]: " sn_opt
        case "$sn_opt" in
            1)
                rollback_snapshot
                pause
                ;;
            2)
                read -p "请输入快照备份说明备注 (例如: 大更新前备份): " user_note
                user_note=$(echo "$user_note" | tr -d '[:space:]')
                [ -z "$user_note" ] && user_note="手动创建配置快照"
                create_backup "$user_note"
                echo -e "\n${GREEN}✓ 配置快照已成功保存至 ${BACKUP_DIR}！(最多保留 $MAX_BACKUPS 个版本)${PLAIN}"
                pause
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}输入无效！${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

rollback_snapshot() {
    local snaps=()
    mapfile -t snaps < <(ls -1t "${BACKUP_DIR}"/Caddyfile_* 2>/dev/null | grep -v '\.note$')

    if [ ${#snaps[@]} -eq 0 ]; then
        echo -e "\n${YELLOW}当前备份库中暂无任何历史快照。${PLAIN}"
        return
    fi

    echo -e "\n${YELLOW}=========================== 历史配置快照列表 ===========================${PLAIN}"
    printf "%-6s | %-20s | %-10s | %-32s\n" "[序号]" "快照生成时间" "大小" "备注说明"
    echo "--------------------------------------------------------------------------------"
    for i in "${!snaps[@]}"; do
        local sf="${snaps[$i]}"
        local fname="${sf##*/}"
        local raw_ts="${fname#Caddyfile_}"
        local fmt_ts="$raw_ts"
        if [[ "$raw_ts" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})(.*)$ ]]; then
            fmt_ts="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}${BASH_REMATCH[7]}"
        fi
        local fsize
        fsize=$(wc -c < "$sf" 2>/dev/null || echo "0")
        local note="自动备份"
        [ -f "${sf}.note" ] && note=$(cat "${sf}.note" 2>/dev/null)
        printf "%-6s | %-20s | %-10s | %-32s\n" "[$((i+1))]" "$fmt_ts" "${fsize}B" "$note"
    done
    echo "--------------------------------------------------------------------------------"

    read -p "请输入要回滚的快照序号 [1-${#snaps[@]}], 输入 0 取消: " rb_idx
    if ! [[ "$rb_idx" =~ ^[0-9]+$ ]] || [ "$rb_idx" -lt 1 ] || [ "$rb_idx" -gt "${#snaps[@]}" ]; then
        return
    fi

    local target_snap="${snaps[$((rb_idx-1))]}"

    echo -e "\n${BLUE}------------------------- 配置差异对比 (Diff) -------------------------${PLAIN}"
    echo -e "${RED}--- 当前运行配置 (将被替换)${PLAIN}"
    echo -e "${GREEN}+++ 目标回滚快照${PLAIN}"
    echo "------------------------------------------------------------------------"
    local diff_output
    diff_output=$(diff -u "$CADDY_FILE" "$target_snap" 2>/dev/null | sed '1,2d')
    if [ -z "$diff_output" ]; then
        echo -e "  ${YELLOW}(当前配置与该快照内容完全一致，无差异)${PLAIN}"
    else
        while IFS= read -r dline; do
            if [[ "$dline" =~ ^\+ ]]; then
                echo -e "${GREEN}${dline}${PLAIN}"
            elif [[ "$dline" =~ ^\- ]]; then
                echo -e "${RED}${dline}${PLAIN}"
            elif [[ "$dline" =~ ^@@ ]]; then
                echo -e "${BLUE}${dline}${PLAIN}"
            else
                echo " ${dline}"
            fi
        done <<< "$diff_output"
    fi
    echo -e "${BLUE}------------------------------------------------------------------------${PLAIN}"

    read -p "确认将当前配置回滚到该快照版本并平滑重载生效吗? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        create_backup "回滚前系统自动备份"
        cp -f "$target_snap" "$CADDY_FILE"
        ensure_caddyfile_perms "$CADDY_FILE"
        if safe_reload; then
            echo -e "\n${GREEN}✓ 已成功回滚至所选快照版本，配置已生效！${PLAIN}"
        else
            echo -e "\n${RED}✗ 回滚加载失败，已触发自动安全防线！${PLAIN}"
        fi
    else
        echo -e "${YELLOW}回滚操作已取消。${PLAIN}"
    fi
}

# 菜单 9: 手动安全编辑 (临时文件 + 语法预检 + 草稿安全保护)
edit_caddyfile() {
    ensure_caddy_installed || return 1
    local target_dir
    target_dir="$(dirname "$CADDY_FILE")"
    local tmp_file
    tmp_file=$(mktemp "${target_dir}/.cad_edit.XXXXXX") || { echo -e "${RED}无法创建临时工作文件！${PLAIN}"; pause; return 1; }
    cp -f "$CADDY_FILE" "$tmp_file"

    local editor="${EDITOR:-${VISUAL:-nano}}"
    command -v "$editor" >/dev/null 2>&1 || editor=vim
    command -v "$editor" >/dev/null 2>&1 || editor=vi

    while true; do
        "$editor" "$tmp_file"
        if caddy validate --config "$tmp_file" >/dev/null 2>&1; then
            create_backup "手动编辑前备份"
            cp -f "$tmp_file" "$CADDY_FILE"
            ensure_caddyfile_perms "$CADDY_FILE"
            if safe_reload; then
                echo -e "${GREEN}✓ 语法验证通过，配置已保存并平滑重载！${PLAIN}"
            else
                local draft="${target_dir}/Caddyfile.draft.$(date +%s)"
                cp -f "$tmp_file" "$draft" 2>/dev/null || true
                echo -e "${YELLOW}提示: 运行时生效失败（已自动回滚），您编辑的草稿已暂存至: $draft${PLAIN}"
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
                    local draft="${target_dir}/Caddyfile.draft.$(date +%s)"
                    cp -f "$tmp_file" "$draft" 2>/dev/null || true
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

# 菜单 10: 查看日志
view_logs() {
    echo -e "\n${YELLOW}====================== Caddy 实时运行与 SSL 证书日志 (最新 40 行) ======================${PLAIN}"
    journalctl -u caddy -n 40 --no-pager
    pause
}

# 菜单 11: 服务运维控制 (重载 / 重启 / 停止 / 启动)
service_control() {
    echo -e "\n${YELLOW}请选择服务运维动作：${PLAIN}"
    echo -e "  1. 平滑重载 (Reload - 语法预检通过后平滑重载)"
    echo -e "  2. 重启服务 (Restart - 语法校验安全拦截后重启)"
    echo -e "  3. 停止服务 (Stop)"
    echo -e "  4. 启动服务 (Start)"
    echo -e "  0. 返回主菜单"
    read -p "请输入选项 [0-4]: " s_opt
    case $s_opt in
        1)
            ensure_caddy_installed || { pause; return 1; }
            echo -e "${BLUE}正在执行配置平滑重载...${PLAIN}"
            safe_reload
            pause
            ;;
        2)
            ensure_caddy_installed || { pause; return 1; }
            ensure_caddyfile_perms "$CADDY_FILE"
            echo -e "${BLUE}正在执行配置语法安全预检以保护存量业务...${PLAIN}"
            if ! caddy validate --config "$CADDY_FILE" >/dev/null 2>&1; then
                echo -e "${RED}✗ 配置文件语法校验未通过！已拦截重启操作以保护在线业务不受中断！${PLAIN}"
                caddy validate --config "$CADDY_FILE"
                echo -e "${YELLOW}建议: 请在主菜单选择 [3] 或 [9] 修正配置后再尝试重启。${PLAIN}"
            else
                echo -e "${GREEN}✓ 语法预检通过，正在重启 Caddy 服务...${PLAIN}"
                if systemctl restart caddy; then
                    echo -e "${GREEN}✓ Caddy 服务重启成功！${PLAIN}"
                else
                    echo -e "\n${RED}✗ Caddy 重启失败！${PLAIN}"
                    echo -e "${YELLOW}--- systemctl status caddy ---${PLAIN}"
                    systemctl status caddy --no-pager 2>/dev/null
                    echo -e "${YELLOW}--- journalctl -u caddy -n 30 ---${PLAIN}"
                    journalctl -u caddy -n 30 --no-pager 2>/dev/null
                    echo -e "${YELLOW}提示: 您可在主菜单选择 [6] 检查端口冲突，或选择 [10] 查看详细日志。${PLAIN}"
                fi
            fi
            pause
            ;;
        3)
            echo -e "${BLUE}正在停止 Caddy 服务...${PLAIN}"
            if systemctl stop caddy; then
                echo -e "${YELLOW}✓ Caddy 服务已成功停止！${PLAIN}"
            else
                echo -e "\n${RED}✗ Caddy 停止失败！${PLAIN}"
                echo -e "${YELLOW}--- systemctl status caddy ---${PLAIN}"
                systemctl status caddy --no-pager 2>/dev/null
                echo -e "${YELLOW}--- journalctl -u caddy -n 30 ---${PLAIN}"
                journalctl -u caddy -n 30 --no-pager 2>/dev/null
            fi
            pause
            ;;
        4)
            ensure_caddy_installed || { pause; return 1; }
            ensure_caddyfile_perms "$CADDY_FILE"
            echo -e "${BLUE}正在启动 Caddy 服务...${PLAIN}"
            if systemctl start caddy; then
                echo -e "${GREEN}✓ Caddy 服务启动成功！${PLAIN}"
            else
                echo -e "\n${RED}✗ Caddy 启动失败！${PLAIN}"
                echo -e "${YELLOW}--- systemctl status caddy ---${PLAIN}"
                systemctl status caddy --no-pager 2>/dev/null
                echo -e "${YELLOW}--- journalctl -u caddy -n 30 ---${PLAIN}"
                journalctl -u caddy -n 30 --no-pager 2>/dev/null
                echo -e "${YELLOW}提示: 您可在主菜单选择 [6] 检查 80/443 端口冲突，或选择 [8] 检查配置语法。${PLAIN}"
            fi
            pause
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}无效操作选项。${PLAIN}"
            pause
            ;;
    esac
}

# 菜单 12: Caddy 一键安装模块
# 一键安装 / 更新官方标准版 Caddy
install_caddy_standard() {
    clear
    echo -e "${BLUE}====================================================${PLAIN}"
    echo -e "${GREEN}          一键安装 / 升级官方标准版 Caddy            ${PLAIN}"
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
        init_env
        ensure_caddyfile_perms "$CADDY_FILE"
        systemctl enable caddy > /dev/null 2>&1
        systemctl restart caddy > /dev/null 2>&1
        echo -e "\n${GREEN}✓ Caddy 安装成功并已设置开机自启！版本: $(caddy version | awk '{print $1}')${PLAIN}"
    else
        echo -e "\n${RED}✗ Caddy 安装失败，请检查网络或软件源！${PLAIN}"
    fi
    pause
}

# 菜单 12: 一键安装 / 更新 Caddy 环境 (支持标准版与 Cloudflare 增强版)
install_caddy() {
    clear
    echo -e "${BLUE}====================================================${PLAIN}"
    echo -e "${GREEN}             一键安装 / 升级 Caddy 环境              ${PLAIN}"
    echo -e "${BLUE}====================================================${PLAIN}"
    echo -e "请选择要安装或更新的 Caddy 版本："
    echo -e "  1. 官方标准版 Caddy (基于系统软件包管理器，纯净稳定)"
    echo -e "  2. Cloudflare 增强版 Caddy (集成 DNS-01 模块，支持泛域名/小黄云穿透)"
    echo -e "  0. 返回主菜单"
    read -p "请输入选项 [0-2] (回车默认 2): " inst_opt
    inst_opt="${inst_opt:-2}"
    case "$inst_opt" in
        1)
            install_caddy_standard
            ;;
        2)
            install_caddy_cf
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项！${PLAIN}"
            pause
            ;;
    esac
}

# CLI 模式: 状态输出
cli_status() {
    echo -e "${BLUE}======================== Caddy 运行状态报告 ========================${PLAIN}"
    if command -v caddy > /dev/null 2>&1; then
        local caddy_ver
        caddy_ver=$(caddy version 2>/dev/null | awk '{print $1}')
        local caddy_edition="官方标准版"
        if has_cf_dns_module; then
            caddy_edition="Cloudflare 增强版"
        fi
        echo -e "Caddy 主程序  : ${GREEN}已安装${PLAIN} (版本: ${caddy_ver}, 发行: ${GREEN}${caddy_edition}${PLAIN})"
    else
        echo -e "Caddy 主程序  : ${RED}未安装${PLAIN}"
    fi

    if systemctl is-active --quiet caddy 2>/dev/null; then
        echo -e "Systemd 服务  : ${GREEN}● 正在运行 (Active)${PLAIN}"
    else
        echo -e "Systemd 服务  : ${RED}● 已停止 (Inactive)${PLAIN}"
    fi

    local acme_status="${YELLOW}默认 HTTP-01 / TLS-ALPN-01 模式${PLAIN}"
    if is_cf_dns_active; then
        local t
        t=$(get_cf_dns_token)
        local mask_t="${t:0:4}****${t: -4}"
        acme_status="${GREEN}● Cloudflare DNS-01 自动化引擎 (Token: ${mask_t})${PLAIN}"
    elif has_cf_dns_token; then
        acme_status="${RED}Token 已配置但缺失 Cloudflare 插件模块${PLAIN}"
    elif has_cf_dns_module; then
        acme_status="${YELLOW}Cloudflare 插件已安装 (待配置 Token)${PLAIN}"
    fi
    echo -e "ACME 证书引擎 : ${acme_status}"

    load_rules
    local act_cnt=0
    local dis_cnt=0
    for ((i = 1; i <= RULE_TOTAL; i++)); do
        if [ "${RULE_STATUS[i]}" == "active" ]; then
            act_cnt=$((act_cnt + 1))
        else
            dis_cnt=$((dis_cnt + 1))
        fi
    done
    echo -e "反代规则统计  : 共 ${BOLD}${RULE_TOTAL}${PLAIN} 条 (启用: ${GREEN}${act_cnt}${PLAIN}, 停用: ${YELLOW}${dis_cnt}${PLAIN})"

    if command -v ss > /dev/null 2>&1; then
        local p80
        p80=$(ss -tln '( sport = :80 )' 2>/dev/null | grep -c LISTEN || echo 0)
        local p443
        p443=$(ss -tln '( sport = :443 )' 2>/dev/null | grep -c LISTEN || echo 0)
        local str_p80="${RED}未监听${PLAIN}"
        [ "$p80" -gt 0 ] 2>/dev/null && str_p80="${GREEN}监听中${PLAIN}"
        local str_p443="${RED}未监听${PLAIN}"
        [ "$p443" -gt 0 ] 2>/dev/null && str_p443="${GREEN}监听中${PLAIN}"
        echo -e "Web 核心端口  : 80端口 (${str_p80}), 443端口 (${str_p443})"
    fi
    echo -e "${BLUE}====================================================================${PLAIN}"
}

# CLI 模式: 帮助说明
show_help() {
    echo -e "${BLUE}caddy-pro (快捷指令: cad) - 极简高可靠 Caddy 反向代理交互式管理系统${PLAIN}"
    echo -e "版本: v${VERSION}\n"
    echo -e "命令行用法:"
    echo -e "  cad                  启动交互式 TUI 管理控制台"
    echo -e "  cad list             列出所有反向代理规则 (包括启用与停用状态)"
    echo -e "  cad status           查看 Caddy 服务运行状态与规则统计"
    echo -e "  cad reload           预检并平滑重载 Caddyfile 配置"
    echo -e "  cad doctor [domain]  执行 SSL 证书与网络诊断 (双栈/DNS/CF/端口冲突)"
    echo -e "  cad backup [note]    创建当前配置的时间戳快照备份"
    echo -e "  cad cf status        查看 Cloudflare DNS-01 模块与 Token 状态"
    echo -e "  cad cf set <token>   配置 Cloudflare API Token 并开启 DNS-01"
    echo -e "  cad cf remove        移除 Cloudflare DNS-01 配置 (切回 HTTP-01)"
    echo -e "  cad -v, --version    查看版本信息"
    echo -e "  cad -h, --help       查看帮助信息"
}

# 主菜单循环
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
        echo -e "  ${GREEN}2.${PLAIN} 添加反代规则 (智能探测/支持HTTPS后端)"
        echo -e "  ${GREEN}3.${PLAIN} 交互式修改反代规则 (免开Nano/原位修改)"
        echo -e "  ${GREEN}4.${PLAIN} 启用 / 停用反代规则 (无损状态切换)"
        echo -e "  ${GREEN}5.${PLAIN} 删除已有反代规则"
        echo -e "  ${GREEN}6.${PLAIN} SSL 证书中心 & DNS-01 自动化 (SSL Doctor/Cloudflare)"
        echo -e "  ${GREEN}7.${PLAIN} 快照时光机与安全回滚 (保留15个版本/Diff对比)"
        echo -e "  ${GREEN}8.${PLAIN} 检查配置并平滑重载 Caddy (免重启生效)"
        echo -e "  ${GREEN}9.${PLAIN} 手动编辑 Caddyfile 配置文件 (安全预检+草稿保护)"
        echo -e " ${GREEN}10.${PLAIN} 查看 Caddy 运行状态与证书日志"
        echo -e " ${GREEN}11.${PLAIN} 服务运维控制 (重载 / 重启 / 停止 / 启动)"
        echo -e " ${GREEN}12.${PLAIN} 一键安装 / 更新 Caddy 环境"
        echo -e "  ${GREEN}0.${PLAIN} 退出管理系统"
        echo -e "${BLUE}================================================================${PLAIN}"

        load_rules
        local active_rules=0
        local disabled_rules=0
        for ((idx_c = 1; idx_c <= RULE_TOTAL; idx_c++)); do
            if [ "${RULE_STATUS[idx_c]}" == "active" ]; then
                active_rules=$((active_rules + 1))
            else
                disabled_rules=$((disabled_rules + 1))
            fi
        done

        local svc_status="${RED}● 已停止 (Inactive)${PLAIN}"
        if systemctl is-active --quiet caddy 2>/dev/null; then
            svc_status="${GREEN}● 正在运行 (Active)${PLAIN}"
        fi
        local acme_summary="${YELLOW}HTTP-01 (默认)${PLAIN}"
        if is_cf_dns_active; then
            acme_summary="${GREEN}Cloudflare DNS-01 (已启用)${PLAIN}"
        elif has_cf_dns_token; then
            acme_summary="${RED}Token已配置缺插件${PLAIN}"
        elif has_cf_dns_module; then
            acme_summary="${YELLOW}插件就绪待配Token${PLAIN}"
        fi
        echo -e "服务状态: ${svc_status} | 规则统计: ${GREEN}${active_rules} 启用${PLAIN}, ${YELLOW}${disabled_rules} 停用${PLAIN} | ACME: ${acme_summary}"
        echo -e "${BLUE}----------------------------------------------------------------${PLAIN}"

        read -p "请输入功能编号 [0-12]: " num
        case $num in
            1)
                list_rules
                pause
                ;;
            2)
                add_rule
                ;;
            3)
                edit_rule_inplace
                ;;
            4)
                toggle_rule
                ;;
            5)
                del_rule
                ;;
            6)
                ssl_center_menu
                ;;
            7)
                snapshot_time_machine
                ;;
            8)
                ensure_caddy_installed && safe_reload
                pause
                ;;
            9)
                edit_caddyfile
                ;;
            10)
                view_logs
                ;;
            11)
                service_control
                ;;
            12)
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

# 启动与双模 CLI 调度
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        list|ls)
            check_root
            init_env
            list_rules
            exit 0
            ;;
        status)
            check_root
            init_env
            cli_status
            exit 0
            ;;
        reload)
            check_root
            init_env
            ensure_caddy_installed || exit 1
            safe_reload
            exit $?
            ;;
        doctor)
            check_root
            init_env
            run_ssl_doctor "$2"
            exit 0
            ;;
        backup)
            check_root
            init_env
            create_backup "${2:-CLI手动创建快照}"
            echo -e "${GREEN}✓ 配置快照已成功创建并保存至: ${BACKUP_DIR}${PLAIN}"
            exit 0
            ;;
        cf)
            check_root
            init_env
            case "$2" in
                set)
                    cli_cf_set "$3"
                    ;;
                remove|rm|del)
                    cli_cf_remove
                    ;;
                status|"")
                    cli_cf_status
                    ;;
                *)
                    echo -e "${RED}[错误] 未知的 cf 子命令: $2${PLAIN}"
                    echo -e "用法: cad cf [status | set <token> | remove]"
                    exit 1
                    ;;
            esac
            exit 0
            ;;
        help|--help|-h)
            show_help
            exit 0
            ;;
        version|--version|-v)
            echo "caddy-pro v${VERSION}"
            exit 0
            ;;
        "")
            main_menu "$@"
            ;;
        *)
            echo -e "${RED}[错误] 未知命令参数: $1${PLAIN}\n"
            show_help
            exit 1
            ;;
    esac
fi
