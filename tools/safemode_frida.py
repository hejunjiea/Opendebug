#!/usr/bin/env python3
"""只用 frida 进出安全模式（禁用全部 tweak 注入）+ 用户空间重启(userspace reboot)。

────────────────────────────────────────────────────────────────────────
机制（本机真机实测，非推断；jbroot = /private/var/containers/Bundle/Application/.jbroot-AA81787E72D520AA）
────────────────────────────────────────────────────────────────────────
本机真正的注入器是 **每个进程都会通过 DYLD_INSERT_LIBRARIES 载入的 systemhook**，
不是 ElleKit 的 libinjector：

  证据 1（A 级）  launchctl procinfo <SpringBoard pid> ⇒
                  DYLD_INSERT_LIBRARIES => /usr/lib/systemhook-AA81787E72D520AA.dylib
                  （环境里**没有** _MSSafeMode / _SafeMode）
  证据 2（STATIC）该 dylib 内含字符串：
                  _SafeMode / _MSSafeMode / /basebin/.safe_mode /
                  allow_inject_with_safe_mode / _allow_inject_with_safe_mode
  证据 3（A 级）  写入标记之前：frida spawn 的进程带 TweakInject/{Crane,Choicy}（2 个）；
                  写入之后：同方式 spawn 的进程 TweakInject 模块 = []（0 个）
  ⇒ 该判定在**进程注入时**执行 ⇒ 只需让进程重新 spawn 即可生效，**不需要重启设备/用户空间**。

★ 标记的**真实落点**（2026-10-06 单变量实测，这条最容易搞错）：
  - 注入器检查的是 <jbroot>/basebin/.safe_mode（postinst 建的软链 → /var/mobile/.eksafemode），
    且检查**跟随软链**（实测：悬空软链 ⇒ 不生效，仍注入 2 个 tweak）。
  - 但它解析软链目标时用的是 **jbroot 侧** 的 /var/mobile：
        <jbroot>/var/mobile  ≠  真实 /var/mobile            （不同 inode：22747725 vs 2）
        <jbroot>/var/mobile/.eksafemode   ← 真正生效的标记文件
  - 实测对照：写 <jbroot>/var/mobile/.eksafemode + 重启 SpringBoard ⇒ 新 SB 0 个 tweak（安全模式）；
              写 真实 /var/mobile/.eksafemode + 重启 SpringBoard       ⇒ 新 SB 仍 47 个 tweak（无效）。
  - 该目录 = /private/var/mobile/Containers/Shared/AppGroup/<jbroot 名>/var/mobile，权限 mobile:mobile 0755
    ⇒ SpringBoard(mobile) 自己就能创建/删除 ⇒ 插件侧不需要 root 组件。
  ⇒ 本脚本 enter/mark 只写 <jbroot>/var/mobile/.eksafemode；exit 先删它、再 respring，并顺手清理
    真实 /var/mobile/.eksafemode（旧版本误写的历史遗留，注入器不看它）。

恢复铁律（规则 25）：先删标记，再 respring / 重启用户空间；顺序不得颠倒。
────────────────────────────────────────────────────────────────────────
用法：
  python3 safemode_enter.py status              # 只读：uid / jbroot / 两个标记 / 内容
  python3 safemode_enter.py probe               # 只读：spawn 一个临时进程，看它有没有被注入 tweak
  python3 safemode_enter.py enter       --yes   # 写标记 + SIGKILL SpringBoard ⇒ 新进程起即安全模式
  python3 safemode_enter.py exit        --yes   # 先删标记、再 SIGTERM SpringBoard ⇒ 恢复注入
  python3 safemode_enter.py ureboot     --yes   # 只重启用户空间（不改标记）
  python3 safemode_enter.py enter-ureboot --yes # 写标记 + 用户空间重启 = 全局安全模式

风险（enter/ureboot/enter-ureboot）：
  - 前台 App 被杀；resp不重要服务随用户空间重启；frida-server 以新 pid 重生（re.frida.server.plist）。
  - 安全模式下所有 tweak（含 ios-mcp）不再注入；frida-server 与 LaunchDaemons 不受影响。
  - 已在跑的进程保持原状，除非它被重启（所以 enter 会顺带 SIGKILL SpringBoard）。
"""
import argparse
import sys
import time

import frida

# 注入器检查的软链：<jbroot> + MARKER_LINK（postinst 创建，指向 /var/mobile/.eksafemode）
MARKER_LINK = "/basebin/.safe_mode"
# ★ 真正生效的标记文件：<jbroot> + MARKER_FLAG
#   （路径事实：<jbroot>/var/mobile 与真实 /var/mobile 是两个不同 inode 的目录）
MARKER_FLAG = "/var/mobile/.eksafemode"
# 真实根路径下的同名文件：本机注入器**不看**它；status 展示 + exit 清理历史遗留
MARKER_REAL = "/var/mobile/.eksafemode"

# 在 launchd(pid 1) 里跑，uid=0（root），因此能写 jbroot 且能 kill SpringBoard
AGENT = r"""
const access   = new NativeFunction(Module.getExportByName(null, 'access'),   'int',  ['pointer', 'int']);
const fopen    = new NativeFunction(Module.getExportByName(null, 'fopen'),    'pointer', ['pointer', 'pointer']);
const fread    = new NativeFunction(Module.getExportByName(null, 'fread'),    'ulong', ['pointer', 'ulong', 'ulong', 'pointer']);
const fwrite   = new NativeFunction(Module.getExportByName(null, 'fwrite'),   'ulong', ['pointer', 'ulong', 'ulong', 'pointer']);
const fclose   = new NativeFunction(Module.getExportByName(null, 'fclose'),   'int',  ['pointer']);
const unlink   = new NativeFunction(Module.getExportByName(null, 'unlink'),   'int',  ['pointer']);
const lstat    = new NativeFunction(Module.getExportByName(null, 'lstat'),    'int',  ['pointer', 'pointer']);
const readlink = new NativeFunction(Module.getExportByName(null, 'readlink'), 'long', ['pointer', 'pointer', 'ulong']);
const getuid   = new NativeFunction(Module.getExportByName(null, 'getuid'),   'uint', []);
const kill     = new NativeFunction(Module.getExportByName(null, 'kill'),     'int',  ['int', 'int']);

const send_op = %(OP)s;
const sb_pid  = %(SB_PID)d;
const real    = Memory.allocUtf8String("%(MARKER_REAL)s");

// jbroot：从已加载模块路径里截出 ".../.jbroot-XXXXXXXX"
function findJbroot() {
    for (const m of Process.enumerateModules()) {
        const i = m.path.indexOf("/.jbroot-");
        if (i === -1) continue;
        const rest = m.path.indexOf("/", i + 1);
        return rest === -1 ? m.path : m.path.substring(0, rest);
    }
    return null;
}
const jbroot = findJbroot();
// ★ 真正生效的标记文件 = <jbroot>/var/mobile/.eksafemode
//   （注入器检查 <jbroot>/basebin/.safe_mode 这个软链，但解析目标时用的是 jbroot 侧的 /var/mobile）
const flag = jbroot ? Memory.allocUtf8String(jbroot + "%(MARKER_FLAG)s") : null;
// 注入器检查的那条软链（仅展示 / 供排查；不要直接写它：写它会跟随到**真实** /var/mobile）
const link = jbroot ? Memory.allocUtf8String(jbroot + "%(MARKER_LINK)s") : null;

function stat(marker) {
    if (!marker) return { exists: false, content: null, note: "jbroot 未找到" };
    const r = { path: marker.readUtf8String(), exists: access(marker, 0) === 0, content: null };
    if (r.exists) {
        const f = fopen(marker, Memory.allocUtf8String("r"));
        if (!f.isNull()) {
            const b = Memory.alloc(512);
            const n = fread(b, 1, 512, f);
            r.content = n > 0 ? b.readUtf8String(n) : "(0 bytes)";
            fclose(f);
        }
    }
    return r;
}

// 软链自身的状态（lstat 拿类型；readlink 拿目标）
function linkInfo(p) {
    if (!p) return { path: null, exists: false, isSymlink: null, target: null };
    const r = { path: p.readUtf8String(), exists: access(p, 0) === 0, isSymlink: null, target: null };
    const st = Memory.alloc(256);
    if (lstat(p, st) === 0) r.isSymlink = (st.add(4).readU16() & 0xF000) === 0xA000;
    const b = Memory.alloc(1024);
    const n = readlink(p, b, 1023);
    r.target = n > 0 ? b.readUtf8String(n) : null;
    return r;
}

function status() {
    return { uid: getuid(), flag: stat(flag), link: linkInfo(link), real: stat(real) };
}

function writeMarker(marker, tag) {
    const reason = "[" + new Date().toString() + "] frida safemode_enter.py " + tag;
    const f = fopen(marker, Memory.allocUtf8String("w"));
    if (f.isNull()) return "fopen('" + marker.readUtf8String() + "','w') failed";
    const buf = Memory.allocUtf8String(reason);
    fwrite(buf, 1, reason.length, f);
    fclose(f);
    return reason;
}

let out = { op: send_op, jbroot: jbroot, before: status(), after: null };

if (send_op === "enter") {
    out.reason = writeMarker(flag, "enter");
    out.real_cleaned = unlink(real);   // 真实路径的同名文件是旧版本误写的历史遗留，注入器不看它
    out.killed = kill(sb_pid, 9);      // SIGKILL：让 SpringBoard 立即重生，否则它仍是旧（带 tweak）的进程
} else if (send_op === "mark") {
    out.reason = writeMarker(flag, "mark");
    out.real_cleaned = unlink(real);
} else if (send_op === "exit") {
    // 铁律：先删标记，再 respring（顺序不得颠倒）；真实路径的历史遗留也清掉
    out.unlinked_flag = unlink(flag);
    out.unlinked_real = unlink(real);
    out.killed = kill(sb_pid, 15) === 0 ? 15 : -1;   // SIGTERM：干净退出，由 launchd 拉起（新进程恢复注入）
}

out.after = status();
send(out);
"""


def call(dev, sb_pid, op):
    session = dev.attach(1)          # launchd
    script = session.create_script(
        AGENT % {"OP": '"%s"' % op, "SB_PID": sb_pid or 0,
                 "MARKER_FLAG": MARKER_FLAG, "MARKER_LINK": MARKER_LINK,
                 "MARKER_REAL": MARKER_REAL}
    )
    box = []
    script.on("message", lambda m, d: box.append(m))
    script.load()
    for _ in range(60):
        if box:
            break
        time.sleep(0.1)
    session.detach()
    if not box:
        raise RuntimeError("agent 无返回")
    msg = box[0]
    if msg.get("type") != "send":
        raise RuntimeError("agent 出错: %s" % msg)
    return msg["payload"]


def pid_of(dev, name, tries=10):
    """enumerate_processes 在用户空间重启后会偶发
    NotSupportedError: this feature requires an iOS Developer Disk Image…
    / TransportError: the connection is closed —— 都是暂时性的，重试即可。"""
    last = None
    for _ in range(tries):
        try:
            for p in dev.enumerate_processes():
                if p.name == name:
                    return p.pid
            return None
        except Exception as e:
            last = e
            time.sleep(3)
    print("  ! enumerate_processes(%s) 连续失败: %s: %s" % (name, type(last).__name__, last),
          file=sys.stderr)
    return None


def springboard_pid(dev):
    return pid_of(dev, "SpringBoard")


def wait_for_device(timeout=240):
    """用户空间重启期间 USB/frida-server 会短暂消失；等它回来。"""
    t0 = time.time()
    last = None
    while time.time() - t0 < timeout:
        time.sleep(3)
        try:
            dev = frida.get_usb_device(timeout=5)
            ps = dev.enumerate_processes()
            if any(p.name == "frida-server" for p in ps):
                print("  [%3ds] 设备已回来：进程 %d 个，frida-server pid=%s"
                      % (time.time() - t0, len(ps), pid_of(dev, "frida-server")))
                return dev
        except Exception as e:
            last = "%s: %s" % (type(e).__name__, e)
            print("  [%3ds] 等设备… %s" % (time.time() - t0, last))
    raise RuntimeError("等待设备超时（%ds）" % timeout)


def tweaks_in(dev, pid):
    """返回该进程里 TweakInject 注入的模块名列表。"""
    s = dev.attach(pid)
    sc = s.create_script(
        "send(Process.enumerateModules().filter(function(m){"
        "return m.path.indexOf('TweakInject') !== -1;}).map(function(m){return m.name;}))"
    )
    box = []
    sc.on("message", lambda m, d: box.append(m))
    sc.load()
    for _ in range(30):
        if box:
            break
        time.sleep(0.1)
    s.detach()
    return box[0]["payload"] if box and box[0].get("type") == "send" else None


def fresh_probe(dev, jbroot):
    """新建一个临时进程，看它是否被注入 tweak —— 这是安全模式唯一可靠的判据。"""
    try:
        pid = dev.spawn([jbroot + "/usr/bin/sleep", "20"])
        dev.resume(pid)
    except Exception as e:
        return "spawn 失败: %s: %s" % (type(e).__name__, e)
    time.sleep(1.5)
    try:
        return tweaks_in(dev, pid)
    except Exception as e:
        return "attach失败: %s" % type(e).__name__


def injection_probe(dev):
    """守护进程判据：安全模式下 launchd 拉起的守护进程里**不应**再有 TweakInject 注入。"""
    out = {}
    for name in ("locationd", "runningboardd", "gpsd"):
        pid = pid_of(dev, name)
        if not pid:
            continue
        try:
            out[name] = tweaks_in(dev, pid)
        except Exception as e:
            out[name] = "attach失败: %s" % type(e).__name__
    return out


def userspace_reboot(dev, jbroot):
    lc = (jbroot or "") + "/usr/bin/launchctl"
    pid = dev.spawn([lc, "reboot", "userspace"])
    print("已 spawn %s (pid=%d) → reboot userspace，resume…" % (lc, pid))
    dev.resume(pid)
    return pid


def usb_device(tries=8):
    """get_usb_device 在用户空间重启后也会暂时失败，重试。"""
    last = None
    for _ in range(tries):
        try:
            return frida.get_usb_device(timeout=10)
        except Exception as e:
            last = e
            time.sleep(3)
    raise last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action",
                    choices=["status", "probe", "enter", "exit", "ureboot", "enter-ureboot"])
    ap.add_argument("--yes", action="store_true", help="破坏性动作必须显式确认")
    args = ap.parse_args()

    dev = usb_device()
    sb = springboard_pid(dev)

    st = call(dev, sb, "status")
    jbroot = st.get("jbroot")

    if args.action == "status":
        print("SpringBoard pid =", sb)
        print("jbroot =", jbroot)
        print("★ 标记文件 %-44s : %s   ← 注入器真正检查（jbroot 侧）"
              % ((jbroot + MARKER_FLAG) if jbroot else MARKER_FLAG, st["before"]["flag"]))
        print("  注入软链 %-44s : %s   ← postinst 创建，注入器跟随它"
              % ((jbroot + MARKER_LINK) if jbroot else MARKER_LINK, st["before"]["link"]))
        print("  真实根路径 %-42s : %s   ← 注入器不看；旧版误写的历史遗留，exit 时清理"
              % (MARKER_REAL, st["before"]["real"]))
        return 0

    if args.action == "probe":
        print("新建临时进程的 TweakInject 模块 =", fresh_probe(dev, jbroot))
        print("守护进程探针 =", injection_probe(dev))
        return 0

    if not args.yes:
        print("!! %s 会重启 SpringBoard 或整个用户空间：所有前台 App 被杀，"
              "全部 tweak（含 ios-mcp）停止注入。" % args.action, file=sys.stderr)
        print("!! 确认请加 --yes", file=sys.stderr)
        return 2

    if args.action in ("enter", "exit"):
        print(call(dev, sb, args.action))
        time.sleep(2)
        print("SpringBoard pid now =", springboard_pid(dev))
        time.sleep(2)
        print("新建临时进程的 TweakInject 模块 =", fresh_probe(dev, jbroot))
        return 0

    # ureboot / enter-ureboot
    if args.action == "enter-ureboot":
        res = call(dev, sb, "mark")
        jbroot = res.get("jbroot")
        print("标记已写：", res["after"])
    print("jbroot =", jbroot)

    userspace_reboot(dev, jbroot)
    dev = wait_for_device()
    print("重启后状态：", call(dev, sb, "status"))
    print("SpringBoard pid now =", springboard_pid(dev))
    print("新建临时进程的 TweakInject 模块 =", fresh_probe(dev, jbroot))
    print("守护进程探针（安全模式应为空列表）：", injection_probe(dev))
    return 0


if __name__ == "__main__":
    sys.exit(main())
