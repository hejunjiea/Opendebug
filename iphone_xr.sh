#!/bin/bash

# =============================================================================
# 🟢 1. 基础配置区
# =============================================================================
BUILD_MODE=2                # 2 = roothide
DEBUG=1
FINALPACKAGE=0
SSH_PASSWORD="${ODBG_SSH_PASSWORD:-alpine}"   # 💡 手机 SSH / Root 密码（默认 alpine，可用 ODBG_SSH_PASSWORD 覆盖）

# 设备配置（本仓库不保存任何设备 UDID；用 `idevice_id -l` 查自己的设备后传进来）
UDID_A="${ODBG_UDID_A:-}"
PORT_A="2222"

if [ -z "$UDID_A" ]; then
    echo "❌ 未设置设备 UDID。用法: export ODBG_UDID_A=\$(idevice_id -l | head -1) && ./iphone_xr.sh"
    exit 1
fi

# 环境初始化
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export THEOS=/opt/theos
export PATH=$THEOS/bin:$PATH
cd "$(dirname "$0")"

# =============================================================================
# ⚡️ 2. USB 隧道启动
# =============================================================================
echo "🔍 [USB 隧道] 正在为手机建立隧道 (Port: $PORT_A)..."
lsof -ti:"$PORT_A" | xargs kill -9 >/dev/null 2>&1
iproxy "$PORT_A":22 -u "$UDID_A" >/dev/null 2>&1 &
sleep 1.5

# =============================================================================
# 🛠 3. 核心编译与 Expect 自动填密安装引擎
# =============================================================================
run_make() {
    local scheme=$1      
    echo "📦 [开始构建] 架构: $scheme"
    
    gmake clean > /dev/null 2>&1
    
    # 编译生成 deb
    if ! gmake package THEOS_PACKAGE_SCHEME=$scheme FINALPACKAGE=$FINALPACKAGE DEBUG=$DEBUG; then
        echo "❌ [编译失败]"
        return 1
    fi

    # 动态精准获取最新生成的 deb 文件路径
    local DEB_FILE=$(ls -t packages/*.deb | head -1)
    if [ -z "$DEB_FILE" ]; then
        echo "❌ [错误] 未找到编译好的 deb 文件。"
        return 1
    fi

    echo "📤 [传输中] 正在推送: $(basename "$DEB_FILE") ..."
    
    # 💡 1. 自动应答 SCP 传输密码
    /usr/bin/expect <<EOF
        set timeout 30
        spawn scp -P "$PORT_A" -o StrictHostKeyChecking=no "$DEB_FILE" mobile@127.0.0.1:/tmp/install.deb
        expect {
            -re ".*assword.*" {
                send "$SSH_PASSWORD\r"
                exp_continue
            }
            eof
        }
EOF

    echo "⚡ [安装中] 正在执行远程提权安装、注销与重启..."
    
    # 💡 2. 使用 echo + sudo -S 配合 expect 自动应答 SSH 登录密码
    # 注意这里把整段安装+注销命令用双引号/单引号包裹，并加上了 -S 参数
    /usr/bin/expect <<EOF
        set timeout 30
        spawn ssh -p "$PORT_A" -o StrictHostKeyChecking=no mobile@127.0.0.1 "echo '$SSH_PASSWORD' | sudo -S dpkg -i /tmp/install.deb && uicache -p / && killall -9 SpringBoard"
        expect {
            -re ".*assword.*" {
                send "$SSH_PASSWORD\r"
                exp_continue
            }
            eof
        }
EOF

    echo "✅ [任务成功] 插件已自动安装并触发桌面重启！"
}

# =============================================================================
# 🚀 4. 执行流程
# =============================================================================
case $BUILD_MODE in
    1) run_make "rootless" ;; 
    2) run_make "roothide" ;; 
esac

echo "==========================================================="
echo "🎉 任务结束"
echo "==========================================================="