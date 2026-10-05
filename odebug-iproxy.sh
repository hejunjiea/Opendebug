#!/bin/bash
# 转发设备 4321 端口到电脑 127.0.0.1:4321（需手机 USB 插着 + 已装 idevice 工具）
# 用途：在电脑上连接 ODebug越狱插件 调试控制台
# 用法: ./iproxy.sh
PORT=4321

# 启动前检测端口是否已被占用（避免 Address already in use）
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "⚠️  端口 $PORT 已被占用（可能已有 iproxy/nc 在运行）："
    lsof -nP -iTCP:$PORT -sTCP:LISTEN
    echo ""
    echo "  如果转发已在工作，直接用 nc 127.0.0.1 $PORT 连接即可。"
    echo "  如需重启转发：先杀掉占用进程，再运行本脚本。"
    echo "     lsof -ti :$PORT | xargs kill"
    exit 1
fi

echo "转发设备 $PORT → 电脑 127.0.0.1:$PORT (Ctrl-C 退出)..."
iproxy $PORT $PORT
