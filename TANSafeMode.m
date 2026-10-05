/**
 * TANSafeMode.m — ODebug 安全模式开关实现（机制见 TANSafeMode.h）
 *
 * 2026-10-06 真机单变量实测（frida 探针读进程自己的 TweakInject 模块数）：
 *   标记不存在            → tweakinject=2（Choicy/Crane） = 正常注入
 *   标记普通文件          → tweakinject=0                = 安全模式
 *   悬空软链              → tweakinject=2                = 正常注入（⇒ 检查跟随软链）
 *   软链 + 目标存在       → tweakinject=0                = 安全模式
 *   ★ 标记写 <jbroot>/var/mobile/.eksafemode + SIGKILL SpringBoard ⇒ 新 SpringBoard 0 个 tweak
 *   ★ 标记写真实 /var/mobile/.eksafemode                         ⇒ 新 SpringBoard 仍 47 个 tweak
 */
#import "TANSafeMode.h"
#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <signal.h>
#import <spawn.h>
#import <sys/stat.h>
#import <unistd.h>

extern char **environ;

/// 旧版本（1.0.118-2 之前）误写的路径：注入器不看它，仅用于清理与提示
static NSString *const kTANLegacyRealFlagPath = @"/var/mobile/.eksafemode";

NSString *const TANSafeModeDarwinOnNotification = @"com.tanyou.opendebug.safemode.on";
NSString *const TANSafeModeDarwinOffNotification = @"com.tanyou.opendebug.safemode.off";

/// 从任意 dylib 路径里截出 "/.jbroot-xxxx"（roothide 容器根）
static NSString *tan_jbroot_in_path(NSString *p) {
    if (!p.length) return nil;
    NSRange r = [p rangeOfString:@"/.jbroot-"];
    if (r.location == NSNotFound) return nil;
    NSRange after = NSMakeRange(r.location + 1, p.length - r.location - 1);
    NSUInteger slash = [p rangeOfString:@"/" options:0 range:after].location;
    return slash == NSNotFound ? p : [p substringToIndex:slash];
}

NSString *TANJbrootPath(void) {
    static NSString *cached = nil;
    if (cached) return cached;
    Dl_info info;
    if (dladdr((void *)TANJbrootPath, &info) != 0 && info.dli_fname) {
        cached = tan_jbroot_in_path([NSString stringWithUTF8String:info.dli_fname]);
    }
    if (!cached) {   // dladdr 兜底：扫已加载 image
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n && !cached; i++) {
            const char *nm = _dyld_get_image_name(i);
            if (nm) cached = tan_jbroot_in_path([NSString stringWithUTF8String:nm]);
        }
    }
    return cached;
}

NSString *TANSafeModeMarkerLinkPath(void) {
    NSString *jb = TANJbrootPath();
    return jb ? [jb stringByAppendingString:@"/basebin/.safe_mode"] : @"/basebin/.safe_mode";
}

NSString *TANSafeModeFlagPath(void) {
    static NSString *cached = nil;
    if (cached) return cached;
    NSString *jb = TANJbrootPath();
    // ★ 必须是 jbroot 侧的 /var/mobile（注入器解析软链用的就是这个视角）
    cached = jb ? [jb stringByAppendingString:@"/var/mobile/.eksafemode"] : kTANLegacyRealFlagPath;
    return cached;
}

BOOL TANSafeModeIsOn(void) {
    return access(TANSafeModeFlagPath().fileSystemRepresentation, F_OK) == 0;
}

static BOOL tan_exists(NSString *p) {
    return p.length && access(p.fileSystemRepresentation, F_OK) == 0;
}

/// 注入软链状态（用 lstat/readlink，不跟随 —— 跟随会把悬空软链报成「不存在」）
static NSString *tan_markerLinkState(void) {
    NSString *link = TANSafeModeMarkerLinkPath();
    const char *lp = link.fileSystemRepresentation;
    struct stat st;
    if (lstat(lp, &st) != 0) {
        return [NSString stringWithFormat:@"不存在（需重装 ODebug：postinst 会建软链 %@ → %@）", link, kTANLegacyRealFlagPath];
    }
    if (!S_ISLNK(st.st_mode)) {
        return [NSString stringWithFormat:@"不是软链而是普通文件: %@", link];
    }
    char buf[PATH_MAX] = {0};
    ssize_t n = readlink(lp, buf, sizeof(buf) - 1);
    NSString *dest = n > 0 ? [NSString stringWithUTF8String:buf] : @"?";
    if (![dest isEqualToString:kTANLegacyRealFlagPath]) {
        return [NSString stringWithFormat:@"指向 %@（预期 %@）", dest, kTANLegacyRealFlagPath];
    }
    return [NSString stringWithFormat:@"OK（%@ → %@）", link, dest];
}

BOOL TANSafeModeEnable(NSString **detail) {
    NSString *flag = TANSafeModeFlagPath();
    NSString *body = [NSString stringWithFormat:
                      @"[%@] ODebug 安全模式标记\n"
                      @"删除本文件（或电脑侧 safemode_enter.py exit --yes）再 respring 即可退出安全模式。\n",
                      [NSDate date]];
    NSError *err = nil;
    BOOL ok = [body writeToFile:flag atomically:YES encoding:NSUTF8StringEncoding error:&err];
    if (!ok) {   // atomically:YES 会先写同目录临时文件再改名，受限时退回直接写
        err = nil;
        ok = [body writeToFile:flag atomically:NO encoding:NSUTF8StringEncoding error:&err];
    }
    if (ok) ok = tan_exists(flag);        // 写后复验，避免「报成功但其实没落盘」
    if (ok) {                             // 清掉旧版本误写的真实路径，避免误导排查
        [[NSFileManager defaultManager] removeItemAtPath:kTANLegacyRealFlagPath error:nil];
    }
    if (detail) {
        *detail = ok ? [NSString stringWithFormat:@"标记已写入 %@（注入软链 %@）", flag, tan_markerLinkState()]
                     : [NSString stringWithFormat:@"写标记失败 %@：%@", flag, err.localizedDescription ?: @"未知错误"];
    }
    return ok;
}

BOOL TANSafeModeDisable(NSString **detail) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *flag = TANSafeModeFlagPath();
    NSString *legacy = kTANLegacyRealFlagPath;
    BOOL hadLegacy = tan_exists(legacy);
    if (hadLegacy) [fm removeItemAtPath:legacy error:nil];   // 旧版本误写的真实路径，顺手清掉
    if (!tan_exists(flag)) {
        if (detail) *detail = [NSString stringWithFormat:@"标记本来就不存在（%@）%@", flag,
                               hadLegacy ? @"；已清理旧版误写的 /var/mobile/.eksafemode" : @""];
        return YES;
    }
    NSError *err = nil;
    BOOL ok = [fm removeItemAtPath:flag error:&err];
    if (detail) {
        *detail = ok ? [NSString stringWithFormat:@"标记已删除（%@）%@", flag,
                        hadLegacy ? @"；同时清理了旧版误写的 /var/mobile/.eksafemode" : @""]
                     : [NSString stringWithFormat:@"删标记失败 %@：%@", flag, err.localizedDescription ?: @"未知错误"];
    }
    return ok;
}

NSString *TANSafeModeStatusText(void) {
    NSString *flag = TANSafeModeFlagPath();
    BOOL marked = tan_exists(flag);
    // ★ 不能再用「本控制台能应答 ⇒ 不是安全模式」反推：odebugd 注入器可以把 ODebug 强行注入回
    //   已经在安全模式里的 SpringBoard（标记照旧生效、其它插件照旧不注入）⇒ 直接读标记说话。
    NSString *note = marked
        ? @"  说明: 标记**存在**，本控制台却活着 ⇒ 本进程是被 odebugd 注入器强行注入回来的\n"
          @"        （安全模式仍然生效：其它插件一律不注入。要真正退出：!safe off + !safe respring）\n"
        : @"  说明: 标记不存在 + 本控制台能应答 ⇒ 正常注入，不是安全模式\n";
    return [NSString stringWithFormat:
            @"===== ODebug 安全模式 =====\n"
            @"标记文件: %@\n"
            @"  当前: %@\n"
            @"注入软链: %@\n"
            @"  状态: %@\n"
            @"旧版误写路径: %@（注入器不看它）\n"
            @"原理: 注入器在**进程启动时**读一次标记，标记存在 ⇒ 该进程不注入任何 tweak\n"
            @"  注入器解析软链用的是 jbroot 侧路径，所以标记必须落在 <jbroot>/var/mobile/ 下\n"
            @"%@"
            @"命令:\n"
            @"  !safe on        写标记 + respring（SpringBoard 变干净；其它守护进程要等重启）\n"
            @"  !safe on all    写标记 + jbctl reboot_userspace（全部进程都干净，约 30-60 秒，会杀光所有 App）\n"
            @"  !safe off       删标记（+ !safe respring 才恢复注入）\n"
            @"  !safe respring  只重启 SpringBoard\n"
            @"  !safe status    本状态\n"
            @"退出安全模式（安全模式下 tweaks 全不注入；若本控制台能应答，那是 odebugd 注入器强行注入的）:\n"
            @"  1) 电脑（SSH / iproxy 已就绪）: 删掉上面的标记文件后 sbreload\n"
            @"  2) Filza / DFTerminal: 删除 %@ 后 sbreload\n"
            @"============================",
            flag,
            marked ? @"存在 ⇒ 新进程进入安全模式"
                   : @"不存在 ⇒ 正常注入",
            TANSafeModeMarkerLinkPath(),
            tan_markerLinkState(),
            kTANLegacyRealFlagPath,
            note,
            flag];
}

void TANSafeModeRespring(void) {
    kill(getpid(), SIGKILL);
}

BOOL TANSafeModeSpawnUreboot(NSString **detail) {
    NSString *jb = TANJbrootPath();
    if (!jb) { if (detail) *detail = @"jbroot 未知"; return NO; }
    NSString *ctl = [jb stringByAppendingString:@"/basebin/jbctl"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:ctl]) {
        if (detail) *detail = [NSString stringWithFormat:@"%@ 不可执行", ctl];
        return NO;
    }
    pid_t pid = 0;
    const char *argv[] = { ctl.fileSystemRepresentation, "reboot_userspace", NULL };
    int rc = posix_spawn(&pid, ctl.fileSystemRepresentation, NULL, NULL, (char *const *)argv, environ);
    if (detail) {
        *detail = rc == 0 ? [NSString stringWithFormat:@"pid %d（%@ reboot_userspace）", pid, ctl]
                          : [NSString stringWithFormat:@"posix_spawn 失败 rc=%d（%@）", rc, ctl];
    }
    return rc == 0;
}

static void tan_safeModeDarwinCallback(CFNotificationCenterRef center, void *observer,
                                       CFNotificationName name, const void *object,
                                       CFDictionaryRef info) {
    NSString *n = name ? (__bridge NSString *)name : @"";
    NSString *detail = nil;
    if ([n isEqualToString:TANSafeModeDarwinOnNotification]) {
        BOOL ok = TANSafeModeEnable(&detail);
        NSLog(@"[ODebug] 收到「进入安全模式」: %@", detail);
        if (ok) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ TANSafeModeRespring(); });
        } else {   // 失败就把开关改回「关」，避免设置页显示与实际不符
            CFPreferencesSetAppValue(CFSTR("safeMode"), kCFBooleanFalse, CFSTR("com.tanyou.opendebug.settings"));
            CFPreferencesAppSynchronize(CFSTR("com.tanyou.opendebug.settings"));
        }
    } else if ([n isEqualToString:TANSafeModeDarwinOffNotification]) {
        BOOL ok = TANSafeModeDisable(&detail);
        NSLog(@"[ODebug] 收到「退出安全模式」: %@", detail);
        if (ok) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ TANSafeModeRespring(); });
        }
    }
}

void TANSafeModeRegisterDarwinListener(void) {
    CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(c, NULL, tan_safeModeDarwinCallback,
                                    (__bridge CFStringRef)TANSafeModeDarwinOnNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(c, NULL, tan_safeModeDarwinCallback,
                                    (__bridge CFStringRef)TANSafeModeDarwinOffNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    NSLog(@"[ODebug] 安全模式开关监听已注册（%@ / %@）", TANSafeModeDarwinOnNotification, TANSafeModeDarwinOffNotification);
}
