/**
 * TANDebugConsole - TCP 远程调试控制台 (端口 4321)
 *
 * 连接 localhost:4321 进行运行时调试。每条命令必须带认证令牌：`AUTH <token> <命令>`，未认证不执行。
 *   例：AUTH abc123 !plist read /var/mobile/Library/Preferences/x.plist
 * 令牌来源：读偏好设置 com.tanyou.opendebug.settings/debugAuthToken（OpenDebug 设置页可看/改）；
 *   未设置时首次启动自动生成 UUID 并打印到设备 syslog（`[TANConsole] 调试令牌:`）。
 * 支持命令：!eval / !class / !mem read|write / !icons list|hide|show / !plist read|write /
 *          !vc [ClassName] / !vcapp [bundleId] / !grep <关键词>(过滤上一条命令输出) / !ivars [关键词]
 *          !safe on|on all|off|respring|status（安全模式：写标记 /var/mobile/.eksafemode 禁用全部插件）
 * 说明：!eval 里的 sharedManager/contextHost 别名依赖主插件 Open（提供 TANFloatController/TANContextHost）。
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/utsname.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <UIKit/UIKit.h>
#import "TANDebugConsole.h"
#import "TANDebugVCDump.h"
#import "TANHookConsole.h"
#import "TANSafeMode.h"

// ANSI 颜色（iTerm2/终端显示；非终端会显示转义码）
#define CLR_RED     @"\033[31m"
#define CLR_GREEN   @"\033[32m"
#define CLR_YELLOW  @"\033[33m"
#define CLR_BLUE    @"\033[34m"
#define CLR_CYAN    @"\033[36m"
#define CLR_RESET   @"\033[0m"

// 给消息包一层颜色
static NSString *tan_clr(NSString *color, NSString *msg) {
    return [NSString stringWithFormat:@"%@%@%@", color, msg, CLR_RESET];
}

/// 判断指针是否落在进程已映射的可读内存区。
/// 用途：!ivars / !mem read 在 dereference 前先校验，防止读悬垂指针 → SIGSEGV → 安全模式。
/// @try/@catch 挡不住 SIGSEGV（信号异常不是 NSException），必须靠这个前置检查。
static BOOL tan_isReadableAddress(const void *ptr) {
    if (!ptr) return NO;
    vm_address_t addr = (vm_address_t)(uintptr_t)ptr;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objName;
    kern_return_t kr = vm_region_64(mach_task_self(), &addr, &size,
        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &objName);
    if (kr != KERN_SUCCESS) return NO;
    return (info.protection & VM_PROT_READ) != 0;
}

/// 判断类是否来自系统框架（镜像路径在 /System/ 或 /usr/lib/）。
/// 用途：!ivars 默认跳过系统类，只显示插件自定义类的 ivar，避免 UIView 几百个系统 ivar 刷屏。
/// KVO 包装类（NSKVONotifying_*）动态生成、image 可能为 nil，返回 NO 让上层继续收集。
static BOOL tan_isSystemFrameworkClass(Class cls) {
    const char *img = class_getImageName(cls);
    if (!img) return NO;
    NSString *path = [NSString stringWithUTF8String:img];
    return [path hasPrefix:@"/System/"] || [path hasPrefix:@"/usr/lib/"];
}

// Forward declarations
static void _hideIconWithBundleId(NSString *bid, id allIcons, void(^reply)(NSString *));
static void _showIconWithReply(void(^reply)(NSString *));
static NSRange _findBracket(NSString *s, NSUInteger start);

// !grep 重放过滤用的状态：记录上一条命令，重放时把输出捕获进 buffer
static NSString *tan_lastCmd = nil;
static NSMutableString *tan_captureBuf = nil;
static BOOL tan_captureOnly = NO;

/// 发送响应到 TCP 客户端（不关闭连接，支持交互式连续输入）
static void tan_sendRsp(int fd, NSString *msg) {
    NSLog(@"[TANConsole] >> %@", msg);
    if (!msg) return;
    if (tan_captureOnly) {                     // !grep 重放模式：只进 buffer，不写 fd
        if (tan_captureBuf) [tan_captureBuf appendFormat:@"%@\n", msg];
        return;
    }
    msg = [msg stringByAppendingString:@"\n"];
    const char *s = [msg UTF8String];
    size_t len = strlen(s), off = 0;
    while (off < len) {                       // 循环写，避免大输出只写部分
        ssize_t w = write(fd, s + off, len - off);
        if (w <= 0) break;
        off += (size_t)w;
    }
}

/// 运行时调用类方法（performSelector 避免编译期方法解析——OpenDebug 不编译主插件头文件）
static id tan_callClassSelector(NSString *className, NSString *selName) {
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![cls respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [cls performSelector:sel];
#pragma clang diagnostic pop
}

/// 解析 [Target method] 里的 Target：类名 / sharedManager / contextHost 别名 / 0x实例地址
/// 地址形式解析为对象并做可读性校验（防悬垂指针崩溃），返回 nil 表示无法解析
static id tan_resolveTarget(NSString *name) {
    if ([name isEqualToString:@"sharedManager"]) return tan_callClassSelector(@"TANFloatController", @"sharedManager");
    if ([name isEqualToString:@"contextHost"]) return tan_callClassSelector(@"TANContextHost", @"sharedInstance");
    if ([name hasPrefix:@"0x"] || [name hasPrefix:@"0X"]) {
        unsigned long long addr = 0;
        NSScanner *sc = [NSScanner scannerWithString:name];
        if (![sc scanHexLongLong:&addr] || addr == 0) return nil;
        id obj = (__bridge id)(void *)(uintptr_t)addr;
        if (!tan_isReadableAddress((__bridge const void *)obj)) return nil;  // 悬垂指针拒绝
        return obj;
    }
    return NSClassFromString(name);
}

/// 跳过一段类型编码（支持 @ 对象 / {结构体} / (联合) / [数组] / ^指针 / 单字符），返回下一段位置
static const char *tan_skipType(const char *t) {
    if (!t || !*t) return NULL;
    char c = t[0];
    if (c == '{' || c == '(' || c == '[') {
        char open = c;
        char close = (open == '{') ? '}' : (open == '(') ? ')' : ']';
        int depth = 0; const char *p = t;
        while (*p) {
            if (*p == open) depth++;
            else if (*p == close) { depth--; if (depth == 0) { p++; break; } }
            p++;
        }
        return p;
    }
    if (c == '@') {                       // 对象，可能带 "类名"
        const char *p = t + 1;
        if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p == '"') p++; }
        return p;
    }
    if (c == '^') return tan_skipType(t + 1);
    return t + 1;                         // 单字符类型（v/B/c/Q/:/#/*/f/d…）
}

/// 跳类型 + 后面的偏移数字（编码形如 @28@0:8Q16：返回类型带总大小、每参数带偏移）
static const char *tan_skipTypeAndOffset(const char *t) {
    t = tan_skipType(t);
    if (!t) return NULL;
    while (*t >= '0' && *t <= '9') t++;
    return t;
}

/// 判断 selector 第一个参数是否为对象(@)。返回 NO 表示标量（NSUInteger/BOOL 等）。
/// 用于 !eval 参数分发：标量参数若传 NSNumber 指针会被 objc_msgSend 当数值 → objectAtIndex: 越界崩。
static BOOL tan_firstArgIsObject(id target, SEL s) {
    Method m = class_getInstanceMethod(object_getClass(target), s);
    if (!m) return NO;
    const char *t = method_getTypeEncoding(m);
    if (!t) return NO;
    t = tan_skipTypeAndOffset(t);   // 返回类型 + size
    t = tan_skipTypeAndOffset(t);   // self @0
    t = tan_skipTypeAndOffset(t);   // _cmd :8
    return (t && t[0] == '@');
}

/// 递归求值: !eval [[[Target m1] m2] m3]
static id tan_evalExpr(NSString *expr) {
    expr = [expr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([expr hasPrefix:@"["] && [expr hasSuffix:@"]"])
        expr = [expr substringWithRange:NSMakeRange(1, expr.length - 2)];

    id target = nil;
    NSInteger pos = 0;

    if ([expr characterAtIndex:0] == '[') {
        NSRange br = _findBracket(expr, 0);
        if (br.location == NSNotFound) return nil;
        NSString *nested = [expr substringWithRange:NSMakeRange(br.location - 1, br.length + 2)];
        target = tan_evalExpr(nested);
        pos = br.location + br.length;
    } else {
        NSRange sr = [expr rangeOfString:@" "];
        if (sr.location == NSNotFound) return nil;
        NSString *cname = [expr substringToIndex:sr.location];
        target = tan_resolveTarget(cname);   // 支持类名 / 别名 / 0x实例地址
        pos = sr.location;
    }
    if (!target) return nil;

    NSString *sel = [[expr substringFromIndex:pos + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (sel.length == 0) return nil;
    if ([sel hasSuffix:@"]"]) sel = [sel substringToIndex:sel.length - 1];   // 嵌套外层方法去掉尾部 ']'（如 'class]' → 'class'）
    NSRange lc = [sel rangeOfString:@":" options:NSBackwardsSearch];
    if (lc.location != NSNotFound && lc.location < sel.length - 1) {
        NSString *sn = [sel substringToIndex:lc.location + 1];
        NSString *as = [[sel substringFromIndex:lc.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        SEL s = NSSelectorFromString(sn);
        if (![target respondsToSelector:s]) return (id)@"(无此方法)";   // 防 unrecognized selector 崩溃
        if (tan_firstArgIsObject(target, s)) {   // 对象参数：按原样传
            id arg = nil;
            if ([as hasPrefix:@"@\""] && [as hasSuffix:@"\""])
                arg = [as substringWithRange:NSMakeRange(2, as.length - 3)];
            else if ([as isEqualToString:@"nil"]) arg = nil;
            else if ([as isEqualToString:@"YES"]) arg = @YES;
            else if ([as isEqualToString:@"NO"]) arg = @NO;
            else arg = @([as integerValue]);
            return ((id(*)(id,SEL,id))objc_msgSend)(target, s, arg);
        } else {                                 // 标量参数：传真实标量（防 NSNumber 指针当索引越界崩）
            uintptr_t scalar = 0;
            if ([as isEqualToString:@"YES"]) scalar = 1;
            else if ([as isEqualToString:@"NO"]) scalar = 0;
            else scalar = (uintptr_t)[as integerValue];
            return ((id(*)(id,SEL,uintptr_t))objc_msgSend)(target, s, scalar);
        }
    }
    SEL s = NSSelectorFromString(sel);
    if (![target respondsToSelector:s]) return (id)@"(无此方法)";       // 防 unrecognized selector 崩溃
    return ((id(*)(id,SEL))objc_msgSend)(target, s);
}

/// 找匹配括号，返回括号内内容范围
static NSRange _findBracket(NSString *s, NSUInteger start) {
    if (start >= s.length || [s characterAtIndex:start] != '[') return NSMakeRange(NSNotFound, 0);
    NSInteger depth = 1;
    for (NSUInteger i = start + 1; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '[') depth++;
        else if (c == ']') { depth--; if (depth == 0) return NSMakeRange(start + 1, i - start - 1); }
    }
    return NSMakeRange(NSNotFound, 0);
}

/// 傻瓜式命令菜单（全部命令 + 用法）
static NSString *tan_helpText(void) {
    return @"===== ODebug 调试控制台 =====\n"
    @"【页面/视图】\n"
    @"  !vc                    查看当前页面(SpringBoard)视图树\n"
    @"  !vc top                只看最上层控制器+内存地址\n"
    @"  !vc 类名               只看类名含关键字的视图（如 !vc UIButton）\n"
    @"【跨进程看App】(需在设置→ODebug 选注入目标并重启该App)\n"
    @"  !front                 看当前前台App的最上层控制器+地址\n"
    @"  !vcapp [bundleId]      让注入App打印视图树到syslog（如 !vcapp tv.danmaku.bilianime）\n"
    @"  !vcapp top             让注入App打印最上层控制器+地址\n"
    @"【类/对象】\n"
    @"  !class 类名             查看类的方法和属性（如 !class UIViewController）\n"
    @"  !inheritance 类名       查看类的继承链（如 !inheritance UIViewController）\n"
    @"  !ivars 地址 [all] [关键词] 查看对象实例变量（默认只显示插件自定义类，加 all 含系统类，再加关键词按名字过滤）\n"
    @"【内存】\n"
    @"  !mem read 地址 [长度]   读内存（如 !mem read 0x1234 16）\n"
    @"  !mem write 地址 字节    写内存\n"
    @"【文件】\n"
    @"  !ls 路径                列出目录内容（如 !ls /var/mobile）\n"
    @"  !cat 路径               读文本文件（如 !cat /var/mobile/xx.txt）\n"
    @"  !plist read 路径        读plist（如 !plist read /var/mobile/xx.plist）\n"
    @"  !plist write 路径 键 值  写plist\n"
    @"【桌面图标】\n"
    @"  !icons list             列出所有图标\n"
    @"  !icons hide bundleId    隐藏图标（如 !icons hide com.taobao.fleamarket）\n"
    @"  !icons show             恢复图标\n"
    @"【环境】\n"
    @"  !process                当前进程信息(pid/bundle/参数)\n"
    @"  !sys                    设备/系统信息(型号/版本/内存/CPU)\n"
    @"  !apps                   列出所有已安装App(emoji+颜色区分系统/用户)\n"
    @"  !bundle bundleId        查看App的Info.plist(路径/版本/权限)\n"
    @"  !icon bundleId          显示App真实图标(需iTerm2)\n"
    @"【Dump类结构】\n"
    @"  !dump bundleId          dump App所有类(每类一文件,自动拉取到电脑)\n"
    @"  !dump 插件.dylib路径    dump插件dylib的类(如 !dump /var/jb/.../Open.dylib)\n"
    @"【调用方法】\n"
    @"  [类名/0x地址 方法]      调用方法（如 [TOJBClass001 TOJBMETHOD353] / [0x1068a2400 dataContainerURL]）\n"
    @"  !eval [类名/0x地址 方法] 链式/强制调用（如 !eval [[TOJBClass001 m] m2]）\n"
    @"【动态观察】(log-only hook，日志写 /var/jb/tmp/ODebugHook.log)\n"
    @"  !hook 类名 方法名         动态 hook 并记录调用（如 !hook FBScene setForeground:）\n"
    @"  !hook list               列出当前活跃 hooks\n"
    @"  !unhook 类名 方法名       恢复原实现\n"
    @"  !hook log [行数]         读取 hook 调用日志\n"
    @"【安全模式】(禁用全部插件；标记 /var/mobile/.eksafemode)\n"
    @"  !safe on               写标记 + respring（只清 SpringBoard）\n"
    @"  !safe on all           写标记 + 重启用户空间（所有进程都干净，约30-60秒，会杀光App）\n"
    @"  !safe off              删标记（配 !safe respring 生效）\n"
    @"  !safe respring         只重启 SpringBoard\n"
    @"  !safe status           查看安全模式状态 + 退出办法\n"
    @"【其他】\n"
    @"  !grep 关键词             过滤上一条命令输出（重放+只显示匹配行，对任何命令有效）\n"
    @"  help / ?                显示本菜单\n"
    @"  clear                   清屏(odebug.sh)\n"
    @"  注: odebug.sh 里非!开头的输入作为Mac本地命令执行(可 cat/ls/grep)\n"
    @"============================";
}

/// 获取当前前台 App 的 bundleId（SpringBoard 进程），多方式兜底
static NSString *tan_frontmostBundleId(void) {
    NSString *bid = nil;
    @try {
        id workspace = [NSClassFromString(@"LSApplicationWorkspace") valueForKey:@"defaultWorkspace"];
        if (workspace) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id front = [workspace performSelector:@selector(frontmostApplication)];
#pragma clang diagnostic pop
            if (front) {
                id v = [front valueForKey:@"applicationIdentifier"];
                if (!v) v = [front valueForKey:@"bundleIdentifier"];
                bid = v;
            }
        }
    } @catch (NSException *e) {}
    if (!bid.length) {   // 兜底：UIApplication 私有方法
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id app = [[UIApplication sharedApplication] performSelector:@selector(_accessibilityFrontMostApplication)];
#pragma clang diagnostic pop
            if (app) bid = [app valueForKey:@"bundleIdentifier"];
        } @catch (NSException *e) {}
    }
    if (!bid.length) NSLog(@"[TANConsole] 前台App识别失败");
    return bid;
}

/// dump 单个类的完整结构（继承/协议/属性/实例方法/类方法）——用于 dylib dump
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

/// 解析并执行调试命令
static void tan_eval(int fd, NSString *raw) {
    raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (raw.length == 0 || [raw isEqualToString:@"help"] || [raw isEqualToString:@"?"]
        || [raw isEqualToString:@"h"] || [raw isEqualToString:@"help / ?"] || [raw isEqualToString:@"/?"]
        || [raw isEqualToString:@"菜单"] || [raw isEqualToString:@"命令"]) {
        tan_sendRsp(fd, tan_helpText());
        return;
    }

    // !hook / !unhook / !hooklog - 动态方法观察（log-only，TANHookConsole 模块）
    if ([raw hasPrefix:@"!hook"] || [raw hasPrefix:@"!unhook"]) {
        if (TANHookHandleCommand(fd, raw)) return;
    }

    // !grep <关键词> - 重放上一条命令，只显示匹配行（通用过滤，!vc TOJB 只对 !vc 有效，!grep 对任何命令有效）
    if ([raw hasPrefix:@"!grep"]) {
        NSString *pat = [[raw substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (pat.length == 0) { tan_sendRsp(fd, @"用法: !grep <关键词>，过滤上一条命令输出（如先 !ivars 0x... 再 !grep shortcutItems）"); return; }
        if (tan_lastCmd.length == 0) { tan_sendRsp(fd, @"还没有上一条命令，先执行一个命令再 !grep"); return; }
        tan_captureBuf = [NSMutableString string];
        tan_captureOnly = YES;
        tan_eval(fd, tan_lastCmd);            // 重放上一条命令，输出进 buffer
        tan_captureOnly = NO;
        NSString *all = tan_captureBuf;
        tan_captureBuf = nil;
        if (all.length == 0) { tan_sendRsp(fd, @"(上一条命令无输出)"); return; }
        NSArray *lines = [all componentsSeparatedByString:@"\n"];
        NSMutableArray *hits = [NSMutableArray array];
        for (NSString *line in lines) {
            if ([line localizedCaseInsensitiveContainsString:pat]) [hits addObject:line];
        }
        if (hits.count == 0) tan_sendRsp(fd, [NSString stringWithFormat:@"(无匹配 \"%@\")", pat]);
        else tan_sendRsp(fd, [hits componentsJoinedByString:@"\n"]);
        return;
    }
    tan_lastCmd = raw;                         // 记录供 !grep 重放

    // !safe - 安全模式开关（禁用全部 tweak）：标记 /var/mobile/.eksafemode + respring / 用户空间重启
    if ([raw hasPrefix:@"!safe"]) {
        NSString *arg = [[raw substringFromIndex:5] stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (arg.length == 0 || [arg isEqualToString:@"status"] || [arg isEqualToString:@"?"]) {
            tan_sendRsp(fd, TANSafeModeStatusText());
            return;
        }
        if ([arg isEqualToString:@"on"]) {
            NSString *detail = nil;
            if (!TANSafeModeEnable(&detail)) { tan_sendRsp(fd, [NSString stringWithFormat:@"❌ %@", detail]); return; }
            tan_sendRsp(fd, [NSString stringWithFormat:
                @"✅ %@\n即将 respring 进入安全模式（SpringBoard 立刻干净；其它守护进程要等用户空间重启/自行重启，"
                @"想一次清完用 !safe on all）", detail]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ TANSafeModeRespring(); });
            return;
        }
        if ([arg isEqualToString:@"on all"]) {
            NSString *detail = nil, *udetail = nil;
            if (!TANSafeModeEnable(&detail)) { tan_sendRsp(fd, [NSString stringWithFormat:@"❌ %@", detail]); return; }
            BOOL ok = TANSafeModeSpawnUreboot(&udetail);
            tan_sendRsp(fd, [NSString stringWithFormat:@"✅ %@\n%@", detail,
                ok ? [NSString stringWithFormat:@"已触发用户空间重启：%@（约 30-60 秒，回来后所有进程都干净）", udetail]
                   : [NSString stringWithFormat:@"⚠️ 用户空间重启没触发（%@），退回 respring：只清 SpringBoard", udetail]]);
            if (!ok) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ TANSafeModeRespring(); });
            }
            return;
        }
        if ([arg isEqualToString:@"off"]) {
            NSString *detail = nil;
            BOOL ok = TANSafeModeDisable(&detail);
            tan_sendRsp(fd, [NSString stringWithFormat:@"%@ %@\n（标记只在进程启动时生效：还要 respring/重启进程才恢复注入，见 !safe respring）",
                             ok ? @"✅" : @"❌", detail]);
            return;
        }
        if ([arg isEqualToString:@"respring"]) {
            tan_sendRsp(fd, @"✅ 立即 respring（SpringBoard 重启，TCP 连接会断）");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ TANSafeModeRespring(); });
            return;
        }
        tan_sendRsp(fd, @"用法: !safe [status|on|on all|off|respring]（安全模式下控制台不可用，退出: rm -f /var/mobile/.eksafemode && sbreload）");
        return;
    }

    // !mem read/write - 运行时内存操作
    if ([raw hasPrefix:@"!mem"]) {
        NSArray *parts = [[raw substringFromIndex:5] componentsSeparatedByString:@" "];
        parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (parts.count >= 2 && [parts[0] isEqualToString:@"read"]) {
            unsigned long long addr = 0; NSUInteger len = 16;
            NSScanner *sc = [NSScanner scannerWithString:parts[1]]; [sc scanHexLongLong:&addr];
            if (parts.count >= 3) len = [parts[2] integerValue];
            if (len > 256) len = 256;
            if (addr > 0) {
                if (!tan_isReadableAddress((void *)(uintptr_t)addr)) {
                    tan_sendRsp(fd, [NSString stringWithFormat:@"地址不可读（悬垂指针或越界，已拒绝读取以免崩溃）: %#llx", addr]);
                    return;
                }
                NSMutableString *out = [NSMutableString stringWithFormat:@"%#llx:", addr];
                for (NSUInteger i = 0; i < len; i++) {
                    unsigned char b = ((unsigned char *)addr)[i];
                    [out appendFormat:@" %02x", b];
                }
                tan_sendRsp(fd, out);
            } else { tan_sendRsp(fd, @"地址无效"); }
        } else if (parts.count >= 3 && [parts[0] isEqualToString:@"write"]) {
            unsigned long long addr = 0, val = 0;
            NSScanner *sc = [NSScanner scannerWithString:parts[1]]; [sc scanHexLongLong:&addr];
            NSScanner *sv = [NSScanner scannerWithString:parts[2]]; [sv scanHexLongLong:&val];
            if (addr > 0) {
                vm_protect(mach_task_self(), (vm_address_t)addr, 1, 0, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
                *(unsigned char *)addr = (unsigned char)val;
                tan_sendRsp(fd, [NSString stringWithFormat:@"已写 %02x → %#llx", (unsigned)val, addr]);
            } else { tan_sendRsp(fd, @"地址无效"); }
        } else { tan_sendRsp(fd, @"用法: !mem read <addr> [len] 或 !mem write <addr> <byte>"); }
        return;
    }

    // !vc [ClassName|top] - 遍历 keyWindow 打印 view -> controller 映射；top 只输出最上层控制器+内存地址
    // 注意：!vc 是 SpringBoard 进程内的视图树（含前台 App 的 scene）。看 App 自己的控制器用 !vcapp
    NSString *frontBid = tan_frontmostBundleId();
    NSString *frontHint = frontBid.length
        ? [NSString stringWithFormat:@"\033[36m[SpringBoard视图树] 当前前台App: %@\033[0m（看该App自己的控制器用 !vcapp / !vcapp top）\n", frontBid]
        : @"\033[36m[SpringBoard视图树]\033[0m（看目标App自己的控制器用 !vcapp）\n";
    if ([raw hasPrefix:@"!vc "]) {
        NSString *filter = [[raw substringFromIndex:4] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([filter isEqualToString:@"top"]) {
            tan_sendRsp(fd, [frontHint stringByAppendingString:TANVCDumpTopViewControllerString()]);
            return;
        }
        // 遍历所有 window（含悬浮窗/overlay），避免菜单在非 keyWindow 里查不到
        NSString *result = TANVCDumpAllWindowsToStringFiltered(filter);
        tan_sendRsp(fd, result.length ? [frontHint stringByAppendingString:result] : @"(空)");
        return;
    }
    if ([raw isEqualToString:@"!vc"]) {
        tan_sendRsp(fd, [frontHint stringByAppendingString:TANVCDumpAllWindowsToStringFiltered(@"")]);
        return;
    }

    // !front - 傻瓜式：让当前前台 App 打印最上层控制器+内存地址（跨进程看当前页面）
    if ([raw isEqualToString:@"!front"] || [raw hasPrefix:@"!front "]) {
        NSString *frontBid = tan_frontmostBundleId();
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.tanyou.open/dumpVCTop"), NULL, NULL, YES);
        if (frontBid.length) {
            tan_sendRsp(fd, [NSString stringWithFormat:@"已让前台 App %@ 打印最上层控制器，用 idevicesyslog | grep -A 5 VCDumpTop 查看", frontBid]);
        } else {
            tan_sendRsp(fd, @"已广播 dumpVCTop（前台 App 会响应），用 idevicesyslog | grep -A 5 VCDumpTop 查看");
        }
        return;
    }

    // !vcapp [bundleId|top] - 发 Darwin 通知，让注入目标 App 打印视图树；top 只打印最上层控制器+内存地址
    if ([raw hasPrefix:@"!vcapp"]) {
        NSString *bid = [[raw substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([bid isEqualToString:@"top"]) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.tanyou.open/dumpVCTop"), NULL, NULL, YES);
            tan_sendRsp(fd, @"已广播 dumpVCTop（若目标 App 未在前台或未重启注入，请先打开它；用 idevicesyslog | grep -A 5 VCDumpTop 查看）");
            return;
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.tanyou.open/dumpVC"), NULL, NULL, YES);
        if (bid.length) {
            tan_sendRsp(fd, [NSString stringWithFormat:@"已向 %@ 发送 dumpVC（若目标 App 未在前台或未重启注入，请先打开它；用 idevicesyslog | grep -A 100 VCDump 查看）", bid]);
        } else {
            tan_sendRsp(fd, @"已广播 dumpVC（若目标 App 未在前台或未重启注入，请先打开它；用 idevicesyslog | grep -A 100 VCDump 查看）");
        }
        return;
    }

    // !icons list/hide/show - 桌面图标管理
    if ([raw hasPrefix:@"!icons"]) {
        NSArray *parts = [[raw substringFromIndex:7] componentsSeparatedByString:@" "];
        parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        id iconCtrl = [NSClassFromString(@"SBIconController") valueForKey:@"sharedInstance"];
        if (!iconCtrl) { tan_sendRsp(fd, @"无 SBIconController"); return; }
        id rootFolder = [iconCtrl valueForKeyPath:@"model.rootFolder"];
        if (!rootFolder) { tan_sendRsp(fd, @"无 rootFolder"); return; }
        id allIcons = [rootFolder valueForKey:@"allIcons"];
        if (parts.count >= 2 && [parts[0] isEqualToString:@"hide"]) {
            _hideIconWithBundleId(parts[1], allIcons, ^(NSString *r) { tan_sendRsp(fd, r); });
        } else if (parts.count >= 2 && [parts[0] isEqualToString:@"show"]) {
            _showIconWithReply(^(NSString *r) { tan_sendRsp(fd, r); });
        } else {
            // 构建 bundleId → 显示名 映射（文本控制台显示不了图片，用 emoji + 名字代替图标）
            NSMutableDictionary *names = [NSMutableDictionary dictionary];
            @try {
                id workspace = [NSClassFromString(@"LSApplicationWorkspace") valueForKey:@"defaultWorkspace"];
                id apps = [workspace valueForKey:@"allInstalledApplications"];
                for (id app in apps) {
                    id b = [app valueForKey:@"applicationIdentifier"];
                    id n = [app valueForKey:@"localizedName"];
                    if ([b isKindOfClass:[NSString class]] && [b length]) {
                        names[b] = [n isKindOfClass:[NSString class]] ? n : @"?";
                    }
                }
            } @catch (NSException *e) {}
            NSMutableString *result = [NSMutableString string];
            for (id icon in allIcons) {
                NSString *bid = [icon valueForKey:@"applicationBundleID"];
                if ([bid isKindOfClass:[NSString class]] && bid.length) {
                    NSString *name = [names objectForKey:bid] ?: @"?";
                    [result appendFormat:@"📱 %@\t%@\n", bid, name];
                }
            }
            tan_sendRsp(fd, result.length ? result : @"(无图标)");
        }
        return;
    }

    // !plist read/write - plist 文件操作
    if ([raw hasPrefix:@"!plist"]) {
        NSArray *parts = [[raw substringFromIndex:7] componentsSeparatedByString:@" "];
        parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (parts.count >= 2 && [parts[0] isEqualToString:@"read"]) {
            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:parts[1]];
            tan_sendRsp(fd, dict ? [NSString stringWithFormat:@"%@", dict] : @"文件不存在或非 plist");
        } else if (parts.count >= 4 && [parts[0] isEqualToString:@"write"]) {
            NSString *path = parts[1]; NSString *key = parts[2]; NSString *val = parts[3];
            NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:path];
            if (!dict) dict = [NSMutableDictionary dictionary];
            dict[key] = val;
            BOOL ok = [dict writeToFile:path atomically:YES];
            tan_sendRsp(fd, ok ? @"已写入" : @"写入失败");
        } else {
            tan_sendRsp(fd, @"用法: !plist read <path>  |  !plist write <path> <key> <value>");
        }
        return;
    }

    // !class [类名] - 列出类的属性和方法（缺参提示用法）
    if ([raw isEqualToString:@"!class"] || [raw hasPrefix:@"!class "]) {
        NSString *cn = [raw hasPrefix:@"!class "] ? [[raw substringFromIndex:7] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
        if (cn.length == 0) { tan_sendRsp(fd, @"用法: !class <类名>，如 !class UIViewController"); return; }
        Class cls = NSClassFromString(cn);
        if (!cls) { tan_sendRsp(fd, [NSString stringWithFormat:@"类 \"%@\" 不存在（Swift 类需带完整命名空间，如 BBPegasusSwift.BBPegasusViewController）", cn]); return; }
        NSMutableString *r = [NSMutableString string];
        [r appendFormat:@"\033[34m#pragma mark - %@\033[0m\n\n", cn];

        unsigned int pc = 0;
        objc_property_t *props = class_copyPropertyList(cls, &pc);
        [r appendFormat:@"// %d 个属性\n", pc];
        for (unsigned int i = 0; i < pc; i++) {
            NSString *n = [NSString stringWithUTF8String:property_getName(props[i])];
            NSString *a = [NSString stringWithUTF8String:property_getAttributes(props[i])];
            [r appendFormat:@"@property (%@) %@;\n", a, n];
        }
        free(props);

        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        [r appendFormat:@"\n// %d 个实例方法\n", mc];
        for (unsigned int i = 0; i < mc; i++) {
            [r appendFormat:@"- %@\n", NSStringFromSelector(method_getName(methods[i]))];
        }
        free(methods);

        unsigned int cmc = 0;
        Method *cMethods = class_copyMethodList(objc_getMetaClass(cn.UTF8String), &cmc);
        [r appendFormat:@"\n// %d 个类方法\n", cmc];
        for (unsigned int i = 0; i < cmc; i++) {
            [r appendFormat:@"+ %@\n", NSStringFromSelector(method_getName(cMethods[i]))];
        }
        free(cMethods);

        tan_sendRsp(fd, r);
        return;
    }

    // !inheritance [类名] - 打印类的继承链（superclass 链）
    if ([raw isEqualToString:@"!inheritance"] || [raw hasPrefix:@"!inheritance "]) {
        NSString *cn = [raw hasPrefix:@"!inheritance "] ? [[raw substringFromIndex:13] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
        if (cn.length == 0) { tan_sendRsp(fd, @"用法: !inheritance <类名>，如 !inheritance UIViewController"); return; }
        Class cls = NSClassFromString(cn);
        if (!cls) { tan_sendRsp(fd, [NSString stringWithFormat:@"类 \"%@\" 不存在", cn]); return; }
        NSMutableArray *chain = [NSMutableArray array];
        while (cls) { [chain addObject:NSStringFromClass(cls)]; cls = [cls superclass]; }
        tan_sendRsp(fd, tan_clr(CLR_CYAN, [chain componentsJoinedByString:@"  →  "]));
        return;
    }

    // !ivars <地址> [all] [关键词] - 列出对象实例变量（沿 superclass 链收集，KVO 包装类也能看到真实 ivar）
    // 默认跳过系统框架类（UIView 等），只显示插件自定义类的 ivar；加 all 显示全部（含系统类）
    // 安全：默认只显示「地址+类名」；对象 description 仅在显式加 desc 参数时调用（悬垂/部分释放对象
    // 的 description 会 SIGSEGV，@try 挡不住，findings L1302 先例）
    if ([raw hasPrefix:@"!ivars "]) {
        NSArray *parts = [[raw substringFromIndex:7] componentsSeparatedByString:@" "];
        parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        BOOL showAll = (parts.count >= 2 && [parts[1] isEqualToString:@"all"]);
        NSString *filter = nil;                       // 可选：只显示名字含关键词的 ivar
        BOOL showDesc = NO;                           // 可选：额外调用对象 description（有风险）
        NSMutableArray *rest = [NSMutableArray arrayWithArray:parts];
        if (rest.count > 1 && [rest[1] isEqualToString:@"all"]) [rest removeObjectAtIndex:1];
        if (rest.count > 1 && [rest[1] isEqualToString:@"desc"]) { showDesc = YES; [rest removeObjectAtIndex:1]; }
        if (rest.count > 1 && [rest[1] isEqualToString:@"all"]) [rest removeObjectAtIndex:1]; // all desc / desc all
        if (rest.count >= 2) filter = rest[1];
        unsigned long long addr = 0;
        NSScanner *sc = [NSScanner scannerWithString:parts[0]]; [sc scanHexLongLong:&addr];
        if (addr == 0) { tan_sendRsp(fd, @"用法: !ivars <对象地址> [all] [desc] [关键词]，如 !ivars 0x10a3d2c00 或 !ivars 0x10a3d2c00 all shortcutItems 或 !ivars 0x10a3d2c00 all desc（desc 会调用对象 description，悬垂对象有崩溃风险）"); return; }
        id obj = (__bridge id)(void *)(uintptr_t)addr;
        // 前置校验：悬垂指针/越界地址直接拒绝，绝不 dereference（SIGSEGV 挡不住）
        if (!tan_isReadableAddress((__bridge const void *)obj)) {
            tan_sendRsp(fd, [NSString stringWithFormat:@"地址不可读（悬垂指针，对象可能已释放）: %#llx\n提示: 用当次会话 !vc top 现取的地址，跨会话/重启后旧地址会失效", addr]);
            return;
        }
        NSMutableString *r = [NSMutableString stringWithFormat:@"%@ %p 的 ivars%@:\n", NSStringFromClass(object_getClass(obj)), obj, showAll ? @"(全部)" : @"(自定义类)"];
        NSMutableSet *seen = [NSMutableSet set];
        Class cls = object_getClass(obj);
        while (cls) {                                   // 从当前类沿 superclass 链向上收集
            if (!showAll && tan_isSystemFrameworkClass(cls)) break;  // 默认到系统类就停
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *name = ivar_getName(ivars[i]);
                NSString *n = [NSString stringWithUTF8String:name];
                if ([seen containsObject:n]) continue;  // 去重（子类同名覆盖）
                [seen addObject:n];
                if (filter.length > 0 && ![n localizedCaseInsensitiveContainsString:filter]) continue;  // 关键词过滤
                const char *type = ivar_getTypeEncoding(ivars[i]);
                NSString *valStr = @"?";
                @try {
                    // 只用 object_getIvar（按偏移直接读内存，不走 KVC，避免触发私有 getter 崩溃）
                    if (type && type[0] == '@') {
                        id val = object_getIvar(obj, ivars[i]);
                        if (val && !tan_isReadableAddress((__bridge const void *)val)) {
                            valStr = @"(悬垂指针)";     // ivar 里的对象已释放，任何 msgSend 都会崩
                        } else if (!val) {
                            valStr = @"nil";
                        } else {
                            // 地址+类名（安全，只读 isa 不发消息）；description/集合 count 仅 showDesc 时
                            // 注：%p 本身带 0x 前缀，不要再加 0x，否则显示成 0x0x... 会被误抄
                            Class vc = object_getClass(val);   // 纯读 isa，无 msgSend
                            NSString *cn = vc ? NSStringFromClass(vc) : @"?";
                            if (showDesc) {
                                @try {
                                    if ([val isKindOfClass:[NSArray class]] || [val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSSet class]]) {
                                        valStr = [NSString stringWithFormat:@"%p %@ (count=%lu)", val, cn, (unsigned long)[val count]];
                                    } else {
                                        NSString *desc = [NSString stringWithFormat:@"%@", val];
                                        if (desc.length > 150) desc = [[desc substringToIndex:150] stringByAppendingString:@"…(截断)"];
                                        valStr = [NSString stringWithFormat:@"%p %@ = %@", val, cn, desc];
                                    }
                                } @catch (NSException *e2) {
                                    valStr = [NSString stringWithFormat:@"%p %@ (desc 不可读)", val, cn];
                                }
                            } else {
                                valStr = [NSString stringWithFormat:@"%p %@", val, cn];
                            }
                        }
                    } else {
                        valStr = @"(非对象)";
                    }
                } @catch (NSException *e) { valStr = @"(不可读)"; }
                [r appendFormat:@"  %s (%s) = %@\n", name, type, valStr];
            }
            free(ivars);
            cls = class_getSuperclass(cls);
        }
        tan_sendRsp(fd, r);
        return;
    }

    // !ls [路径] - 列出目录内容
    if ([raw isEqualToString:@"!ls"] || [raw hasPrefix:@"!ls "]) {
        NSString *path = [raw hasPrefix:@"!ls "] ? [[raw substringFromIndex:4] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"/";
        if (path.length == 0) path = @"/";
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
        if (!items) { tan_sendRsp(fd, [NSString stringWithFormat:@"无法读取目录: %@", path]); return; }
        NSMutableString *r = [NSMutableString stringWithFormat:@"%@/:\n", path];
        for (NSString *name in [items sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *full = [path stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            [[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir];
            [r appendFormat:@"  %@%@\n", name, isDir ? @"/" : @""];
        }
        tan_sendRsp(fd, r);
        return;
    }

    // !cat <文件> - 读文本文件内容
    if ([raw hasPrefix:@"!cat "]) {
        NSString *path = [[raw substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (path.length == 0) { tan_sendRsp(fd, @"用法: !cat <文件路径>，如 !cat /var/mobile/xx.txt"); return; }
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (!content) content = [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:nil];
        if (!content) { tan_sendRsp(fd, [NSString stringWithFormat:@"无法读取: %@", path]); return; }
        tan_sendRsp(fd, content);
        return;
    }

    // !process - 当前进程信息
    if ([raw isEqualToString:@"!process"] || [raw hasPrefix:@"!process "]) {
        NSProcessInfo *pi = [NSProcessInfo processInfo];
        NSMutableString *r = [NSMutableString string];
        [r appendFormat:@"进程: %@ (pid %d)\n", pi.processName, pi.processIdentifier];
        [r appendFormat:@"bundleId: %@\n", [NSBundle mainBundle].bundleIdentifier ?: @"?"];
        [r appendFormat:@"可执行文件: %@\n", [NSBundle mainBundle].executablePath ?: @"?"];
        [r appendFormat:@"启动参数: %@\n", [pi.arguments componentsJoinedByString:@" "]];
        [r appendFormat:@"系统版本: %@\n", pi.operatingSystemVersionString];
        [r appendFormat:@"运行时长: %.0f 秒\n", pi.systemUptime];
        tan_sendRsp(fd, r);
        return;
    }

    // !sys - 设备/系统信息
    if ([raw isEqualToString:@"!sys"] || [raw hasPrefix:@"!sys "]) {
        struct utsname u; uname(&u);
        NSProcessInfo *pi = [NSProcessInfo processInfo];
        NSMutableString *r = [NSMutableString string];
        [r appendFormat:@"设备型号: %s\n", u.machine];
        [r appendFormat:@"系统: %s %s\n", u.sysname, u.release];
        [r appendFormat:@"iOS 版本: %@\n", pi.operatingSystemVersionString];
        [r appendFormat:@"内存: %.0f MB\n", (double)pi.physicalMemory / 1024.0 / 1024.0];
        [r appendFormat:@"CPU 核数: %ld\n", (long)pi.activeProcessorCount];
        tan_sendRsp(fd, r);
        return;
    }

    // !apps - 列出所有已安装 App（颜色区分：系统=绿[系统]，用户=黄[用户]）
    // ANSI 颜色码在终端（nc/odebug.sh）里显示；非终端环境会显示转义字符
    if ([raw isEqualToString:@"!apps"] || [raw hasPrefix:@"!apps "]) {
        NSMutableString *r = [NSMutableString string];
        NSInteger sysCount = 0, userCount = 0;
        @try {
            id workspace = [NSClassFromString(@"LSApplicationWorkspace") valueForKey:@"defaultWorkspace"];
            id apps = [workspace valueForKey:@"allInstalledApplications"];
            for (id app in apps) {
                NSString *bid = [app valueForKey:@"applicationIdentifier"];
                if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
                NSString *name = [app valueForKey:@"localizedName"];
                // 系统/用户判断：优先 applicationType（LSApplicationRecord 无 isSystemApplication 键会崩）
                BOOL isSys = NO;
                @try {
                    id appType = [app valueForKey:@"applicationType"];
                    if ([appType isKindOfClass:[NSString class]]) isSys = [appType isEqualToString:@"System"];
                } @catch (NSException *e) {
                    @try { isSys = [[app valueForKey:@"isSystemApplication"] boolValue]; } @catch (NSException *e2) {}
                }
                if (isSys) sysCount++; else userCount++;
                // 图标标识 + 颜色：系统应用 ⚙️绿色，用户应用 📱黄色
                NSString *icon = isSys ? @"⚙️" : @"📱";
                NSString *color = isSys ? @"\033[32m" : @"\033[33m";
                NSString *tag = isSys ? @"[系统]" : @"[用户]";
                [r appendFormat:@"%@%@ %@ %@\t%@\033[0m\n",
                    color, icon, tag, bid, [name isKindOfClass:[NSString class]] ? name : @"?"];
            }
        } @catch (NSException *e) {
            tan_sendRsp(fd, [NSString stringWithFormat:@"读取失败: %@", e.reason]);
            return;
        }
        tan_sendRsp(fd, [NSString stringWithFormat:@"共 %ld 个 App（系统 %ld / 用户 %ld）:\n%@",
            (long)(sysCount + userCount), (long)sysCount, (long)userCount, r]);
        return;
    }

    // !bundle <bundleId> - 查看某个 App 的 Info.plist（可执行路径、版本、权限）
    if ([raw isEqualToString:@"!bundle"] || [raw hasPrefix:@"!bundle "]) {
        NSString *bid = [raw hasPrefix:@"!bundle "] ? [[raw substringFromIndex:8] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
        if (bid.length == 0) { tan_sendRsp(fd, @"用法: !bundle <bundleId>，如 !bundle tv.danmaku.bilianime"); return; }

        // 复用 !apps 的遍历方式找 proxy（applicationProxyForIdentifier: 在这个环境可能不可用）
        id proxy = nil;
        @try {
            id workspace = [NSClassFromString(@"LSApplicationWorkspace") valueForKey:@"defaultWorkspace"];
            id apps = [workspace valueForKey:@"allInstalledApplications"];
            for (id app in apps) {
                id b = [app valueForKey:@"applicationIdentifier"];
                if ([b isKindOfClass:[NSString class]] && [b isEqualToString:bid]) { proxy = app; break; }
            }
        } @catch (NSException *e) {}
        if (!proxy) { tan_sendRsp(fd, tan_clr(CLR_RED, [NSString stringWithFormat:@"未找到 App: %@", bid])); return; }

        // 逐项 @try 保护读取（不同 iOS 的 proxy 键可能缺失，缺失显示 ?）
        NSMutableString *r = [NSMutableString string];
        NSArray *pairs = @[
            @[@"bundleId", @"applicationIdentifier"],
            @[@"显示名", @"localizedName"],
            @[@"版本", @"shortVersionString"],
            @[@"Build", @"bundleVersion"],
            @[@"可执行文件", @"executableName"],
        ];
        for (NSArray *pair in pairs) {
            NSString *v = @"?";
            @try { id val = [proxy valueForKey:pair[1]]; if (val) v = [NSString stringWithFormat:@"%@", val]; } @catch (NSException *e) {}
            [r appendFormat:@"%@: %@\n", pair[0], v];
        }
        @try {
            id url = [proxy valueForKey:@"bundleURL"];
            if ([url isKindOfClass:[NSURL class]]) [r appendFormat:@"可执行路径: %@\n", [url path]];
        } @catch (NSException *e) {}
        @try {
            id ent = [proxy valueForKey:@"entitlements"];
            if ([ent isKindOfClass:[NSDictionary class]] && [ent count]) {
                [r appendFormat:@"权限 (%ld 项):\n", (long)[ent count]];
                for (NSString *k in ent) [r appendFormat:@"  %@ = %@\n", k, ent[k]];
            } else {
                [r appendString:@"权限: (无)\n"];
            }
        } @catch (NSException *e) { [r appendString:@"权限: (读取失败)\n"]; }
        tan_sendRsp(fd, r);
        return;
    }

    // !icon <bundleId> - 用 iTerm2 imgcat 显示 App 真实图标（需 iTerm2/支持 OSC1337 的终端）
    if ([raw isEqualToString:@"!icon"] || [raw hasPrefix:@"!icon "]) {
        NSString *bid = [raw hasPrefix:@"!icon "] ? [[raw substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
        if (bid.length == 0) { tan_sendRsp(fd, @"用法: !icon <bundleId>，如 !icon tv.danmaku.bilianime"); return; }
        id proxy = nil;
        @try {
            id workspace = [NSClassFromString(@"LSApplicationWorkspace") valueForKey:@"defaultWorkspace"];
            id apps = [workspace valueForKey:@"allInstalledApplications"];
            for (id app in apps) {
                id b = [app valueForKey:@"applicationIdentifier"];
                if ([b isKindOfClass:[NSString class]] && [b isEqualToString:bid]) { proxy = app; break; }
            }
        } @catch (NSException *e) {}
        if (!proxy) { tan_sendRsp(fd, tan_clr(CLR_RED, [NSString stringWithFormat:@"未找到 App: %@", bid])); return; }

        // 循环尝试多个 variant（1-6），只接受真正的 PNG（magic 校验）
        // ⚠️ iconDataForVariant: 参数是值类型 NSUInteger，必须用 objc_msgSend 传整数（performSelector 传 NSNumber 会错）
        NSData *iconData = nil;
        int usedVariant = 0;
        for (int v = 1; v <= 6 && iconData.length == 0; v++) {
            NSData *d = nil;
            @try {
                d = ((NSData *(*)(id, SEL, NSUInteger))objc_msgSend)(proxy, @selector(iconDataForVariant:), (NSUInteger)v);
            } @catch (NSException *e) {}
            if (d.length > 8 && memcmp(d.bytes, "\x89PNG", 4) == 0) { iconData = d; usedVariant = v; }
        }
        if (!iconData.length) {   // fallback：从 Info.plist 的 CFBundleIcons 读图标文件
            @try {
                id url = [proxy valueForKey:@"bundleURL"];
                NSBundle *bundle = [NSBundle bundleWithURL:url];
                NSDictionary *primary = bundle.infoDictionary[@"CFBundleIcons"][@"CFBundlePrimaryIcon"];
                NSArray *files = primary[@"CFBundleIconFiles"];
                if (!files && primary[@"CFBundleIconName"]) files = @[primary[@"CFBundleIconName"]];
                for (NSString *f in files ?: @[@"AppIcon", @"AppIcon60x60@2x"]) {
                    NSString *p = [bundle pathForResource:f ofType:nil];
                    if (p && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
                        NSData *d = [NSData dataWithContentsOfFile:p];
                        if (d.length > 8 && memcmp(d.bytes, "\x89PNG", 4) == 0) { iconData = d; break; }
                    }
                }
            } @catch (NSException *e) {}
        }
        NSLog(@"[TANConsole] !icon %@ 取到 %lu 字节 PNG=%d variant=%d",
            bid, (unsigned long)iconData.length,
            iconData.length > 8 && memcmp(iconData.bytes, "\x89PNG", 4) == 0,
            usedVariant);
        if (!iconData.length) { tan_sendRsp(fd, tan_clr(CLR_RED, @"无法获取图标数据")); return; }

        // iTerm2 imgcat：ESC]1337;File=name=xx.png;size=N;inline=1;base64:<data>BEL
        NSString *b64 = [iconData base64EncodedStringWithOptions:0];
        NSString *imgcat = [NSString stringWithFormat:@"\033]1337;File=name=%@.png;size=%lu;inline=1;base64:%@\a",
            bid, (unsigned long)iconData.length, b64];
        tan_sendRsp(fd, imgcat);
        return;
    }

    // !dump <bundleId | dylib路径> - 跨进程 dump App 类，或 dump 指定越狱插件 dylib 的类（SpringBoard 进程内）
    if ([raw isEqualToString:@"!dump"] || [raw hasPrefix:@"!dump "]) {
        NSString *bid = [raw hasPrefix:@"!dump "] ? [[raw substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
        if (bid.length == 0) {
            tan_sendRsp(fd, @"!dump 用法:\n"
                @"  ① dump App:   !dump <bundleId>\n"
                @"     结果 → App 容器 tmp/classdump_<bundleId>/（每类一个 .txt，自动拉取到电脑）\n"
                @"  ② dump 插件:  !dump <插件.dylib路径>\n"
                @"     例: !dump /var/jb/Library/MobileSubstrate/DynamicLibraries/Open.dylib\n"
                @"     结果 → /tmp/classdump_<插件名>.txt（自动拉取到电脑）\n"
                @"  插件目录: !ls /var/jb/Library/MobileSubstrate/DynamicLibraries/\n"
                @"  注意: 插件 dylib 必须已被注入当前进程（插件 dump 看 SpringBoard 已加载的插件）");
            return;
        }

        // dylib 路径：在 SpringBoard 进程内直接 dump 该插件 dylib 的类（镜像路径精确匹配）
        if ([bid hasSuffix:@".dylib"] || [bid hasPrefix:@"/"]) {
            NSString *dylibPath = bid;
            NSString *dylibName = [dylibPath lastPathComponent];   // TrollOpenJB.dylib
            NSString *dylibBase = [dylibName stringByDeletingPathExtension];  // TrollOpenJB
            // 每类一个文件：用 NSTemporaryDirectory() 拿真实容器 tmp 路径（/tmp、/var/mobile 都被越狱重定向，SSH 看不到）
            NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"classdump_%@", dylibBase]];
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:dir error:nil];
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSInteger count = 0;
            NSMutableArray *classNames = [NSMutableArray array];
            unsigned int total = 0;
            Class *classes = objc_copyClassList(&total);
            if (classes) {
                for (unsigned int i = 0; i < total; i++) {
                    @try {
                        const char *img = class_getImageName(classes[i]);
                        if (img) {
                            NSString *imgStr = [NSString stringWithUTF8String:img];
                            // 精确路径 或 文件名后缀匹配（兼容容器/逻辑路径差异）
                            if ([imgStr isEqualToString:dylibPath] || [imgStr hasSuffix:dylibName]) {
                                NSString *clsName = NSStringFromClass(classes[i]);
                                [classNames addObject:clsName];
                                NSString *file = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.txt", clsName]];
                                [tan_classDumpString(classes[i]) writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
                                count++;
                            }
                        }
                    } @catch (NSException *e) {}
                }
                free(classes);
            }
            // 直接返回类名列表（不用找文件），方便下一步 !class / 动态调用
            tan_sendRsp(fd, [NSString stringWithFormat:@"已 dump %ld 个类（文件 → %@/）\n===== 类名列表 =====\n%@",
                (long)count, dir, [classNames componentsJoinedByString:@"\n"]]);
            return;
        }

        // 广播 dumpClasses，轮询扫描 App 容器 tmp 找 classdump 文件（SpringBoard 有权限读 App 容器）
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.tanyou.open/dumpClasses"), NULL, NULL, YES);

        BOOL found = NO;
        NSFileManager *fm = [NSFileManager defaultManager];
        for (int i = 0; i < 30 && !found; i++) {
            sleep(1);
            @try {
                NSArray *uuids = [fm contentsOfDirectoryAtPath:@"/var/mobile/Containers/Data/Application" error:nil];
                for (NSString *uuid in uuids) {
                    NSString *dir = [NSString stringWithFormat:@"/var/mobile/Containers/Data/Application/%@/tmp/classdump_%@", uuid, bid];
                    if ([fm fileExistsAtPath:dir]) {
                        found = YES;
                        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
                        tan_sendRsp(fd, [NSString stringWithFormat:@"已 dump %lu 个类 → %@/（odebug.sh 会自动拉取到电脑）",
                            (unsigned long)files.count, dir]);
                        return;
                    }
                }
            } @catch (NSException *e) {}
        }
        tan_sendRsp(fd, tan_clr(CLR_RED, @"等待 App dump 超时（App 可能未在前台/未注入，先打开它再试）"));
        return;
    }

    // !eval [Target method] - 调用 Objective-C 方法
    if ([raw hasPrefix:@"!eval "]) {
        NSString *expr = [[raw substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![expr hasPrefix:@"["]) { tan_sendRsp(fd, @"格式: !eval [Target method]"); return; }
        id result = nil;
        @try {   // 兜底：任何异常（NSRangeException/NSInvalidArgument…）只打印，绝不崩 SpringBoard
            result = tan_evalExpr(expr);
        } @catch (NSException *e) {
            tan_sendRsp(fd, [NSString stringWithFormat:@"(已拦截异常 %@: %@，不会崩)", e.name, e.reason]);
            return;
        }
        tan_sendRsp(fd, result ? [NSString stringWithFormat:@"%@", result] : @"(nil)");
        return;
    }

    // 简写格式: [Target method] 或 [Target method:arg]
    if (![raw hasPrefix:@"["] || ![raw hasSuffix:@"]"]) { tan_sendRsp(fd, @"格式错"); return; }
    NSString *body = [raw substringWithRange:NSMakeRange(1, raw.length-2)];
    NSInteger sp = -1;
    for (NSInteger i = 0; i < (NSInteger)body.length; i++) {
        if ([body characterAtIndex:i] == ' ') { sp = i; break; }
    }
    if (sp < 0) { tan_sendRsp(fd, @"缺方法"); return; }
    NSString *tn = [body substringToIndex:sp];
    NSString *sel = [[body substringFromIndex:sp+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    id target = tan_resolveTarget(tn);   // 支持类名 / 别名 / 0x实例地址
    if (!target) { tan_sendRsp(fd, [NSString stringWithFormat:@"?%@（支持 类名 / sharedManager / contextHost / 0x地址）", tn]); return; }
    SEL s = NSSelectorFromString(sel);
    if ([target respondsToSelector:s]) {
        id r = ((id(*)(id,SEL))objc_msgSend)(target, s);
        tan_sendRsp(fd, r ? [NSString stringWithFormat:@"%@", r] : @"(nil)");
        return;
    }
    NSRange cr = [sel rangeOfString:@":" options:NSBackwardsSearch];
    if (cr.location != NSNotFound && cr.location < sel.length-1) {
        NSString *sn = [sel substringToIndex:cr.location+1];
        NSString *as = [[sel substringFromIndex:cr.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        id arg = nil;
        if ([as isEqualToString:@"nil"]) arg = nil;
        else if ([as isEqualToString:@"YES"]) arg = @YES;
        else if ([as isEqualToString:@"NO"]) arg = @NO;
        else arg = @([as integerValue]);
        SEL s2 = NSSelectorFromString(sn);
        if ([target respondsToSelector:s2]) {
            id r = ((id(*)(id,SEL,id))objc_msgSend)(target, s2, arg);
            tan_sendRsp(fd, r ? [NSString stringWithFormat:@"%@", r] : @"(nil)");
            return;
        }
    }
    tan_sendRsp(fd, [NSString stringWithFormat:@"无 %@", sel]);
}

/// 隐藏桌面图标（修改 IconState.plist）
/// 递归从 iconLists 移除指定 bundleId（支持文件夹嵌套），返回是否找到
static BOOL tan_removeIconRecursive(NSMutableArray *lists, NSString *bid) {
    BOOL found = NO;
    for (id pageObj in lists) {
        if (![pageObj isKindOfClass:[NSMutableArray class]]) continue;
        NSMutableArray *page = pageObj;
        NSMutableArray *rm = [NSMutableArray array];
        for (id icon in page) {
            NSString *iBid = nil;
            if ([icon isKindOfClass:[NSDictionary class]]) iBid = [icon valueForKey:@"bundleIdentifier"] ?: [icon valueForKey:@"displayIdentifier"];
            else if ([icon isKindOfClass:[NSString class]]) iBid = icon;
            if (iBid && [iBid isEqualToString:bid]) { [rm addObject:icon]; found = YES; }
        }
        [page removeObjectsInArray:rm];
        // 递归文件夹（NSDictionary 里嵌套的 iconLists）
        for (id icon in page) {
            if ([icon isKindOfClass:[NSDictionary class]]) {
                id sub = [icon valueForKey:@"iconLists"];
                if ([sub isKindOfClass:[NSMutableArray class]]) {
                    if (tan_removeIconRecursive(sub, bid)) found = YES;
                }
            }
        }
    }
    return found;
}

static void _hideIconWithBundleId(NSString *bid, id allIcons, void(^reply)(NSString *)) {
    NSString *path = @"/var/mobile/Library/SpringBoard/IconState.plist";
    NSMutableDictionary *plist = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!plist) { reply(@"无法读取 IconState.plist"); return; }
    NSMutableArray *lists = [plist valueForKey:@"iconLists"];
    BOOL found = NO;
    if ([lists isKindOfClass:[NSMutableArray class]]) {
        found = tan_removeIconRecursive(lists, bid);
    }
    if (found) {
        NSString *backup = @"/tmp/IconState_backup.plist";
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:backup]) [fm copyItemAtPath:path toPath:backup error:nil];
        [plist writeToFile:path atomically:YES];
        NSString *path2 = @"/var/mobile/Library/SpringBoard/DesiredIconState.plist";
        NSMutableDictionary *plist2 = [NSMutableDictionary dictionaryWithContentsOfFile:path2];
        if (plist2) {
            NSMutableArray *lists2 = [plist2 valueForKey:@"iconLists"];
            if ([lists2 isKindOfClass:[NSMutableArray class]]) {
                tan_removeIconRecursive(lists2, bid);
                [plist2 writeToFile:path2 atomically:YES];
            }
        }
        reply([NSString stringWithFormat:@"已隐藏 %@（已备份到 /tmp，重启生效）", bid]);
    } else {
        reply(@"未找到该图标在布局中");
    }
}

/// 从备份恢复桌面图标
static void _showIconWithReply(void(^reply)(NSString *)) {
    NSString *backup = @"/tmp/IconState_backup.plist";
    NSString *path = @"/var/mobile/Library/SpringBoard/IconState.plist";
    NSString *path2 = @"/var/mobile/Library/SpringBoard/DesiredIconState.plist";
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:backup]) {
        [fm copyItemAtPath:backup toPath:path error:nil];
        [fm copyItemAtPath:backup toPath:path2 error:nil];
        reply(@"已恢复桌面布局备份（重启 SpringBoard 后生效）");
    } else {
        reply(@"没有找到备份文件 /tmp/IconState_backup.plist");
    }
}

// 调试控制台是本插件的核心功能：正式包（FINALPACKAGE=1，不带 -DDEBUG）也要编译进去。
// 想编一个不含控制台的精简包：gmake package ADDITIONAL_CFLAGS=-DTAN_NO_CONSOLE
#ifndef TAN_NO_CONSOLE
#pragma mark - 调试控制台认证

/// 读取/生成调试令牌（只读自己的域 com.tanyou.opendebug.settings/debugAuthToken）
static NSString *tan_debugToken(void) {
    static NSString *token = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFStringRef domain = CFSTR("com.tanyou.opendebug.settings");
        CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("debugAuthToken"), domain);
        if (v && [(__bridge id)v isKindOfClass:[NSString class]] && [(__bridge NSString *)v length] > 0) {
            token = (__bridge_transfer NSString *)v;
        } else {
            token = [[NSUUID UUID] UUIDString];
            CFPreferencesSetAppValue(CFSTR("debugAuthToken"), (__bridge CFPropertyListRef)token, domain);
            CFPreferencesAppSynchronize(domain);
            NSLog(@"[TANConsole] 调试令牌: %@", token);
        }
    });
    return token;
}

/// 解析单条消息：`AUTH <token> <命令>`，令牌正确返回命令，否则返回 nil
static NSString *tan_authParse(NSString *raw) {
    if (![raw hasPrefix:@"AUTH "]) return nil;
    NSString *rest = [raw substringFromIndex:5];
    NSRange sp = [rest rangeOfString:@" "];
    if (sp.location == NSNotFound) return nil;
    if (![[rest substringToIndex:sp.location] isEqualToString:tan_debugToken()]) return nil;
    return [rest substringFromIndex:sp.location + 1];
}

__attribute__((constructor)) void TANDebugConsoleStart(void) {
    // 只在 SpringBoard 进程启动 TCP 服务（插件为全进程注入，其他进程不应绑 4321）
    if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return;
    NSLog(@"[TANConsole] 启动...");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) { NSLog(@"[TANConsole] socket失败"); return; }
        int opt = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        struct sockaddr_in a = {0};
        a.sin_len = sizeof(a);
        a.sin_family = AF_INET;
        BOOL bindAll = NO;   // 偏好 debugBindAll=1 ⇒ 4321 也监听所有网卡（WLAN 直连，token 鉴权）
        {
            CFStringRef domain = CFSTR("com.tanyou.opendebug.settings");
            CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("debugBindAll"), domain);
            if (v && [(__bridge id)v isKindOfClass:[NSNumber class]]) bindAll = [(__bridge NSNumber *)v boolValue];
            if (v) CFRelease(v);
        }
        a.sin_addr.s_addr = bindAll ? htonl(INADDR_ANY) : inet_addr("127.0.0.1");
        a.sin_port = htons(4321);
        if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
            NSLog(@"[TANConsole] bind失败"); close(s); return;
        }
        if (listen(s, 5) < 0) { NSLog(@"[TANConsole] listen失败"); close(s); return; }
        NSLog(@"[TANConsole] ✅ 已启动 (端口4321)");
        while (1) {
            struct sockaddr_in ca; socklen_t cl = sizeof(ca);
            int c = accept(s, (struct sockaddr *)&ca, &cl);
            if (c < 0) continue;
            // 傻瓜式欢迎提示（不关闭连接，客户端先看到再输入）
            const char *welcome = "\033[34mODebug 调试控制台\033[0m: 输入 help 看命令菜单（可连续输入多条）\n";
            write(c, welcome, strlen(welcome));

            // 交互式会话：缓冲累积 + 按行分割，支持连续输入（TCP 分包/多行粘贴也健壮）
            NSMutableString *accum = [NSMutableString string];
            char tmp[4096];
            while (1) {
                ssize_t n = read(c, tmp, sizeof(tmp));
                if (n <= 0) break;                    // 客户端关闭/出错 → 结束会话
                [accum appendString:[[NSString alloc] initWithBytes:tmp length:(NSUInteger)n encoding:NSUTF8StringEncoding]];
                NSRange nl;
                while ((nl = [accum rangeOfString:@"\n"]).location != NSNotFound) {
                    NSString *line = [accum substringToIndex:nl.location];
                    [accum deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
                    line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (line.length == 0) continue;
                    NSString *cmd = tan_authParse(line);
                    if (cmd.length == 0) {
                        tan_sendRsp(c, @"未认证: 请发送 AUTH <token> <命令>；输入 help 看菜单");
                        continue;
                    }
                    NSLog(@"[TANConsole] << %@", cmd);
                    tan_eval(c, cmd);
                }
            }
            close(c);
        }
    });
}
#endif // TAN_NO_CONSOLE
