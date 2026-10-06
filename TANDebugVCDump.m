//
//  TANDebugVCDump.m
//  实现：沿 nextResponder 链找 view 的控制器；递归输出视图树；注册 Darwin 通知触发 dump。
//

#import "TANDebugVCDump.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>

UIViewController *TANVCDumpViewControllerForView(UIView *view) {
    id responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) return responder;
        responder = [responder nextResponder];
    }
    return nil;
}

static void tan_appendViewTree(UIView *view, NSInteger depth, NSString *filter, NSMutableString *out) {
    NSString *indent = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@"  " startingAtIndex:0];
    NSString *clsName = NSStringFromClass([view class]);
    if (filter.length == 0 || [clsName rangeOfString:filter].location != NSNotFound) {
        UIViewController *vc = TANVCDumpViewControllerForView(view);
        CGRect f = view.frame;
        [out appendFormat:@"%@<%@> %p frame=(%.0f,%.0f,%.0f,%.0f) -> %@ %p\n",
         indent, clsName, view, f.origin.x, f.origin.y, f.size.width, f.size.height,
         vc ? NSStringFromClass([vc class]) : @"(无控制器)", vc ? (__bridge void *)vc : NULL];
    }
    for (UIView *sub in view.subviews) {
        tan_appendViewTree(sub, depth + 1, filter, out);
    }
}

NSString *TANVCDumpKeyWindowToStringFiltered(NSString *filter) {
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    NSMutableString *result = [NSMutableString string];
    if (keyWindow) {
        [result appendFormat:@"keyWindow: %@ %@\n", NSStringFromClass([keyWindow class]), NSStringFromCGRect(keyWindow.frame)];
        tan_appendViewTree(keyWindow, 0, filter ?: @"", result);
    } else {
        [result appendString:@"(无 keyWindow)\n"];
    }
    return result;
}

NSString *TANVCDumpKeyWindowToString(void) {
    return TANVCDumpKeyWindowToStringFiltered(@"");
}

/// 遍历所有 window（含悬浮窗/overlay）；每个 window 标头 + 视图树。
/// 带 filter 时只输出含匹配 view 的 window（空 window 整段跳过，减少刷屏）
NSString *TANVCDumpAllWindowsToStringFiltered(NSString *filter) {
    NSMutableString *result = [NSMutableString string];
    NSArray *windows = [UIApplication sharedApplication].windows;
    if (!windows.count) return @"(无 window)";
    for (UIWindow *w in windows) {
        NSMutableString *sub = [NSMutableString string];
        tan_appendViewTree(w, 0, filter ?: @"", sub);
        if (sub.length == 0) continue;   // 过滤模式下无匹配 → 跳过整个 window
        [result appendFormat:@"[window] %@ %@\n", NSStringFromClass([w class]), NSStringFromCGRect(w.frame)];
        [result appendString:sub];
    }
    return result;
}

/// 沿 presented / 容器链找最上层控制器（KVC 读 topViewController/selectedViewController 避免 performSelector warning）
static UIViewController *tan_topViewController(UIViewController *vc) {
    UIViewController *cur = vc;
    int guard = 0;
    while (cur && guard++ < 30) {
        UIViewController *next = nil;
        @try {
            if (cur.presentedViewController) {
                next = cur.presentedViewController;
            } else if ([cur respondsToSelector:@selector(topViewController)]) {          // UINavigationController
                id t = [cur valueForKey:@"topViewController"];
                if (t && t != cur) next = t;
            } else if ([cur respondsToSelector:@selector(selectedViewController)]) {      // UITabBarController
                id t = [cur valueForKey:@"selectedViewController"];
                if (t && t != cur) next = t;
            } else if ([cur respondsToSelector:@selector(childViewControllers)]) {        // 通用容器
                id ch = [cur valueForKey:@"childViewControllers"];
                if ([ch isKindOfClass:[NSArray class]] && [ch count]) next = [ch lastObject];
            }
        } @catch (NSException *e) {}
        if (!next || next == cur) break;
        cur = next;
    }
    return cur;
}

/// 只输出最上层控制器：类名 + 内存地址
NSString *TANVCDumpTopViewControllerString(void) {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *top = tan_topViewController(window.rootViewController);
    if (top) {
        // 类名青色 + 地址黄色（控制台终端显示用；syslog 里 ANSI 会乱码，跨进程用 Plain 版）
        return [NSString stringWithFormat:@"Top: \033[36m%@\033[0m \033[33m%p\033[0m", NSStringFromClass([top class]), top];
    }
    return @"(无 rootViewController)";
}

/// 不带颜色的最上层控制器（App 跨进程 dump 到 syslog 用，避免 ANSI 码乱码）
static NSString *tan_topViewControllerPlainString(void) {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *top = tan_topViewController(window.rootViewController);
    if (top) {
        return [NSString stringWithFormat:@"Top: %@ %p", NSStringFromClass([top class]), top];
    }
    return @"(无 rootViewController)";
}

/// 是否有可见 UI（keyWindow + rootViewController 都存在）——过滤后台进程
static BOOL tan_hasVisibleUI(void) {
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    if (!w) w = [UIApplication sharedApplication].windows.firstObject;
    if (!w) return NO;
    return tan_topViewController(w.rootViewController) != nil;
}

/// 把 dump 文本回传给 odebugd(4322)（WLAN 下 Mac 没有 idevicesyslog，靠这个通道显示）
/// 异步后台发，失败静默（daemon 不在也无所谓，syslog 里仍有 NSLog 的那份）
void tan_sendVcDumpToDaemon(NSString *text) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return;
        struct sockaddr_in a = {0};
        a.sin_family = AF_INET;
        a.sin_port = htons(4322);
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        struct timeval tv = {2, 0};
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        if (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) {
            NSString *msg = [NSString stringWithFormat:@"VCDUMP %@\n", text];
            const char *p = msg.UTF8String;
            size_t left = strlen(p);
            while (left > 0) {
                ssize_t w = write(fd, p, left);
                if (w <= 0) break;
                p += w; left -= w;
            }
        }
        close(fd);
    });
}

/// Darwin 通知回调：把当前进程的视图树打印到 syslog（[open] 前缀，供 idevicesyslog grep）
/// 只响应前台且有 UI 的 App，避免后台进程（如 mapspushd）产生噪音。
/// 同步执行（不 dispatch_async 主队列）——后台挂起的 App 主队列不跑，同步才能打印。
static void tan_dumpVCNotification(CFNotificationCenterRef c, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    if (!tan_hasVisibleUI()) return;
    NSString *tree = TANVCDumpKeyWindowToString();
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
    NSLog(@"[open] /VCDump [%@]:\n%@", bid, tree);
    tan_sendVcDumpToDaemon([NSString stringWithFormat:@"VCDump [%@]:\n%@", bid, tree]);
}

/// Darwin 通知回调：只打印最上层控制器（类名 + 内存地址），只响应前台且有 UI 的 App
static void tan_dumpVCTopNotification(CFNotificationCenterRef c, void *observer, CFStringRef name,
                                      const void *object, CFDictionaryRef userInfo) {
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    if (!tan_hasVisibleUI()) return;
    NSString *s = tan_topViewControllerPlainString();   // 不带颜色（syslog 里 ANSI 会乱码）
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
    NSLog(@"[open] /VCDumpTop [%@]:\n%@", bid, s);
    tan_sendVcDumpToDaemon([NSString stringWithFormat:@"VCDumpTop [%@]:\n%@", bid, s]);
}

/// dump 单个类的完整结构（继承/协议/属性/实例方法/类方法）
static NSString *tan_classDumpString(Class cls) {
    NSMutableString *r = [NSMutableString string];
    [r appendFormat:@"\n#pragma mark - %@\n", NSStringFromClass(cls)];
    NSMutableArray *chain = [NSMutableArray array];
    Class c = cls;
    while (c) { [chain addObject:NSStringFromClass(c)]; c = [c superclass]; }
    [r appendFormat:@"继承: %@\n", [chain componentsJoinedByString:@" → "]];
    unsigned int n = 0;
    Protocol *__unsafe_unretained *protos = class_copyProtocolList(cls, &n);
    if (n > 0) {
        [r appendString:@"协议: "];
        for (unsigned int i = 0; i < n; i++) [r appendFormat:@"%@ ", NSStringFromProtocol(protos[i])];
        [r appendString:@"\n"];
    }
    free(protos);
    objc_property_t *props = class_copyPropertyList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        [r appendFormat:@"@property (%@) %@;\n",
            [NSString stringWithUTF8String:property_getAttributes(props[i])],
            [NSString stringWithUTF8String:property_getName(props[i])]];
    }
    free(props);
    Method *methods = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        [r appendFormat:@"- %@\n", NSStringFromSelector(method_getName(methods[i]))];
    }
    free(methods);
    Method *cm = class_copyMethodList(object_getClass(cls), &n);
    for (unsigned int i = 0; i < n; i++) {
        [r appendFormat:@"+ %@\n", NSStringFromSelector(method_getName(cm[i]))];
    }
    free(cm);
    return r;
}

/// 在当前进程 dump 属于自己的类到 tmp 文件（由注入目标 App 收到通知后调用）
static void tan_dumpOwnClassesToFile(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
    // 用 bundlePath 前缀匹配类镜像（镜像路径 = bundlePath/可执行文件），比 hasSuffix 可靠
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    if (!bundlePath.length) { NSLog(@"[open] /ClassDump [%@]: 无法确定 bundle 路径", bid); return; }

    // 写目录 classdump_<bid>/，每个类一个文件（方便电脑上按类名查看）
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"classdump_%@", bid]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dir error:nil];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSInteger clsCount = 0;
    unsigned int total = 0;
    Class *classes = objc_copyClassList(&total);
    if (classes) {
        for (unsigned int i = 0; i < total; i++) {
            @try {
                const char *img = class_getImageName(classes[i]);
                if (img) {
                    NSString *imgStr = [NSString stringWithUTF8String:img];
                    // 只 dump App 主二进制（在 bundle 内且不在 Frameworks 子目录），避免 5 万+ 框架类
                    if ([imgStr hasPrefix:bundlePath] && [imgStr rangeOfString:@"/Frameworks/"].location == NSNotFound) {
                        NSString *clsName = NSStringFromClass(classes[i]);
                        NSString *file = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.txt", clsName]];
                        [tan_classDumpString(classes[i]) writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
                        clsCount++;
                    }
                }
            } @catch (NSException *e) {}
        }
        free(classes);
    }
    NSLog(@"[open] /ClassDump [%@]: 已 dump %ld 个类 → %@/", bid, (long)clsCount, dir);
}

/// Darwin 通知回调：App 在自己进程里 dump 自己的类到文件（跨进程，由 !dump 触发）
static void tan_dumpClassesNotification(CFNotificationCenterRef c, void *observer, CFStringRef name,
                                        const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        tan_dumpOwnClassesToFile();
    });
}

void TANVCDumpRegisterDarwinListener(void) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        tan_dumpVCNotification, CFSTR("com.tanyou.open/dumpVC"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        tan_dumpVCTopNotification, CFSTR("com.tanyou.open/dumpVCTop"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        tan_dumpClassesNotification, CFSTR("com.tanyou.open/dumpClasses"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}
