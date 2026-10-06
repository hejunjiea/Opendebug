//
//  odebugd.m — ODebug 常驻调试服务（LaunchDaemon，root）
//
//  为什么需要它
//  ------------
//  安全模式的定义是「这个进程一个 tweak 都不注入」，所以跑在 SpringBoard 里的 ODebug
//  TCP 控制台（4321）在安全模式下**必然**消失 —— 没有 ODebug.dylib 就没有控制台。
//  frida 之所以在安全模式下还能用，是因为 frida-server 是 **LaunchDaemon**（root、非 tweak），
//  从进程外工作。odebugd 就是同样定位的服务：
//
//    · 保命通道：查/写/删安全模式标记、重启 SpringBoard、重启用户空间 —— 安全模式下照旧可用；
//    · root 基础调试：进程列表、文件读写、plist 读取、系统信息；
//    · 注入器（进阶）：把 ODebug.dylib 注入到指定进程，让 4321 控制台在安全模式里也回来。
//
//  协议与 SpringBoard 内控制台完全一致：连上后发 `AUTH <token> <命令>`，可连续多行。
//  默认端口 **4322**（4321 留给插件内控制台，两者可同时存在）。
//
//  安全模式下的标记路径（真机实测，勿改）
//  -------------------------------------
//    注入器检查 <jbroot>/basebin/.safe_mode（软链）并**跟随软链**；
//    ★ 真正决定生死的文件 = <jbroot>/var/mobile/.eksafemode
//    写真实 /var/mobile/.eksafemode 无效（两个不同的目录/inode）。
//

#import <Foundation/Foundation.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <dirent.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <ptrauth.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>

extern char **environ;

// iOS SDK 的 <mach/mach_vm.h> 是 #error unsupported，但 libsystem_kernel 照样导出这几个符号
// （越狱注入器的标准做法就是自己声明）。32/64 位通用，不依赖 vm_* 的旧接口。
extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address,
                                      mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address,
                                        mach_vm_size_t size);
extern kern_return_t mach_vm_protect(vm_map_t target, mach_vm_address_t address,
                                     mach_vm_size_t size, boolean_t set_max, vm_prot_t new_prot);
extern kern_return_t mach_vm_write(vm_map_t target, mach_vm_address_t address,
                                   vm_offset_t data, mach_msg_type_number_t dataCnt);
extern kern_return_t mach_vm_read_overwrite(vm_map_t target, mach_vm_address_t address,
                                            mach_vm_size_t size, mach_vm_address_t data,
                                            mach_vm_size_t *outsize);

static NSString *gJbroot = nil;

/// 兜底注入用的插件路径。roothide 把 tweak 实际注入用的副本放在 <jbroot>/usr/lib/TweakInject/ODebug.dylib
/// （真机实测：用这个路径 !fd 能把镜像载进越狱进程、且目标存活），旧的 DynamicLibraries 路径留作后备。
static NSString *odbgDefaultPluginPath(void) {
    NSString *inject = [gJbroot stringByAppendingString:@"/usr/lib/TweakInject/ODebug.dylib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:inject]) return inject;
    return [gJbroot stringByAppendingString:@"/Library/MobileSubstrate/DynamicLibraries/ODebug.dylib"];
}
static NSString *gLogPath = nil;
static int gPort = 4322;
static int gBindAny = 0;   // 1 = 绑 0.0.0.0（WLAN 直连模式，靠 token 鉴权），默认只绑回环
static NSString *gVersion = @"1.0.144";
static volatile int gAutoInject = 1;                            // 安全模式兜底：自动把 ODebug.dylib 注入 SpringBoard
static pthread_mutex_t gInjLock = PTHREAD_MUTEX_INITIALIZER;    // 同一时刻只允许一个注入（客户端 vs 看门狗）
static volatile time_t gExpectedSbRestart = 0;                  // odebugd 自己 respring 的时刻：看门狗据此不把「按预期重启」当崩溃循环

#pragma mark - 日志

static void applog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ [%d] %@\n", [NSDate date], getpid(), body];
    if (gLogPath) {
        FILE *f = fopen(gLogPath.UTF8String, "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); }
    }
    fputs(line.UTF8String, stderr);
}

// ── 崩溃取证：daemon 曾经「无声无息」死掉（日志里没有任何痕迹），加信号/异常兜底把回溯写进日志 ──
static void odbgCrashHandler(int sig) {
    void *bt[64];
    int n = backtrace(bt, 64);
    NSString *hdr = [NSString stringWithFormat:@"%@ [%d] 💥 收到信号 %d，回读 %d 帧回溯:\n", [NSDate date], getpid(), sig, n];
    FILE *f = gLogPath ? fopen(gLogPath.UTF8String, "a") : NULL;
    if (f) { fputs(hdr.UTF8String, f); fflush(f); backtrace_symbols_fd(bt, n, fileno(f)); fclose(f); }
    fputs(hdr.UTF8String, stderr); fflush(stderr);
    backtrace_symbols_fd(bt, n, 2);
    signal(sig, SIG_DFL);
    raise(sig);
}
static void odbgUncaughtExceptionHandler(NSException *e) {
    NSString *msg = [NSString stringWithFormat:@"%@ [%d] 💥 未捕获异常 %@: %@\n%@\n", [NSDate date], getpid(),
                     e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]];
    FILE *f = gLogPath ? fopen(gLogPath.UTF8String, "a") : NULL;
    if (f) { fputs(msg.UTF8String, f); fclose(f); }
    fputs(msg.UTF8String, stderr);
}
static void odbgInstallCrashHandlers(void) {
    // SIGTERM/SIGINT/SIGHUP/SIGSYS 默认行为也是直接死、不会留下任何痕迹 ⇒ 一并接进来（SIGKILL 接不了）
    signal(SIGTERM, odbgCrashHandler);
    signal(SIGINT,  odbgCrashHandler);
    signal(SIGHUP,  odbgCrashHandler);
    signal(SIGSYS,  odbgCrashHandler);
    int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP};
    for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) signal(sigs[i], odbgCrashHandler);
    NSSetUncaughtExceptionHandler(&odbgUncaughtExceptionHandler);
}

#pragma mark - 基础工具

static NSString *jbrootFromPath(const char *path) {
    if (!path) return nil;
    NSString *p = @(path);
    NSRange r = [p rangeOfString:@"/.jbroot-"];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = r.location;
    NSUInteger slash = [p rangeOfString:@"/" options:0
                                 range:NSMakeRange(start + 1, p.length - start - 1)].location;
    return slash == NSNotFound ? [p substringFromIndex:start] : [p substringToIndex:slash];
}

static NSString *findJbroot(void) {
    // 1) 环境变量：roothide 给被 patch 的进程注入 CFFIXED_USER_HOME=<jbroot>/var/root
    for (const char **k = (const char *[]){"ODEBUG_JBROOT", "CFFIXED_USER_HOME", "HOME", NULL}; *k; k++) {
        const char *v = getenv(*k);
        NSString *j = jbrootFromPath(v);
        if (j) { fprintf(stderr, "odebugd: jbroot 来自 %s=%s\n", *k, v); return j; }
    }
    // 2) 自己的可执行文件路径：launchd 的 Program 已被 roothide 改写成绝对 jbroot 路径
    {
        char exe[PATH_MAX] = {0};
        uint32_t sz = sizeof(exe);
        if (_NSGetExecutablePath(exe, &sz) == 0) {
            NSString *j = jbrootFromPath(exe);
            if (j) { fprintf(stderr, "odebugd: jbroot 来自可执行路径 %s\n", exe); return j; }
        }
    }
    // 3) 扫目录（用 POSIX opendir，绕开 Foundation 可能的路径重映射）
    for (const char **base = (const char *[]){"/private/var/containers/Bundle/Application",
                                              "/var/containers/Bundle/Application", NULL}; *base; base++) {
        DIR *d = opendir(*base);
        if (!d) { fprintf(stderr, "odebugd: opendir(%s) 失败 errno=%d\n", *base, errno); continue; }
        struct dirent *e;
        while ((e = readdir(d))) {
            if (strncmp(e->d_name, ".jbroot-", 8) != 0) continue;
            NSString *j = [@(*base) stringByAppendingPathComponent:@(e->d_name)];
            closedir(d);
            fprintf(stderr, "odebugd: jbroot 来自目录扫描 %s\n", j.UTF8String);
            return j;
        }
        closedir(d);
        fprintf(stderr, "odebugd: %s 下没找到 .jbroot-*\n", *base);
    }
    return nil;
}

/// 注入器真正检查的标记文件（<jbroot>/var/mobile/.eksafemode）
static NSString *markerPath(void) {
    return [gJbroot stringByAppendingString:@"/var/mobile/.eksafemode"];
}
/// 真实根路径下的同名文件：本机注入器**不看**它，仅用于展示与清理历史遗留
static NSString *legacyMarkerPath(void) { return @"/var/mobile/.eksafemode"; }
/// postinst 建的软链（注入器检查它，并跟随到 markerPath()）
static NSString *markerLinkPath(void) {
    return [gJbroot stringByAppendingString:@"/basebin/.safe_mode"];
}

static NSString *trim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *stringFromFile(NSString *path, NSUInteger cap) {
    NSData *d = [NSData dataWithContentsOfFile:path options:0 error:NULL];
    if (!d) return nil;
    if (d.length > cap) d = [d subdataWithRange:NSMakeRange(0, cap)];
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    return s;
}

static NSString *describePath(NSString *path) {
    struct stat st;
    if (lstat(path.UTF8String, &st) != 0) {
        return [NSString stringWithFormat:@"%@  (不存在, errno=%d)", path, errno];
    }
    char mode[16];
    snprintf(mode, sizeof(mode), "%s", (S_ISLNK(st.st_mode) ? "link" :
                                        S_ISDIR(st.st_mode) ? "dir" : "file"));
    NSString *extra = @"";
    if (S_ISLNK(st.st_mode)) {
        char buf[1024] = {0};
        ssize_t n = readlink(path.UTF8String, buf, sizeof(buf) - 1);
        if (n > 0) extra = [NSString stringWithFormat:@" -> %s", buf];
    }
    return [NSString stringWithFormat:@"%@  [%s %o %lldB %d:%d]%@",
            path, mode, st.st_mode & 07777, (long long)st.st_size, st.st_uid, st.st_gid, extra];
}

static pid_t pidOfName(const char *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return 0;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return 0;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) { free(procs); return 0; }
    pid_t found = 0;
    size_t n = len / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < n; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) { found = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return found;
}

static NSString *allProcs(NSString *filter) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0) return @"sysctl 失败";
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return @"malloc 失败";
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) { free(procs); return @"sysctl 失败"; }
    NSMutableString *out = [NSMutableString string];
    size_t n = len / sizeof(struct kinfo_proc);
    int shown = 0;
    for (size_t i = 0; i < n; i++) {
        NSString *comm = @(procs[i].kp_proc.p_comm);
        NSString *line = [NSString stringWithFormat:@"%-6d uid=%-5d %@\n",
                          procs[i].kp_proc.p_pid, procs[i].kp_eproc.e_ucred.cr_uid, comm];
        if (filter.length && ![comm.lowercaseString containsString:filter.lowercaseString]) continue;
        [out appendString:line];
        shown++;
        if (shown >= 400) { [out appendString:@"… (截断)\n"]; break; }
    }
    free(procs);
    [out appendFormat:@"共 %d 条\n", shown];
    return out;
}

static NSString *listDir(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:path error:&err];
    if (!entries) return [NSString stringWithFormat:@"读取失败: %@", err.localizedDescription ?: @"unknown"];
    entries = [entries sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *out = [NSMutableString string];
    for (NSString *e in entries) {
        [out appendFormat:@"%@\n", describePath([path stringByAppendingPathComponent:e])];
    }
    [out appendFormat:@"共 %lu 项\n", (unsigned long)entries.count];
    return out;
}

#pragma mark - 安全模式

static NSString *markerStatusLine(NSString *path, NSString *label) {
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    NSString *content = exists ? stringFromFile(path, 300) : nil;
    return [NSString stringWithFormat:@"%@: %@%@\n", label,
            exists ? @"存在 ⇒ 安全模式(新进程不注入 tweak)" : @"不存在 ⇒ 正常注入",
            content.length ? [NSString stringWithFormat:@"\n    内容: %@", content] : @""];
}

static BOOL writeMarker(NSString *tag, NSString **err) {
    NSString *path = markerPath();
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *body = [NSString stringWithFormat:
        @"[%@] odebugd 安全模式标记 (%@)\n"
        @"删除本文件（或用 odebug.sh 的 m → off / odebugd 的 !safe off）再 respring 即可退出安全模式。\n",
        [NSDate date], tag];
    NSError *e = nil;
    if (![body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&e]) {
        if (err) *err = [NSString stringWithFormat:@"写入失败: %@ (%@)", e.localizedDescription, path];
        return NO;
    }
    return YES;
}

static NSString *cmdSafe(NSString *arg) {
    NSString *a = trim(arg).lowercaseString;
    if (a.length == 0 || [a isEqualToString:@"status"]) {
        pid_t sb = pidOfName("SpringBoard");
        BOOL linkDangling = (access(markerPath().UTF8String, F_OK) != 0);
        return [NSString stringWithFormat:
            @"===== ODebug 安全模式（odebugd，root 视角）=====\n"
            @"jbroot: %@\n"
            @"标记文件(★注入器真正检查): %@\n"
            @"%@"
            @"注入软链: %@%@\n"
            @"真实路径(注入器不看，仅清理): %@\n"
            @"SpringBoard pid: %d\n"
            @"odebugd: pid %d, uid %d, 端口 %d\n"
            @"说明: 本服务是 LaunchDaemon ⇒ 安全模式下照旧应答；插件内控制台(4321)则不可用。\n"
            @"命令: !safe on | on all | off | respring | status\n",
            gJbroot, markerPath(),
            markerStatusLine(markerPath(), @"  当前"),
            markerLinkPath(), linkDangling ? @"  (悬空 ⇒ 等于没标记)" : @"  (指向标记文件)",
            legacyMarkerPath(), sb, getpid(), getuid(), gPort];
    }
    if ([a isEqualToString:@"on"] || [a isEqualToString:@"enter"]) {
        NSString *err = nil;
        if (!writeMarker(@"!safe on", &err)) return [NSString stringWithFormat:@"❌ %@\n", err];
        pid_t sb = pidOfName("SpringBoard");
        NSString *killed = @"SpringBoard 未找到（标记已写入，进程重启后生效）";
        if (sb > 0) {
            killed = [NSString stringWithFormat:@"已 SIGKILL SpringBoard(pid %d) ⇒ 新 SpringBoard 起即安全模式", sb];
            gExpectedSbRestart = time(NULL);   // 我们自己杀 SB ⇒ 告诉看门狗这是按预期重启，不是崩溃循环
            kill(sb, SIGKILL);
        }
        return [NSString stringWithFormat:@"✅ 标记已写入 %@\n%@\n", markerPath(), killed];
    }
    if ([a isEqualToString:@"on all"] || [a isEqualToString:@"all"]) {
        NSString *err = nil;
        if (!writeMarker(@"!safe on all", &err)) return [NSString stringWithFormat:@"❌ %@\n", err];
        NSString *lc = [gJbroot stringByAppendingString:@"/usr/bin/launchctl"];
        const char *argv[] = {lc.UTF8String, "reboot", "userspace", NULL};
        pid_t p = 0;
        int rc = posix_spawn(&p, argv[0], NULL, NULL, (char *const *)argv, environ);
        return [NSString stringWithFormat:
            @"✅ 标记已写入 %@\n%@ launchctl reboot userspace (rc=%d, pid=%d)\n"
            @"约 20-30 秒后设备回来（所有 App 被杀，标记保留 ⇒ 全用户空间干净）。\n",
            markerPath(), rc == 0 ? @"已启动" : @"启动失败", rc, p];
    }
    if ([a isEqualToString:@"off"] || [a isEqualToString:@"exit"]) {
        int r1 = unlink(markerPath().UTF8String);
        int r2 = unlink(legacyMarkerPath().UTF8String);
        pid_t sb = pidOfName("SpringBoard");
        NSString *killed = @"SpringBoard 未找到";
        if (sb > 0) {
            killed = [NSString stringWithFormat:@"已 SIGTERM SpringBoard(pid %d)", sb];
            gExpectedSbRestart = time(NULL);   // 同上：主动 respring 不计入崩溃循环
            kill(sb, SIGTERM);
        }
        return [NSString stringWithFormat:
            @"✅ 先删标记（<jbroot> 侧 unlink=%d，真实路径 unlink=%d），再重启 SpringBoard（规则 25 的顺序）\n%@\n",
            r1, r2, killed];
    }
    if ([a isEqualToString:@"respring"]) {
        pid_t sb = pidOfName("SpringBoard");
        if (sb <= 0) return @"SpringBoard 未找到\n";
        gExpectedSbRestart = time(NULL);       // 同上：主动 respring 不计入崩溃循环
        kill(sb, SIGKILL);
        return [NSString stringWithFormat:@"已 SIGKILL SpringBoard(pid %d)（标记未动）\n", sb];
    }
    return [NSString stringWithFormat:@"未知命令: !safe %@（可用 on / on all / off / respring / status）\n", arg];
}

#pragma mark - 注入器可行性探针（task_for_pid / 远程 VM / 远程线程）

static NSString *cmdTaskProbe(NSString *arg) {
    pid_t pid = (pid_t)strtol(trim(arg).UTF8String, NULL, 10);
    if (pid <= 0) return @"用法: !tp <pid>\n";
    NSMutableString *out = [NSMutableString string];
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    [out appendFormat:@"task_for_pid(%d) => %s(%d)\n", pid, mach_error_string(kr), kr];
    if (kr != KERN_SUCCESS) {
        [out appendString:@"⇒ 当前二进制没有 task_for_pid 权限（需要 platform-application / task_for_pid-allow 等 entitlement）\n"];
        return out;
    }
    mach_vm_address_t addr = 0;
    kr = mach_vm_allocate(task, &addr, 0x4000, VM_FLAGS_ANYWHERE);
    [out appendFormat:@"mach_vm_allocate(0x4000) => %s(%d) addr=0x%llx\n", mach_error_string(kr), kr, addr];
    if (kr == KERN_SUCCESS) {
        kern_return_t kr2 = mach_vm_protect(task, addr, 0x4000, FALSE,
                                            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
        [out appendFormat:@"mach_vm_protect(RWX) => %s(%d)  ⟵ 注入 shellcode 的前提\n",
                          mach_error_string(kr2), kr2];
        char probe[] = "odebugd-probe";
        mach_vm_size_t wrote = 0;
        kern_return_t kr3 = mach_vm_write(task, addr, (vm_offset_t)probe, sizeof(probe));
        [out appendFormat:@"mach_vm_write => %s(%d)\n", mach_error_string(kr3), kr3];
        (void)wrote;
        mach_vm_deallocate(task, addr, 0x4000);
    }
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t nthreads = 0;
    kr = task_threads(task, &threads, &nthreads);
    [out appendFormat:@"task_threads => %s(%d), 线程数=%u\n", mach_error_string(kr), kr, nthreads];
    if (kr == KERN_SUCCESS && threads) {
        for (mach_msg_type_number_t i = 0; i < nthreads; i++) mach_port_deallocate(mach_task_self(), threads[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)threads, sizeof(thread_t) * nthreads);
    }
    mach_port_deallocate(mach_task_self(), task);
    return out;
}

#pragma mark - 注入器：task_for_pid + 远程 dlopen（安全模式下把 ODebug 塞回进程）

typedef struct { uint64_t loadAddr; uint64_t pathAddr; char path[512]; } odbg_image_t;

static BOOL vmRead(task_t task, mach_vm_address_t addr, void *buf, size_t len) {
    mach_vm_size_t out = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, addr, len,
                                             (mach_vm_address_t)(uintptr_t)buf, &out);
    return kr == KERN_SUCCESS && out == len;
}

/// 读远端镜像列表（task_dyld_info → dyld_all_image_infos → infoArray）。返回条数，失败 -1
static int remoteImages(task_t task, odbg_image_t **out) {
    *out = NULL;
    applog(@"[dbg] remoteImages enter task=0x%x", task);
    task_dyld_info_data_t info;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&info, &cnt) != KERN_SUCCESS) return -1;
    mach_vm_address_t aii = info.all_image_info_addr;
    if (!aii) return -1;
    uint8_t hdr[16];
    if (!vmRead(task, aii, hdr, sizeof(hdr))) return -1;
    // struct dyld_all_image_infos: u32 version; u32 infoArrayCount; const dyld_image_info* infoArray;
    uint32_t count = *(uint32_t *)(hdr + 4);
    uint64_t arrayAddr = *(uint64_t *)(hdr + 8);
    if (!count || count > 4000 || !arrayAddr) return -1;
    size_t bytes = (size_t)count * 24;
    uint8_t *raw = malloc(bytes);
    if (!raw) return -1;
    if (!vmRead(task, arrayAddr, raw, bytes)) { free(raw); return -1; }
    odbg_image_t *imgs = calloc(count, sizeof(odbg_image_t));
    int n = 0;
    for (uint32_t i = 0; i < count; i++) {
        uint64_t load = *(uint64_t *)(raw + i * 24);
        uint64_t path = *(uint64_t *)(raw + i * 24 + 8);
        if (!load || !path) continue;
        imgs[n].loadAddr = load;
        imgs[n].pathAddr = path;
        char buf[512] = {0};
        if (vmRead(task, path, buf, sizeof(buf) - 1)) {
            memcpy(imgs[n].path, buf, sizeof(buf));
            n++;
        }
    }
    free(raw);
    *out = imgs;
    applog(@"[dbg] remoteImages leave n=%d", n);
    return n;
}

/// arm64e 上 dlsym/_dyld_get_image_header 返回的可能是带 PAC 签名的指针，算偏移前必须剥离
static uint64_t stripPAC(uint64_t v) {
    // arm64e：dlsym 返回的函数指针带 PAC 签名（实测 0xe4110001c1d07168），高 16 位是签名，
    // 直接 & 低 48 位还原真实地址；__builtin_ptrauth_strip 在本机 SDK 上不生效（实测无效），不要用。
    // ★ iOS arm64e 用户态 VA 只有 47 位：bit47 及以上都是 PAC 签名位。
    // 之前用 48 位掩码会把 bit47 留下来，`sleep` 就解析成了 0x8001a3f201a8 这种垃圾地址（实测踩过）。
    return v & 0x00007FFFFFFFFFFFULL;
}

/// 在本地找出与远端同名镜像的符号偏移，再加到远端镜像基址上
static uint64_t remoteSymbol(task_t task, odbg_image_t *imgs, int n,
                             const char *imageMatch, const char *sym) {
    void *localSym = dlsym(RTLD_DEFAULT, sym);
    if (!localSym) return 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm || !strstr(nm, imageMatch)) continue;
        const void *hdr = _dyld_get_image_header(i);
        if (!hdr) continue;
        uint64_t symAddr = stripPAC((uint64_t)(uintptr_t)localSym);
        uint64_t imgBase = stripPAC((uint64_t)(uintptr_t)hdr);
        if (symAddr <= imgBase) continue;
        uint64_t off = symAddr - imgBase;
        if (off > 0x4000000ULL) continue;              // 偏移离谱 ⇒ 这个镜像不是持有该符号的那个
        for (int j = 0; j < n; j++) {
            if (!strstr(imgs[j].path, imageMatch)) continue;
            uint64_t cand = imgs[j].loadAddr + off;
            uint32_t w = 0;
            if (!vmRead(task, cand, &w, 4) || w == 0) continue;   // 远端该地址必须可读且非零
            return cand;
        }
    }
    return 0;
}

// 读取线程状态里的 PC「字段形态」：arm64e 是 __opaque_pc（签名形式），arm64 是 __pc
#if __has_feature(ptrauth_calls)
#define ODBG_PC_FIELD(ts) ((uint64_t)(uintptr_t)(ts).__opaque_pc)
#else
#define ODBG_PC_FIELD(ts) ((uint64_t)(uintptr_t)(ts).__pc)
#endif

static void emitMov64(uint32_t *p, int *n, int rd, uint64_t val) {
    p[(*n)++] = 0xD2800000u | ((uint32_t)(val & 0xFFFF) << 5) | (uint32_t)rd;
    p[(*n)++] = 0xF2A00000u | ((uint32_t)((val >> 16) & 0xFFFF) << 5) | (uint32_t)rd;
    p[(*n)++] = 0xF2C00000u | ((uint32_t)((val >> 32) & 0xFFFF) << 5) | (uint32_t)rd;
    p[(*n)++] = 0xF2E00000u | ((uint32_t)((val >> 48) & 0xFFFF) << 5) | (uint32_t)rd;
}

/// 在目标进程里加载 dylib。
/// ★ 一路踩过来的三条硬约束（都是实测）：
///   1) 匿名内存取指会被内核判死 → 不能让目标执行我们自己写的 shellcode（用 thread_create_running 造线程必崩）；
///   2) 裸 mach 线程没有 pthread/TLS → 在它上面调 dlopen / pthread_create 也会当场崩（locationd 连崩数次）；
///   3) 目标里的 dlopen 是签名页里的正常代码 → 只要在**已有正规 pthread** 上执行就没问题。
/// 所以路线 = 劫持目标里已有的线程：把它的 PC 指到 dlopen（x0=路径、x1=3、LR=pause 停车），
/// 用线程自己的栈和 TLS；线程没被调度就原样还原，再换下一个线程试。
#if __has_feature(ptrauth_calls)
/// 把裸地址按 SDK 约定签成 PC 字段能接受的形式（process_independent_code + "pc"）
static void *odbgSignPC(uint64_t raw) {
    void *pre = ptrauth_sign_unauthenticated((void *)(uintptr_t)raw, ptrauth_key_function_pointer, 0);
    arm_thread_state64_t t; memset(&t, 0, sizeof(t));
    __darwin_arm_thread_state64_set_pc_fptr(t, pre);
    return (void *)(uintptr_t)t.__opaque_pc;
}
/// 同上，但用 LR 的鉴别符 "lr"
static void *odbgSignLR(uint64_t raw) {
    void *pre = ptrauth_sign_unauthenticated((void *)(uintptr_t)raw, ptrauth_key_function_pointer, 0);
    arm_thread_state64_t t; memset(&t, 0, sizeof(t));
    __darwin_arm_thread_state64_set_lr_fptr(t, pre);
    return (void *)(uintptr_t)t.__opaque_lr;
}
/// dlopen 用：先当作函数指针签一次，再走访问器转成内核要的 process_independent_code + "pc"
static void *odbgPreSignedPC(uint64_t raw) {
    return ptrauth_sign_unauthenticated((void *)(uintptr_t)raw, ptrauth_key_function_pointer, 0);
}
static void *odbgPreSignedLR(uint64_t raw) {
    return ptrauth_sign_unauthenticated((void *)(uintptr_t)raw, ptrauth_key_function_pointer, 0);
}
/// SP 用 process_independent_data + "sp"
static void *odbgSignSP(uint64_t raw) {
    return ptrauth_sign_unauthenticated((void *)(uintptr_t)raw, ptrauth_key_process_independent_data,
                                        ptrauth_string_discriminator("sp"));
}
#endif

// ── 手写 arm64 stub 需要的一小把指令发射器（偏移 0，配合 add 用）────────────────
static void emitInsn(uint32_t *p, int *n, uint32_t insn) { if (*n < 1000) p[(*n)++] = insn; }
static void emitAddImm(uint32_t *p, int *n, int rd, int rn, uint32_t imm) {
    emitInsn(p, n, 0x91000000u | ((imm & 0xFFFu) << 10) | ((uint32_t)rn << 5) | (uint32_t)rd);
}
static void __attribute__((unused)) emitLdr32(uint32_t *p, int *n, int rt, int rn) { emitInsn(p, n, 0xB9400000u | ((uint32_t)rn << 5) | (uint32_t)rt); }
static void emitStr32(uint32_t *p, int *n, int rt, int rn) { emitInsn(p, n, 0xB9000000u | ((uint32_t)rn << 5) | (uint32_t)rt); }
static void emitStr64(uint32_t *p, int *n, int rt, int rn) { emitInsn(p, n, 0xF9000000u | ((uint32_t)rn << 5) | (uint32_t)rt); }
static void emitBlr(uint32_t *p, int *n, int rn) { emitInsn(p, n, 0xD63F0000u | ((uint32_t)rn << 5)); }
static void emitRet(uint32_t *p, int *n) { emitInsn(p, n, 0xD65F03C0u); }
// PACIZA <Xd>：给函数指针签名。arm64e 的 _pthread_start 用认证分支调回调，不签就当场 auth-trap。
static void emitPaciza(uint32_t *p, int *n, int rd) { emitInsn(p, n, 0xDAC123E0u | (uint32_t)rd); }
// b <label>：imm26 相对当前这条指令
static void emitBLabel(uint32_t *p, int *n, int targetIdx) {
    emitInsn(p, n, 0x14000000u | ((uint32_t)(targetIdx - *n) & 0x03FFFFFFu));
}
// 回填 emitMov64 占位（占位时还不知道 routine 的地址）
static void patchMov64(uint32_t *p, int idx, int rd, uint64_t val) {
    p[idx]     = 0xD2800000u | ((uint32_t)(val & 0xFFFF) << 5) | (uint32_t)rd;
    p[idx + 1] = 0xF2A00000u | ((uint32_t)((val >> 16) & 0xFFFF) << 5) | (uint32_t)rd;
    p[idx + 2] = 0xF2C00000u | ((uint32_t)((val >> 32) & 0xFFFF) << 5) | (uint32_t)rd;
    p[idx + 3] = 0xF2E00000u | ((uint32_t)((val >> 48) & 0xFFFF) << 5) | (uint32_t)rd;
}

// ─────────────────────────────────────────────────────────────────────────────
// frida 式注入：新线程 + 「写 R/W 再翻 R+X」的代码页 + stub 里 pthread_create
//
// 依据 frida 16.1.4（源码 /Users/tanyou/Desktop/1study_ios_tweak/000-frida/frida）：
//   frida-core/src/darwin/frida-helper-backend-glue.m:2277-2360  payload 分配 / 代码页翻 R+X / 数据页
//                                                :2390-2430  thread_create + set_state
//                                                :4816-4927  arm64 mach stub（paciza 回调 + mach_msg_receive 停车）
//                                                :4930-5010  arm64 pthread stub（dlopen/dlsym + 收尾）
// 相对我们旧的「劫持线程」法，四件事被改掉了：
//   1) 不等用户态窗口：thread_create 直接在目标里造一个新线程（空闲 SpringBoard 也能立刻起来）；
//   2) 匿名 RWX 页取指必崩 ⇒ 严格「mach_vm_allocate 可写 → 写 stub → mach_vm_protect(R|X)」；
//      （frida 的 gum/gummemory.c:207 在 Darwin arm64 上把 rwx 支持写死成 NONE，就是这条约束）
//   3) 裸 mach 线程没有 pthread/TLS ⇒ 它只允许调 mach 层 API（task_self_trap /
//      thread_self_trap / mach_port_allocate / pthread_create），真正的 dlopen 交给
//      pthread_create 出来的正规 pthread 干；
//   4) arm64e 的 _pthread_start 用认证分支调回调 ⇒ 传回调前必须 paciza（0xdac123e2）。
//
// 数据流：裸线程写 canary ⇒ 证明代码页真的执行了；pthread 写 dlopen 返回值与「收尾完成」标记；
//         daemon 轮询数据页 + 远端镜像表判定成功，失败时能区分「没跑到／pthread 没造出来／dlopen 失败」。
// ─────────────────────────────────────────────────────────────────────────────
#define ODBG_PAYLOAD_CODE_OFF   0x0
#define ODBG_PAYLOAD_DATA_OFF   0x4000
#define ODBG_PAYLOAD_STACK_OFF  0x8000
#define ODBG_PAYLOAD_STACK_SIZE 0x40000
#define ODBG_PAYLOAD_SIZE       (ODBG_PAYLOAD_STACK_OFF + ODBG_PAYLOAD_STACK_SIZE)

#define ODBG_D_TASK         0     // uint32  task_self_trap() 返回
#define ODBG_D_MACH_THREAD  4     // uint32  thread_self_trap() 返回（裸线程自己，收尾时终止它）
#define ODBG_D_RECV_PORT    8     // uint32  mach_port_allocate 的接收端口（裸线程在这上面等一个永不到来的消息）
#define ODBG_D_PTHREAD_RC   12    // uint32  pthread_create 返回值
#define ODBG_D_ENTRY_HIT    16    // uint64  canary：代码页第一件事就写它
#define ODBG_D_DLOPEN_RC    24    // uint64  dlopen 返回值（0 = 失败）
#define ODBG_D_ROUTINE_DONE 32    // uint64  收尾完成标记（0xC0FFEE）
#define ODBG_D_THREAD_SLOT  40    // uint64  pthread_create 输出的 pthread_t
#define ODBG_D_MSG          48    // mach_msg_empty_rcv_t（32 字节）
#define ODBG_D_MSGH_LOCAL_PORT (ODBG_D_MSG + 12)   // mach_msg_header_t 里 msgh_local_port 的偏移
#define ODBG_D_DLERR_PTR    88    // uint64 dlerror() 返回的错误字符串指针（dlopen 失败时用）
#define ODBG_D_PATH         96
#define ODBG_DATA_BYTES     (ODBG_D_PATH + 1024)

/// 返回 KERN_SUCCESS = 注入成功；*executed = 代码页是否真的跑起来过（决定要不要退回劫持法）
static uint64_t odbgStatePC(arm_thread_state64_t *st);
static BOOL odbgParkedInPause(arm_thread_state64_t *st, uint64_t pauseAddr);
static kern_return_t remoteNewThread2(task_t task, uint64_t pcAddr, uint64_t lrAddr,
                                      uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
                                      uint64_t *stackTopOut, thread_act_t *outTh, NSString **err);

/// 远端符号地址的**字节校验**：远端前 n 字节必须和本进程同名符号一致。
/// 共享缓存里的代码在进程间逐字节相同，所以「偏移算错了」这种情况会被它挡住——
/// 真机教训：把 dlopen 的偏移照搬到 dlerror 上时地址错了，目标一调用 dlerror 就整进程被杀。
__attribute__((unused)) static BOOL odbgSymbolBytesMatch(task_t task, uint64_t cand, uint64_t localAddr, size_t n) {
    if (task == MACH_PORT_NULL || !cand || !localAddr || n == 0 || n > 64) return NO;
    uint8_t lb[64], rb[64];
    // 两边都用 vmRead 读，避免直接解引用（dlsym 返回的指针在 arm64e 上带签名/PAC 位，
    // 直接 memcpy 会 SIGSEGV —— 1.0.138 就是这么把 daemon 打成崩溃重启循环的）
    if (!vmRead(mach_task_self(), stripPAC(localAddr), lb, n)) return NO;
    if (!vmRead(task, cand, rb, n)) return NO;
    return memcmp(lb, rb, n) == 0;
}

/// 生成 frida 式注入 stub（返回指令条数）：
///   ① 裸 mach 线程段：写 canary → pthread_create_from_mach_thread(&slot, paciza(routine), arg)
///      → 记返回值 → 在 pause 里死循环停车（裸线程交给 pthread 收尾，自己不再返回）
///   ② pthread 回调段（routine）：dlopen(path, RTLD_NOW|RTLD_GLOBAL) → 记 rc/完成标记 → pthread_exit
/// 注意：所有地址都是**目标里**的绝对地址，必须等代码页/数据页分配完才能生成。
static int odbgBuildFridaStub(uint32_t *code, uint64_t codeAddr, uint64_t dataAddr, uint32_t canary,
                              uint64_t pthreadCreAddr, uint64_t dlopenAddr, uint64_t pthreadExitAddr,
                              uint64_t dlerrorAddr, uint64_t pauseAddr,
                              uint64_t *routineAddrOut, uint64_t *parkAddrOut) {
    int cn = 0;
    // ① 裸 mach 线程的 stub：canary → pthread_create_from_mach_thread(&slot, paciza(routine), arg)
    //    → 记返回值 → 在 pause 里死循环停车（裸线程交给 pthread 收尾，自己不再返回）
    emitMov64(code, &cn, 19, dataAddr);
    emitMov64(code, &cn, 0, (uint64_t)canary);
    emitAddImm(code, &cn, 1, 19, ODBG_D_ENTRY_HIT); emitStr64(code, &cn, 0, 1);
    emitAddImm(code, &cn, 0, 19, ODBG_D_THREAD_SLOT);   // x0 = &slot（pthread_t 输出）
    emitMov64(code, &cn, 1, 0);                         // x1 = attr = NULL（★ frida 也是这么传的）
    int routineConstIdx = cn;
    emitMov64(code, &cn, 2, 0);                         // x2 = routine（占位，稍后回填）
    emitPaciza(code, &cn, 2);                           // ★ arm64e：回调指针必须签名（C 函数指针 = paciza）
    emitMov64(code, &cn, 3, dataAddr);                  // x3 = arg（回调参数，本回调用不到）
    emitMov64(code, &cn, 16, pthreadCreAddr); emitBlr(code, &cn, 16);
    emitAddImm(code, &cn, 1, 19, ODBG_D_PTHREAD_RC); emitStr32(code, &cn, 0, 1);
    int parkIdx = cn;                                   // 停车：while (1) pause();
    emitMov64(code, &cn, 16, pauseAddr); emitBlr(code, &cn, 16);
    emitBLabel(code, &cn, parkIdx);
    // ② 正规 pthread 上的 stub：dlopen(path, RTLD_NOW|RTLD_GLOBAL) → 记 rc / 完成标记 → pthread_exit
    int routineIdx = cn;
    emitMov64(code, &cn, 19, dataAddr);
    emitAddImm(code, &cn, 0, 19, ODBG_D_PATH);
    emitMov64(code, &cn, 1, 3);
    emitMov64(code, &cn, 16, dlopenAddr); emitBlr(code, &cn, 16);
    emitAddImm(code, &cn, 1, 19, ODBG_D_DLOPEN_RC); emitStr64(code, &cn, 0, 1);
    if (dlerrorAddr) {                                  // 成功时 dlerror() 返回 NULL，顺手记下 dyld 的报错文本
        emitAddImm(code, &cn, 1, 19, ODBG_D_DLERR_PTR);
        emitMov64(code, &cn, 16, dlerrorAddr); emitBlr(code, &cn, 16);
        emitStr64(code, &cn, 0, 1);
    }
    emitMov64(code, &cn, 0, 0xC0FFEEULL);
    emitAddImm(code, &cn, 1, 19, ODBG_D_ROUTINE_DONE); emitStr64(code, &cn, 0, 1);
    if (pthreadExitAddr) { emitMov64(code, &cn, 16, pthreadExitAddr); emitBlr(code, &cn, 16); }
    emitRet(code, &cn);
    uint64_t routineAddr = codeAddr + (uint64_t)routineIdx * 4;
    uint64_t parkAddr    = codeAddr + (uint64_t)parkIdx * 4;
    patchMov64(code, routineConstIdx, 2, routineAddr);
    *routineAddrOut = routineAddr;
    *parkAddrOut = parkAddr;
    return cn;
}

static kern_return_t remoteDlopenFrida(task_t task, odbg_image_t *imgs, int n, const char *path,
                                      NSMutableString *log, BOOL *executed) {
    *executed = NO;
    uint64_t dlopenAddr    = remoteSymbol(task, imgs, n, "libdyld.dylib", "dlopen");
    // ★ 关键教训（真机实测）：裸 mach 线程上直接调 pthread_create 会把靶子进程搞死。
    //   frida 的解法是优先用 Apple 私有 SPI pthread_create_from_mach_thread（它能从裸线程安全建 pthread）。
    uint64_t pthreadCreAddr  = remoteSymbol(task, imgs, n, "libsystem_pthread.dylib", "pthread_create_from_mach_thread");
    uint64_t pthreadExitAddr = remoteSymbol(task, imgs, n, "libsystem_pthread.dylib", "pthread_exit");
    // ★ 真机教训（1.0.137/1.0.139 两次）：在目标我们新建的 pthread 上调用 dlerror() 会把**整个进程**打死
    //   （收尾标记写不出、canary 已写、目标 5 秒内换 pid）。地址校验是通过的，所以问题不是偏移，而是
    //   dlerror 依赖 dyld 自己的每线程错误状态——我们这条线程不是 dyld 初始化出来的。
    //   ⇒ 注入流程彻底不碰 dlerror（失败时只看 dlopen 返回值 + 镜像表）。
    uint64_t dlerrorAddr     = 0;
    uint64_t pauseAddr       = remoteSymbol(task, imgs, n, "libsystem_c.dylib", "pause");
    const uint32_t canary = 0x0DB60001u;
    if (!dlopenAddr || !pthreadCreAddr || !pauseAddr) {
        [log appendFormat:@"[frida] 远端符号不全（dlopen=0x%llx pthread_create_from_mach_thread=0x%llx pause=0x%llx）⇒ 退回劫持法\n",
                          dlopenAddr, pthreadCreAddr, pauseAddr];
        return KERN_FAILURE;
    }
    // ★ 布局教训（真机实测）：代码页/数据页/栈 **必须各自单独分配**。
    //   一整块大分配（code+0x0 / data+0x4000 / stack+0x8000 同处一块）在真机上必死：
    //   把大块里的第一页单独翻成 R|X 之后，目标线程一取指就整进程被杀（同尺寸的独立页则完全正常）。
    mach_vm_address_t codePage = 0, dataPage = 0;
    kern_return_t kr = mach_vm_allocate(task, &codePage, 0x4000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[frida] 代码页分配失败：%s\n", mach_error_string(kr)];
        return kr;
    }
    kr = mach_vm_allocate(task, &dataPage, 0x4000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[frida] 数据页分配失败：%s\n", mach_error_string(kr)];
        return kr;
    }
    uint64_t codeAddr = (uint64_t)codePage;
    uint64_t dataAddr = (uint64_t)dataPage;
    uint64_t stackTop = 0;

    uint32_t code[1024];
    uint64_t routineAddr = 0, parkAddr = 0;
    int cn = odbgBuildFridaStub(code, codeAddr, dataAddr, canary, pthreadCreAddr, dlopenAddr,
                                pthreadExitAddr, dlerrorAddr, pauseAddr, &routineAddr, &parkAddr);

    // 数据页：路径字符串 + 各槽位清零（canary 槽、pthread_t 槽、返回值槽都由 stub 回写）
    uint8_t data[ODBG_DATA_BYTES];
    memset(data, 0, sizeof(data));
    uint32_t msgSize = 32;                                  // 遗留字段：别的路径用，保留无害
    memcpy(data + ODBG_D_MSG + 4, &msgSize, 4);
    size_t pathLen = strlen(path) + 1;
    if (pathLen > 1000) pathLen = 1000;
    memcpy(data + ODBG_D_PATH, path, pathLen);
    mach_vm_write(task, dataAddr, (vm_offset_t)data, (mach_msg_type_number_t)sizeof(data));
    mach_vm_write(task, codeAddr, (vm_offset_t)code, (mach_msg_type_number_t)(cn * 4));
    // ★ 写 R/W → 翻成 R+X（绝不能是 RWX）；真机 `!rx` 已证实目标里这种页可以取指
    kr = mach_vm_protect(task, codeAddr, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[frida] 代码页翻 R|X 失败：%s ⇒ 退回劫持法（什么都没执行过，目标没被碰过）\n",
                          mach_error_string(kr)];
        return KERN_FAILURE;
    }
    [log appendFormat:@"[frida] code@0x%llx data@0x%llx（stub %d 字节，已翻 R|X；"
                      @"pthread_create_from_mach_thread@0x%llx）\n",
                      codeAddr, dataAddr, cn * 4, pthreadCreAddr];

    thread_act_t th = MACH_PORT_NULL;
    NSString *err = nil;
    kr = remoteNewThread2(task, codeAddr, parkAddr, 0, dataAddr, 0, 0, &stackTop, &th, &err);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[frida] 建线程失败：%s %@ ⇒ 退回劫持法\n", mach_error_string(kr), err ?: @""];
        return kr;
    }
    [log appendFormat:@"[frida] 裸线程已起（PC=代码页入口 0x%llx / SP=0x%llx / LR=停车点 0x%llx）\n",
                      codeAddr, stackTop, parkAddr];

    const char *leaf = strrchr(path, '/');
    leaf = leaf ? leaf + 1 : path;
    BOOL injected = NO;
    uint64_t canarySeen = 0, dlopenRc = 0, done = 0, slot = 0;
    uint32_t pthreadRc = 0;
    for (int k = 0; k < 100 && !injected; k++) {           // 最多 ~10 秒
        usleep(k < 6 ? 5000 : 100 * 1000);                 // ★ 头几轮 5ms 密集采样：要抓「还没跑就死」的瞬间
        BOOL canaryOk = vmRead(task, dataAddr + ODBG_D_ENTRY_HIT, &canarySeen, 8);
        vmRead(task, dataAddr + ODBG_D_PTHREAD_RC, &pthreadRc, 4);
        vmRead(task, dataAddr + ODBG_D_DLOPEN_RC, &dlopenRc, 8);
        vmRead(task, dataAddr + ODBG_D_ROUTINE_DONE, &done, 8);
        vmRead(task, dataAddr + ODBG_D_THREAD_SLOT, &slot, 8);
        if (k < 6) {
            arm_thread_state64_t cst; memset(&cst, 0, sizeof(cst));
            mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            kern_return_t gk = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&cst, &sc);
            [log appendFormat:@"[frida] #%d canary=%@(0x%llx) 数据页%@ 线程=%@\n", k,
                              canarySeen == (uint64_t)canary ? @"✓" : @"✗", canarySeen,
                              canaryOk ? @"可读" : @"读不到",
                              gk == KERN_SUCCESS ? [NSString stringWithFormat:@"活着 PC=0x%llx", odbgStatePC(&cst)]
                                                 : [NSString stringWithFormat:@"死(%s)", mach_error_string(gk)]];
        }
        odbg_image_t *i2 = NULL;
        int n2 = remoteImages(task, &i2);
        for (int j = 0; j < n2; j++) if (strstr(i2[j].path, leaf)) { injected = YES; break; }
        if (i2) free(i2);
        if (!injected && done == 0xC0FFEEULL) break;       // 回调已收尾但镜像没出现 ⇒ dlopen 失败
    }
    if (canarySeen == (uint64_t)canary) *executed = YES;
    [log appendFormat:@"[frida] canary=%s pthread_create_from_mach_thread=返回 %u pthread_t=0x%llx dlopen=0x%llx 收尾=%@\n",
                      *executed ? "✓ 代码页已执行" : "✗ 没出现",
                      pthreadRc, slot, dlopenRc, done == 0xC0FFEEULL ? @"✓ 已完成" : @"✗ 未完成"];
    if (!*executed)
        [log appendString:@"[frida] ⚠️ 新线程压根没跑到代码页 ⇒ 与 dlopen 无关（看代码页/R+X 或 set_state）\n"];
    else if (pthreadRc != 0)
        [log appendFormat:@"[frida] ⚠️ pthread_create_from_mach_thread 返回 %u ⇒ 没造出 pthread\n", pthreadRc];
    else if (!injected && done == 0xC0FFEEULL && dlopenRc == 0) {
        [log appendString:@"[frida] dlopen 返回 0（失败）：路径不对 / 签名不被接受 / 依赖不可加载\n"];
        uint64_t errPtr = 0;
        if (vmRead(task, dataAddr + ODBG_D_DLERR_PTR, &errPtr, 8) && errPtr) {
            char ebuf[512]; memset(ebuf, 0, sizeof(ebuf));
            if (vmRead(task, errPtr, ebuf, sizeof(ebuf) - 1))
                [log appendFormat:@"[frida] dyld 原话：%s\n", ebuf];
        } else {
            [log appendString:@"[frida] （dyld 没给出错误文本）\n"];
        }
    }
    // ★ 绝不能 thread_terminate 目标里的线程：真机实测会让本 daemon 被内核当场杀掉（EXC_GUARD）
    mach_port_deallocate(mach_task_self(), th);
    if (injected) {
        [log appendString:@"[frida] 注入成功（pthread_create_from_mach_thread 法，无需等用户态窗口）✅\n"];
        return KERN_SUCCESS;
    }
    return KERN_FAILURE;
}

/// ★★ 「直接调目标自己的 dlopen」法（真机实测：匿名 R+X 代码页取指必被杀，此法不用代码页）：
///   thread_create 出裸线程后，x0..x7 完全由我们掌控 ⇒ 直接把 PC 设成目标镜像里**已签名、已在跑**的
///   dlopen（libdyld.dylib），x0 = 我们写进目标数据页的路径字符串，x1 = RTLD 标志，LR = 目标的 pause
///   （dlopen 返回后停在那儿，不会落回 0）。整条链只调「目标已有的代码」，没有任何自造可执行页。
///   与 frida 的区别：frida 会先造正规 pthread 再 dlopen（怕裸线程没有 TLS）；这里先直接试，
///   成了就省掉整个 stub/pthread 阶段。风险：dlopen 或被加载库的初始化若碰线程 TLS，线程会崩
///   （整个靶子进程一起死）⇒ 先在 !spawn 出来的牺牲进程上验证，别拿 SpringBoard 试。
static kern_return_t remoteDlopenDirect(task_t task, odbg_image_t *imgs, int n, const char *path,
                                       NSMutableString *log, BOOL *executed) {
    *executed = NO;
    uint64_t dlopenAddr = remoteSymbol(task, imgs, n, "libdyld.dylib", "dlopen");
    uint64_t pauseAddr  = remoteSymbol(task, imgs, n, "libsystem_c.dylib", "pause");
    if (!dlopenAddr || !pauseAddr) {
        [log appendFormat:@"[direct] 远端符号缺失：dlopen=0x%llx pause=0x%llx\n", dlopenAddr, pauseAddr];
        return KERN_FAILURE;
    }
    mach_vm_address_t dataAddr = 0;
    kern_return_t kr = mach_vm_allocate(task, &dataAddr, 0x4000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[direct] 路径页分配失败：%s\n", mach_error_string(kr)];
        return kr;
    }
    size_t plen = strlen(path) + 1;
    if (plen > 4000) plen = 4000;
    kr = mach_vm_write(task, dataAddr, (vm_offset_t)path, (mach_msg_type_number_t)plen);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[direct] 写路径失败：%s\n", mach_error_string(kr)];
        return kr;
    }
    mach_vm_address_t stack = 0;
    kr = mach_vm_allocate(task, &stack, 0x40000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[direct] 栈分配失败：%s\n", mach_error_string(kr)];
        return kr;
    }
    uint64_t stackTop = ((uint64_t)stack + 0x40000 - 16) & ~0xFULL;

    thread_act_t th = MACH_PORT_NULL;
    kr = thread_create(task, &th);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[direct] thread_create 失败：%s\n", mach_error_string(kr)];
        return kr;
    }
    arm_thread_state64_t ts; memset(&ts, 0, sizeof(ts));
#if __has_feature(ptrauth_calls)
    __darwin_arm_thread_state64_set_pc_fptr(ts, odbgPreSignedPC(dlopenAddr));
    __darwin_arm_thread_state64_set_lr_fptr(ts, odbgPreSignedLR(pauseAddr));
    __darwin_arm_thread_state64_set_sp(ts, (void *)(uintptr_t)stackTop);
#else
    ts.__pc = dlopenAddr; ts.__lr = pauseAddr; ts.__sp = stackTop;
#endif
    ts.__x[0] = (uint64_t)dataAddr;      // dlopen 的第 1 参：路径
    ts.__x[1] = 3;                       // dlopen 的第 2 参：RTLD_LAZY|RTLD_NOW
    kern_return_t sk = thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&ts, ARM_THREAD_STATE64_COUNT);
    if (sk != KERN_SUCCESS) {
        [log appendFormat:@"[direct] thread_set_state 失败：%s\n", mach_error_string(sk)];
        thread_terminate(th);
        mach_port_deallocate(mach_task_self(), th);
        return KERN_FAILURE;
    }
    thread_resume(th);
    [log appendFormat:@"[direct] PC=dlopen@0x%llx x0=0x%llx(\"%s\") x1=3 LR=pause@0x%llx SP=0x%llx\n",
                      dlopenAddr, (uint64_t)dataAddr, path, pauseAddr, stackTop];

    const char *leaf = strrchr(path, '/');
    leaf = leaf ? leaf + 1 : path;
    BOOL injected = NO;
    for (int k = 0; k < 120 && !injected; k++) {
        usleep(100 * 1000);
        odbg_image_t *i2 = NULL;
        int n2 = remoteImages(task, &i2);
        for (int j = 0; j < n2; j++) if (strstr(i2[j].path, leaf)) { injected = YES; break; }
        if (i2) free(i2);
        if (!injected && (k == 20 || k == 60)) {       // 诊断：2 秒 / 6 秒时看一眼线程 PC（LR 在 pause 里=已返回）
            arm_thread_state64_t cur; memset(&cur, 0, sizeof(cur));
            mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            kern_return_t gk = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&cur, &sc);
            if (gk == KERN_SUCCESS) {
                uint64_t pc = odbgStatePC(&cur);
                BOOL parked = odbgParkedInPause(&cur, pauseAddr);
                [log appendFormat:@"[direct] %d ms 后线程 PC=0x%llx LR=0x%llx（dlopen=0x%llx pause=0x%llx %@）\n",
                                  (k + 1) * 100, pc,
                                  (uint64_t)(uintptr_t)__darwin_arm_thread_state64_get_lr(cur),
                                  dlopenAddr, pauseAddr,
                                  (parked ? @"LR 在 pause 里 ⇒ dlopen 已返回" : @"还没返回 ⇒ dlopen 里/线程已死")];
            } else {
                [log appendFormat:@"[direct] %d ms 后 thread_get_state=%s ⇒ 线程已死（多半 TLS/异常）\n",
                                  (k + 1) * 100, mach_error_string(gk)];
                break;
            }
        }
    }
    if (injected) {
        *executed = YES;
        [log appendString:@"[direct] 注入成功（新线程直接调目标自己的 dlopen）✅\n"];
    } else {
        [log appendString:@"[direct] ❌ 镜像表里没出现该 dylib\n"];
    }
    // 不能对 target 里的新线程调 thread_terminate：实测 daemon 会被内核直接杀掉（见 !call 注释）
    mach_port_deallocate(mach_task_self(), th);
    return injected ? KERN_SUCCESS : KERN_FAILURE;
}

#pragma mark - 诊断：新线程直调目标里的任意符号（!call）
/// 在目标进程分配一页并写入字符串，返回远端地址（失败返回 0）
static uint64_t remoteWriteString(task_t task, const char *str, NSString **err) {
    mach_vm_address_t addr = 0;
    kern_return_t kr = mach_vm_allocate(task, &addr, 0x4000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        if (err) *err = [NSString stringWithFormat:@"分配字符串页失败：%s", mach_error_string(kr)];
        return 0;
    }
    size_t len = strlen(str) + 1;
    if (len > 4000) len = 4000;
    kr = mach_vm_write(task, addr, (vm_offset_t)str, (mach_msg_type_number_t)len);
    if (kr != KERN_SUCCESS) {
        if (err) *err = [NSString stringWithFormat:@"写字符串失败：%s", mach_error_string(kr)];
        return 0;
    }
    return (uint64_t)addr;
}

/// 在目标进程造一个新线程：PC/LR 按 PAC 约定签名，x0/x1 由调用者给定，SP 用新分配的栈
static kern_return_t remoteNewThread2(task_t task, uint64_t pcAddr, uint64_t lrAddr,
                                      uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
                                      uint64_t *stackTopOut, thread_act_t *outTh, NSString **err) {
    mach_vm_address_t stack = 0;
    kern_return_t kr = mach_vm_allocate(task, &stack, 0x40000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        if (err) *err = [NSString stringWithFormat:@"分配栈失败：%s", mach_error_string(kr)];
        return kr;
    }
    uint64_t stackTop = ((uint64_t)stack + 0x40000 - 16) & ~0xFULL;
    thread_act_t th = MACH_PORT_NULL;
    kr = thread_create(task, &th);
    if (kr != KERN_SUCCESS) {
        if (err) *err = [NSString stringWithFormat:@"thread_create 失败：%s", mach_error_string(kr)];
        return kr;
    }
    arm_thread_state64_t ts; memset(&ts, 0, sizeof(ts));
#if __has_feature(ptrauth_calls)
    __darwin_arm_thread_state64_set_pc_fptr(ts, odbgPreSignedPC(pcAddr));
    __darwin_arm_thread_state64_set_lr_fptr(ts, odbgPreSignedLR(lrAddr));
    __darwin_arm_thread_state64_set_sp(ts, (void *)(uintptr_t)stackTop);
#else
    ts.__pc = pcAddr; ts.__lr = lrAddr; ts.__sp = stackTop;
#endif
    ts.__x[0] = x0;
    ts.__x[1] = x1;
    ts.__x[2] = x2;
    ts.__x[3] = x3;
    kr = thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&ts, ARM_THREAD_STATE64_COUNT);
    if (kr != KERN_SUCCESS) {
        if (err) *err = [NSString stringWithFormat:@"thread_set_state 失败：%s", mach_error_string(kr)];
        thread_terminate(th);
        mach_port_deallocate(mach_task_self(), th);
        return kr;
    }
    thread_resume(th);
    if (stackTopOut) *stackTopOut = stackTop;
    *outTh = th;
    return KERN_SUCCESS;
}

static kern_return_t remoteNewThread(task_t task, uint64_t pcAddr, uint64_t lrAddr,
                                     uint64_t x0, uint64_t x1, uint64_t *stackTopOut,
                                     thread_act_t *outTh, NSString **err) {
    return remoteNewThread2(task, pcAddr, lrAddr, x0, x1, 0, 0, stackTopOut, outTh, err);
}

/// 「返回值落到 pause」的判定：线程跑完我们的调用后停在 pause 内部时，PC 落在 libsystem_kernel 的
/// 系统调用桩上（不在 pause 自己那段），只有 LR 还在 pause 体内（实测 LR = pause+0x2C）⇒ 用 LR 判断。
static BOOL odbgParkedInPause(arm_thread_state64_t *st, uint64_t pauseAddr) {
    uint64_t lr = (uint64_t)(uintptr_t)__darwin_arm_thread_state64_get_lr(*st);
    return (lr >= pauseAddr && lr < pauseAddr + 0x400);
}

static uint64_t odbgStatePC(arm_thread_state64_t *st) {
#if __has_feature(ptrauth_calls) && defined(__LP64__)
    return (uint64_t)(uintptr_t)__darwin_arm_thread_state64_get_pc(*st);   // 官方访问器，跨进程 PAC 也能还原
#else
    return (uint64_t)(uintptr_t)st->__pc;
#endif
}

/// ★★ 「借目标自己的 pthread_create + 目标自己的 dlopen」法（完全不写代码页，也不需要用户态窗口）：
///   裸线程（寄存器齐全）调 pthread_create(&slot, NULL, dlopen, 路径) —— 新线程是**正规 pthread**（libpthread
///   会建好 TLS、栈、pthread_t），它调用 dlopen(路径, x1 残留值)；dlopen 返回后 pthread 正常退出。
///   风险：_pthread_start 调 start_routine 时只保证 x0=参数，x1（dlopen 的 mode）是残留值 ⇒ 可能被当成 RTLD_NOLOAD。
static kern_return_t remoteDlopenPthread(task_t task, odbg_image_t *imgs, int n, const char *path,
                                         NSMutableString *log, BOOL *executed) {
    *executed = NO;
    uint64_t pcreate = remoteSymbol(task, imgs, n, "libsystem_pthread.dylib", "pthread_create");
    uint64_t dlopenAddr = remoteSymbol(task, imgs, n, "libdyld.dylib", "dlopen");
    uint64_t pauseAddr  = remoteSymbol(task, imgs, n, "libsystem_c.dylib", "pause");
    if (!pcreate || !dlopenAddr || !pauseAddr) {
        [log appendFormat:@"[pth] 远端符号缺失：pthread_create=0x%llx dlopen=0x%llx pause=0x%llx\n",
                          pcreate, dlopenAddr, pauseAddr];
        return KERN_FAILURE;
    }
    mach_vm_address_t data = 0;
    kern_return_t kr = mach_vm_allocate(task, &data, 0x4000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[pth] 数据页分配失败：%s\n", mach_error_string(kr)];
        return kr;
    }
    size_t plen = strlen(path) + 1;
    if (plen > 3000) plen = 3000;
    kr = mach_vm_write(task, data, (vm_offset_t)path, (mach_msg_type_number_t)plen);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[pth] 写路径失败：%s\n", mach_error_string(kr)];
        return kr;
    }
    uint64_t zero = 0;
    mach_vm_write(task, data + 0x1000 - 16, (vm_offset_t)&zero, (mach_msg_type_number_t)sizeof(zero));
    uint64_t slotAddr = data + 0x1000 - 16;           // pthread_t 输出槽

    thread_act_t th = MACH_PORT_NULL;
    uint64_t stackTop = 0;
    NSString *err = nil;
    kr = remoteNewThread2(task, pcreate, pauseAddr, slotAddr, 0, dlopenAddr, (uint64_t)data,
                          &stackTop, &th, &err);
    if (kr != KERN_SUCCESS) {
        [log appendFormat:@"[pth] %@\n", err];
        return kr;
    }
    [log appendFormat:@"[pth] 裸线程 PC=pthread_create@0x%llx x0=&slot(0x%llx) x1=0 x2=dlopen@0x%llx "
                      @"x3=路径(0x%llx) LR=pause@0x%llx SP=0x%llx\n",
                      pcreate, slotAddr, dlopenAddr, (uint64_t)data, pauseAddr, stackTop];

    const char *leaf = strrchr(path, '/');
    leaf = leaf ? leaf + 1 : path;
    BOOL injected = NO;
    for (int k = 0; k < 120 && !injected; k++) {
        usleep(100 * 1000);
        odbg_image_t *i2 = NULL;
        int n2 = remoteImages(task, &i2);
        for (int j = 0; j < n2; j++) if (strstr(i2[j].path, leaf)) { injected = YES; break; }
        if (i2) free(i2);
        if (!injected && (k == 4 || k == 19 || k == 59)) {
            uint64_t slotVal = 0;
            BOOL slotOK = vmRead(task, slotAddr, &slotVal, sizeof(slotVal));
            arm_thread_state64_t cur; memset(&cur, 0, sizeof(cur));
            mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            kern_return_t gk = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&cur, &sc);
            [log appendFormat:@"[pth] %d ms：pthread_t 槽=0x%llx(%@) 裸线程 %@\n",
                              (k + 1) * 100, slotVal, (slotOK && slotVal) ? @"已创建 ⇒ pthread_create 跑通" : @"还是 0",
                              gk == KERN_SUCCESS
                                ? [NSString stringWithFormat:@"活着 PC=0x%llx LR=0x%llx", odbgStatePC(&cur),
                                     (uint64_t)(uintptr_t)__darwin_arm_thread_state64_get_lr(cur)]
                                : [NSString stringWithFormat:@"已死(%s)", mach_error_string(gk)]];
        }
    }
    if (injected) {
        *executed = YES;
        [log appendString:@"[pth] ✅ 注入成功（裸线程 → 目标的 pthread_create → 目标的 dlopen）\n"];
    } else {
        [log appendString:@"[pth] ❌ 镜像表里没出现该 dylib\n"];
    }
    mach_port_deallocate(mach_task_self(), th);
    return injected ? KERN_SUCCESS : KERN_FAILURE;
}

static kern_return_t remoteDlopenHijack(task_t task, const char *path, NSString **detail) {
    kern_return_t kr = KERN_FAILURE;
    NSMutableString *log = [NSMutableString string];
    odbg_image_t *imgs = NULL;
    int n = remoteImages(task, &imgs);
    if (n <= 0) { *detail = @"读不到远端镜像表（remoteImages 失败）"; return KERN_FAILURE; }
    const char *leaf = strrchr(path, '/');
    leaf = leaf ? leaf + 1 : path;
    for (int i = 0; i < n; i++)
        if (strstr(imgs[i].path, leaf)) {
            [log appendFormat:@"该 dylib 已在镜像表里（%@），无需注入\n", @(imgs[i].path)];
            *detail = log;
            free(imgs);
            return KERN_SUCCESS;
        }
    // ★ 只执行已经签好名的代码（共享缓存里的 dlopen）。匿名页取指会被内核按 W^X/签名判死，
    //   所以这里不再写 shellcode，而是劫持目标已有线程、把 PC 换成 dlopen（用 SDK 访问器按 PAC 约定签名）。
    uint64_t dlopenAddr = remoteSymbol(task, imgs, n, "libdyld.dylib", "dlopen");
    uint64_t pauseAddr  = remoteSymbol(task, imgs, n, "libsystem_c.dylib", "pause");
    if (!dlopenAddr) { *detail = @"定位不到远端 dlopen"; free(imgs); return KERN_FAILURE; }
    // ★ LR 必须是「我们自己解析出来的裸地址」。绝不能把 thread_get_state 读回来的 __opaque_pc/__opaque_lr
    //   直接喂给 ptrauth_sign_unauthenticated：那是内核签过名的值（鉴别符是 "pc"/"lr"），
    //   而 sign_unauthenticated 内部会先按（function_pointer, 0）验证一次 ⇒ 鉴别符不匹配 ⇒ 命中
    //   auth-trap（autiza + brk #0xc470）⇒ daemon 当场 SIGBUS（真机实测 odebugd.m:579 崩过一次）。
    if (!pauseAddr) { *detail = @"定位不到远端 pause（LR 停车点）"; free(imgs); return KERN_FAILURE; }
    // ★ 只挑「PC 不在 libsystem_kernel 里」的 RUNNING 线程。实测教训：抓到 run_state=RUNNING 的线程 12、
    //   set_state 也 successful，但 origPC 落在 libsystem_kernel（syscall 桩 / svc 附近）⇒ 线程其实已经陷进
    //   内核，返回时走内核栈帧、忽略我们写进 pcb 的 PC ⇒ 注入无声失败（线程也没停在 pause）。所以要用 PC
    //   把「真的在用户态跑代码」的窗口和「在 syscall 桩上」的窗口区分开。上界用「比 skBase 大的最小镜像基址」近似。
    uint64_t skBase = 0, skEnd = 0;
    for (int i = 0; i < n; i++) if (strstr(imgs[i].path, "libsystem_kernel")) { skBase = imgs[i].loadAddr; break; }
    if (skBase) {
        uint64_t best = 0;
        for (int i = 0; i < n; i++) { uint64_t b = imgs[i].loadAddr; if (b > skBase && (best == 0 || b < best)) best = b; }
        skEnd = best ? best : skBase + 0x40000;
    }
    [log appendFormat:@"dlopen@0x%llx pause@0x%llx (imgs=%d) libsystem_kernel=0x%llx-0x%llx\n",
                     dlopenAddr, pauseAddr, n, skBase, skEnd];
    mach_vm_size_t psz = strlen(path) + 1;
    mach_vm_address_t pathAddr = 0;
    kr = mach_vm_allocate(task, &pathAddr, 0x4000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) { *detail = @"分配远端路径内存失败"; free(imgs); return kr; }
    mach_vm_write(task, pathAddr, (vm_offset_t)path, (mach_msg_type_number_t)psz);
    thread_act_array_t list = NULL;
    mach_msg_type_number_t cnt = 0;
    kr = task_threads(task, &list, &cnt);
    if (kr != KERN_SUCCESS || cnt == 0) { *detail = @"task_threads 失败"; free(imgs); return kr; }
    [log appendFormat:@"线程数=%d\n", cnt];
    // ★ 只挑「正在用户态运行」的线程（run_state=RUNNING）。阻塞在 syscall 里的线程（WAITING）
    //   改 PC 根本不会被执行（内核按 syscall 返回路径走），而且改它的状态容易把目标弄死。
    //   真机已验证：忙循环（始终用户态）的线程一劫持就成。
    // ★ 只挑「正在用户态运行」（run_state=RUNNING）的线程。实测结论：
    //   阻塞在 syscall 里的线程（WAITING）靠 thread_set_state 改 PC 是劫持不了的——内核按 syscall
    //   返回路径走，线程保存状态里的 PC 不生效；连 thread_abort() 把 syscall 打断也没用
    //   （真机实测 abort=(os/kern) successful，但写进去的 PC 依旧不执行、目标进程还活着）。
    //   所以改成「轮询等一个用户态窗口」：目标任何一瞬间在用户态执行（Darwin 通知、定时器、触摸、
    //   动画…）都能被我们抓住并劫持。SpringBoard 空闲时 17 个线程全 WAITING ⇒ 需要外部制造活动
    //   （点亮/触摸屏幕，或者等它自己的定时器醒来）。忙循环线程（始终用户态）则是立刻成功。
    for (mach_msg_type_number_t i = 0; i < cnt && i < 2048; i++) {
        thread_basic_info_data_t tbi; mach_msg_type_number_t tc = THREAD_BASIC_INFO_COUNT;
        int rs = -1;
        if (thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&tbi, &tc) == KERN_SUCCESS) rs = tbi.run_state;
        [log appendFormat:@"  线程 %d run_state=%d%@\n", i, rs, rs == TH_STATE_RUNNING ? @" (用户态运行中 ✓)" : @" (阻塞在 syscall)"];
    }
    BOOL injected = NO;
    uint32_t waited = 0;
    for (int round = 0; round < 3600 && !injected; round++) {     // 最多等 ~180 秒抓一个用户态窗口
        thread_act_array_t cur = NULL; mach_msg_type_number_t curn = 0;
        if (task_threads(task, &cur, &curn) != KERN_SUCCESS) break;
        int pick = -1;
        int nRun = 0, nStub = 0;
        for (mach_msg_type_number_t i = 0; i < curn; i++) {
            thread_basic_info_data_t tbi; mach_msg_type_number_t tc = THREAD_BASIC_INFO_COUNT;
            if (thread_info(cur[i], THREAD_BASIC_INFO, (thread_info_t)&tbi, &tc) != KERN_SUCCESS
                || tbi.run_state != TH_STATE_RUNNING) continue;
            nRun++;
            arm_thread_state64_t ts; memset(&ts, 0, sizeof(ts));
            mach_msg_type_number_t tsc = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(cur[i], ARM_THREAD_STATE64, (thread_state_t)&ts, &tsc) != KERN_SUCCESS) continue;
            uint64_t pc = stripPAC(ODBG_PC_FIELD(ts));
            if (skBase && pc >= skBase && pc < skEnd) { nStub++; continue; }   // 在 syscall 桩上 ⇒ 劫持无效
            pick = (int)i; break;
        }
        if (pick < 0) {
            if (round == 0 || round % 50 == 0)
                [log appendFormat:@"  等用户态窗口…（第 %d 轮，%u 个线程全阻塞 / RUNNING=%d 但都落在 syscall 桩上=%d）\n",
                                 round, curn, nRun, nStub];
            for (mach_msg_type_number_t i = 0; i < curn; i++) mach_port_deallocate(mach_task_self(), cur[i]);
            vm_deallocate(mach_task_self(), (vm_address_t)cur, curn * sizeof(thread_act_t));
            usleep(50 * 1000);      // 20Hz 采样：SB 的用户态窗口可能只有几十毫秒，采样越密越容易抓到
            waited++;
            continue;
        }
        [log appendFormat:@"★ 第 %d 轮抓到用户态线程 %d/%u\n", round, pick, curn];
        thread_act_t th = cur[pick];
        if (thread_suspend(th) != KERN_SUCCESS) {
            for (mach_msg_type_number_t i = 0; i < curn; i++) mach_port_deallocate(mach_task_self(), cur[i]);
            vm_deallocate(mach_task_self(), (vm_address_t)cur, curn * sizeof(thread_act_t));
            usleep(100 * 1000);
            continue;
        }
        arm_thread_state64_t st; memset(&st, 0, sizeof(st));
        mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, &sc) != KERN_SUCCESS) {
            thread_resume(th);
            for (mach_msg_type_number_t i = 0; i < curn; i++) mach_port_deallocate(mach_task_self(), cur[i]);
            vm_deallocate(mach_task_self(), (vm_address_t)cur, curn * sizeof(thread_act_t));
            usleep(100 * 1000);
            continue;
        }
#if __has_feature(ptrauth_calls)
        uint64_t origPC = (uint64_t)(uintptr_t)st.__opaque_pc;
#else
        uint64_t origPC = (uint64_t)(uintptr_t)st.__pc;
#endif
        arm_thread_state64_t ns = st;
        ns.__x[0] = (uint64_t)pathAddr;      // dlopen(path, ...)
        ns.__x[1] = 3;                        // RTLD_NOW|RTLD_GLOBAL
#if __has_feature(ptrauth_calls)
        __darwin_arm_thread_state64_set_pc_fptr(ns, odbgPreSignedPC(dlopenAddr));
        // LR 设成远端 pause：dlopen 返回后线程停在 libsystem_c 里（保持原栈原 TLS），我们轮询到结果
        // 之后再把保存的原状态写回，线程不丢；顺带能读一下它的 x0（dlopen 返回值）。
        __darwin_arm_thread_state64_set_lr_fptr(ns, odbgPreSignedLR(pauseAddr));
#else
        ns.__pc = dlopenAddr; ns.__lr = origPC;
#endif
        uint64_t parkedField = ODBG_PC_FIELD(ns);  // 我们写进去的 PC 字段形态（纯整数比较用，不做 PAC 运算）
        kern_return_t sk = thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&ns, ARM_THREAD_STATE64_COUNT);
        thread_resume(th);
        [log appendFormat:@"劫持线程 %d/%u set_state=%s origPC=0x%llx\n", pick, curn, mach_error_string(sk), origPC];
        for (int k = 0; k < 45 && !injected; k++) {   // 最多 ~9 秒：jb 里 dlopen 一个 dylib 可能很慢
            usleep(200 * 1000);
            odbg_image_t *i2 = NULL;
            int n2 = remoteImages(task, &i2);
            for (int j = 0; j < n2; j++)
                if (strstr(i2[j].path, leaf)) { injected = YES; break; }
            if (i2) free(i2);
        }
        if (injected) {
            arm_thread_state64_t now; memset(&now, 0, sizeof(now));
            mach_msg_type_number_t nc = ARM_THREAD_STATE64_COUNT;
            uint64_t ret = 0;
            if (thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&now, &nc) == KERN_SUCCESS)
                ret = (uint64_t)now.__x[0];
            [log appendFormat:@"✅ 线程 %d 成功 dlopen（x0≈dlopen 返回值=0x%llx）\n", pick, ret];
            // 把停在 pause 里的线程收回原处（dlopen 已经完成，线程不再丢）
            thread_suspend(th);
            thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, ARM_THREAD_STATE64_COUNT);
            thread_resume(th);
        } else {
            // 没跑起来 —— ★ 绝不能无条件恢复：如果线程此刻还在 dlopen 里，把状态改回去会把 dyld 锁
            //   带进死锁（后面所有 dlopen 都永远 WAITING：真机实测第二轮 2 个线程 run_state=3）。
            //   只在它明确停在 pause（dlopen 已正常返回）时才恢复。
            arm_thread_state64_t q; memset(&q, 0, sizeof(q));
            mach_msg_type_number_t qc = ARM_THREAD_STATE64_COUNT;
            BOOL atPause = NO, backInStub = NO;
            if (thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&q, &qc) == KERN_SUCCESS) {
                atPause = (ODBG_PC_FIELD(q) == parkedField);
                uint64_t qpc = stripPAC(ODBG_PC_FIELD(q));
                backInStub = (skBase && qpc >= skBase && qpc < skEnd);
            }
            if (atPause || backInStub) {
                // 已停在 pause（dlopen 正常返回）／PC 回到 syscall 桩（说明我们写的 PC 压根没生效）⇒ 都可以安全还原
                [log appendFormat:@"  线程 %d %@ ⇒ 还原状态，继续等下一个窗口\n", pick,
                                 atPause ? @"停在 pause" : @"PC 回到 syscall 桩（写入未生效）"];
                thread_suspend(th);
                thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, ARM_THREAD_STATE64_COUNT);
                thread_resume(th);
            } else {
                [log appendFormat:@"⚠️ 线程 %d 未停在 pause 且 PC 不在 syscall 桩（可能还在 dlopen 中），保持不动、不再试其它线程\n", pick];
                for (mach_msg_type_number_t i = 0; i < curn; i++) mach_port_deallocate(mach_task_self(), cur[i]);
                vm_deallocate(mach_task_self(), (vm_address_t)cur, curn * sizeof(thread_act_t));
                break;
            }
        }
        for (mach_msg_type_number_t i = 0; i < curn; i++) mach_port_deallocate(mach_task_self(), cur[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)cur, curn * sizeof(thread_act_t));
    }
    [log appendFormat:@"等待轮数=%u，注入%@\n", waited, injected ? @"成功 ✅" : @"未成功 ❌"];
    for (mach_msg_type_number_t i = 0; i < cnt; i++) mach_port_deallocate(mach_task_self(), list[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_act_t));
    free(imgs);
    if (injected) { kr = KERN_SUCCESS; [log appendString:@"注入成功\n"]; }
    else { kr = KERN_FAILURE; [log appendString:@"❌ 所有线程都没跑起来\n"]; }
    *detail = log;
    return kr;
}

/// 注入 dylib 的统一入口：先试 frida 式（新线程，立刻能起），只有「代码页压根没执行过」才退回劫持法。
/// 之所以加这道闸：frida 路径失败但代码页执行过 ⇒ dlopen 本身也救不回来，退回劫持法只会白等几十秒。
static kern_return_t remoteDlopen(task_t task, const char *path, NSString **detail) {
    NSMutableString *log = [NSMutableString string];
    odbg_image_t *imgs = NULL;
    int n = remoteImages(task, &imgs);
    if (n <= 0) { *detail = @"读不到远端镜像表（remoteImages 失败）"; if (imgs) free(imgs); return KERN_FAILURE; }
    const char *leaf = strrchr(path, '/');
    leaf = leaf ? leaf + 1 : path;
    for (int i = 0; i < n; i++)
        if (strstr(imgs[i].path, leaf)) {
            [log appendFormat:@"该 dylib 已在镜像表里（%@），无需注入\n", @(imgs[i].path)];
            *detail = log; free(imgs);
            return KERN_SUCCESS;
        }
    // ① frida 式：新线程 + R+X 代码页 + stub 里 pthread_create（不等用户态窗口）
    BOOL executed = NO;
    kern_return_t kr = remoteDlopenFrida(task, imgs, n, path, log, &executed);
    free(imgs);
    if (kr == KERN_SUCCESS) { *detail = log; return KERN_SUCCESS; }
    if (executed) {
        [log appendString:@"代码页已经执行过 ⇒ 问题在 stub/dlopen 本身，不再退回劫持法\n"];
        *detail = log;
        return KERN_FAILURE;
    }
    [log appendString:@"—— 退回劫持法（把已有线程的 PC 换成 dlopen、LR 停 pause）——\n"];
    NSString *d2 = nil;
    kern_return_t kr2 = remoteDlopenHijack(task, path, &d2);
    if (d2) [log appendFormat:@"%@\n", d2];
    *detail = log;
    return kr2;
}

/// !fd <pid|springboard|self> <dylib 路径>：只走 frida 式注入（新线程 + R+X 代码页），
/// 不退回劫持法。专给「牺牲进程」做验证用：万一代码页取指被判死，崩的只是靶子进程。
static NSString *cmdFridaDlopen(NSString *arg) {
    NSArray<NSString *> *parts = [trim(arg) componentsSeparatedByString:@" "];
    if (parts.count < 2) return @"用法: !fd <pid|springboard|self> <dylib 绝对路径>\n";
    NSString *who = parts[0];
    pid_t pid = [who.lowercaseString hasPrefix:@"spring"] ? pidOfName("SpringBoard")
              : ([who.lowercaseString isEqualToString:@"self"] ? getpid() : (pid_t)atoi(who.UTF8String));
    if (pid <= 0) return @"用法: !fd <pid|springboard|self> <dylib 绝对路径>\n";
    NSString *path = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" "];
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"task_for_pid(%d) 失败: %s\n", pid, mach_error_string(kr)];
    odbg_image_t *imgs = NULL;
    int n = remoteImages(task, &imgs);
    NSMutableString *log = [NSMutableString stringWithFormat:@"目标 pid=%d 路径=%@ 镜像数=%d\n", pid, path, n];
    BOOL executed = NO;
    kr = remoteDlopenFrida(task, imgs, n, path.UTF8String, log, &executed);
    if (imgs) free(imgs);
    mach_port_deallocate(mach_task_self(), task);
    [log appendFormat:@"结果：%@（代码页执行过=%d）\n", kr == KERN_SUCCESS ? @"成功 ✅" : @"失败 ❌", (int)executed];
    return log;
}

/// !dld <pid|springboard|self> <dylib 路径>：只走「新线程直接 PC=目标的 dlopen」法，不写任何代码页、
/// 不退回劫持法。牺牲进程验证首选。
static NSString *cmdDirectDlopen(NSString *arg) {
    NSArray<NSString *> *parts = [trim(arg) componentsSeparatedByString:@" "];
    if (parts.count < 2) return @"用法: !dld <pid|springboard|self> <dylib 绝对路径>\n";
    NSString *who = parts[0];
    pid_t pid = [who.lowercaseString hasPrefix:@"spring"] ? pidOfName("SpringBoard")
              : ([who.lowercaseString isEqualToString:@"self"] ? getpid() : (pid_t)atoi(who.UTF8String));
    if (pid <= 0) return @"用法: !dld <pid|springboard|self> <dylib 绝对路径>\n";
    NSString *path = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" "];
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"task_for_pid(%d) 失败: %s\n", pid, mach_error_string(kr)];
    odbg_image_t *imgs = NULL;
    int n = remoteImages(task, &imgs);
    NSMutableString *log = [NSMutableString stringWithFormat:@"目标 pid=%d 路径=%@ 镜像数=%d\n", pid, path, n];
    BOOL executed = NO;
    kr = remoteDlopenDirect(task, imgs, n, path.UTF8String, log, &executed);
    if (imgs) free(imgs);
    mach_port_deallocate(mach_task_self(), task);
    [log appendFormat:@"结果：%@\n", kr == KERN_SUCCESS ? @"成功 ✅" : @"失败 ❌"];
    return log;
}

/// !call <pid|springboard|self> <镜像名> <符号> [x0 十六进制|str:文本] [x1 十六进制]
/// 诊断用：新线程 + PC=目标镜像里解析出的符号 + LR=目标的 pause + x0/x1 可控；
/// 轮询 thread_get_state 看线程死没死、PC 有没有落在 pause ⇒ 判定「新线程 + set_state + PAC 签名」这套机制本身是否成立。
static NSString *cmdCall(NSString *arg) {
    NSArray<NSString *> *parts = [trim(arg) componentsSeparatedByString:@" "];
    if (parts.count < 3) return @"用法: !call <pid|springboard|self> <镜像名> <符号> [x0 十六进制|str:文本] [x1 十六进制]\n";
    NSString *who = parts[0];
    pid_t pid = [who.lowercaseString hasPrefix:@"spring"] ? pidOfName("SpringBoard")
              : ([who.lowercaseString isEqualToString:@"self"] ? getpid() : (pid_t)atoi(who.UTF8String));
    if (pid <= 0) return @"用法: !call <pid|springboard|self> <镜像名> <符号> [x0 十六进制|str:文本] [x1 十六进制]\n";
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"task_for_pid(%d) 失败: %s\n", pid, mach_error_string(kr)];
    odbg_image_t *imgs = NULL;
    int n = remoteImages(task, &imgs);
    uint64_t pc = remoteSymbol(task, imgs, n, parts[1].UTF8String, parts[2].UTF8String);
    uint64_t pauseAddr = remoteSymbol(task, imgs, n, "libsystem_c.dylib", "pause");
    if (imgs) free(imgs);
    NSMutableString *out = [NSMutableString stringWithFormat:@"pid=%d %@!%@ => PC=0x%llx LR=pause@0x%llx\n",
                             pid, parts[1], parts[2], pc, pauseAddr];
    if (!pc || !pauseAddr) {
        mach_port_deallocate(mach_task_self(), task);
        [out appendString:@"❌ 远端符号解析失败（镜像名/符号名拼写？）\n"];
        return out;
    }
    NSString *err = nil;
    uint64_t x0 = 0, x1 = 0;
    if (parts.count > 3) {
        NSString *a0 = parts[3];
        if ([a0 hasPrefix:@"str:"]) {
            NSString *text = [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)] componentsJoinedByString:@" "];
            text = [text substringFromIndex:4];
            x0 = remoteWriteString(task, text.UTF8String, &err);
            if (!x0) {
                mach_port_deallocate(mach_task_self(), task);
                [out appendFormat:@"❌ %@\n", err];
                return out;
            }
            [out appendFormat:@"字符串(0x%llx)=\"%@\"\n", x0, text];
        } else {
            x0 = strtoull(a0.UTF8String, NULL, 16);
        }
    }
    if (parts.count > 4 && ![parts[3] hasPrefix:@"str:"]) x1 = strtoull(parts[4].UTF8String, NULL, 16);
    [out appendFormat:@"x0=0x%llx x1=0x%llx\n", x0, x1];
    applog(@"[call] 符号解析完成 pc=0x%llx pause=0x%llx x0=0x%llx x1=0x%llx", pc, pauseAddr, x0, x1);

    thread_act_t th = MACH_PORT_NULL;
    uint64_t stackTop = 0;
    kr = remoteNewThread(task, pc, pauseAddr, x0, x1, &stackTop, &th, &err);
    if (kr != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), task);
        [out appendFormat:@"❌ %@\n", err];
        return out;
    }
    [out appendFormat:@"已起新线程 SP=0x%llx，开始轮询：\n", stackTop];
    applog(@"[call] 线程已起 th=0x%x sp=0x%llx", th, stackTop);
    BOOL parked = NO, dead = NO;
    for (int k = 0; k < 30; k++) {                  // 最多 3 秒
        usleep(100 * 1000);
        arm_thread_state64_t cur; memset(&cur, 0, sizeof(cur));
        mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
        kern_return_t gk = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&cur, &sc);
        if (gk != KERN_SUCCESS) {
            [out appendFormat:@"%4d ms: thread_get_state=%s(%d) ⇒ 线程已死 ❌\n",
                              (k + 1) * 100, mach_error_string(gk), gk];
            dead = YES;
            break;
        }
        uint64_t nowPC = odbgStatePC(&cur);
        if (k == 0) {
            applog(@"[call] 第 1 轮 x0=0x%llx x1=0x%llx x2=0x%llx x3=0x%llx sp=0x%llx lr=0x%llx pc=0x%llx",
                   (uint64_t)cur.__x[0], (uint64_t)cur.__x[1], (uint64_t)cur.__x[2], (uint64_t)cur.__x[3],
                   (uint64_t)(uintptr_t)__darwin_arm_thread_state64_get_sp(cur),
                   (uint64_t)(uintptr_t)__darwin_arm_thread_state64_get_lr(cur), nowPC);
            [out appendFormat:@"寄存器 x0=0x%llx x1=0x%llx x2=0x%llx x3=0x%llx sp=0x%llx lr=0x%llx\n",
                              (uint64_t)cur.__x[0], (uint64_t)cur.__x[1], (uint64_t)cur.__x[2], (uint64_t)cur.__x[3],
                              (uint64_t)(uintptr_t)__darwin_arm_thread_state64_get_sp(cur),
                              (uint64_t)(uintptr_t)__darwin_arm_thread_state64_get_lr(cur)];
        }
        thread_basic_info_data_t tbi; memset(&tbi, 0, sizeof(tbi));
        mach_msg_type_number_t tic = THREAD_BASIC_INFO_COUNT;
        kern_return_t ik = thread_info(th, THREAD_BASIC_INFO, (thread_info_t)&tbi, &tic);
        BOOL atPause = odbgParkedInPause(&cur, pauseAddr);
        if (k == 0 || k == 4 || k == 9 || k == 19 || atPause) {
            [out appendFormat:@"%4d ms: 线程活着 PC=0x%llx LR=0x%llx run_state=%d %@\n",
                              (k + 1) * 100, nowPC,
                              (uint64_t)(uintptr_t)__darwin_arm_thread_state64_get_lr(cur),
                              ik == KERN_SUCCESS ? tbi.run_state : -1,
                              atPause ? @"✅ 已返回并停在 pause" : @""];
            applog(@"[call] %d ms 线程活着 pc=0x%llx run_state=%d atPause=%d", (k + 1) * 100, nowPC,
                   ik == KERN_SUCCESS ? tbi.run_state : -1, atPause ? 1 : 0);
        }
        if (atPause) { parked = YES; break; }
    }
    applog(@"[call] 轮询结束 dead=%d parked=%d", dead, parked);
    [out appendFormat:@"诊断结论：%@\n", dead ? @"线程崩溃（机制或 PAC 签名有问题，或是被调函数自身崩）❌"
                                       : (parked ? @"新线程 + set_state + PAC 签名 + 返回 pause 全部成立 ✅"
                                                 : @"线程还活着但没停在 pause（还在被调函数里）⚠️")];
    // 真机实测（1.0.123）：对这张新线程 port 调 thread_terminate 后 odebugd 立刻被内核杀掉
    // （日志里没有 💥 信号回溯、只有下一次启动横幅 ⇒ 不可捕获的 SIGKILL，多半是 EXC_GUARD）
    // ⇒ 不 terminate、也不回收线程 port：线程自己停在目标的 pause 里，随目标进程一起消失。
    mach_port_deallocate(mach_task_self(), task);
    applog(@"[call] 全部完成");
    return out;
}

/// !pth <pid|springboard|self> <dylib 路径>：只走「借目标 pthread_create + 目标 dlopen」法，不写代码页、不回退。
static NSString *cmdPthreadDlopen(NSString *arg) {
    NSArray<NSString *> *parts = [trim(arg) componentsSeparatedByString:@" "];
    if (parts.count < 2) return @"用法: !pth <pid|springboard|self> <dylib 绝对路径>\n";
    NSString *who = parts[0];
    pid_t pid = [who.lowercaseString hasPrefix:@"spring"] ? pidOfName("SpringBoard")
              : ([who.lowercaseString isEqualToString:@"self"] ? getpid() : (pid_t)atoi(who.UTF8String));
    if (pid <= 0) return @"用法: !pth <pid|springboard|self> <dylib 绝对路径>\n";
    NSString *path = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" "];
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"task_for_pid(%d) 失败: %s\n", pid, mach_error_string(kr)];
    odbg_image_t *imgs = NULL;
    int n = remoteImages(task, &imgs);
    NSMutableString *log = [NSMutableString stringWithFormat:@"目标 pid=%d 路径=%@ 镜像数=%d\n", pid, path, n];
    BOOL executed = NO;
    kr = remoteDlopenPthread(task, imgs, n, path.UTF8String, log, &executed);
    if (imgs) free(imgs);
    mach_port_deallocate(mach_task_self(), task);
    applog(@"[pth] 收尾 kr=%d executed=%d", kr, executed);
    [log appendFormat:@"结果：%@\n", kr == KERN_SUCCESS ? @"成功 ✅" : @"失败 ❌"];
    return log;
}

/// !rx <pid|springboard|self> [self|target|payload|addimm|fdbug]：判定「目标能不能执行我们自己的代码页」。
/// 极小 stub = 往数据页写 canary 然后原地自旋（0x14000000 = b .）；造裸线程跑它 ⇒ 看 canary 出不出来。
///   self   先在 daemon 自己这边把 scratch 页翻成 R|X，再 mach_vm_remap 进目标（frida 的做法）
///   target 直接在目标里分配页、写码、翻 R|X（!fd 原来的做法）
static NSString *cmdRxTest(NSString *arg) {
    NSArray<NSString *> *parts = [trim(arg) componentsSeparatedByString:@" "];
    NSString *who = parts.count > 0 ? (NSString *)parts[0] : @"";
    if (who.length == 0) return @"用法: !rx <pid|springboard|self> [self|target|payload|addimm|fdbug]\n";
    NSString *mode = parts.count > 1 ? ((NSString *)parts[1]).lowercaseString : @"self";
    pid_t pid = [who.lowercaseString hasPrefix:@"spring"] ? pidOfName("SpringBoard")
              : ([who.lowercaseString isEqualToString:@"self"] ? getpid() : (pid_t)atoi(who.UTF8String));
    if (pid <= 0) return @"用法: !rx <pid|springboard|self> [self|target|payload|addimm|fdbug]\n";
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"task_for_pid(%d) 失败: %s\n", pid, mach_error_string(kr)];
    NSMutableString *out = [NSMutableString stringWithFormat:@"pid=%d 模式=%@\n", pid, mode];
    const uint32_t canary = 0x0DB60002u;
    mach_vm_address_t dataAddr = 0;
    kr = mach_vm_allocate(task, &dataAddr, 0x4000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), task); return @"数据页分配失败\n"; }
    uint64_t zero = 0;
    mach_vm_write(task, dataAddr, (vm_offset_t)&zero, sizeof(zero));
    mach_vm_address_t dst = 0;
    kr = mach_vm_allocate(task, &dst, 0x4000, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), task); return @"目标代码页占位分配失败\n"; }
    odbg_image_t *imgs = NULL; int n = remoteImages(task, &imgs);
    uint64_t pauseAddr = remoteSymbol(task, imgs, n, "libsystem_c.dylib", "pause");
    if (imgs) free(imgs);
    if (!pauseAddr) {   // ★ 靶子刚起来时 dyld 镜像表可能还没就绪（remoteImages 拿到 0 张）⇒ 别拿地址 0 去造线程
        mach_port_deallocate(mach_task_self(), task);
        return [NSString stringWithFormat:@"%@（镜像数=%d）：符号解析失败、靶子镜像表可能还没就绪，等 2 秒再来一次\n",
                                          @"pause 解析失败", n];
    }
    // ★ 模式 payload：完全复刻 remoteDlopenFrida 的布局（一次大分配，code/data/stack 同处一块），
    //   但 stub 只做「写两个 canary 然后原地自旋」⇒ 用来分辨「布局/thread_create 有问题」还是「stub 里的调用有问题」。
    if ([mode isEqualToString:@"payload"]) {
        mach_vm_address_t base = 0;
        kr = mach_vm_allocate(task, &base, ODBG_PAYLOAD_SIZE, VM_FLAGS_ANYWHERE);
        if (kr != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), task); return @"payload 分配失败\n"; }
        uint64_t cAddr = (uint64_t)base + ODBG_PAYLOAD_CODE_OFF;
        uint64_t dAddr = (uint64_t)base + ODBG_PAYLOAD_DATA_OFF;
        uint64_t sTop  = (uint64_t)base + ODBG_PAYLOAD_STACK_OFF + ODBG_PAYLOAD_STACK_SIZE - 16;
        uint32_t c2[64]; int n2 = 0;
        emitMov64(c2, &n2, 19, dAddr);
        emitMov64(c2, &n2, 0, (uint64_t)canary);
        emitStr64(c2, &n2, 0, 19);                     // data+0 = canary（已验证过的写法）
        emitAddImm(c2, &n2, 1, 19, 16);                // ★ 顺便验证 emitAddImm 本身
        emitMov64(c2, &n2, 0, (uint64_t)(canary + 1));
        emitStr64(c2, &n2, 0, 1);                      // data+16 = canary+1
        emitInsn(c2, &n2, 0x14000000u);                // b .
        uint8_t dpage[ODBG_DATA_BYTES]; memset(dpage, 0, sizeof(dpage));
        mach_vm_write(task, dAddr, (vm_offset_t)dpage, (mach_msg_type_number_t)sizeof(dpage));
        mach_vm_write(task, cAddr, (vm_offset_t)c2, (mach_msg_type_number_t)(n2 * 4));
        kern_return_t pk = mach_vm_protect(task, cAddr, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        thread_act_t th = MACH_PORT_NULL;
        kern_return_t ck = thread_create(task, &th);
        kern_return_t sk = KERN_FAILURE;
        if (ck == KERN_SUCCESS) {
            arm_thread_state64_t ts; memset(&ts, 0, sizeof(ts));
#if __has_feature(ptrauth_calls)
            __darwin_arm_thread_state64_set_pc_fptr(ts, odbgPreSignedPC(cAddr));
            __darwin_arm_thread_state64_set_lr_fptr(ts, odbgPreSignedLR(pauseAddr));
            __darwin_arm_thread_state64_set_sp(ts, (void *)(uintptr_t)sTop);
#else
            ts.__pc = cAddr; ts.__lr = pauseAddr; ts.__sp = sTop;
#endif
            sk = thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&ts, ARM_THREAD_STATE64_COUNT);
            thread_resume(th);
        }
        [out appendFormat:@"payload 模式 base=0x%llx code=0x%llx data=0x%llx 栈顶=0x%llx protect(R|X)=%s "
                          @"thread_create=%s set_state=%s\n",
                          (uint64_t)base, cAddr, dAddr, sTop, mach_error_string(pk),
                          mach_error_string(ck), mach_error_string(sk)];
        for (int k = 0; k < 60; k++) {
            if (k) usleep(5000);
            uint32_t v0 = 0, v1 = 0;
            BOOL ok0 = vmRead(task, dAddr, &v0, 4);
            vmRead(task, dAddr + 16, &v1, 4);
            if (!ok0) { [out appendFormat:@"❌ %d ms：数据页读不到（目标已死）；此前 v0=0x%x v1=0x%x\n", (k + 1) * 5, v0, v1]; break; }
            if (v0 == canary) { [out appendFormat:@"✅ %d ms：v0=0x%x（data+0 写成功）v1=0x%x\n", (k + 1) * 5, v0, v1];
                                if (v1 == canary + 1) [out appendString:@"✅ emitAddImm 也正确（data+16 命中）\n"];
                                break; }
        }
        mach_port_deallocate(mach_task_self(), th);
        mach_port_deallocate(mach_task_self(), task);
        return out;
    }
    // ★ 模式 addimm：只换掉「已验证的 4 条指令 stub」里的一条 —— 用 emitAddImm+emitStr64 写第二、三个槽位，
    //   用来判定 emitAddImm/emitStr64 的编码到底对不对（!rx target 那套已验证的构造，其余全不变）。
    if ([mode isEqualToString:@"addimm"]) {
        uint32_t c3[64]; int n3 = 0;
        emitMov64(c3, &n3, 19, (uint64_t)dataAddr);
        emitMov64(c3, &n3, 0, (uint64_t)canary);
        emitAddImm(c3, &n3, 1, 19, 16); emitStr64(c3, &n3, 0, 1);       // data+16 = canary
        emitMov64(c3, &n3, 0, (uint64_t)(canary + 1));
        emitAddImm(c3, &n3, 1, 19, 32); emitStr64(c3, &n3, 0, 1);       // data+32 = canary+1
        emitInsn(c3, &n3, 0x14000000u);                                 // b .
        uint8_t dp[64]; memset(dp, 0, sizeof(dp));
        mach_vm_write(task, dataAddr, (vm_offset_t)dp, 64);
        mach_vm_write(task, dst, (vm_offset_t)c3, (mach_msg_type_number_t)(n3 * 4));
        kr = mach_vm_protect(task, dst, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        [out appendFormat:@"addimm 模式 dst=0x%llx 写码 %d 字节、protect(R|X)=%s\n",
                          (uint64_t)dst, n3 * 4, mach_error_string(kr)];
        thread_act_t t3 = MACH_PORT_NULL; NSString *e3 = nil;
        kr = remoteNewThread2(task, (uint64_t)dst, pauseAddr, 0, (uint64_t)dataAddr, 0, 0, NULL, &t3, &e3);
        [out appendFormat:@"造线程 kr=%s %@\n", mach_error_string(kr), e3 ?: @""];
        for (int k = 0; k < 20; k++) {
            usleep(100 * 1000);
            uint32_t w0 = 0, w1 = 0;
            BOOL ok0 = vmRead(task, dataAddr + 16, &w0, 4);
            vmRead(task, dataAddr + 32, &w1, 4);
            if (!ok0) { [out appendFormat:@"❌ %d ms：读不到（目标已死）\n", (k + 1) * 100]; break; }
            if (w0 == canary) { [out appendFormat:@"✅ %d ms：data+16=0x%x（emitAddImm+emitStr64 正确）data+32=0x%x\n",
                                               (k + 1) * 100, w0, w1]; break; }
        }
        mach_port_deallocate(mach_task_self(), t3);
        mach_port_deallocate(mach_task_self(), task);
        return out;
    }
    // ★ 模式 fdbug：用 `!rx target` 已经验证过的构造（独立代码页/数据页 + remoteNewThread2 + LR=目标真实 pause）
    //   去跑 `!fd` 的**整份 stub** ⇒ 分辨「stub 编码有问题」还是「!fd 那套构造/LR 有问题」。
    if ([mode isEqualToString:@"fdbug"]) {
        odbg_image_t *im2 = NULL; int n2 = remoteImages(task, &im2);
        uint64_t dlopenAddr = remoteSymbol(task, im2, n2, "libdyld.dylib", "dlopen");
        uint64_t pcfAddr    = remoteSymbol(task, im2, n2, "libsystem_pthread.dylib", "pthread_create_from_mach_thread");
        uint64_t pexitAddr  = remoteSymbol(task, im2, n2, "libsystem_pthread.dylib", "pthread_exit");
        [out appendFormat:@"符号 dlopen=0x%llx pcfmt=0x%llx pthread_exit=0x%llx pause=0x%llx\n",
                          dlopenAddr, pcfAddr, pexitAddr, pauseAddr];
        uint8_t dp[ODBG_DATA_BYTES]; memset(dp, 0, sizeof(dp));
        const char *dpath = "/var/mobile/odbgprobe.dylib";
        memcpy(dp + ODBG_D_PATH, dpath, strlen(dpath) + 1);
        mach_vm_write(task, dataAddr, (vm_offset_t)dp, (mach_msg_type_number_t)sizeof(dp));
        uint32_t c4[1024]; uint64_t rAddr = 0, pAddr = 0;
        uint64_t derrAddr = 0;   // 同上：dlerror 会在目标的新线程上把进程打死，不调用
        if (im2) free(im2);
        int n4 = odbgBuildFridaStub(c4, (uint64_t)dst, (uint64_t)dataAddr, 0x0DB60001u, pcfAddr,
                                    dlopenAddr, pexitAddr, derrAddr, pauseAddr, &rAddr, &pAddr);
        mach_vm_write(task, dst, (vm_offset_t)c4, (mach_msg_type_number_t)(n4 * 4));
        kr = mach_vm_protect(task, dst, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        [out appendFormat:@"fdbug 模式 dst=0x%llx 写码 %d 字节 routine=0x%llx park=0x%llx protect(R|X)=%s\n",
                          (uint64_t)dst, n4 * 4, rAddr, pAddr, mach_error_string(kr)];
        thread_act_t t4 = MACH_PORT_NULL; NSString *e4 = nil;
        kr = remoteNewThread2(task, (uint64_t)dst, pauseAddr, 0, (uint64_t)dataAddr, 0, 0, NULL, &t4, &e4);
        [out appendFormat:@"造线程（LR=真 pause）kr=%s %@\n", mach_error_string(kr), e4 ?: @""];
        for (int k = 0; k < 30; k++) {
            usleep(100 * 1000);
            uint64_t cv = 0, dv = 0; uint32_t pv = 0;
            BOOL ok = vmRead(task, (uint64_t)dataAddr + ODBG_D_ENTRY_HIT, &cv, 8);
            vmRead(task, (uint64_t)dataAddr + ODBG_D_PTHREAD_RC, &pv, 4);
            vmRead(task, (uint64_t)dataAddr + ODBG_D_DLOPEN_RC, &dv, 8);
            if (!ok) { [out appendFormat:@"❌ %d ms：数据页读不到（目标已死）\n", (k + 1) * 100]; break; }
            if (cv) { [out appendFormat:@"✅ %d ms：canary=0x%llx ⇒ 整份 stub 跑到过了（pthread rc=%u dlopen=0x%llx）\n",
                                               (k + 1) * 100, cv, pv, dv];
                      if (dv) [out appendString:@"✅ dlopen 成功 ⇒ frida 式注入成功\n"];
                      break; }
        }
        mach_port_deallocate(mach_task_self(), t4);
        mach_port_deallocate(mach_task_self(), task);
        return out;
    }
    uint32_t code[256]; int cn = 0;
    emitMov64(code, &cn, 19, (uint64_t)dataAddr);
    emitMov64(code, &cn, 0, (uint64_t)canary);
    emitStr64(code, &cn, 0, 19);
    code[cn++] = 0x14000000u;                       // b .（原地自旋）
    if ([mode isEqualToString:@"target"]) {
        mach_vm_write(task, dst, (vm_offset_t)code, (mach_msg_type_number_t)(cn * 4));
        kr = mach_vm_protect(task, dst, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        [out appendFormat:@"目标内建页 dst=0x%llx 写码 %d 字节、protect(R|X)=%s\n",
                          (uint64_t)dst, cn * 4, mach_error_string(kr)];
    } else {
        mach_vm_address_t scratch = 0;
        kr = mach_vm_allocate(mach_task_self(), &scratch, 0x4000, VM_FLAGS_ANYWHERE);
        if (kr != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), task); return @"daemon scratch 分配失败\n"; }
        mach_vm_write(mach_task_self(), scratch, (vm_offset_t)code, (mach_msg_type_number_t)(cn * 4));
        kr = mach_vm_protect(mach_task_self(), scratch, 0x4000, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
        [out appendFormat:@"daemon 自建 scratch=0x%llx 写码 %d 字节、protect(R|X)=%s\n",
                          (uint64_t)scratch, cn * 4, mach_error_string(kr)];
        vm_prot_t cur = 0, max = 0;
        vm_address_t dstAddr = (vm_address_t)dst;
        kr = vm_remap(task, &dstAddr, 0x4000, 0, VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)scratch,
                      FALSE, &cur, &max, VM_INHERIT_COPY);
        dst = (mach_vm_address_t)dstAddr;
        [out appendFormat:@"vm_remap 进目标 dst=0x%llx kr=%s cur=%d max=%d\n",
                          (uint64_t)dst, mach_error_string(kr), cur, max];
        if (kr != KERN_SUCCESS) { mach_port_deallocate(mach_task_self(), task); return out; }
    }
    thread_act_t th = MACH_PORT_NULL; NSString *err = nil;
    kr = remoteNewThread2(task, (uint64_t)dst, pauseAddr, 0, (uint64_t)dataAddr, 0, 0, NULL, &th, &err);
    [out appendFormat:@"造裸线程 PC=0x%llx LR=pause@0x%llx：kr=%s %@\n",
                      (uint64_t)dst, pauseAddr, mach_error_string(kr), err ?: @""];
    for (int k = 0; k < 30; k++) {
        usleep(100 * 1000);
        uint32_t v = 0;
        BOOL ok = vmRead(task, dataAddr, &v, sizeof(v));
        if (!ok) { [out appendFormat:@"❌ %d ms：数据页读不到（目标可能已死）\n", (k + 1) * 100]; break; }
        if (v == canary) { [out appendFormat:@"✅ %d ms：canary=0x%x 出现 ⇒ 目标执行了我们自己的代码页！\n", (k + 1) * 100, v]; break; }
        if (k == 9 || k == 29) {
            arm_thread_state64_t cur; memset(&cur, 0, sizeof(cur));
            mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            kern_return_t gk = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&cur, &sc);
            [out appendFormat:@"%d ms：canary=0x%x 裸线程=%@\n", (k + 1) * 100, v,
                              gk == KERN_SUCCESS ? [NSString stringWithFormat:@"活着 PC=0x%llx", odbgStatePC(&cur)]
                                                 : [NSString stringWithFormat:@"已死(%s)", mach_error_string(gk)]];
        }
    }
    mach_port_deallocate(mach_task_self(), th);
    mach_port_deallocate(mach_task_self(), task);
    return out;
}

static NSString *cmdImages(NSString *arg) {
    NSArray *parts = [trim(arg) componentsSeparatedByString:@" "];
    if (parts.count == 0 || ((NSString *)parts[0]).length == 0) return @"用法: !imgs <pid|springboard> [过滤词]\n";
    NSString *who = parts[0];
    NSString *filter = parts.count > 1 ? (NSString *)parts[1] : @"";
    pid_t pid = [who.lowercaseString hasPrefix:@"spring"] ? pidOfName("SpringBoard")
              : ([who.lowercaseString isEqualToString:@"self"] ? getpid() : (pid_t)atoi(who.UTF8String));
    if (pid <= 0) return @"用法: !imgs <pid|springboard> [过滤词]（pid 必须是数字）\n";
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"task_for_pid(%d) 失败: %s\n", pid, mach_error_string(kr)];
    odbg_image_t *imgs = NULL;
    int n = remoteImages(task, &imgs);
    if (n < 0) { mach_port_deallocate(mach_task_self(), task); return @"读不到远端镜像表\n"; }
    NSMutableString *out = [NSMutableString stringWithFormat:@"pid=%d 镜像数=%d\n", pid, n];
    int shown = 0;
    for (int i = 0; i < n && shown < 600; i++) {
        NSString *p = @(imgs[i].path);
        if (filter.length && ![p localizedCaseInsensitiveContainsString:filter]) continue;
        [out appendFormat:@"  %3d 0x%llx %@\n", i, imgs[i].loadAddr, p];
        shown++;
    }
    free(imgs);
    mach_port_deallocate(mach_task_self(), task);
    if (!shown) [out appendFormat:@"（没有匹配 “%@” 的镜像）\n", filter];
    return out;
}

/// !sym <pid|springboard> <镜像片段> <符号> —— 诊断远端符号地址解析（PAC/偏移）
static NSString *cmdSym(NSString *arg) {
    NSArray *parts = [trim(arg) componentsSeparatedByString:@" "];
    if (parts.count < 3) return @"用法: !sym <pid|springboard> <镜像片段> <符号>\n";
    NSString *who = parts[0], *img = parts[1], *sym = parts[2];
    pid_t pid = [who.lowercaseString hasPrefix:@"spring"] ? pidOfName("SpringBoard") : (pid_t)atoi(who.UTF8String);
    if (pid <= 0) return @"用法: !sym <pid|springboard> <镜像片段> <符号>（pid 必须是数字）\n";
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"task_for_pid(%d) 失败: %s\n", pid, mach_error_string(kr)];
    odbg_image_t *imgs = NULL;
    int n = remoteImages(task, &imgs);
    if (n < 0) { mach_port_deallocate(mach_task_self(), task); return @"读不到远端镜像表\n"; }
    NSMutableString *out = [NSMutableString string];
    void *ls = dlsym(RTLD_DEFAULT, sym.UTF8String);
    [out appendFormat:@"本地 dlsym(%@) = %p（剥离后 0x%llx）\n", sym, ls, ls ? stripPAC((uint64_t)(uintptr_t)ls) : 0ULL];
    uint64_t remote = remoteSymbol(task, imgs, n, img.UTF8String, sym.UTF8String);
    [out appendFormat:@"远端解析 = 0x%llx\n", remote];
    if (remote) {
        uint32_t w = 0;
        if (vmRead(task, remote, &w, 4)) [out appendFormat:@"该地址前 4 字节 = 0x%08x\n", w];
        else [out appendString:@"该地址不可读\n"];
    }
    free(imgs);
    mach_port_deallocate(mach_task_self(), task);
    return out;
}

/// !exec <pid|springboard> —— 远端执行探针：造一个裸线程，只让它写一个哨兵值再自旋。
/// 用来区分「匿名 RWX 到底能不能执行」和「pthread_create/dlopen 才崩」。
static NSString *cmdExecProbe(NSString *arg) {
    NSArray *parts = [trim(arg) componentsSeparatedByString:@" "];
    NSString *who = parts.count > 0 ? parts[0] : @"";
    NSString *mode = parts.count > 1 ? parts[1] : @"code";
    pid_t pid = [who.lowercaseString hasPrefix:@"spring"] ? pidOfName("SpringBoard")
              : ([who.lowercaseString isEqualToString:@"self"] ? getpid() : (pid_t)atoi(who.UTF8String));
    if (pid <= 0) return @"用法: !exec <pid|springboard|self> [code|sleep|clone]\n";
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"task_for_pid(%d) 失败: %s\n", pid, mach_error_string(kr)];
    NSMutableString *out = [NSMutableString stringWithFormat:@"目标 pid=%d 模式=%@\n", pid, mode];
    odbg_image_t *imgs = NULL;
    int nimg = remoteImages(task, &imgs);
    [out appendFormat:@"镜像数=%d\n", nimg];
    uint64_t sleepAddr = imgs ? remoteSymbol(task, imgs, nimg, "libsystem_c.dylib", "sleep") : 0;
    uint64_t pauseAddr = imgs ? remoteSymbol(task, imgs, nimg, "libsystem_c.dylib", "pause") : 0;
    uint64_t getpidAddr = imgs ? remoteSymbol(task, imgs, nimg, "libsystem_kernel.dylib", "getpid") : 0;
    [out appendFormat:@"远端 sleep=0x%llx pause=0x%llx getpid=0x%llx\n", sleepAddr, pauseAddr, getpidAddr];
    const mach_vm_size_t kRegion = 0x4000;
    mach_vm_address_t mem = 0;
    kr = mach_vm_allocate(task, &mem, kRegion, VM_FLAGS_ANYWHERE);
    [out appendFormat:@"allocate => %s addr=0x%llx\n", mach_error_string(kr), mem];
    if (kr != KERN_SUCCESS) { if (imgs) free(imgs); mach_port_deallocate(mach_task_self(), task); return out; }
    kr = mach_vm_protect(task, mem, kRegion, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    [out appendFormat:@"protect RWX => %s\n", mach_error_string(kr)];
    mach_vm_address_t codeAddr = mem + 0x1000;
    mach_vm_address_t flagAddr = mem + 0x2000;
    uint64_t sentinel = 0xDEADBEEFCAFEBABEULL;
    mach_vm_write(task, flagAddr, (vm_offset_t)&sentinel, sizeof(sentinel));
    arm_thread_state64_t st;
    memset(&st, 0, sizeof(st));
    BOOL libMode = [mode isEqualToString:@"lib"];
    BOOL nopMode = [mode isEqualToString:@"nop"] && !libMode;
    BOOL rawMode = nopMode || [mode isEqualToString:@"raw"];
    BOOL cloneMode = [mode isEqualToString:@"clone"] || libMode;
    uint64_t wantPC = codeAddr;
    if (cloneMode) {
        // ★ 关键实验：从目标已有线程克隆线程状态，这样 SP/flags 是内核自己写出来的合法（带签名）形式，
        // 只把 PC 换成我们要去的地址。用来区分「是我们的裸 SP 被内核当作签名指针处理坏了」还是「匿名页不可执行」。
        thread_act_array_t list = NULL; mach_msg_type_number_t cnt = 0;
        kern_return_t tk = task_threads(task, &list, &cnt);
        mach_msg_type_number_t sc0 = ARM_THREAD_STATE64_COUNT;
        kern_return_t gk0 = tk == KERN_SUCCESS && cnt > 0
            ? thread_get_state(list[0], ARM_THREAD_STATE64, (thread_state_t)&st, &sc0) : tk;
        [out appendFormat:@"克隆线程状态 => %s (线程数=%d)\n", mach_error_string(gk0), cnt];
        if (cnt && list) { for (mach_msg_type_number_t i = 0; i < cnt; i++) mach_port_deallocate(mach_task_self(), list[i]); vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_act_t)); }
        if (gk0 != KERN_SUCCESS) {
            mach_vm_deallocate(task, mem, kRegion);
            if (imgs) free(imgs);
            mach_port_deallocate(mach_task_self(), task);
            return out;
        }
        wantPC = libMode ? (getpidAddr ? getpidAddr : codeAddr) : (sleepAddr ? sleepAddr : codeAddr);
        if (!libMode) st.__x[0] = 5;
        if (pauseAddr) {
            void *pre = ptrauth_sign_unauthenticated((void *)(uintptr_t)pauseAddr, ptrauth_key_function_pointer, 0);
#if __has_feature(ptrauth_calls)
            __darwin_arm_thread_state64_set_lr_fptr(st, pre);
#else
            st.__lr = (uint64_t)(uintptr_t)pre;
#endif
        }
    }
    if (libMode) {
        [out appendFormat:@"模式=lib：PC→远端 getpid（不碰 TLS 的库函数），SP 用克隆值\n"];
    } else if (cloneMode) {
        [out appendFormat:@"模式=clone：PC→sleep(5) 用 SDK 访问器写入，SP 用克隆值\n"];
    } else if ([mode isEqualToString:@"sleep"] && sleepAddr) {
        wantPC = sleepAddr;
        st.__x[0] = 5;
        [out appendFormat:@"模式=sleep：PC 指向远端 %@ 的真实函数（不是匿名页）\n", @"sleep"];
    } else if (nopMode) {
        uint32_t c[4]; c[0] = 0x14000000u;   // b .  只自旋，不碰任何内存/库
        kr = mach_vm_write(task, codeAddr, (vm_offset_t)c, 4);
        [out appendFormat:@"write nop 自旋(1 insn) => %s\n", mach_error_string(kr)];
    } else {
        uint32_t c[16]; int nc = 0;
        emitMov64(c, &nc, 19, flagAddr);
        emitMov64(c, &nc, 0, 0x1234567890ULL);
        c[nc++] = 0xF9000260u;                 // str x0, [x19]
        c[nc++] = 0x14000000u;                 // b .
        kr = mach_vm_write(task, codeAddr, (vm_offset_t)c, (mach_msg_type_number_t)(nc * 4));
        [out appendFormat:@"write shellcode(%d insn) => %s\n", nc, mach_error_string(kr)];
    }
    if (cloneMode) {
#if __has_feature(ptrauth_calls)
        // 用 SDK 的“已签名函数指针”访问器写 PC：它做 auth_and_resign（function_pointer → process_independent_code + "pc"）
        void *pcPre = ptrauth_sign_unauthenticated((void *)(uintptr_t)wantPC, ptrauth_key_function_pointer, 0);
        __darwin_arm_thread_state64_set_pc_fptr(st, pcPre);
#else
        st.__pc = wantPC;
#endif
    } else if (rawMode) {
#if __has_feature(ptrauth_calls)
        // ★ 关键：按 SDK 约定把三个指针都“签好”再交给内核（SP 用 data 密钥 + "sp"，PC/LR 用 code 密钥 + "pc"/"lr"）
        st.__opaque_sp = odbgSignSP(mem + kRegion - 64);
        st.__opaque_pc = odbgSignPC(wantPC);
        st.__opaque_lr = odbgSignLR(pauseAddr ? pauseAddr : 0);
        st.__opaque_flags = 0;
#else
        st.__sp = mem + kRegion - 64;
        st.__pc = wantPC;
#endif
    } else {
#if __has_feature(ptrauth_calls)
        st.__opaque_sp = (void *)(uintptr_t)(mem + kRegion - 64);
        st.__opaque_pc = (void *)(uintptr_t)wantPC;
        st.__opaque_flags = 0x1;   // NO_PTRAUTH：告诉内核这组指针没有签名
#else
        st.__sp = mem + kRegion - 64;
        st.__pc = wantPC;
#endif
    }
    thread_act_t th = MACH_PORT_NULL;
    applog(@"[exec] pid=%d mode=%@ mem=0x%llx wantPC=0x%llx", pid, mode, (uint64_t)mem, wantPC);
    kr = thread_create(task, &th);                      // ★ 三步式：先只创建（挂起态）
    applog(@"[exec] thread_create => %s port=0x%x", mach_error_string(kr), th);
    [out appendFormat:@"thread_create => %s port=0x%x\n", mach_error_string(kr), th];
    if (kr == KERN_SUCCESS) {
        kr = thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, ARM_THREAD_STATE64_COUNT);
        applog(@"[exec] set_state => %s", mach_error_string(kr));
        [out appendFormat:@"thread_set_state => %s\n", mach_error_string(kr)];
        {   // resume 之前回读：这是内核真正存下来的状态，线程还没机会跑
            arm_thread_state64_t r2; memset(&r2, 0, sizeof(r2));
            mach_msg_type_number_t sc2 = ARM_THREAD_STATE64_COUNT;
            kern_return_t g2 = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&r2, &sc2);
#if __has_feature(ptrauth_calls)
            applog(@"[exec] resume 前回读 => %s pc=0x%llx sp=0x%llx lr=0x%llx flags=0x%x",
                   mach_error_string(g2), (uint64_t)(uintptr_t)r2.__opaque_pc,
                   (uint64_t)(uintptr_t)r2.__opaque_sp, (uint64_t)(uintptr_t)r2.__opaque_lr, r2.__opaque_flags);
#else
            applog(@"[exec] resume 前回读 => %s pc=0x%llx sp=0x%llx lr=0x%llx",
                   mach_error_string(g2), (uint64_t)(uintptr_t)r2.__pc,
                   (uint64_t)(uintptr_t)r2.__sp, (uint64_t)(uintptr_t)r2.__lr);
#endif
        }
        kr = thread_resume(th);
        applog(@"[exec] resume => %s", mach_error_string(kr));
        [out appendFormat:@"thread_resume => %s\n", mach_error_string(kr)];
        usleep(300 * 1000);
        thread_suspend(th);
        arm_thread_state64_t cur;
        mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
        kern_return_t gk = thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&cur, &sc);
#if __has_feature(ptrauth_calls)
        uint64_t curpc = (uint64_t)(uintptr_t)cur.__opaque_pc, cursp = (uint64_t)(uintptr_t)cur.__opaque_sp;
        uint32_t curflags = cur.__opaque_flags;
#else
        uint64_t curpc = (uint64_t)(uintptr_t)cur.__pc, cursp = (uint64_t)(uintptr_t)cur.__sp;
        uint32_t curflags = 0;
#endif
        thread_basic_info_data_t tbi2; mach_msg_type_number_t tc2 = THREAD_BASIC_INFO_COUNT;
        kern_return_t ik = thread_info(th, THREAD_BASIC_INFO, (thread_info_t)&tbi2, &tc2);
        [out appendFormat:@"get_state => %s pc=0x%llx sp=0x%llx flags=0x%x（期望 pc=0x%llx）\n",
                          mach_error_string(gk), curpc, cursp, curflags, wantPC];
        if (ik == KERN_SUCCESS)
            [out appendFormat:@"thread_info => run_state=%d suspend_count=%d cpu=%d\n",
                              tbi2.run_state, tbi2.suspend_count, tbi2.cpu_usage];
        thread_resume(th);
        uint64_t r = sentinel;
        for (int i = 0; i < 30; i++) { usleep(100 * 1000); if (!vmRead(task, flagAddr, &r, sizeof(r))) break; if (r != sentinel) break; }
        if (nopMode)
            [out appendFormat:@"（nop 模式，指针已按 SDK 约定签名）线程仍在 = %@\n", gk == KERN_SUCCESS ? @"✅ 是（匿名 RWX 页可以取指执行）" : @"❌ 否（线程已死 ⇒ 多半是 W^X/AMFI 判死匿名取指）"];
        else if (libMode)
            [out appendFormat:@"（lib 模式 getpid）线程仍在 = %@\n", gk == KERN_SUCCESS ? @"✅ 是（裸线程能跑不碰 TLS 的库函数）" : @"❌ 否（线程已死）"];
        else if (cloneMode)
            [out appendFormat:@"（clone 模式）线程仍在 = %@\n", gk == KERN_SUCCESS ? @"✅ 是（克隆状态 + 访问器写 PC 可行）" : @"❌ 否（线程已死）"];
        else if ([mode isEqualToString:@"sleep"])
            [out appendFormat:@"（sleep 模式）线程仍在 = %@\n", gk == KERN_SUCCESS ? @"是（能跑库函数）" : @"否（线程已死）"];
        else
            [out appendFormat:@"flag=0x%llx ⇒ shellcode %@\n", r,
                              r == 0x1234567890ULL ? @"✅ 确实在远端跑起来了（匿名 RWX 可执行）" : @"❌ 没跑起来（页面不可执行 / 线程没被调度）"];
        thread_terminate(th);
        mach_port_deallocate(mach_task_self(), th);
    }
    mach_vm_deallocate(task, mem, kRegion);
    if (imgs) free(imgs);
    mach_port_deallocate(mach_task_self(), task);
    return out;
}

/// !win <pid|springboard|self> [秒数] —— 只**采样**目标线程的 run_state，看它有没有「用户态运行窗口」
/// （注入必须抓到这种窗口：阻塞在 syscall 里的线程改 PC 不会被内核执行）。完全不改动目标，安全。
static NSString *cmdWindowProbe(NSString *arg) {
    NSArray<NSString *> *parts = [trim(arg) componentsSeparatedByString:@" "];
    if (!parts.count || !parts[0].length) return @"用法: !win <pid|springboard|self> [秒数]\n";
    NSString *who = parts[0];
    pid_t pid = [who.lowercaseString hasPrefix:@"spring"] ? pidOfName("SpringBoard")
              : ([who.lowercaseString isEqualToString:@"self"] ? getpid() : (pid_t)atoi(who.UTF8String));
    if (pid <= 0) return @"用法: !win <pid|springboard|self> [秒数]\n";
    int secs = parts.count > 1 ? atoi(parts[1].UTF8String) : 10;
    if (secs < 1) secs = 1;
    if (secs > 120) secs = 120;
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"task_for_pid(%d) 失败: %s\n", pid, mach_error_string(kr)];
    NSMutableString *out = [NSMutableString stringWithFormat:@"目标 pid=%d，采样 %d 秒（每 100ms 一次，只读）\n", pid, secs];
    int samples = secs * 10, withWin = 0, maxRun = 0, maxTotal = 0, firstWin = -1, lastRun = 0;
    for (int t = 0; t < samples; t++) {
        thread_act_array_t list = NULL; mach_msg_type_number_t cnt = 0;
        if (task_threads(task, &list, &cnt) != KERN_SUCCESS) break;
        int run = 0;
        for (mach_msg_type_number_t i = 0; i < cnt; i++) {
            thread_basic_info_data_t tbi; mach_msg_type_number_t tc = THREAD_BASIC_INFO_COUNT;
            if (thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&tbi, &tc) == KERN_SUCCESS
                && tbi.run_state == TH_STATE_RUNNING) run++;
            mach_port_deallocate(mach_task_self(), list[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_act_t));
        if (run > 0) { withWin++; if (firstWin < 0) firstWin = t; }
        lastRun = run;
        if (run > maxRun) maxRun = run;
        if ((int)cnt > maxTotal) maxTotal = (int)cnt;
        usleep(100 * 1000);
    }
    [out appendFormat:@"有用户态窗口的采样=%d/%d（%.0f%%）", withWin, samples, samples ? 100.0 * withWin / samples : 0.0];
    if (firstWin >= 0) [out appendFormat:@"，首次出现在第 %.1f 秒", firstWin / 10.0];
    [out appendFormat:@"\nRUNNING 峰值=%d，最后一次采样 RUNNING=%d，线程数峰值=%d\n", maxRun, lastRun, maxTotal];
    if (withWin == 0) [out appendString:@"⚠️ 全程没有任何线程在用户态运行 ⇒ 此刻无法注入（点亮/触摸屏幕制造活动后再试）\n"];
    mach_port_deallocate(mach_task_self(), task);
    return out;
}

/// !hj <pid|springboard|self> write [文本] —— 劫持目标已有线程调 write(1, 文本, n)
/// !hj <pid|springboard|self> open <路径>   —— 劫持目标已有线程调 dlopen(路径, RTLD_NOW|RTLD_GLOBAL)
/// 只调用共享缓存里已签名的库函数（不写匿名代码）；LR 一律设成 pause，让被劫持线程停在
/// 那里**不返回**——这样能把「劫持到底有没有生效」和「返回原处会不会把进程弄死」分开看。
static NSString *cmdHijack(NSString *arg) {
    NSArray<NSString *> *parts = [trim(arg) componentsSeparatedByString:@" "];
    if (parts.count < 2) return @"用法: !hj <pid|springboard|self> write [文本] | !hj <pid> open <dylib路径>\n";
    NSString *who = parts[0], *mode = parts[1];
    pid_t pid = [who.lowercaseString hasPrefix:@"spring"] ? pidOfName("SpringBoard")
              : ([who.lowercaseString isEqualToString:@"self"] ? getpid() : (pid_t)atoi(who.UTF8String));
    if (pid <= 0) return @"用法: !hj <pid|springboard|self> write|open ...\n";
    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) return [NSString stringWithFormat:@"task_for_pid(%d) 失败: %s\n", pid, mach_error_string(kr)];
    NSMutableString *out = [NSMutableString stringWithFormat:@"目标 pid=%d 模式=%@\n", pid, mode];
    odbg_image_t *imgs = NULL;
    int nimg = remoteImages(task, &imgs);
    uint64_t writeAddr  = imgs ? remoteSymbol(task, imgs, nimg, "libsystem_kernel.dylib", "write") : 0;
    uint64_t pauseAddr  = imgs ? remoteSymbol(task, imgs, nimg, "libsystem_c.dylib", "pause") : 0;
    uint64_t dlopenAddr = imgs ? remoteSymbol(task, imgs, nimg, "libdyld.dylib", "dlopen") : 0;
    [out appendFormat:@"镜像=%d write@0x%llx pause@0x%llx dlopen@0x%llx\n", nimg, writeAddr, pauseAddr, dlopenAddr];
    BOOL isWrite = [mode isEqualToString:@"write"];
    NSString *payload = nil;
    if (isWrite) {
        payload = parts.count > 2 ? [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@" "]
                                  : @"ODBG-HIJACK-HI\n";
    } else {
        if (parts.count < 3) { if (imgs) free(imgs); mach_port_deallocate(mach_task_self(), task); return @"用法: !hj <pid> open <dylib路径>\n"; }
        payload = parts[2];
    }
    uint64_t fnAddr = isWrite ? writeAddr : dlopenAddr;
    if (!fnAddr || !pauseAddr) {
        if (imgs) free(imgs); mach_port_deallocate(mach_task_self(), task);
        return [out stringByAppendingString:@"❌ 定位不到 write/dlopen/pause（远端符号解析失败）\n"];
    }
    const mach_vm_size_t kRegion = 0x4000;
    mach_vm_address_t mem = 0;
    kr = mach_vm_allocate(task, &mem, kRegion, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        if (imgs) free(imgs); mach_port_deallocate(mach_task_self(), task);
        return [out stringByAppendingString:@"❌ 分配远端内存失败\n"];
    }
    mach_vm_address_t argAddr = mem + 0x800;
    const char *ps = payload.UTF8String;
    mach_vm_write(task, argAddr, (vm_offset_t)ps, (mach_msg_type_number_t)strlen(ps) + 1);
    thread_act_array_t list = NULL;
    mach_msg_type_number_t cnt = 0;
    kr = task_threads(task, &list, &cnt);
    [out appendFormat:@"task_threads=%s 线程数=%d\n", mach_error_string(kr), cnt];
    BOOL alive = YES;
    int aliveCnt = -1;
    if (kr == KERN_SUCCESS) {
        // ★ 优先挑「正在用户态运行」的线程：阻塞在 syscall 里的线程改 PC 不会被执行
        int pick = -1;
        for (mach_msg_type_number_t i = 0; i < cnt; i++) {
            thread_basic_info_data_t tbi; mach_msg_type_number_t tc = THREAD_BASIC_INFO_COUNT;
            if (thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&tbi, &tc) == KERN_SUCCESS
                && tbi.run_state == TH_STATE_RUNNING) { pick = (int)i; break; }
        }
        if (pick < 0) pick = 0;
        [out appendFormat:@"选中的线程=%d（-1 之前没找到用户态运行中的线程就退回 0）\n", pick];
        for (mach_msg_type_number_t i = (mach_msg_type_number_t)pick; i < cnt; i++) {
            thread_act_t th = list[i];
            thread_basic_info_data_t b2; mach_msg_type_number_t bc = THREAD_BASIC_INFO_COUNT;
            int rsNow = -1;
            if (thread_info(th, THREAD_BASIC_INFO, (thread_info_t)&b2, &bc) == KERN_SUCCESS) rsNow = b2.run_state;
            if (thread_suspend(th) != KERN_SUCCESS) continue;
            arm_thread_state64_t st; memset(&st, 0, sizeof(st));
            mach_msg_type_number_t sc = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, &sc) != KERN_SUCCESS) { thread_resume(th); continue; }
#if __has_feature(ptrauth_calls)
            uint64_t origPC = (uint64_t)(uintptr_t)st.__opaque_pc;
#else
            uint64_t origPC = (uint64_t)(uintptr_t)st.__pc;
#endif
            arm_thread_state64_t ns = st;
            if (isWrite) { ns.__x[0] = 1; ns.__x[1] = (uint64_t)argAddr; ns.__x[2] = (uint64_t)strlen(ps); }
            else         { ns.__x[0] = (uint64_t)argAddr; ns.__x[1] = 3; }
#if __has_feature(ptrauth_calls)
            __darwin_arm_thread_state64_set_pc_fptr(ns, odbgPreSignedPC(fnAddr));
            __darwin_arm_thread_state64_set_lr_fptr(ns, odbgPreSignedLR(pauseAddr));
#else
            ns.__pc = fnAddr; ns.__lr = pauseAddr;
#endif
            kern_return_t sk = thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&ns, ARM_THREAD_STATE64_COUNT);
            thread_resume(th);
            [out appendFormat:@"劫持线程 %d/%d set_state=%s origPC=0x%llx fn=0x%llx run_state=%d\n", i, cnt, mach_error_string(sk), origPC, fnAddr, rsNow];
            if (rsNow != TH_STATE_RUNNING) {
                kern_return_t ak = thread_abort(th);
                [out appendFormat:@"  ⇒ 非用户态运行中（run_state=%d）⇒ thread_abort=%s\n", rsNow, mach_error_string(ak)];
            }
            for (int k = 0; k < 10; k++) {
                usleep(200 * 1000);
                odbg_image_t *i2 = NULL;
                int n2 = remoteImages(task, &i2);
                if (i2) free(i2);
                if (n2 < 0) { alive = NO; break; }
            }
            if (alive) {
                odbg_image_t *i2 = NULL;
                aliveCnt = remoteImages(task, &i2);
                if (i2) {
                    if (!isWrite) {
                        const char *leaf = strrchr(ps, '/'); leaf = leaf ? leaf + 1 : ps;
                        for (int j = 0; j < aliveCnt; j++)
                            if (strstr(i2[j].path, leaf)) [out appendFormat:@"✅ 远端镜像表里已出现: %@\n", @(i2[j].path)];
                    }
                    free(i2);
                }
            }
            [out appendFormat:@"结果: 目标 %@，远端镜像数=%d\n", alive ? @"✅ 还活着" : @"❌ 已死", aliveCnt];
            if (alive) {   // 把线程恢复原状，别把它永远停在 pause
                thread_suspend(th);
                thread_set_state(th, ARM_THREAD_STATE64, (thread_state_t)&st, ARM_THREAD_STATE64_COUNT);
                thread_resume(th);
            }
            break;   // 只试第一个能挂起的线程
        }
    }
    if (list) {
        for (mach_msg_type_number_t i = 0; i < cnt; i++) mach_port_deallocate(mach_task_self(), list[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)list, cnt * sizeof(thread_act_t));
    }
    if (imgs) free(imgs);
    mach_vm_deallocate(task, mem, kRegion);
    mach_port_deallocate(mach_task_self(), task);
    return out;
}

/// 起一个一次性进程当注入试验靶子（不会被 odebugd 退出带走）
static NSString *cmdSpawn(NSString *arg) {
    NSString *line = trim(arg);
    if (!line.length) return @"用法: !spawn <可执行文件> [参数...]\n";
    const char *cs = line.UTF8String;
    char *argv[64]; int n = 0;
    char *buf = strdup(cs);
    char *save = NULL;
    for (char *t = strtok_r(buf, " ", &save); t && n < 62; t = strtok_r(NULL, " ", &save)) argv[n++] = t;
    argv[n] = NULL;
    if (n == 0) { free(buf); return @"用法: !spawn <可执行文件> [参数...]\n"; }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    posix_spawn_file_actions_t fa;                 // ★ 把 3 以上的 fd 全关掉（含 odebugd 的监听 socket）
    posix_spawn_file_actions_init(&fa);
    int maxfd = getdtablesize();
    if (maxfd > 512) maxfd = 512;
    for (int i = 3; i < maxfd; i++)
        if (fcntl(i, F_GETFD) != -1) posix_spawn_file_actions_addclose(&fa, i);   // 只关真正打开的 fd，否则 addclose 会 EBADF
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, &attr, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    free(buf);
    return [NSString stringWithFormat:@"posix_spawn rc=%d pid=%d\n", rc, pid];
}

static NSString *cmdInjectImpl(NSString *arg) {
    NSArray<NSString *> *parts = [trim(arg) componentsSeparatedByString:@" "];
    if (parts.count == 0 || parts[0].length == 0) {
        return @"用法: !inject <pid|springboard> [dylib路径]\n"
               @"  默认注入 ODebug.dylib（会先确保 libellekit 已加载，因为 ODebug 需要它的 MSHookMessageEx）\n";
    }
    pid_t pid = 0;
    if ([parts[0].lowercaseString hasPrefix:@"spring"]) {
        pid = pidOfName("SpringBoard");
    } else {
        pid = (pid_t)strtol(parts[0].UTF8String, NULL, 10);
    }
    if (pid <= 0) return [NSString stringWithFormat:@"❌ 找不到目标进程: %@\n", parts[0]];

    NSString *dylib = parts.count > 1 ? parts[1] : odbgDefaultPluginPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dylib]) {
        return [NSString stringWithFormat:@"❌ dylib 不存在: %@\n", dylib];
    }

    applog(@"[inject] 目标 pid=%d dylib=%@", pid, dylib);
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"目标 pid=%d，dylib=%s\n", pid, dylib.UTF8String];

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    [out appendFormat:@"task_for_pid => %s(%d)\n", mach_error_string(kr), kr];
    if (kr != KERN_SUCCESS) return out;

    // ODebug 依赖 substrate API（MSHookMessageEx）。真机正常模式下该符号由 <jbroot>/usr/lib/libellekit.dylib
    // 提供（实测 SpringBoard 的 1375 个镜像里没有任何名字含 substrate 的库）；安全模式下 tweak 加载器没跑
    // ⇒ ellekit 不在，dlopen ODebug 会因符号缺失失败 ⇒ 先补依赖，再注入目标。
    // ★ 依赖检查：ODebug 唯一的非系统依赖符号是 substrate 的 MSHookMessageEx。正常模式下它由
    //   libellekit / CydiaSubstrate / roothidehooks 任一提供（实测 SpringBoard 里挂的是
    //   basebin/fallback/CydiaSubstrate.framework/CydiaSubstrate，**没有** libellekit.dylib）⇒
    //   只要远端能解析到这个符号就跳过依赖加载，免得在 SpringBoard 里做多余的线程劫持。
    BOOL haveHook = NO;
    {
        odbg_image_t *deps = NULL;
        int ndeps = remoteImages(task, &deps);
        if (ndeps > 0) {
            const char *cands[] = {"libellekit", "CydiaSubstrate", "roothidehooks", "substrate"};
            for (int ci = 0; ci < 4 && !haveHook; ci++)
                if (remoteSymbol(task, deps, ndeps, cands[ci], "MSHookMessageEx")) haveHook = YES;
        }
        if (deps) free(deps);
    }
    [out appendFormat:@"[依赖] 远端已能解析 MSHookMessageEx ⇒ %@\n", haveHook ? @"跳过依赖加载" : @"需要补依赖"];
    if (!haveHook && ![dylib containsString:@"libellekit"]) {
        for (NSString *dep in @[[gJbroot stringByAppendingString:@"/usr/lib/libellekit.dylib"],
                                [gJbroot stringByAppendingString:@"/usr/lib/libsubstrate.dylib"]]) {
            if (![fm fileExistsAtPath:dep]) continue;
            NSString *d = nil;
            kr = remoteDlopen(task, dep.UTF8String, &d);
            [out appendFormat:@"[依赖] %@ => %@\n", dep.lastPathComponent, d];
            if ([d hasPrefix:@"✅"] || [d hasPrefix:@"已加载"]) break;
        }
    }
    NSString *d = nil;
    kr = remoteDlopen(task, dylib.UTF8String, &d);
    [out appendFormat:@"[目标] %@\n", d];
    mach_port_deallocate(mach_task_self(), task);
    return out;
}

#pragma mark - 命令分发

/// 在设备上运行一条命令并捕获输出（WLAN 自给自足：!dpkg 等用）
static NSString *odbgRunCapture(NSString *exe, NSArray<NSString *> *args, int timeoutSec) {
    int outfd[2];
    if (pipe(outfd) != 0) return @"❌ pipe 失败\n";
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, outfd[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, outfd[1], STDERR_FILENO);
    int maxfd = getdtablesize();
    if (maxfd > 512) maxfd = 512;
    for (int i = 3; i < maxfd; i++)
        if (fcntl(i, F_GETFD) != -1 && i != outfd[0] && i != outfd[1]) posix_spawn_file_actions_addclose(&fa, i);
    const char **argv = calloc(args.count + 2, sizeof(char *));
    argv[0] = exe.UTF8String;
    for (NSUInteger i = 0; i < args.count; i++) argv[i + 1] = args[i].UTF8String;
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, &attr, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    free(argv);
    close(outfd[1]);
    if (rc != 0) { close(outfd[0]); return [NSString stringWithFormat:@"❌ posix_spawn(%@) rc=%d\n", exe, rc]; }
    NSMutableData *buf = [NSMutableData data];
    fcntl(outfd[0], F_SETFL, O_NONBLOCK);
    time_t deadline = time(NULL) + timeoutSec;
    while (time(NULL) < deadline) {
        char tmp[4096];
        ssize_t n = read(outfd[0], tmp, sizeof(tmp));
        if (n > 0) {
            [buf appendBytes:tmp length:(NSUInteger)n];
            if (buf.length > 400 * 1024) break;
            continue;
        }
        int st = 0; pid_t w = waitpid(pid, &st, WNOHANG);
        if (w == pid) {   // 收尾：再吸一口剩余输出
            while ((n = read(outfd[0], tmp, sizeof(tmp))) > 0) [buf appendBytes:tmp length:(NSUInteger)n];
            close(outfd[0]);
            NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
            if (!s) s = [[NSString alloc] initWithData:buf encoding:NSISOLatin1StringEncoding];
            if (s.length > 20000) s = [[s substringToIndex:20000] stringByAppendingString:@"\n…(截断)"];
            return [NSString stringWithFormat:@"退出码=%d\n%@", WEXITSTATUS(st), s];
        }
        usleep(80 * 1000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    close(outfd[0]);
    NSString *s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:buf encoding:NSISOLatin1StringEncoding];
    return [NSString stringWithFormat:@"⏱ 超时(%d 秒)已杀，已有输出：\n%@", timeoutSec, s];
}

/// !putb <路径> <base64> —— 追加写一段二进制（WLAN 上传文件用，配 !pute 收尾）
static NSString *cmdPutBegin(NSString *arg) {
    NSRange sp = [arg rangeOfString:@" "];
    if (sp.location == NSNotFound) return @"用法: !putb <路径> <base64 段>\n";
    NSString *path = trim([arg substringToIndex:sp.location]);
    NSString *b64 = trim([arg substringFromIndex:sp.location + 1]);
    NSData *d = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!d) return @"❌ base64 解不开\n";
    FILE *f = fopen(path.UTF8String, "ab");
    if (!f) return [NSString stringWithFormat:@"❌ 打不开 %@（errno=%d，目录不存在或没权限）\n", path, errno];
    size_t w = d.length ? fwrite(d.bytes, 1, d.length, f) : 0;
    fclose(f);
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    unsigned long long sz = [at fileSize];
    return [NSString stringWithFormat:@"已追加 %zu 字节，累计 %llu 字节\n", w, sz];
}

/// !pute <路径> —— 上传收尾（chmod + 报大小）
static NSString *cmdPutEnd(NSString *arg) {
    NSString *path = trim(arg);
    if (!path.length) return @"用法: !pute <路径>\n";
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (!at) return @"❌ 文件不存在\n";
    chmod(path.UTF8String, 0755);
    return [NSString stringWithFormat:@"✅ %@ 就绪，%llu 字节（0755）\n", path, [at fileSize]];
}

/// !dpkg <deb路径> —— 用 jbroot 里的 dpkg 装包（装完 !restart 换新 daemon）
static NSString *cmdDpkgInstall(NSString *arg) {
    NSString *deb = trim(arg);
    if (!deb.length) return @"用法: !dpkg <deb 路径>（先用 !putb/!pute 传上来）\n";
    NSString *dpkg = [gJbroot stringByAppendingString:@"/usr/bin/dpkg"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dpkg]) dpkg = @"/usr/bin/dpkg";
    return odbgRunCapture(dpkg, @[ @"-i", deb ], 120);
}

/// !restart —— 自杀让 launchd 拉起新进程（升级 odebugd 后用）
static NSString *cmdRestart(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        applog(@"收到 !restart ⇒ SIGTERM 自杀，launchd 会拉起新进程");
        kill(getpid(), SIGTERM);
    });
    return @"0.4 秒后自杀重启（KeepAlive 会拉起），稍等 2 秒再重连\n";
}

static NSString *helpText(void) {
    return [NSString stringWithFormat:
        @"ODebug 常驻调试服务 odebugd %@ (pid %d)\n"
        @"  —— LaunchDaemon，安全模式下照旧运行（插件内控制台 4321 在安全模式下不可用）\n"
        @"安全模式:\n"
        @"  !safe status        查看标记/软链/SpringBoard\n"
        @"  !safe on            写标记 + SIGKILL SpringBoard（只有 SpringBoard 干净）\n"
        @"  !safe on all        写标记 + 重启用户空间（全部进程干净，约 20-30 秒）\n"
        @"  !safe off           先删标记、再 SIGTERM SpringBoard（退出安全模式）\n"
        @"  !safe respring      只重启 SpringBoard（不动标记）\n"
        @"调试:\n"
        @"  !ps [过滤]          进程列表（pid/uid/名字）\n"
        @"  !ls <路径>          列目录（含属主/权限/大小/软链目标）\n"
        @"  !cat <路径>         读文件（最多 512KB）\n"
        @"  !plist read <路径>  读 plist\n"
        @"注入（安全模式下把 ODebug 塞回进程）:\n"
        @"  !auto status|on|off|run  安全模式兜底：自动把 ODebug 注入 SpringBoard（默认开）\n"
        @"  !inject springboard 注入 ODebug.dylib 到 SpringBoard（自动先补 libellekit）\n"
        @"  !inject <pid>       注入到指定 pid\n"
        @"  !exec <pid>         远端 shellcode 执行探针（只写一个 flag，不加载任何库）\n"
        @"  !fd <pid|springboard> <dylib>  frida 式注入（新线程 + R+X 代码页），不会退回劫持法\n"
        @"  !dld <pid|springboard> <dylib> 新线程直接把 PC 设成目标的 dlopen（不写代码页），不回退\n"
        @"  !call <pid|springboard> <镜像> <符号> [x0|str:文本] [x1]  新线程直调目标符号（诊断用）\n"
        @"  !rx <pid|springboard> [self|target|payload|addimm|fdbug]  代码页取指试验（canary 自旋，判能不能执行匿名/remap 页）\n"
        @"  !pth <pid|springboard> <dylib>  裸线程借目标的 pthread_create 让正规 pthread 去 dlopen（不写代码页）\n"
        @"  !win <pid|springboard> [秒]  只读采样：目标有没有「用户态运行窗口」（注入的前提）\n"
        @"  !hj <pid> write [文本]  劫持目标线程调 write(1,文本,n)，验证「劫持能不能生效」\n"
        @"  !hj <pid> open <路径>   劫持目标线程调 dlopen(路径,3)，验证「能不能把库装进去」\n"
        @"  !imgs <pid> [过滤]  列目标进程已加载的镜像（找依赖库用）\n"
        @"  !tp <pid>           task_for_pid / 远程 VM / 远程线程可行性探针\n"
        @"  !spawn <路径> [参数] 起一个一次性进程（注入试验靶子）\n"
        @"  !putb <路径> <b64> WLAN 上传：追加一段 base64（配 !pute）\n"
        @"  !pute <路径>        WLAN 上传收尾（chmod 0755 + 报大小）\n"
        @"  !dpkg <deb路径>     用 jbroot 的 dpkg 装包（装完 !restart 生效）\n"
        @"  !restart            自杀重启 daemon（launchd KeepAlive 拉起）\n"
        @"  !sys                系统与服务信息\n"
        @"  !net                网络状态：绑定模式 + 手机各网卡 IP（WLAN 直连用）\n"
        @"  !log [n]            看 odebugd 自己的日志（默认 40 行）\n"
        @"  !exit               断开本连接\n", gVersion, getpid()];
}

/// !net：网络状态——当前绑定模式 + 各网卡 IP（WLAN 直连要连哪个地址一目了然）
static NSString *netInfo(void) {
    NSMutableString *r = [NSMutableString stringWithFormat:
        @"odebugd 端口 %d，绑定 %@%@\n",
        gPort, gBindAny ? @"0.0.0.0（WLAN 直连开启）" : @"127.0.0.1（仅本机）",
        gBindAny ? @"：同网段电脑直连 手机IP:4322，凭 token 鉴权" : @"：设置页开「WLAN 直连」或 !bind 后 !restart"];
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) == 0) {
        char buf[INET_ADDRSTRLEN] = {0};
        for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
            if (p->ifa_addr && p->ifa_addr->sa_family == AF_INET) {
                struct sockaddr_in *sa = (struct sockaddr_in *)p->ifa_addr;
                if (inet_ntop(AF_INET, &sa->sin_addr, buf, sizeof(buf)) && strcmp(buf, "127.0.0.1") != 0)
                    [r appendFormat:@"  %@: %s\n", @(p->ifa_name), buf];
            }
        }
        freeifaddrs(ifa);
    }
    [r appendString:@"4321（插件控制台）跟随各自进程的 debugBindAll 设置（改后需 respring）"];
    return r;
}

static NSString *systemInfo(void) {
    struct utsname u;
    uname(&u);
    struct timeval boot = {0};
    size_t sz = sizeof(boot);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    sysctl(mib, 2, &boot, &sz, NULL, 0);
    double up = [NSDate date].timeIntervalSince1970 - boot.tv_sec;
    return [NSString stringWithFormat:
        @"odebugd %@  pid=%d  uid=%d  euid=%d  port=%d\n"
        @"jbroot: %@\n"
        @"uname: %s %s %s (%s)\n"
        @"设备启动于 %.2f 小时前\n"
        @"日志: %@\n",
        gVersion, getpid(), getuid(), geteuid(), gPort, gJbroot,
        u.sysname, u.release, u.version, u.machine, up / 3600.0, gLogPath];
}

static NSString *tailLog(NSString *arg) {
    int n = atoi(trim(arg).UTF8String);
    if (n <= 0) n = 40;
    NSString *content = stringFromFile(gLogPath, 512 * 1024);
    if (!content) return @"(暂无日志)";
    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    NSUInteger start = lines.count > (NSUInteger)n ? lines.count - (NSUInteger)n : 0;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = start; i < lines.count; i++) {
        if (lines[i].length) [out appendFormat:@"%@\n", lines[i]];
    }
    return out;
}

/// 目标进程的镜像表里有没有某个库（roothide 会把 ODebug.dylib 落到 <jbroot>/usr/lib/TweakInject/，
/// 所以按 leaf 名子串匹配，不按完整路径）。
static BOOL odbgHasImage(pid_t pid, const char *needle) {
    if (pid <= 0) return NO;
    task_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return NO;
    odbg_image_t *imgs = NULL;
    int n = remoteImages(task, &imgs);
    BOOL found = NO;
    for (int i = 0; i < n && imgs; i++) {
        if (strstr(imgs[i].path, needle)) { found = YES; break; }
    }
    if (imgs) free(imgs);
    mach_port_deallocate(mach_task_self(), task);
    return found;
}

/// 注入命令的互斥包装：看门狗和客户端连接共用一把锁，避免两次注入同时去挄 SpringBoard 的线程。
static NSString *cmdInject(NSString *arg) {
    if (pthread_mutex_trylock(&gInjLock) != 0) {
        return @"❌ 另一个注入正在进行（自动兜底或其它连接），稍等再试\n";
    }
    NSString *r = cmdInjectImpl(arg);
    pthread_mutex_unlock(&gInjLock);
    return r;
}

/// 安全模式兜底看门狗（★ 这是本项目「安全模式下也能用」的最后一环）：
/// SpringBoard 如果在「安全模式开启时」启动，tweak 加载器就没跑 ⇒ ODebug.dylib 不在 SB 里 ⇒
/// 插件内的 4321 控制台是死的（而且控制台自己没法自救：它压根没被加载）。
/// odebugd 是 LaunchDaemon，安全模式下照旧常驻，所以由它盯着 SB：发现 SB 里没有 ODebug 就注入。
/// 注入本身只能在目标「有用户态线程」的瞬间做（实测 SB 空闲时窗口率约 2%），所以会等 1~3 分钟。
static void *autoInjectThread(void *arg) {
    (void)arg;
    time_t lastInject = 0;
    pid_t  lastSb = 0;
    pid_t  announced = 0;
    int    repeats = 0;
    for (;;) {
        sleep(5);
        if (!gAutoInject) continue;
        pid_t sb = pidOfName("SpringBoard");
        if (sb <= 0) continue;
        if (lastSb && sb != lastSb) {   // SB 换 pid 了：是「按预期重启」还是「我们刚注入它就死」？
            if (gExpectedSbRestart && time(NULL) - gExpectedSbRestart < 180) {
                // odebugd 自己发起的 respring（!safe on/off/respring）——真机踩过：这会被误判成
                // 「注入后 SB 立刻重启」，两次就把自动兜底停掉了。按预期重启不计数。
                applog(@"[watchdog] SB 按预期重启（odebugd 自己 respring 的）⇒ 不计入崩溃循环");
                gExpectedSbRestart = 0;
                repeats = 0;
            } else if (lastInject && time(NULL) - lastInject < 90) {
                repeats++;
                applog(@"[watchdog] ⚠️ 注入后 %ld 秒内 SB 就换了新 pid（第 %d 次）", (long)(time(NULL) - lastInject), repeats);
                if (repeats >= 2) {
                    gAutoInject = 0;
                    applog(@"[watchdog] ⛔ 连续 %d 次「注入后 SB 立刻重启」⇒ 自动兜底停用（!auto on 可再开）", repeats);
                }
            } else {
                repeats = 0;
            }
        }
        lastSb = sb;
        if (odbgHasImage(sb, "ODebug.dylib")) { announced = 0; continue; }   // 已经在里面了（正常模式或之前注入过）
        if (gAutoInject == 0) continue;
        if (announced != sb) {
            applog(@"[watchdog] SpringBoard(%d) 里没有 ODebug.dylib（多半是安全模式启动的）⇒ 自动兜底注入", sb);
            announced = sb;
        }
        NSString *dylib = odbgDefaultPluginPath();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dylib]) { applog(@"[watchdog] ❌ 找不到 %@，跳过", dylib); continue; }
        NSString *r = cmdInject([NSString stringWithFormat:@"%d %@", sb, dylib]);
        r = [r stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([r hasPrefix:@"❌ 另一个注入"]) continue;      // 客户端在注入，下一轮再看
        lastInject = time(NULL);
        if (r.length > 4000) r = [r substringToIndex:4000];
        applog(@"[watchdog] 注入结果:\n%@", r);
        if ([r containsString:@"注入成功"]) {
            applog(@"[watchdog] ✅ ODebug.dylib 已进入 SpringBoard(%d)，插件内 4321 控制台应该回来了（无需 respring）", sb);
        }
    }
    return NULL;
}

static NSString *cmdAuto(NSString *arg) {
    NSString *a = trim(arg).lowercaseString;
    pid_t sb = pidOfName("SpringBoard");
    BOOL has = (sb > 0) ? odbgHasImage(sb, "ODebug.dylib") : NO;
    if (a.length == 0 || [a hasPrefix:@"status"]) {
        return [NSString stringWithFormat:
            @"自动兜底注入（安全模式）: %@\n"
            @"  SpringBoard pid=%d，ODebug.dylib %@\n"
            @"  机制: 每 5 秒查一次；发现 SB 里没有 ODebug 就注入（等「用户态窗口」，可能等 1~3 分钟）\n"
            @"  触发场景: 安全模式开启时启动的 SB —— 插件 4321 控制台是死的，注入后无需 respring 即恢复\n"
            @"  !auto on | !auto off | !auto run（立刻试一次）\n",
            gAutoInject ? @"已开启 ✅" : @"已停用 ⛔", sb,
            sb > 0 ? (has ? @"已在镜像表里 ✅" : @"不在镜像表里 ❌") : @"（找不到 SB）"];
    }
    if ([a hasPrefix:@"on"])  { gAutoInject = 1; applog(@"[auto] 开启自动兜底"); return @"自动兜底注入已开启 ✅\n"; }
    if ([a hasPrefix:@"off"]) { gAutoInject = 0; applog(@"[auto] 停用自动兜底"); return @"自动兜底注入已停用 ⛔（!auto on 可再开）\n"; }
    if ([a hasPrefix:@"run"]) {
        if (sb <= 0) return @"❌ 找不到 SpringBoard\n";
        NSString *dylib = odbgDefaultPluginPath();
        return [NSString stringWithFormat:@"⚙️ 手动按兜底路径注入 SB(%d)…\n%@", sb,
                cmdInject([NSString stringWithFormat:@"%d %@", sb, dylib])];
    }
    return @"用法: !auto status | on | off | run\n";
}

static NSString *dispatchCommand(NSString *cmd) {
    cmd = trim(cmd);
    if (cmd.length == 0) return @"";
    if ([cmd isEqualToString:@"help"] || [cmd isEqualToString:@"?"] || [cmd isEqualToString:@"h"]) return helpText();
    if ([cmd isEqualToString:@"!exit"] || [cmd isEqualToString:@"exit"] || [cmd isEqualToString:@"quit"]) return @"__BYE__";
    if ([cmd hasPrefix:@"!safe"]) return cmdSafe([cmd substringFromIndex:5]);
    if ([cmd hasPrefix:@"!ps"]) return allProcs(trim([cmd substringFromIndex:3]));
    if ([cmd hasPrefix:@"!ls "]) return listDir(trim([cmd substringFromIndex:4]));
    if ([cmd hasPrefix:@"!cat "]) {
        NSString *path = trim([cmd substringFromIndex:5]);
        NSString *s = stringFromFile(path, 512 * 1024);
        return s ? [NSString stringWithFormat:@"===== %@ =====\n%@\n", path, s]
                 : [NSString stringWithFormat:@"❌ 读不到 %@ (errno=%d)\n", path, errno];
    }
    if ([cmd hasPrefix:@"!plist read "]) {
        NSString *path = trim([cmd substringFromIndex:12]);
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!d) {
            NSArray *a = [NSArray arrayWithContentsOfFile:path];
            return a ? [NSString stringWithFormat:@"===== %@ =====\n%@\n", path, a]
                     : [NSString stringWithFormat:@"❌ 解析失败 %@ (errno=%d)\n", path, errno];
        }
        return [NSString stringWithFormat:@"===== %@ =====\n%@\n", path, d];
    }
    if ([cmd hasPrefix:@"!auto"]) return cmdAuto([cmd substringFromIndex:5]);
    if ([cmd hasPrefix:@"!inject"]) return cmdInject([cmd substringFromIndex:7]);
    if ([cmd hasPrefix:@"!exec "]) return cmdExecProbe([cmd substringFromIndex:6]);
    if ([cmd hasPrefix:@"!win"]) return cmdWindowProbe([cmd substringFromIndex:4]);
    if ([cmd hasPrefix:@"!hj "]) return cmdHijack([cmd substringFromIndex:4]);
    if ([cmd hasPrefix:@"!fd "]) return cmdFridaDlopen([cmd substringFromIndex:4]);
    if ([cmd hasPrefix:@"!dld "]) return cmdDirectDlopen([cmd substringFromIndex:5]);
    if ([cmd hasPrefix:@"!call "]) return cmdCall([cmd substringFromIndex:6]);
    if ([cmd hasPrefix:@"!pth "]) return cmdPthreadDlopen([cmd substringFromIndex:5]);
    if ([cmd hasPrefix:@"!rx "]) return cmdRxTest([cmd substringFromIndex:4]);
    if ([cmd hasPrefix:@"!spawn "]) return cmdSpawn([cmd substringFromIndex:7]);
    if ([cmd hasPrefix:@"!putb "]) return cmdPutBegin([cmd substringFromIndex:6]);
    if ([cmd hasPrefix:@"!pute "]) return cmdPutEnd([cmd substringFromIndex:6]);
    if ([cmd hasPrefix:@"!pute"]) return cmdPutEnd(trim([cmd substringFromIndex:5]));
    if ([cmd hasPrefix:@"!dpkg "]) return cmdDpkgInstall([cmd substringFromIndex:6]);
    if ([cmd hasPrefix:@"!restart"]) return cmdRestart();
    if ([cmd hasPrefix:@"!imgs"]) return cmdImages([cmd substringFromIndex:5]);
    if ([cmd hasPrefix:@"!sym "]) return cmdSym([cmd substringFromIndex:5]);
    if ([cmd hasPrefix:@"!tp "]) return cmdTaskProbe([cmd substringFromIndex:4]);
    if ([cmd isEqualToString:@"!sys"]) return systemInfo();
    if ([cmd isEqualToString:@"!net"]) return netInfo();
    if ([cmd hasPrefix:@"!log"]) return tailLog([cmd substringFromIndex:4]);
    if ([cmd isEqualToString:@"!token"]) return @"";
    return [NSString stringWithFormat:@"未知命令: %@（发 help 看菜单）\n", cmd];
}

#pragma mark - 令牌 / 连接

/// 1.0.144：NSNetService 发布结果打日志（之前静默失败没法排查）
@interface OdbgBonjourLogger : NSObject <NSNetServiceDelegate>
@end
@implementation OdbgBonjourLogger
- (void)netServiceDidPublish:(NSNetService *)sender { applog(@"Bonjour 发布成功: %@%@:%d", sender.name, sender.type, sender.port); }
- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict {
    applog(@"⚠️ Bonjour 发布失败: %@（走 UDP 信标兜底）", errorDict);
}
@end

/// 1.0.144：UDP 广播信标——不依赖 mDNSResponder/组播：每 5 秒向 255.255.255.255:4323
/// 发一行 `ODEBUGD_BEACON <port> <版本>`，电脑端 odebug.sh 监听一次即可拿到手机 IP。
static void *beaconThread(void *unused) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return NULL;
    int bc = 1;
    setsockopt(s, SOL_SOCKET, SO_BROADCAST, &bc, sizeof(bc));
    for (;;) {
        // 信标里带上本机 IP（优选 WiFi en*，跳过蜂窝 pdp*/回环 lo*/隧道 utun*/awdl*）
        char ipbuf[64] = "?";
        struct ifaddrs *ifa = NULL;
        if (getifaddrs(&ifa) == 0) {
            char any[64] = "";
            for (struct ifaddrs *f = ifa; f; f = f->ifa_next) {
                if (!(f->ifa_addr && f->ifa_addr->sa_family == AF_INET)) continue;
                const char *n = f->ifa_name ? f->ifa_name : "";
                if (strncmp(n, "lo", 2) == 0 || strncmp(n, "pdp", 3) == 0 ||
                    strncmp(n, "utun", 4) == 0 || strncmp(n, "awdl", 4) == 0 ||
                    strncmp(n, "bridge", 6) == 0) continue;
                char b[INET_ADDRSTRLEN] = {0};
                inet_ntop(AF_INET, &((struct sockaddr_in *)f->ifa_addr)->sin_addr, b, sizeof(b));
                if (strcmp(b, "127.0.0.1") == 0) continue;
                if (strncmp(n, "en", 2) == 0) { strncpy(ipbuf, b, sizeof(ipbuf) - 1); break; }
                if (!any[0]) strncpy(any, b, sizeof(any) - 1);
            }
            if (!ipbuf[0] && any[0]) {} // en 缺失时退回 any
            if (strcmp(ipbuf, "?") == 0 && any[0]) strncpy(ipbuf, any, sizeof(ipbuf) - 1);
            freeifaddrs(ifa);
        }
        char msg[160];
        snprintf(msg, sizeof(msg), "ODEBUGD_BEACON %s %d %s", ipbuf, gPort, gVersion.UTF8String);
        struct sockaddr_in a = {0};
        a.sin_len = sizeof(a);
        a.sin_family = AF_INET;
        a.sin_port = htons(4323);
        a.sin_addr.s_addr = INADDR_BROADCAST;
        sendto(s, msg, (int)strlen(msg), 0, (struct sockaddr *)&a, sizeof(a));
        sleep(5);
    }
    return NULL;
}

/// 1.0.144：Bonjour(mDNS) 广播线程——WLAN 模式下宣告 _odebugd._tcp.，
/// 电脑端（odebug.sh）用 dns-sd 解析出手机 IP 直连，免手动输地址。
static void *bonjourThread(void *unused) {
    @autoreleasepool {
        static OdbgBonjourLogger *lg;
        NSNetService *svc = [[NSNetService alloc] initWithDomain:@"" type:@"_odebugd._tcp."
                                                             name:@"odebugd" port:gPort];
        lg = [[OdbgBonjourLogger alloc] init];
        svc.delegate = lg;
        [svc setTXTRecordData:[@"path=/" dataUsingEncoding:NSUTF8StringEncoding]];
        [svc scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        [svc publish];
        applog(@"Bonjour 广播 _odebugd._tcp. 开始发布（结果见下一条日志）");
        [[NSRunLoop currentRunLoop] run];
    }
    return NULL;
}

static NSString *loadToken(void) {
    NSArray<NSString *> *cands = @[
        [gJbroot stringByAppendingString:@"/Library/MobileSubstrate/DynamicLibraries/ODebug.plist"],
        [gJbroot stringByAppendingString:@"/var/mobile/Library/Preferences/com.tanyou.opendebug.settings.plist"],
        @"/var/mobile/Library/Preferences/com.tanyou.opendebug.settings.plist",
    ];
    for (NSString *p in cands) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        id t = d[@"debugAuthToken"];
        if ([t isKindOfClass:[NSString class]] && [t length]) return t;
    }
    const char *env = getenv("ODEBUG_TOKEN");
    if (env && env[0]) return @(env);
    return @"opendebug";   // 1.0.144：首装默认令牌（与插件 4321 侧一致，改偏好即热生效）
}

/// 打一行内存/端口占用。daemon 曾经在长轮询命令（!win / !inject 的轮询）之后「无声无息」死掉，
/// 既没有崩溃回溯也没有 exit code —— 这种多半是 jetsam/端口耗尽，所以把 footprint 落到日志里对照。
static void odbgLogFootprint(const char *tag) {
    struct task_basic_info_64 bi;
    mach_msg_type_number_t bc = TASK_BASIC_INFO_64_COUNT;
    unsigned long long rss = 0;
    if (task_info(mach_task_self(), TASK_BASIC_INFO_64, (task_info_t)&bi, &bc) == KERN_SUCCESS)
        rss = (unsigned long long)bi.resident_size;
    mach_port_name_array_t names = NULL;
    mach_port_type_array_t types = NULL;
    mach_msg_type_number_t nn = 0, tn = 0;
    unsigned int ports = 0;
    if (mach_port_names(mach_task_self(), &names, &nn, &types, &tn) == KERN_SUCCESS) {
        ports = (unsigned int)nn;
        vm_deallocate(mach_task_self(), (vm_address_t)names, nn * sizeof(mach_port_name_t));
        vm_deallocate(mach_task_self(), (vm_address_t)types, tn * sizeof(mach_port_type_t));
    }
    applog(@"[%s] pid=%d rss=%.1f MB 端口名=%u", tag, getpid(), rss / 1048576.0, ports);
}

static void clientLoop(int fd) {
    NSString *banner = [NSString stringWithFormat:
        @"ODebug 常驻调试服务 odebugd %@ (pid %d, root, 端口 %d) — 安全模式下也可用\n"
        @"输入 help 看命令菜单（可连续输入多条）\n", gVersion, getpid(), gPort];
    write(fd, banner.UTF8String, strlen(banner.UTF8String));
    applog(@"+conn fd=%d", fd);
    odbgLogFootprint("conn+");

    char buf[4096];
    NSMutableString *pending = [NSMutableString string];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n <= 0) break;
        [pending appendString:[[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding] ?: @""];
        NSRange nl;
        while ((nl = [pending rangeOfString:@"\n"]).location != NSNotFound) {
            NSString *line = [pending substringToIndex:nl.location];
            [pending deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
            line = trim(line);
            if (line.length == 0) continue;
            NSString *cmd = line;
            if ([[line uppercaseString] hasPrefix:@"AUTH "]) {
                NSArray *parts = [line componentsSeparatedByString:@" "];
                if (parts.count < 3) continue;
                NSString *token = parts[1];
                NSRange rest = [line rangeOfString:parts[2]];
                cmd = rest.location == NSNotFound ? @"" : [line substringFromIndex:rest.location];
                NSString *expect = loadToken();
                if (!expect.length || ![token isEqualToString:expect]) {
                    NSString *no = @"❌ 未认证: 请发送 AUTH <token> <命令>（令牌见 ODebug 设置页 / ODebug.plist 的 debugAuthToken）\n";
                    write(fd, no.UTF8String, strlen(no.UTF8String));
                    continue;
                }
            }
            applog(@"cmd: %@", cmd);
            NSString *rsp = dispatchCommand(cmd);
            applog(@"[ok] %@ 完成", cmd);
            odbgLogFootprint("cmd-");
            if ([rsp isEqualToString:@"__BYE__"]) {
                NSString *bye = @"再见\n";
                write(fd, bye.UTF8String, strlen(bye.UTF8String));
                close(fd);
                return;
            }
            if (rsp.length) write(fd, rsp.UTF8String, strlen(rsp.UTF8String));
        }
    }
    applog(@"-conn fd=%d", fd);
    close(fd);
}

static void *clientThread(void *arg) {
    @autoreleasepool {
        int fd = (int)(intptr_t)arg;
        clientLoop(fd);
    }
    return NULL;
}

#pragma mark - main

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        gJbroot = findJbroot();
        if (!gJbroot) {
            fprintf(stderr, "odebugd: 找不到 jbroot（/private/var/containers/Bundle/Application/.jbroot-*）\n");
            return 1;
        }
        NSString *logDir = [gJbroot stringByAppendingString:@"/var/log"];
        [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:NULL];
        gLogPath = [logDir stringByAppendingPathComponent:@"odebugd.log"];
        odbgInstallCrashHandlers();

        const char *pe = getenv("ODEBUGD_PORT");
        if (pe) gPort = atoi(pe);
        const char *pb = getenv("ODEBUGD_BIND");   // "0.0.0.0"/"lan"/"any" ⇒ 监听所有网卡（WLAN 直连）
        int bindExplicit = 0;
        if (pb) { gBindAny = (strcasecmp(pb, "0.0.0.0") == 0 || strcasecmp(pb, "lan") == 0 || strcasecmp(pb, "any") == 0); bindExplicit = 1; }
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) gPort = atoi(argv[++i]);
            if (strcmp(argv[i], "--bind") == 0 && i + 1 < argc) {
                const char *b = argv[++i];
                gBindAny = (strcmp(b, "0.0.0.0") == 0 || strcasecmp(b, "lan") == 0 || strcasecmp(b, "any") == 0);
                bindExplicit = 1;
            }
            if (strcmp(argv[i], "--foreground") == 0) { /* launchd 下默认即前台 */ }
        }
        // 没有显式 --bind/ODEBUGD_BIND 时，跟随设置页的「WLAN 直连」开关（debugBindAll）
        if (!bindExplicit) {
            for (NSString *p in @[
                [gJbroot stringByAppendingString:@"/var/mobile/Library/Preferences/com.tanyou.opendebug.settings.plist"],
                @"/var/mobile/Library/Preferences/com.tanyou.opendebug.settings.plist",
            ]) {
                NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
                id v = d[@"debugBindAll"];
                if ([v respondsToSelector:@selector(boolValue)]) { gBindAny = [v boolValue]; break; }
            }
        }

        applog(@"==== odebugd %@ 启动 (jbroot=%@, port=%d, uid=%d) ====", gVersion, gJbroot, gPort, getuid());

        int srv = socket(AF_INET, SOCK_STREAM, 0);
        if (srv < 0) { applog(@"socket 失败 errno=%d", errno); return 1; }
        int one = 1;
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_port = htons((uint16_t)gPort);
        sa.sin_addr.s_addr = gBindAny ? htonl(INADDR_ANY) : htonl(INADDR_LOOPBACK);   // WLAN 直连模式绑 0.0.0.0（token 鉴权），默认仅回环
        if (bind(srv, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
            applog(@"bind %@:%d 失败 errno=%d", gBindAny ? @"0.0.0.0" : @"127.0.0.1", gPort, errno);
            return 1;
        }
        if (listen(srv, 16) != 0) { applog(@"listen 失败 errno=%d", errno); return 1; }
        fcntl(srv, F_SETFD, FD_CLOEXEC);   // ★ 绝不能被 posix_spawn 出来的子进程继承：否则子进程会一直占着这个监听端口
        applog(@"监听 %@:%d 就绪%@", gBindAny ? @"0.0.0.0" : @"127.0.0.1", gPort, gBindAny ? @"（WLAN 直连已开启：同网段电脑可直接连手机 IP，凭 token 鉴权）" : @"");

        // 1.0.144：WLAN 模式下广播自动发现（Bonjour + UDP 信标双通道），电脑端免手动输 IP
        if (gBindAny) {
            pthread_t bn, bc2;
            if (pthread_create(&bn, NULL, bonjourThread, NULL) == 0) pthread_detach(bn);
            if (pthread_create(&bc2, NULL, beaconThread, NULL) == 0) pthread_detach(bc2);
        }

        pthread_t wd;
        if (pthread_create(&wd, NULL, autoInjectThread, NULL) == 0) pthread_detach(wd);
        applog(@"安全模式兜底看门狗已启动（!auto status 查看）");

        for (;;) {
            int fd = accept(srv, NULL, NULL);
            if (fd < 0) { usleep(100 * 1000); continue; }
            fcntl(fd, F_SETFD, FD_CLOEXEC);
            pthread_t th;
            if (pthread_create(&th, NULL, clientThread, (void *)(intptr_t)fd) == 0) {
                pthread_detach(th);
            } else {
                close(fd);
            }
        }
    }
    return 0;
}
