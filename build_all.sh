#!/bin/bash

# =============================================================================
# ODebug 一键编译脚本（本项目只有 roothide 一种包，不需要选架构）
# 用法：
#   ./build_all.sh                    # 只编译打包（默认，不碰手机、不 respring）
#   INSTALL=1 ./build_all.sh          # 编译 + 推送到手机安装（不 respring）
#   INSTALL=1 RESPRING=1 ./build_all.sh   # 编译 + 安装 + 重启 SpringBoard 让插件生效
# =============================================================================

# 💡【傻瓜注释】改这几行就能控制脚本行为
DEBUG=${DEBUG:-1}                 # 1 = 调试包（带日志，包名带 +debug），0 = 正式包
FINALPACKAGE=${FINALPACKAGE:-0}   # 1 = 发布压缩包（慢），0 = 开发包（编译快）
INSTALL=${INSTALL:-0}             # 1 = 编译完自动装到手机，0 = 只产出 deb
RESPRING=${RESPRING:-0}           # 1 = 安装后 killall SpringBoard（默认关）
BUMP_VERSION=${BUMP_VERSION:-0}   # 1 = 编译时自动递增版本，0 = 保持手写版本
CLEAN=${CLEAN:-1}                 # 1 = 先全量编译，0 = 增量编译（快）
PORT="${ODBG_SSH_PORT:-2222}"  # USB 转发端口（可用 ODBG_SSH_PORT 覆盖）
SSH_PASSWORD="${ODBG_SSH_PASSWORD:-alpine}"   # 手机 SSH/sudo 密码，可用环境变量覆盖
UDID="${ODBG_UDID:-}"                         # 手机 UDID，不填则自动取第一台已连接设备

# 💡【防假成功】管道里任何一步报错都必须让脚本返回失败
set -o pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# 💡 本机 Theos 固定在 /opt/theos；如果环境变量已设置则以环境变量为准
[ -z "$THEOS" ] && export THEOS=/opt/theos
export PATH="$THEOS/bin:$PATH"
# 💡 Mac 上用 gmake（系统自带的 make 是 BSD 版，Theos 不认）
MAKE=$(command -v gmake || command -v make)

cd "$(dirname "$0")" || exit 1

# -----------------------------------------------------------------------------
# 1. 环境自检（缺东西立刻说清楚，不要编译到一半才报错）
# -----------------------------------------------------------------------------
if [ ! -f "$THEOS/makefiles/common.mk" ]; then
    echo "❌ 找不到 Theos：$THEOS/makefiles/common.mk（可用 export THEOS=/你的/theos 指定）"
    exit 1
fi
if [ -z "$MAKE" ]; then
    echo "❌ 找不到 gmake/make，请先安装：brew install make"
    exit 1
fi
if [ ! -f "control" ]; then
    echo "❌ 当前目录不是项目根目录（找不到 control）"
    exit 1
fi

# -----------------------------------------------------------------------------
# 2. 版本号处理（默认不动 control，避免误改）
# -----------------------------------------------------------------------------
OLD_VERSION=$(grep "^Version:" control | cut -d' ' -f2)
if [ "$BUMP_VERSION" -eq 1 ]; then
    perl -i -pe 's/^(Version:\s+\d+\.\d+\.)(\d+)/$1 . ($2+1)/e' control
fi
VERSION=$(grep "^Version:" control | cut -d' ' -f2)
CPUS=$(sysctl -n hw.ncpu)

echo "==========================================================="
echo "📦 ODebug 构建开始"
echo "   🔹 版本: v$OLD_VERSION → v$VERSION"
echo "   🔹 模式: DEBUG=$DEBUG FINALPACKAGE=$FINALPACKAGE CLEAN=$CLEAN"
echo "   🔹 安装: $([ "$INSTALL" -eq 1 ] && echo "编译后推送手机" || echo "仅产出 deb")"
echo "==========================================================="

# -----------------------------------------------------------------------------
# 3. 编译 + 打包
# -----------------------------------------------------------------------------
[ "$CLEAN" -eq 1 ] && $MAKE clean >/dev/null 2>&1

# Finder metadata has leaked through stale bundle staging before. Remove it from
# source and build trees before invoking Theos, then verify the final deb below.
find . -path ./.git -prune -o -name .DS_Store -type f -delete 2>/dev/null || true

if ! $MAKE package \
        THEOS_PACKAGE_SCHEME=roothide \
        FINALPACKAGE="$FINALPACKAGE" \
        DEBUG="$DEBUG" \
        -j"$CPUS"; then
    echo "❌ 编译失败，请看上面第一条 error"
    exit 1
fi

DEB_FILE=$(ls -t packages/*.deb 2>/dev/null | head -1)
if [ -z "$DEB_FILE" ]; then
    echo "❌ 编译命令返回成功，但 packages/ 下没有 deb 产物"
    exit 1
fi
DEB_ABS="$(pwd)/$DEB_FILE"
if dpkg-deb -c "$DEB_FILE" | awk '/\.DS_Store/{found=1} END{exit found ? 0 : 1}'; then
    echo "⚠️  首次打包包含 .DS_Store，直接在已完成的 staging 上重建干净包"
    find .theos/_ .theos/fakeroot -name .DS_Store -type f -delete 2>/dev/null || true
    CLEAN_DEB="${DEB_FILE%.deb}-clean-$$.deb"
    COPYFILE_DISABLE=1 "$THEOS/bin/fakeroot.sh" \
        -p "$(pwd)/.theos/fakeroot" \
        -r dm.pl -Zlzma -z1 \
        -b "$(pwd)/.theos/_" "$(pwd)/$CLEAN_DEB"
    DEB_FILE="$CLEAN_DEB"
    DEB_ABS="$(pwd)/$DEB_FILE"
    if dpkg-deb -c "$DEB_FILE" | awk '/\.DS_Store/{found=1} END{exit found ? 0 : 1}'; then
        echo "❌ 干净重建后仍包含 .DS_Store，拒绝继续安装"
        exit 1
    fi
fi
echo "✅ 打包完成: $DEB_ABS"

# -----------------------------------------------------------------------------
# 4. 可选：推送到手机安装（默认不执行）
# -----------------------------------------------------------------------------
if [ "$INSTALL" -ne 1 ]; then
    echo "ℹ️  未开启安装。要装到手机：INSTALL=1 ./build_all.sh（加 RESPRING=1 才会重启桌面）"
    exit 0
fi

# 💡 自动找设备：不填 ODBG_UDID 就取第一台 USB 连接的设备
if [ -z "$UDID" ] && command -v idevice_id >/dev/null 2>&1; then
    UDID=$(idevice_id -l 2>/dev/null | head -1)
fi
if [ -z "$UDID" ]; then
    echo "❌ 没检测到已连接设备：请插线，或先 export ODBG_UDID=\$(idevice_id -l | head -1)"
    exit 1
fi
if ! command -v iproxy >/dev/null 2>&1; then
    echo "❌ 找不到 iproxy（brew install libimobiledevice）"
    exit 1
fi
if ! command -v expect >/dev/null 2>&1; then
    echo "❌ 找不到 expect（brew install expect），无法自动填 SSH 密码"
    exit 1
fi

# 💡 隧道已通就复用；不通才新建，避免端口被僵尸 iproxy 占住
IPROXY_PID=""
if ! nc -z -G 1 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    lsof -ti:"$PORT" 2>/dev/null | xargs kill -9 >/dev/null 2>&1
    iproxy "$PORT":22 -u "$UDID" >/dev/null 2>&1 &
    IPROXY_PID=$!
    sleep 1.5
fi

cleanup() {
    if [ -n "$IPROXY_PID" ] && kill -0 "$IPROXY_PID" 2>/dev/null; then
        kill "$IPROXY_PID" >/dev/null 2>&1
    fi
}
trap cleanup EXIT

echo "📤 推送: $(basename "$DEB_FILE") → 手机 /tmp/install.deb"
if ! /usr/bin/expect <<EOF
    set timeout 60
    spawn scp -P "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$DEB_FILE" mobile@127.0.0.1:/tmp/install.deb
    expect {
        -re ".*assword.*" { send "$SSH_PASSWORD\r"; exp_continue }
        eof
    }
    catch wait result
    exit [lindex \$result 3]
EOF
then
    echo "❌ 推送安装包失败，未执行 dpkg，也未声称安装成功"
    exit 1
fi

# 💡 RESPRING=1 才 killall SpringBoard；默认只装包，桌面由用户自己决定什么时候重启
RESPRING_CMD=""
[ "$RESPRING" -eq 1 ] && RESPRING_CMD=" && killall -9 SpringBoard"

echo "⚡ 安装中..."
if ! /usr/bin/expect <<EOF
    set timeout 300
    spawn ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null mobile@127.0.0.1 "echo '$SSH_PASSWORD' | sudo -S dpkg -i /tmp/install.deb$RESPRING_CMD"
    expect {
        -re ".*assword.*" { send "$SSH_PASSWORD\r"; exp_continue }
        eof
    }
    catch wait result
    exit [lindex \$result 3]
EOF
then
    echo "❌ dpkg 安装失败"
    exit 1
fi

echo "==========================================================="
echo "✅ 安装完成: v$VERSION"
if [ "$RESPRING" -eq 1 ]; then
    echo "♻️  已按 RESPRING=1 重启 SpringBoard"
else
    echo "ℹ️  tweak 生效需 respring：确认设备状态后手动执行，或下次加 RESPRING=1"
fi
echo "==========================================================="
