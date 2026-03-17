#!/usr/bin/env bash
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

error_exit() {
    echo -e "${RED}错误: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}$1${NC}"
}

warn() {
    echo -e "${YELLOW}$1${NC}"
}

# 检查 root 权限（安装服务需要）
if [[ $EUID -ne 0 ]]; then
   error_exit "此脚本需要 root 权限来安装系统服务，请使用 sudo 运行。"
fi

# 卸载功能
if [[ "$1" == "uninstall" ]]; then
    SERVICE_NAME="openlist-proxy"
    # 停止并禁用服务
    if [[ -f /etc/systemd/system/${SERVICE_NAME}.service ]]; then
        systemctl stop "$SERVICE_NAME"
        systemctl disable "$SERVICE_NAME"
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        info "已删除 systemd 服务"
    elif [[ -f /etc/init.d/${SERVICE_NAME} ]]; then
        rc-service "$SERVICE_NAME" stop
        rc-update del "$SERVICE_NAME"
        rm -f "/etc/init.d/${SERVICE_NAME}"
        info "已删除 OpenRC 服务"
    fi

    # 删除工作目录（假设脚本在 ~/ 下执行，工作目录为 ~/op）
    WORKDIR="./op"
    if [[ -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
        info "已删除工作目录: $WORKDIR"
    else
        warn "工作目录不存在: $WORKDIR"
    fi
    info "卸载完成"
    exit 0
fi

# 创建工作目录并进入
WORKDIR="./op"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
WORKDIR_ABS=$(pwd -P)
info "工作目录: $WORKDIR_ABS"

# 检测系统架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    *) error_exit "不支持的架构: $ARCH (仅支持 amd64)" ;;
esac
info "系统架构: $ARCH"

# 检测发行版
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID=$ID
    if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
        INIT_SYSTEM="systemd"
    elif [[ "$OS_ID" == "alpine" ]]; then
        INIT_SYSTEM="openrc"
    else
        error_exit "不支持的发行版: $OS_ID (仅支持 Ubuntu/Debian/Alpine)"
    fi
else
    error_exit "无法检测系统发行版"
fi
info "初始化系统: $INIT_SYSTEM"

# 下载链接
DOWNLOAD_URL="https://raw.githubusercontent.com/DavidMartineg/OpenList-Proxy-Installer/main/openlist-proxy_Linux_${ARCH}.tar.gz"
info "下载地址: $DOWNLOAD_URL"

# 下载并解压
TMP_FILE=$(mktemp)
warn "正在下载..."
curl -L -o "$TMP_FILE" "$DOWNLOAD_URL" || error_exit "下载失败"
warn "正在解压..."
tar -xzf "$TMP_FILE" || error_exit "解压失败"
rm -f "$TMP_FILE"
info "解压完成，已删除压缩包"

# 确定二进制文件
BIN_NAME="openlist-proxy"
if [[ ! -f "./$BIN_NAME" ]]; then
    # 尝试查找第一个可执行文件
    FOUND_BIN=$(find . -maxdepth 1 -type f -executable | head -1)
    if [[ -n "$FOUND_BIN" ]]; then
        BIN_NAME=$(basename "$FOUND_BIN")
        info "检测到二进制文件: $BIN_NAME"
    else
        error_exit "未找到可执行二进制文件"
    fi
else
    chmod +x "./$BIN_NAME"
fi
BIN_ABS="$WORKDIR_ABS/$BIN_NAME"

# ========== 交互式参数收集 ==========
echo -e "\n${YELLOW}请按照提示配置启动参数:${NC}"

# 1. address
read -p "请输入 -address (完整的 URL，例如 https://example.com): " ADDRESS
while [[ -z "$ADDRESS" ]]; do
    warn "地址不能为空"
    read -p "请输入 -address: " ADDRESS
done

# 2. HTTPS 选择
HTTPS_ENABLED="false"
CERT_FILE=""
KEY_FILE=""
read -p "是否启用 HTTPS? (Y/N，回车默认 N): " -n 1 -r HTTPS_CHOICE
echo
if [[ "$HTTPS_CHOICE" == "Y" || "$HTTPS_CHOICE" == "y" ]]; then
    # 检查 ~/server.crt 和 ~/server.key
    USER_HOME=$(eval echo ~$SUDO_USER)
    CERT_CANDIDATE="$USER_HOME/server.crt"
    KEY_CANDIDATE="$USER_HOME/server.key"
    if [[ -f "$CERT_CANDIDATE" && -f "$KEY_CANDIDATE" ]]; then
        HTTPS_ENABLED="true"
        CERT_FILE="$CERT_CANDIDATE"
        KEY_FILE="$KEY_CANDIDATE"
        info "找到证书: $CERT_FILE"
        info "找到密钥: $KEY_FILE"
    else
        warn "未找到 ~/server.crt 或 ~/server.key，将降级为 HTTP 模式"
        HTTPS_ENABLED="false"
    fi
fi

# 3. 端口
read -p "请输入运行端口 (默认 5243，直接回车使用默认值): " PORT_INPUT
if [[ -z "$PORT_INPUT" || "$PORT_INPUT" == "5243" ]]; then
    PORT=""
    info "使用默认端口 5243 (不添加 -port 参数)"
else
    PORT="$PORT_INPUT"
    info "使用端口: $PORT"
fi

# 4. token
read -p "请输入 -token: " TOKEN
while [[ -z "$TOKEN" ]]; do
    warn "token 不能为空"
    read -p "请输入 -token: " TOKEN
done

# ========== 构建命令 ==========
CMD="$BIN_ABS"
CMD+=" -address \"$ADDRESS\""

if [[ "$HTTPS_ENABLED" == "true" ]]; then
    CMD+=" -cert \"$CERT_FILE\""
    CMD+=" -https true"
    CMD+=" -key \"$KEY_FILE\""
fi

if [[ -n "$PORT" ]]; then
    CMD+=" -port $PORT"
fi

CMD+=" -token \"$TOKEN\""

# ========== 确认命令 ==========
echo -e "\n${YELLOW}生成的启动命令如下:${NC}"
echo "$CMD"

read -p "请确认命令是否正确? (Y/N，回车默认 Y): " -n 1 -r CONFIRM
echo
if [[ "$CONFIRM" == "N" || "$CONFIRM" == "n" ]]; then
    warn "您选择了手动处理。"
    warn "您可以使用以下命令手动启动（或在服务文件中配置）："
    echo "$CMD"
    warn "脚本将退出，不会安装服务。"
    exit 0
fi

# ========== 安装为系统服务 ==========
SERVICE_NAME="openlist-proxy"

if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    info "创建 systemd 服务: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=OpenList Proxy Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORKDIR_ABS
ExecStart=$CMD
Restart=always
User=$SUDO_USER
Group=$SUDO_USER

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    info "服务已启动，状态如下:"
    systemctl status "$SERVICE_NAME" --no-pager

elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
    SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
    info "创建 OpenRC 服务: $SERVICE_FILE"
    cat > "$SERVICE_FILE" <<EOF
#!/sbin/openrc-run

name="OpenList Proxy"
description="OpenList Proxy Service"
command="$BIN_ABS"
command_args="-address \"$ADDRESS\""
command_user="$SUDO_USER"
pidfile="/run/${SERVICE_NAME}.pid"
command_background=true

depend() {
    need net
}

start_pre() {
    # 根据 HTTPS 情况添加额外参数
    if [[ "$HTTPS_ENABLED" == "true" ]]; then
        command_args="\$command_args -cert \"$CERT_FILE\" -https true -key \"$KEY_FILE\""
    fi
    if [[ -n "$PORT" ]]; then
        command_args="\$command_args -port $PORT"
    fi
    command_args="\$command_args -token \"$TOKEN\""
    return 0
}
EOF
    chmod +x "$SERVICE_FILE"
    rc-update add "$SERVICE_NAME" default
    rc-service "$SERVICE_NAME" start
    info "服务已启动，状态如下:"
    rc-service "$SERVICE_NAME" status
fi

info "安装完成！"
info "如需卸载，请使用: $0 uninstall"
