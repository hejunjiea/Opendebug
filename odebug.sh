#!/bin/bash
# macOS 默认 bash 3.2 没编译 readline（read -e 无效、方向键历史不工作、ANSI 处理异常），
# 若装了 Homebrew bash(5+) 则自动用它重跑自己（需 brew install bash）。
if [ -z "$ODEBUG_BASH5" ]; then
    for _b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [ -x "$_b" ]; then
            export ODEBUG_BASH5=1
            exec "$_b" "$0" "$@"
        fi
    done
fi
# 用 rlwrap 包裹自己：稳定 readline（方向键历史、粘贴正常），需 brew install rlwrap。
# read -e 在脚本里粘贴会重复字符，rlwrap 在进程层处理 readline 更可靠。
if [ -z "$ODEBUG_RLWRAP" ] && command -v rlwrap >/dev/null 2>&1; then
    export ODEBUG_RLWRAP=1
    exec rlwrap bash "$0" "$@"
fi

# 有些终端/启动器会把子进程的 stderr 直接丢给 /dev/null（实测：bash 的 fd2 -> /dev/null），
# 而 bash 的 `read -p` 提示符是写 stderr 的 ⇒ 会出现「没有任何提示、看着像卡住」。
# 所以：① 提示符一律用 printf 打到 stdout（见下方各处），② 把 stderr 并到 stdout，报错也看得见。
exec 2>&1

# ODebug 调试控制台傻瓜式脚本
# 在设备上运行（roothide），自动读取调试令牌，交互式菜单 + 数字快捷键
# 用法: ./odebug.sh
#
# 原理：用 bash /dev/tcp 连设备回环 127.0.0.1:4321（控制台只绑本机回环）。
# 每条命令开一次连接发送，read -t 超时检测响应结束（控制台交互式不自动断连）。

PLIST=/var/mobile/Library/Preferences/com.tanyou.opendebug.settings.plist
TOKEN_FILE="$HOME/.odebug_token"
# 端口/主机可覆盖：默认 4321=插件内控制台；ODEBUG_PORT=4322 连 odebugd 守护进程(!net/!fd/!safe/!auto…)；
# WLAN 直连（1.0.142+，免数据线）：ODEBUG_HOST=192.168.0.107 ./odebug.sh（此时不起 iproxy）
HOST=${ODEBUG_HOST:-127.0.0.1}
PORT=${ODEBUG_PORT:-4321}

# ── 傻瓜式端口选择（1.0.144）：直接运行脚本时弹菜单选 4321/4322；设了 ODEBUG_PORT/ODEBUG_HOST 则跳过 ──
if [ -z "$ODEBUG_PORT" ] && [ -t 0 ]; then
    echo ""
    echo "  ═══ 连接哪个控制台？ ═══"
    echo "   1) 插件控制台 4321（默认）── 视图树/类/内存/沙箱文件（能力最强）"
    echo "   2) 守护进程 odebugd 4322 ── 注入!fd/看门狗!auto/!net/救援!safe（安全模式也不失联）"
    printf '%s' "  选择 [1]: "
    read -r _pick
    case "$_pick" in
        2) PORT=4322 ;;
        *) PORT=4321 ;;
    esac
    echo "  → 已选择端口 $PORT"
fi


# ── 端口转发（只在电脑上跑时需要）──────────────────────────────────────────
# 控制台跑在**设备**的 SpringBoard 里，只绑设备自己的 127.0.0.1:4321。
# 在电脑上运行本脚本时，必须先把设备 4321 转出来（iproxy），否则 bash 的 /dev/tcp
# 会报 `connect: Connection refused` + `3: Bad file descriptor`（= 本机 4321 没人监听）。
# 这里自动检测并在需要时后台启动 iproxy，脚本退出时一并收掉。
UDID=${ODEBUG_UDID:-}
if [ -z "$UDID" ] && [ ! -d /var/jb ] && command -v idevice_id >/dev/null 2>&1; then
    UDID=$(idevice_id -l 2>/dev/null | head -1)
fi
TUNNEL_PID=""
trap '[ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null' EXIT

port_up() {
    (exec 3<>/dev/tcp/$HOST/$PORT) >/dev/null 2>&1 || return 1
    exec 3>&- 2>/dev/null
    return 0
}

# 1.0.144：发现手机 IP 的两条路——
# ① Bonjour(mDNS)：手机 WLAN 模式广播 _odebugd._tcp.，dns-sd 解析；
# ② UDP 信标：手机每 5 秒向 255.255.255.255:4323 发 ODEBUGD_BEACON，这里监听 7 秒抓一次。
# （ODEBUG_NO_BONJOUR=1 跳过自动发现）
discover_odebugd() {
    # ① Bonjour
    if command -v dns-sd >/dev/null 2>&1; then
        local tmp; tmp=$(mktemp)
        dns-sd -L odebugd _odebugd._tcp local. > "$tmp" 2>/dev/null &
        local p=$!
        sleep 2
        kill "$p" 2>/dev/null
        local ip=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]+' "$tmp" | head -1 | cut -d: -f1)
        rm -f "$tmp"
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    fi
    # ② UDP 信标：手机每 5 秒广播 `ODEBUGD_BEACON <ip> <port> <版本>`，抓一行解析出 IP
    if command -v nc >/dev/null 2>&1; then
        local tmp2; tmp2=$(mktemp)
        ( nc -lu 4323 > "$tmp2" 2>/dev/null ) &
        local p2=$!
        sleep 7
        kill "$p2" 2>/dev/null
        local bip=$(grep -aoE 'ODEBUGD_BEACON ([0-9]{1,3}\.){3}[0-9]{1,3} [0-9]+' "$tmp2" | head -1 | awk '{print $2}')
        rm -f "$tmp2"
        [ -n "$bip" ] && { echo "$bip"; return 0; }
    fi
    return 1
}

ensure_tunnel() {
    [ -d /var/jb ] && return 0                 # 设备上运行：直连本机回环，无需转发
    [ -n "$ODEBUG_HOST" ] && return 0          # WLAN 直连手机 IP：不需要 usbmuxd 转发
    port_up && return 0
    # Bonjour 自动发现手机 IP（需手机侧「设置→ODebug→WLAN 直连」已开）
    if [ -z "$ODEBUG_NO_BONJOUR" ]; then
        local ip; ip=$(discover_odebugd)
        if [ -n "$ip" ]; then
            HOST="$ip"
            if port_up; then
                echo "📡 Bonjour 自动发现 odebugd：$HOST（WLAN 直连，免数据线）"
                return 0
            fi
            HOST=${ODEBUG_HOST:-127.0.0.1}
        fi
    fi
    if ! command -v iproxy >/dev/null 2>&1; then
        echo "⚠️  本机 $HOST:$PORT 无监听，且找不到 iproxy（brew install usbmuxd）"
        return 1
    fi
    if [ -n "$UDID" ]; then
        iproxy "$PORT" "$PORT" -u "$UDID" >/dev/null 2>&1 &
    else
        iproxy "$PORT" "$PORT" >/dev/null 2>&1 &
    fi
    TUNNEL_PID=$!
    for _i in $(seq 1 40); do
        if port_up; then
            echo "🔌 已自动启动 iproxy $PORT → 设备 $PORT ${UDID:+（$UDID）}"
            return 0
        fi
        sleep 0.25
    done
    echo "⚠️  iproxy 启动失败：$HOST:$PORT 仍无监听"
    return 1
}

# 读取调试令牌，优先级：命令行参数 > 设备设置plist > 本地缓存 > 手动输入
get_token() {
    local t=""
    [ $# -ge 1 ] && t="$1"
    if [ -z "$t" ] && [ -f "$PLIST" ]; then
        t=$(awk '/<key>debugAuthToken<\/key>/{getline; gsub(/<[^>]*>/,""); gsub(/^[ \t]+|[ \t]+$/,""); print; exit}' "$PLIST" 2>/dev/null)
    fi
    if [ -z "$t" ] && [ -f "$TOKEN_FILE" ]; then
        t=$(cat "$TOKEN_FILE" 2>/dev/null)
    fi
    if [ -z "$t" ]; then
        printf '%s' "请输入调试令牌（设置→ODebug→调试令牌）: "; read -r t
        echo "$t" > "$TOKEN_FILE"   # 缓存，下次自动读
    fi
    echo "$t"
}

TOKEN=$(get_token "$1")
echo "✅ 调试令牌: $TOKEN (BASH=$BASH_VERSION)"
ensure_tunnel || true

# 发送单条命令并读取完整响应（环境变量传递避免引号/括号被 shell 二次解析）
# 跨进程命令（!front / !vcapp）结果写在 syslog：Mac 上先启动 idevicesyslog 抓取再发命令，
# 设备上发完后用 log show 查最近日志——这样脚本内直接看到结果，不用切窗口。
send() {
    local cmd="$1"
    # 容错：用户可能误输 AUTH <token> 前缀（脚本已自动加），剥掉只留命令
    if [[ "$cmd" == AUTH* ]]; then
        cmd="${cmd#AUTH }"
        cmd="${cmd#* }"
    fi
    local filter=""
    # 支持管道过滤：!vc | grep UIButton → 命令 !vc，过滤 UIButton
    if [[ "$cmd" == *" | grep "* ]]; then
        filter="${cmd##* | grep }"
        cmd="${cmd%% | grep *}"
    fi

    local is_cross=0
    case "$cmd" in *front*|*vcapp*) is_cross=1;; esac

    # Mac：先启动抓取，避免启动慢错过 App 响应
    local logfile=""
    if [ "$is_cross" = "1" ] && [ ! -d /var/jb ]; then
        logfile=$(mktemp)
        ( idevicesyslog > "$logfile" 2>&1 ) &
        _PID=$!
        sleep 1
    fi

    ensure_tunnel >/dev/null 2>&1
    if ! port_up; then
        echo "❌ 连不上 $HOST:$PORT —— 无转发或目标控制台没在监听。"
        echo "   · 插件控制台(4321)：电脑上另开终端跑 ./odebug-iproxy.sh（本脚本也会尝试自动起 iproxy）"
        echo "   · 守护进程(4322)：ODEBUG_PORT=4322 ./odebug.sh；WLAN：加 ODEBUG_HOST=<手机IP>"
        echo "   · 设备上：确认 ODebug 已注入 SpringBoard（安全模式下由看门狗注入回来）"
        echo "   · 自检：lsof -nP -iTCP:$PORT -sTCP:LISTEN"
        return 1
    fi

    # 发送并捕获响应（过滤控制台欢迎语，避免每条命令重复显示）；!dump 遍历类 + 轮询，给更长超时
    local timeout=2
    case "$cmd" in *dump*) timeout=40;; esac
    local output
    output=$(TOKEN="$TOKEN" CMD="$cmd" TIMEOUT="$timeout" bash -c '
        exec 3<>/dev/tcp/127.0.0.1/4321
        printf "AUTH $TOKEN $CMD\n" >&3
        while read -t $TIMEOUT line <&3; do echo "$line"; done
        exec 3>&-
    ' | grep -v "ODebug 调试控制台: 输入 help")
    if [ -n "$filter" ]; then
        echo "$output" | grep "$filter"
    else
        echo "$output"
    fi

    if [ "$is_cross" = "1" ]; then
        sleep 1
        echo "--- 目标App的视图树(syslog) ---"
        if [ -d /var/jb ]; then
            # 设备上：log show 需 --info --debug 才含 NSLog；只显示 App 的 [open] /VCDump 输出
            log show --last 20s --info --debug \
                --predicate 'eventMessage CONTAINS "VCDump"' 2>/dev/null \
                | grep -E "\[open\] /VCDump|Top:|keyWindow" \
                | { [ -n "$filter" ] && grep "$filter" || cat; } \
                | tail -40
        elif [ -n "$logfile" ]; then
            # Mac：等 App 响应 + idevicesyslog 抓到；只显示 App 的 [open] /VCDump，过滤 SpringBoard 自身日志
            sleep 3
            kill $_PID 2>/dev/null
            grep -E "\[open\] /VCDump|Top:|keyWindow" "$logfile" 2>/dev/null \
                | { [ -n "$filter" ] && grep "$filter" || cat; } \
                | head -40
            rm -f "$logfile"
        fi
    fi

    # !dump：自动把 dump 目录 scp -r 拉取到本地当前目录（在 Mac 上按类名查看）
    case "$cmd" in !dump*)
        local path=$(echo "$output" | grep -oE '(/var/mobile/tmp/|/private/var/mobile/Containers/[^（ )]+|/tmp/|/var/mobile/)classdump_[^（ )]+/?|(/var/mobile/tmp/|/private/var/mobile/Containers/[^（ )]+|/tmp/|/var/mobile/)classdump_[^（ )]+\.txt' | head -1)
        if [ -n "$path" ]; then
            echo "--- 拉取到本地: $(basename "$path") ---"
            if [[ "$path" == */ ]]; then
                # 目录：scp -r 递归拉取（允许输密码）
                scp -r -q -P 2223 "root@127.0.0.1:$path" "./" 2>/dev/null \
                    && echo "✅ 已保存到当前目录（$(basename "$path")/）" \
                    || echo "scp 失败，手动执行: scp -r -P 2223 root@127.0.0.1:$path ./"
            else
                scp -q -P 2223 "root@127.0.0.1:$path" "./" 2>/dev/null \
                    && echo "✅ 已保存到当前目录（$(basename "$path")）" \
                    || echo "scp 失败，手动执行: scp -P 2223 root@127.0.0.1:$path ./"
            fi
        fi
        ;;
    esac
}

# ── 安全模式：两条通道 ──────────────────────────────────────────────────────
# 通道 A（正常模式）：插件控制台 `!safe <cmd>`，命令就在 SpringBoard 里执行，最省事。
# 通道 B（已经是安全模式）：控制台**必然不可用** —— 安全模式的定义就是所有 tweak 都不注入，
#        插件自己也在被禁之列（没有 ODebug.dylib 就没有 4321 控制台）。
#        这时改用电脑侧 frida 脚本：frida-server 是 LaunchDaemon（root、非 tweak），
#        安全模式里照旧活着，所以我们能"像 frida 那样"从进程外把安全模式退掉。
SAFEMODE_TOOL="${ODEBUG_SAFEMODE_TOOL:-$(cd "$(dirname "$0")" && pwd)/tools/safemode_frida.py}"

find_frida_python() {
    local p
    for p in "${ODEBUG_FRIDA_PY:-}" "$HOME/.frida-env/bin/python3" "$(command -v python3)"; do
        [ -n "$p" ] && [ -x "$p" ] && "$p" -c 'import frida' >/dev/null 2>&1 && { echo "$p"; return 0; }
    done
    return 1
}

# 控制台是否真的在应答（只看端口会误判：iproxy 起着但设备侧没监听时连接会立刻被拒）
console_alive() {
    port_up || return 1
    local out
    out=$(TOKEN="$TOKEN" bash -c '
        exec 3<>/dev/tcp/127.0.0.1/4321 || exit 1
        printf "AUTH $TOKEN !safe status\n" >&3
        read -t 3 line <&3 && echo "$line"
        exec 3>&-
    ' 2>/dev/null)
    [ -n "$out" ]
}

safemode_via_frida() {          # $1 = enter | exit | enter-ureboot | status
    local py
    if [ ! -f "$SAFEMODE_TOOL" ]; then
        echo "❌ 找不到 $SAFEMODE_TOOL（可用 ODEBUG_SAFEMODE_TOOL 指定路径）"; return 1
    fi
    py=$(find_frida_python) || { echo "❌ 找不到带 frida 模块的 python（用 ODEBUG_FRIDA_PY=... 指定）"; return 1; }
    echo "🔧 电脑侧 frida 通道: $py $SAFEMODE_TOOL $1"
    "$py" "$SAFEMODE_TOOL" "$1" --yes
}

safemode_do() {                 # $1 = on | onall | off | status | respring
    case "$1" in
        status)  if console_alive; then send "!safe status"; else safemode_via_frida status; fi;;
        on)      if console_alive; then send "!safe on"
                 else echo "ℹ️  控制台不可达（安全模式下插件不注入）→ 自动改走 frida 通道"; safemode_via_frida enter; fi;;
        onall)   if console_alive; then send "!safe on all"; else safemode_via_frida enter-ureboot; fi;;
        off)     if console_alive; then send "!safe off"
                 else echo "ℹ️  控制台不可达 → 用 frida 通道删标记并重启 SpringBoard（退出安全模式）"; safemode_via_frida exit; fi;;
        respring) if console_alive; then send "!safe respring"
                 else echo "ℹ️  安全模式里没有『只 respring』的插件入口：要退出安全模式请用 off（删标记+重启 SB）"; fi;;
        *)       echo "未知安全模式命令: $1（可用 on / on all / off / respring / status）";;
    esac
}

safemode_interactive() {
    printf '%s' "安全模式：on=进入 / on all=连用户空间一起重启 / off=退出(删标记+重启SB) / respring / status
回车=on；只想看状态请输入 status: "
    read -r sm
    case "$sm" in
        ""|on|ON|On)          safemode_do on;;
        all|"on all"|"ON ALL") safemode_do onall;;
        off|OFF|Off)          safemode_do off;;
        respring|rs)          safemode_do respring;;
        status|st)            safemode_do status;;
        *)                    safemode_do "$sm";;
    esac
}

menu() {
    # ANSI 颜色
    local C_G='\033[32m' C_C='\033[36m' C_B='\033[34m' C_Y='\033[33m'
    local C_R='\033[0m' C_D='\033[37m' C_BLD='\033[1m'
    echo
    echo -e "  ${C_BLD}${C_B}═══ ODebug 调试控制台 ═══${C_R}  直接输入命令（无需 AUTH），或按快捷键：\n"
    local sec title
    sec() { title="$1"; echo -e "  ${C_Y}◆${C_R} ${C_BLD}${title}${C_R}"; }
    row() { printf "    ${C_G}%-2s${C_R} ${C_C}%-20s${C_D}%s${C_R}\n" "$1" "$2" "$3"; }

    sec "视图 / 控制器"
    row 1 "!vc [类名]" "视图树(可过滤)"
    row 2 "!vc top" "最上层控制器+地址"
    row 5 "!front" "前台App最上层"
    row 6 "!vcapp top" "App打印最上层"
    row u "!vcapp <bid>" "App打印完整视图树"

    sec "类 / 对象"
    row 3 "!class <类名>" "方法/属性"
    row 4 "!inheritance" "继承链"
    row i "!ivars <addr>" "实例变量 [all] [kw]"

    sec "内存 / 文件"
    row 7 "!mem read" "读内存 <addr> [len]"
    row w "!mem write" "写内存 <addr> <byte>"
    row 8 "!ls <路径>" "列目录"
    row 9 "!cat <路径>" "读文件"
    row r "!plist read" "读plist"
    row y "!plist write" "写plist"

    sec "App / 系统"
    row p "!process" "进程信息"
    row s "!sys" "系统信息"
    row a "!apps" "App列表"
    row b "!bundle <bid>" "App信息"
    row e "!icon <bid>" "App图标"
    row d "!dump <bid>" "导出全部类"
    row c "!icons" "list/hide/show"

    sec "高级"
    row v "!eval [方法]" "调用方法"
    row g "!grep <kw>" "过滤上一条输出"
    row m "!safe on|off" "进/出安全模式(禁用全部插件)"
    row h "help" "帮助"
    row 0 "exit" "退出"

    echo -e "  ${C_D}也可直接输入任意命令，如 !eval [[TOJBClass001 m] m2]${C_R}\n"
}

menu
while true; do
    printf '%s' $'\033[36modebug>\033[0m '; read -r input
    [ -z "$input" ] && { menu; continue; }
    case "$input" in
        0) echo "再见"; exit 0;;
        1) send "!vc";;
        2) send "!vc top";;
        3) printf '%s' "类名: "; read -r cn; [ -n "$cn" ] && send "!class $cn";;
        4) printf '%s' "类名: "; read -r cn; [ -n "$cn" ] && send "!inheritance $cn";;
        5) send "!front";;
        6) send "!vcapp top";;
        7) printf '%s' "地址(0x...): "; read -r addr; printf '%s' "长度[默认16]: "; read -r len; send "!mem read $addr ${len:-16}";;
        8) printf '%s' "目录路径: "; read -r p; [ -n "$p" ] && send "!ls $p";;
        9) printf '%s' "文件路径: "; read -r p; [ -n "$p" ] && send "!cat $p";;
        p|P) send "!process";;
        s|S) send "!sys";;
        a|A) send "!apps";;
        b|B) printf '%s' "bundleId: "; read -r bid; [ -n "$bid" ] && send "!bundle $bid";;
        d|D) printf '%s' "bundleId: "; read -r bid; [ -n "$bid" ] && send "!dump $bid";;
        e|E) printf '%s' "bundleId: "; read -r bid; [ -n "$bid" ] && send "!icon $bid";;
        i|I) printf '%s' "对象地址(0x...): "; read -r addr; printf '%s' "选项(空/all/关键词): "; read -r opt; [ -n "$addr" ] && send "!ivars $addr $opt";;
        u|U) printf '%s' "bundleId(留空=全部注入App): "; read -r bid; [ -n "$bid" ] && send "!vcapp $bid" || send "!vcapp";;
        w|W) printf '%s' "地址(0x...): "; read -r addr; printf '%s' "字节(如 0xAA): "; read -r byte; [ -n "$addr" ] && [ -n "$byte" ] && send "!mem write $addr $byte";;
        r|R) printf '%s' "plist路径: "; read -r p; [ -n "$p" ] && send "!plist read $p";;
        y|Y) printf '%s' "plist路径: "; read -r p; printf '%s' "key: "; read -r k; printf '%s' "值: "; read -r val; [ -n "$p" ] && [ -n "$k" ] && send "!plist write $p $k $val";;
        v|V) printf '%s' "方法调用(如 [[TOJBClass001 m] m2]): "; read -r m; [ -n "$m" ] && send "!eval $m";;
        g|G) printf '%s' "关键词: "; read -r kw; [ -n "$kw" ] && send "!grep $kw";;
        m|M) safemode_interactive;;
        c|C) printf '%s' "icons命令(list/hide <bundleId>/show): "; read -r x; [ -n "$x" ] && send "!icons $x";;
        h|H|help) send "help"; menu;;
        clear|cls) clear; menu;;
        *) if [[ "$input" == \!* || "$input" == AUTH* || "$input" == \[* || "$input" == "help" || "$input" == "?" ]]; then
               send "$input"          # 控制台命令（! 开头 / [类名 方法] / help / ?）
           else
               echo "\$ $input"; eval "$input"   # Mac 本地命令（cat/ls/grep 等）
           fi;;
    esac
done
