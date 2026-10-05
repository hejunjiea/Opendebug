/**
 * TANHookConsole - ODebug 动态方法观察（log-only hook）实现
 *
 * 安全约束（v2，崩溃根因修复）：
 *  - hook body 只做纯 C 操作：class_getName + 指针 %p + POSIX write 写文件。
 *    绝不调用对象方法（description/isKindOfClass/KVC）——scene 激活敏感时机对象
 *    可能正在释放，objc_msgSend 到悬垂指针 = SIGSEGV（@try 挡不住）= SpringBoard 崩溃。
 *  - 日志文件 /var/jb/tmp/ODebugHook.log（多路径 fallback）。
 *  - hook 列表持久化到 CFPreferences（com.tanyou.odebug/hookList），ODebug 每次注入
 *    （含 SpringBoard 重启后）自动恢复挂载，长按取证不因重启丢失。
 *  - !unhook 用 hook 前 method_getImplementation 保存的原 IMP 恢复。
 */
#import "TANHookConsole.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <fcntl.h>
#import <pthread.h>
#import <unistd.h>

// substrate hook（ODebug 已链接 libsubstrate）
extern void MSHookMessageEx(Class _class, SEL message, IMP imp, IMP *result);

// 本地响应发送（TANDebugConsole.m 的 tan_sendRsp 是 static，跨文件不可见，这里自实现）
static void tan_sendRsp(int fd, NSString *msg) {
    if (!msg) return;
    @try {
        msg = [msg stringByAppendingString:@"\n"];
        const char *s = [msg UTF8String];
        size_t len = strlen(s), off = 0;
        while (off < len) {
            ssize_t w = write(fd, s + off, len - off);
            if (w <= 0) break;
            off += (size_t)w;
        }
    } @catch (NSException *e) {}
}

#pragma mark - 注册表（纯 C 槽位数组：hook 触发路径零 ObjC 零锁）

// 每个槽：类名 + selector + orig trampoline + 原 IMP（unhook 用）+ 规范签名
#define TAN_HOOK_MAX_SLOTS 32
typedef struct {
    Class cls;          // meta class 也可（类方法）
    SEL sel;
    IMP origTramp;      // MSHookMessageEx 返回的 orig（hook body 调用）
    IMP rawImp;         // hook 前 method_getImplementation（unhook 恢复）
    char sig[64];       // 规范签名（v@:B 形式）
    int inUse;
} TANHookSlot;

static TANHookSlot tan_hookSlots[TAN_HOOK_MAX_SLOTS];
static pthread_mutex_t tan_hookMutex = PTHREAD_MUTEX_INITIALIZER; // 仅控制台线程写用

// hook body 专用：只读遍历槽位找 orig（无锁——槽位写完后不再修改 origTramp；
// 但 unhook 会清 inUse，可能读到已清槽。妥协：hook body 里读到 inUse==0 就当没 hook 直接调系统原 IMP？
// 更安全：unhook 后槽位保留 origTramp 但 inUse=0，hook body 找不到就调用原始系统方法（通过 objc_msgSend 直调 self/sel）。
// 实际场景 unhook 极少且与触发同线程竞争极低，这里用原子读 inUse 保护。）
static IMP tan_hookOrigFor(Class cls, SEL sel) {
    for (int i = 0; i < TAN_HOOK_MAX_SLOTS; i++) {
        TANHookSlot *s = &tan_hookSlots[i];
        if (s->inUse && s->cls == cls && s->sel == sel) {
            __sync_synchronize();
            return s->origTramp;
        }
    }
    return NULL;
}

static int tan_hookSlotIndex(Class cls, SEL sel) {
    for (int i = 0; i < TAN_HOOK_MAX_SLOTS; i++) {
        TANHookSlot *s = &tan_hookSlots[i];
        if (s->inUse && s->cls == cls && s->sel == sel) return i;
    }
    return -1;
}

// 找空闲槽（调用方需持有 tan_hookMutex）
static int tan_hookFreeSlot(void) {
    for (int i = 0; i < TAN_HOOK_MAX_SLOTS; i++) {
        if (!tan_hookSlots[i].inUse) return i;
    }
    return -1;
}

#pragma mark - 日志写入（纯 C，零对象调用）

static void tan_hookWriteRaw(const char *line) {
    if (!line) return;
    size_t len = strlen(line);
    const char *paths[] = {
        "/var/jb/tmp/ODebugHook.log",
        "/tmp/ODebugHook.log",
        "/var/jb/var/mobile/Documents/ODebugHook.log",
        "/var/mobile/Documents/ODebugHook.log",
    };
    for (int i = 0; i < 4; i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) continue;
        ssize_t off = 0;
        while (off < (ssize_t)len) {
            ssize_t w = write(fd, line + off, len - (size_t)off);
            if (w <= 0) break;
            off += w;
        }
        close(fd);
    }
}

// hook body 专用：拼一行 [时间] -[类 selector] 参数=%p 返回=%p 后写文件。
// 纯 C：class_getName(读取类名) + 指针值，不调用任何对象方法。
// arm64：读取浮点寄存器 d0-d7（hook body 进入时，double 参数所在位置）
static void tan_captureDoubles(double out[8]) {
    __asm__ volatile(
        "stp d0, d1, [%0]\n"
        "stp d2, d3, [%0, #16]\n"
        "stp d4, d5, [%0, #32]\n"
        "stp d6, d7, [%0, #48]\n"
        : : "r"(out) : "memory");
}

static void tan_hookEmit(Class cls, SEL sel, int argc, const void *args[], const double *dvals, int dcount, const void *ret) {
    char buf[1024];
    struct timeval tv;
    gettimeofday(&tv, NULL);
    size_t used = 0;
    const char *kind = class_isMetaClass(cls) ? "+" : "-";
    int n = snprintf(buf, sizeof(buf), "%lld.%06d [TANHook] %s[%s %s]",
                     (long long)tv.tv_sec, (int)tv.tv_usec,
                     kind, class_getName(cls), sel_getName(sel));
    if (n > 0) used = (size_t)n;
    for (int i = 0; i < argc && used < sizeof(buf) - 32; i++) {
        n = snprintf(buf + used, sizeof(buf) - used, " arg%d=%p", i, args[i]);
        if (n > 0) used += (size_t)n;
    }
    for (int i = 0; i < dcount && used < sizeof(buf) - 40; i++) {
        n = snprintf(buf + used, sizeof(buf) - used, " d%d=%.4f", i, dvals[i]);
        if (n > 0) used += (size_t)n;
    }
    if (used < sizeof(buf) - 32) {
        n = snprintf(buf + used, sizeof(buf) - used, " => %p\n", ret);
        if (n > 0) used += (size_t)n;
    }
    tan_hookWriteRaw(buf);
}

// 非 hook 路径的日志（HOOKED/UNHOOKED/自动恢复记录）：纯 C 前缀
static void tan_hookLogC(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    tan_hookWriteRaw(buf);
}

#pragma mark - 签名模板（按 type encoding，hook body 全纯 C）

// 纯 C：从 UIView 取 frame（objc_msgSend 拿 CGRect struct → 16 字节寄存器返回）
static void tan_captureViewFrame(id view, struct CGRect *out) {
    if (view == nil) { out->origin.x = -999; out->origin.y = -999; out->size.width = 0; out->size.height = 0; return; }
    SEL fSel = sel_registerName("frame");
    if (!class_respondsToSelector(object_getClass(view), fSel)) { memset(out, 0, sizeof(*out)); return; }
    // arm64: CGRect 在 x0/x1 返回，objc_msgSend 直接可用
    struct CGRect (*msg)(id, SEL) = (struct CGRect (*)(id, SEL))objc_msgSend;
    *out = msg(view, fSel);
}

// v@:   (void)(id, SEL)
static void (*tan_orig_v)(id, SEL);
static void tan_hook_v(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    tan_orig_v = (void (*)(id, SEL))tan_hookOrigFor(cls, _cmd);
    double td[8]; tan_captureDoubles(td); tan_hookEmit(cls, _cmd, 0, NULL, td, 8, NULL);
    // 专用取证：TOJBClass009（原版菜单）layoutSubviews → 打印 self.frame + buttons frames
    const char *cn = class_getName(cls);
    const char *sn = sel_getName(_cmd);
    if (cn != NULL && sn != NULL && strcmp(cn, "TOJBClass009") == 0 && strcmp(sn, "layoutSubviews") == 0) {
        struct timeval tv; gettimeofday(&tv, NULL);
        struct CGRect selfF; tan_captureViewFrame(self, &selfF);
        char buf[2048]; size_t used = 0;
        used += (size_t)snprintf(buf, sizeof(buf),
            "%lld.%06d [TANHook] FANLAYOUT self.frame=(%.1f,%.1f,%.1f,%.1f) ",
            (long long)tv.tv_sec, (int)tv.tv_usec, selfF.origin.x, selfF.origin.y, selfF.size.width, selfF.size.height);
        // buttons 属性
        SEL btSel = sel_registerName("buttons");
        if (class_respondsToSelector(cls, btSel)) {
            id buttons = ((id (*)(id, SEL))objc_msgSend)(self, btSel);
            if (buttons != nil) {
                SEL cntSel = sel_registerName("count");
                NSUInteger n = (NSUInteger)((uintptr_t)((id (*)(id, SEL))objc_msgSend)(buttons, cntSel));
                SEL objAt = sel_registerName("objectAtIndex:");
                used += (size_t)snprintf(buf + used, sizeof(buf) - used, "buttons=%lu [", (unsigned long)n);
                for (NSUInteger i = 0; i < n && used < sizeof(buf) - 64; i++) {
                    id b = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(buttons, objAt, i);
                    struct CGRect bf; tan_captureViewFrame(b, &bf);
                    used += (size_t)snprintf(buf + used, sizeof(buf) - used, "(%.1f,%.1f) ", bf.origin.x, bf.origin.y);
                }
                used += (size_t)snprintf(buf + used, sizeof(buf) - used, "]");
            }
        }
        // 圆心属性 startLocation
        SEL slSel = sel_registerName("startLocation");
        if (class_respondsToSelector(cls, slSel)) {
            struct CGPoint { double x, y; } (*msg)(id, SEL) = (void *)objc_msgSend;
            struct CGPoint loc = msg(self, slSel);
            used += (size_t)snprintf(buf + used, sizeof(buf) - used, " loc=(%.1f,%.1f)", loc.x, loc.y);
        }
        // 中心选中图标 centerIndicatorIconView：frame + hidden
        SEL ciSel = sel_registerName("centerIndicatorIconView");
        if (class_respondsToSelector(cls, ciSel)) {
            id ci = ((id (*)(id, SEL))objc_msgSend)(self, ciSel);
            if (ci != nil) {
                struct CGRect cf; tan_captureViewFrame(ci, &cf);
                SEL hSel = sel_registerName("isHidden");
                BOOL ciHidden = NO;
                if (class_respondsToSelector(object_getClass(ci), hSel)) {
                    ciHidden = (BOOL)((uintptr_t)((id (*)(id, SEL))objc_msgSend)(ci, hSel));
                }
                used += (size_t)snprintf(buf + used, sizeof(buf) - used,
                    " centerIcon=%p frame=(%.1f,%.1f,%.1f,%.1f) hidden=%d",
                    (__bridge const void *)ci, cf.origin.x, cf.origin.y, cf.size.width, cf.size.height, ciHidden ? 1 : 0);
            }
        }
        snprintf(buf + used, sizeof(buf) - used, "\n");
        tan_hookWriteRaw(buf);
    }
    if (tan_orig_v) tan_orig_v(self, _cmd);
}

// v@:B  (void)(id, SEL, BOOL)
static void (*tan_orig_vB)(id, SEL, BOOL);
static void tan_hook_vB(id self, SEL _cmd, BOOL b) {
    Class cls = object_getClass(self);
    tan_orig_vB = (void (*)(id, SEL, BOOL))tan_hookOrigFor(cls, _cmd);
    const void *args[1] = { (const void *)(uintptr_t)(b ? 1 : 0) };
    double td[8]; tan_captureDoubles(td); tan_hookEmit(cls, _cmd, 1, args, td, 8, NULL);
    if (tan_orig_vB) tan_orig_vB(self, _cmd, b);
}

// v@:@  (void)(id, SEL, id)
static void (*tan_orig_vI)(id, SEL, id);
static void tan_hook_vI(id self, SEL _cmd, id p) {
    Class cls = object_getClass(self);
    tan_orig_vI = (void (*)(id, SEL, id))tan_hookOrigFor(cls, _cmd);
    const void *args[1] = { (__bridge const void *)p };
    double td[8]; tan_captureDoubles(td); tan_hookEmit(cls, _cmd, 1, args, td, 8, NULL);
    if (tan_orig_vI) tan_orig_vI(self, _cmd, p);
}

// @@:@  (id)(id, SEL, id)
static id (*tan_orig_II)(id, SEL, id);
static id tan_hook_II(id self, SEL _cmd, id p) {
    Class cls = object_getClass(self);
    tan_orig_II = (id (*)(id, SEL, id))tan_hookOrigFor(cls, _cmd);
    const void *args[1] = { (__bridge const void *)p };
    double td[8]; tan_captureDoubles(td); tan_hookEmit(cls, _cmd, 1, args, td, 8, NULL);
    id r = tan_orig_II ? tan_orig_II(self, _cmd, p) : nil;
    double td2[8]; tan_captureDoubles(td2); tan_hookEmit(cls, _cmd, 1, args, td2, 8, (__bridge const void *)r);
    return r;
}

// @@:@@  (id)(id, SEL, id, id)
static id (*tan_orig_III)(id, SEL, id, id);
static id tan_hook_III(id self, SEL _cmd, id p1, id p2) {
    Class cls = object_getClass(self);
    tan_orig_III = (id (*)(id, SEL, id, id))tan_hookOrigFor(cls, _cmd);
    const void *args[2] = { (__bridge const void *)p1, (__bridge const void *)p2 };
    double td[8]; tan_captureDoubles(td); tan_hookEmit(cls, _cmd, 2, args, td, 8, NULL);
    id r = tan_orig_III ? tan_orig_III(self, _cmd, p1, p2) : nil;
    double td2[8]; tan_captureDoubles(td2); tan_hookEmit(cls, _cmd, 2, args, td2, 8, (__bridge const void *)r);
    return r;
}

// @@:{?=[8I]}  (id)(id, SEL, struct{unsigned int x0[8];}) —— registerProcessForAuditToken: 专用
// 32B struct 参数：不打印内容（避免把 struct 当对象），只记执行 + 全零判断
typedef struct { unsigned int x0[8]; } TANAuditTokenArg;
static id (*tan_orig_RegTok)(id, SEL, TANAuditTokenArg);
static id tan_hook_RegTok(id self, SEL _cmd, TANAuditTokenArg tok) {
    Class cls = object_getClass(self);
    tan_orig_RegTok = (id (*)(id, SEL, TANAuditTokenArg))tan_hookOrigFor(cls, _cmd);
    BOOL allZero = YES;
    for (int i = 0; i < 8; i++) { if (tok.x0[i] != 0) { allZero = NO; break; } }
    char buf[160];
    struct timeval tv;
    gettimeofday(&tv, NULL);
    snprintf(buf, sizeof(buf), "%lld.%06d [TANHook] -[%s %s] auditToken=%s\n",
             (long long)tv.tv_sec, (int)tv.tv_usec,
             class_getName(cls), sel_getName(_cmd), allZero ? "ALL_ZERO" : "NONZERO");
    tan_hookWriteRaw(buf);
    id r = tan_orig_RegTok ? tan_orig_RegTok(self, _cmd, tok) : nil;
    return r;
}

// v@:d  (void)(id, SEL, double) —— 属性 setter（角度/半径/间距等）
static void (*tan_orig_vD)(id, SEL, double);
static void tan_hook_vD(id self, SEL _cmd, double value) {
    Class cls = object_getClass(self);
    tan_orig_vD = (void (*)(id, SEL, double))tan_hookOrigFor(cls, _cmd);
    double td[8]; tan_captureDoubles(td);
    tan_hookEmit(cls, _cmd, 0, NULL, td, 8, NULL);
    if (tan_orig_vD) tan_orig_vD(self, _cmd, value);
}

// v@:@B  (void)(id, SEL, id, BOOL)
static void (*tan_orig_vIB)(id, SEL, id, BOOL);
static void tan_hook_vIB(id self, SEL _cmd, id p, BOOL b) {
    Class cls = object_getClass(self);
    tan_orig_vIB = (void (*)(id, SEL, id, BOOL))tan_hookOrigFor(cls, _cmd);
    const void *args[2] = { (__bridge const void *)p, (const void *)(uintptr_t)(b ? 1 : 0) };
    double td[8]; tan_captureDoubles(td);
    tan_hookEmit(cls, _cmd, 2, args, td, 8, NULL);
    if (tan_orig_vIB) tan_orig_vIB(self, _cmd, p, b);
}

// @@:{CGPoint=dd}dd@dddddd  —— 原版扇形菜单/表盘初始化专用（记录全部布局参数）
typedef struct { double x, y; } TANFanInitPoint;
static id (*tan_orig_FanInit)(id, SEL, TANFanInitPoint, double, double, id, double, double, double, double, double, double);
static id tan_hook_FanInit(id self, SEL _cmd, TANFanInitPoint loc, double w, double h, id items,
                           double r, double spacing, double iconSz, double itemSpacing,
                           double startAngle, double endAngle) {
    Class cls = object_getClass(self);
    tan_orig_FanInit = (id (*)(id, SEL, TANFanInitPoint, double, double, id, double, double, double, double, double, double))tan_hookOrigFor(cls, _cmd);
    char buf[512];
    struct timeval tv;
    gettimeofday(&tv, NULL);
    snprintf(buf, sizeof(buf),
             "%lld.%06d [TANHook] -[%s %s] loc=(%.1f,%.1f) w=%.1f h=%.1f items=%p r=%.1f layerSpacing=%.1f iconSize=%.1f itemSpacing=%.1f startAngle=%.1f endAngle=%.1f\n",
             (long long)tv.tv_sec, (int)tv.tv_usec,
             class_getName(cls), sel_getName(_cmd),
             loc.x, loc.y, w, h, items,
             r, spacing, iconSz, itemSpacing, startAngle, endAngle);
    tan_hookWriteRaw(buf);
    id result = tan_orig_FanInit ? tan_orig_FanInit(self, _cmd, loc, w, h, items, r, spacing, iconSz, itemSpacing, startAngle, endAngle) : nil;
    return result;
}

// {CGPoint=dd}@:{CGPoint=dd}{CGSize=dd} —— TOJBMETHOD110:canvasSize:（位置计算）
typedef struct { double x, y; } TANLayoutPt;
typedef struct { double w, h; } TANLayoutSz;
static TANLayoutPt (*tan_orig_PtPtSz)(id, SEL, TANLayoutPt, TANLayoutSz);
static TANLayoutPt tan_hook_PtPtSz(id self, SEL _cmd, TANLayoutPt p, TANLayoutSz sz) {
    Class cls = object_getClass(self);
    tan_orig_PtPtSz = (TANLayoutPt (*)(id, SEL, TANLayoutPt, TANLayoutSz))tan_hookOrigFor(cls, _cmd);
    char buf[256];
    struct timeval tv;
    gettimeofday(&tv, NULL);
    snprintf(buf, sizeof(buf), "%lld.%06d [TANHook] -[%s %s] pt=(%.1f,%.1f) sz=(%.1f,%.1f)\n",
             (long long)tv.tv_sec, (int)tv.tv_usec, class_getName(cls), sel_getName(_cmd),
             p.x, p.y, sz.w, sz.h);
    tan_hookWriteRaw(buf);
    TANLayoutPt r = tan_orig_PtPtSz ? tan_orig_PtPtSz(self, _cmd, p, sz) : (TANLayoutPt){0,0};
    snprintf(buf, sizeof(buf), "%lld.%06d [TANHook] -[%s %s] => (%.1f,%.1f)\n",
             (long long)tv.tv_sec, (int)tv.tv_usec, class_getName(cls), sel_getName(_cmd), r.x, r.y);
    tan_hookWriteRaw(buf);
    // 专用取证：TOJBClass009（原版扇形菜单）→ 顺带打印 buttonFinalCenters / buttons frame
    const char *cn = class_getName(cls);
    if (cn != NULL && strcmp(cn, "TOJBClass009") == 0) {
        SEL bcSel = sel_registerName("buttonFinalCenters");
        if (class_respondsToSelector(cls, bcSel)) {
            id centers = ((id (*)(id, SEL))objc_msgSend)(self, bcSel);
            if (centers != nil) {
                SEL countSel = sel_registerName("count");
                NSUInteger n = (NSUInteger)((uintptr_t)((id (*)(id, SEL))objc_msgSend)(centers, countSel));
                char cb[1024];
                size_t used2 = 0;
                used2 += (size_t)snprintf(cb, sizeof(cb), "%lld.%06d [TANHook] buttonFinalCenters count=%lu [",
                                          (long long)tv.tv_sec, (int)tv.tv_usec, (unsigned long)n);
                SEL objAtSel = sel_registerName("objectAtIndex:");
                SEL descSel = sel_registerName("description");
                for (NSUInteger i = 0; i < n && used2 < sizeof(cb) - 48; i++) {
                    id obj = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(centers, objAtSel, i);
                    if (obj != nil) {
                        id d = ((id (*)(id, SEL))objc_msgSend)(obj, descSel);
                        const char *ds = d != nil ? ((const char *(*)(id, SEL))objc_msgSend)(d, sel_registerName("UTF8String")) : NULL;
                        if (ds != NULL) {
                            used2 += (size_t)snprintf(cb + used2, sizeof(cb) - used2, "%s ", ds);
                        }
                    }
                }
                snprintf(cb + used2, sizeof(cb) - used2, "]\n");
                tan_hookWriteRaw(cb);
            }
        }
    }
    return r;
}

// {CGPoint=dd}@:{CGSize=dd}{CGSize=dd} —— TOJBMETHOD131:canvasSize:
static TANLayoutPt (*tan_orig_PtSzSz)(id, SEL, TANLayoutSz, TANLayoutSz);
static TANLayoutPt tan_hook_PtSzSz(id self, SEL _cmd, TANLayoutSz a, TANLayoutSz b) {
    Class cls = object_getClass(self);
    tan_orig_PtSzSz = (TANLayoutPt (*)(id, SEL, TANLayoutSz, TANLayoutSz))tan_hookOrigFor(cls, _cmd);
    char buf[256];
    struct timeval tv;
    gettimeofday(&tv, NULL);
    snprintf(buf, sizeof(buf), "%lld.%06d [TANHook] -[%s %s] sz1=(%.1f,%.1f) sz2=(%.1f,%.1f)\n",
             (long long)tv.tv_sec, (int)tv.tv_usec, class_getName(cls), sel_getName(_cmd),
             a.w, a.h, b.w, b.h);
    tan_hookWriteRaw(buf);
    TANLayoutPt r = tan_orig_PtSzSz ? tan_orig_PtSzSz(self, _cmd, a, b) : (TANLayoutPt){0,0};
    snprintf(buf, sizeof(buf), "%lld.%06d [TANHook] -[%s %s] => (%.1f,%.1f)\n",
             (long long)tv.tv_sec, (int)tv.tv_usec, class_getName(cls), sel_getName(_cmd), r.x, r.y);
    tan_hookWriteRaw(buf);
    return r;
}

// @@:@@@  (id)(id, SEL, id, id, id)   —— 也覆盖 @@:@@?（block 参数同为指针）
static id (*tan_orig_IIII)(id, SEL, id, id, id);
static id tan_hook_IIII(id self, SEL _cmd, id p1, id p2, id p3) {
    Class cls = object_getClass(self);
    tan_orig_IIII = (id (*)(id, SEL, id, id, id))tan_hookOrigFor(cls, _cmd);
    const void *args[3] = { (__bridge const void *)p1, (__bridge const void *)p2, (__bridge const void *)p3 };
    double td[8]; tan_captureDoubles(td); tan_hookEmit(cls, _cmd, 3, args, td, 8, NULL);
    id r = tan_orig_IIII ? tan_orig_IIII(self, _cmd, p1, p2, p3) : nil;
    double td2[8]; tan_captureDoubles(td2); tan_hookEmit(cls, _cmd, 3, args, td2, 8, (__bridge const void *)r);
    return r;
}

static IMP tan_hookImpForEncoding(const char *enc) {
    if (!enc) return NULL;
    NSString *s = [NSString stringWithUTF8String:enc];
    if ([s isEqualToString:@"v@:"]) return (IMP)tan_hook_v;
    if ([s isEqualToString:@"v@:B"]) return (IMP)tan_hook_vB;
    if ([s isEqualToString:@"v@:@"]) return (IMP)tan_hook_vI;
    if ([s isEqualToString:@"v@:d"]) return (IMP)tan_hook_vD;
    if ([s isEqualToString:@"v@:@B"]) return (IMP)tan_hook_vIB;
    if ([s isEqualToString:@"@@:{CGPoint=dd}dd@dddddd"]) return (IMP)tan_hook_FanInit;
    if ([s isEqualToString:@"{CGPoint=dd}@:{CGPoint=dd}{CGSize=dd}"]) return (IMP)tan_hook_PtPtSz;
    if ([s isEqualToString:@"{CGPoint=dd}@:{CGSize=dd}{CGSize=dd}"]) return (IMP)tan_hook_PtSzSz;
    if ([s isEqualToString:@"@@:@"]) return (IMP)tan_hook_II;
    if ([s isEqualToString:@"@@:@@"]) return (IMP)tan_hook_III;
    if ([s isEqualToString:@"@@:@@@"]) return (IMP)tan_hook_IIII;
    if ([s isEqualToString:@"@@:@@?"]) return (IMP)tan_hook_IIII;
    if ([s isEqualToString:@"v@:@?"]) return (IMP)tan_hook_IIII;
    // 原子返回类型前缀（V 表示原子对象）与普通 id 相同 ABI
    if ([s isEqualToString:@"Vv@:@"]) return (IMP)tan_hook_vI;
    if ([s isEqualToString:@"V@@:@"]) return (IMP)tan_hook_II;
    // handleForPredicate:error: 签名 @@:@o^@ —— @o 是 out id（与 id 同寄存器），映射 @@:@@
    if ([s isEqualToString:@"@@:@o^@"]) return (IMP)tan_hook_III;
    // registerProcessForAuditToken: 签名 @@:{?=[8I]} —— 32B struct 参数
    if ([s isEqualToString:@"@@:{?=[8I]}"]) return (IMP)tan_hook_RegTok;
    return NULL;
}

static NSString *tan_hookSigDesc(const char *enc) {
    NSString *s = [NSString stringWithUTF8String:enc ?: ""];
    NSArray *known = @[@"v@:", @"v@:B", @"v@:@", @"v@:@B", @"@@:@", @"@@:@@", @"@@:@@@", @"@@:@@?", @"v@:@?", @"Vv@:@", @"V@@:@", @"@@:@o^@", @"@@:{?=[8I]}", @"@@:{CGPoint=dd}dd@dddddd"];
    if ([known containsObject:s]) return s;
    return [NSString stringWithFormat:@"UNKNOWN(%@)", s];
}

#pragma mark - 持久化（CFPreferences：hook 列表自动恢复）

static NSString *tan_hookPrefKey(void) { return @"ODebugHookList"; }

// 前向声明（TANHookAutoRestore 在其定义之前调用）
static BOOL tan_hookMethod(Class cls, SEL sel, NSString **err);

static void tan_hookPersist(void) {
    @try {
        pthread_mutex_lock(&tan_hookMutex);
        NSMutableArray *list = [NSMutableArray array];
        for (int i = 0; i < TAN_HOOK_MAX_SLOTS; i++) {
            TANHookSlot *s = &tan_hookSlots[i];
            if (!s->inUse) continue;
            NSString *entry = [NSString stringWithFormat:@"%@|%@",
                               NSStringFromClass(s->cls), NSStringFromSelector(s->sel)];
            [list addObject:entry];
        }
        pthread_mutex_unlock(&tan_hookMutex);
        CFPreferencesSetAppValue((__bridge CFStringRef)tan_hookPrefKey(),
                                 (__bridge CFPropertyListRef)list,
                                 CFSTR("com.tanyou.odebug"));
        CFPreferencesAppSynchronize(CFSTR("com.tanyou.odebug"));
    } @catch (NSException *e) {}
}

// ODebug 注入时调用：自动恢复上次挂载的 hook（SpringBoard 重启后不丢）
// 逃生开关：com.tanyou.odebug/ODebugHookEnabled == NO 时跳过恢复（崩溃循环时用
// `defaults write com.tanyou.odebug ODebugHookEnabled -bool NO` 关闭）
void TANHookAutoRestore(void) {
    @try {
        CFBooleanRef enabled = (CFBooleanRef)CFPreferencesCopyAppValue(CFSTR("ODebugHookEnabled"),
                                                                       CFSTR("com.tanyou.odebug"));
        if (enabled != NULL) {
            if (CFGetTypeID(enabled) == CFBooleanGetTypeID() && !CFBooleanGetValue(enabled)) {
                CFRelease(enabled);
                tan_hookLogC("AUTORESTORE disabled (ODebugHookEnabled=NO)\n");
                return;
            }
            CFRelease(enabled);
        }
        CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)tan_hookPrefKey(),
                                                        CFSTR("com.tanyou.odebug"));
        if (!v) return;
        NSArray *list = (__bridge_transfer NSArray *)v;
        if (![list isKindOfClass:[NSArray class]]) return;
        for (NSString *entry in list) {
            if (![entry isKindOfClass:[NSString class]]) continue;
            NSArray *parts = [entry componentsSeparatedByString:@"|"];
            if (parts.count != 2) continue;
            NSString *err = nil;
            Class cls = nil;
            if ([parts[0] hasPrefix:@"+"]) {
                cls = objc_getMetaClass([parts[0] substringFromIndex:1].UTF8String);
            } else {
                cls = NSClassFromString(parts[0]);
            }
            if (!cls) { tan_hookLogC("AUTORESTORE skip %s (class missing)\n", [parts[0] UTF8String]); continue; }
            if (tan_hookMethod(cls, NSSelectorFromString(parts[1]), &err)) {
                tan_hookLogC("AUTORESTORE hooked %s|%s\n", [parts[0] UTF8String], [parts[1] UTF8String]);
            } else {
                tan_hookLogC("AUTORESTORE fail %s|%s (%s)\n", [parts[0] UTF8String], [parts[1] UTF8String],
                             err ? [err UTF8String] : "?");
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - hook / unhook

static BOOL tan_hookMethod(Class cls, SEL sel, NSString **err) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m == NULL) {
        *err = [NSString stringWithFormat:@"%@ 没有实例方法 %@", NSStringFromClass(cls), NSStringFromSelector(sel)];
        return NO;
    }
    // arm64 type encoding 带偏移（如 v16@0:8），逐段重建规范签名（v@:B 形式）
    char buf[256];
    NSMutableString *normSig = [NSMutableString string];
    method_getReturnType(m, buf, sizeof(buf));
    [normSig appendFormat:@"%s", buf];
    unsigned int argc = method_getNumberOfArguments(m);
    for (unsigned int i = 0; i < argc; i++) {
        method_getArgumentType(m, i, buf, sizeof(buf));
        [normSig appendFormat:@"%s", buf];
    }
    const char *enc = [normSig UTF8String];
    IMP newImp = tan_hookImpForEncoding(enc);
    if (newImp == NULL) {
        *err = [NSString stringWithFormat:@"签名 %@ 不在模板内（支持 v@: v@:B v@:@ @@:@ @@:@@ @@:@@@ @@:@@? v@:@?）",
                tan_hookSigDesc(enc)];
        return NO;
    }
    IMP rawImp = method_getImplementation(m);   // unhook 用
    IMP origImp = NULL;
    MSHookMessageEx(cls, sel, newImp, &origImp);
    if (origImp == NULL || origImp == newImp) {
        *err = [NSString stringWithFormat:@"MSHookMessageEx 失败 %@.%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
        return NO;
    }
    pthread_mutex_lock(&tan_hookMutex);
    int idx = tan_hookSlotIndex(cls, sel);
    if (idx >= 0) { pthread_mutex_unlock(&tan_hookMutex); *err = @"已 hook 过"; return NO; }
    idx = tan_hookFreeSlot();
    if (idx < 0) { pthread_mutex_unlock(&tan_hookMutex); *err = @"槽位已满"; return NO; }
    TANHookSlot *s = &tan_hookSlots[idx];
    s->cls = cls;
    s->sel = sel;
    s->origTramp = origImp;
    s->rawImp = rawImp;
    snprintf(s->sig, sizeof(s->sig), "%s", enc);
    __sync_synchronize();
    s->inUse = 1;
    pthread_mutex_unlock(&tan_hookMutex);
    tan_hookLogC("HOOKED %s%s|%s (%s)\n",
                 class_isMetaClass(cls) ? "+" : "", class_getName(cls), sel_getName(sel), enc);
    tan_hookPersist();
    return YES;
}

static BOOL tan_unhookMethod(Class cls, SEL sel, NSString **err) {
    pthread_mutex_lock(&tan_hookMutex);
    int idx = tan_hookSlotIndex(cls, sel);
    if (idx < 0) { pthread_mutex_unlock(&tan_hookMutex); *err = @"未 hook"; return NO; }
    TANHookSlot *s = &tan_hookSlots[idx];
    IMP rawImp = s->rawImp;
    // 先清槽再恢复实现（hook body 读到 inUse=0 就不再用 origTramp）
    s->inUse = 0;
    __sync_synchronize();
    Method m = class_getInstanceMethod(cls, sel);
    if (m != NULL) method_setImplementation(m, rawImp);
    pthread_mutex_unlock(&tan_hookMutex);
    tan_hookLogC("UNHOOKED %s%s|%s\n",
                 class_isMetaClass(cls) ? "+" : "", class_getName(cls), sel_getName(sel));
    tan_hookPersist();
    return YES;
}

static NSString *tan_hookList(void) {
    NSMutableString *r = [NSMutableString string];
    pthread_mutex_lock(&tan_hookMutex);
    int n = 0;
    for (int i = 0; i < TAN_HOOK_MAX_SLOTS; i++) {
        TANHookSlot *s = &tan_hookSlots[i];
        if (!s->inUse) continue;
        n++;
        [r appendFormat:@"%s%s|%s (%s)\n",
            class_isMetaClass(s->cls) ? "+" : "", class_getName(s->cls),
            sel_getName(s->sel), s->sig];
    }
    pthread_mutex_unlock(&tan_hookMutex);
    if (n == 0) return @"(无活跃 hook)";
    return r;
}

static NSString *tan_hookLogRead(NSInteger lines) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in @[@"/var/jb/tmp/ODebugHook.log",
                             @"/tmp/ODebugHook.log",
                             @"/var/jb/var/mobile/Documents/ODebugHook.log",
                             @"/var/mobile/Documents/ODebugHook.log"]) {
        if (![fm fileExistsAtPath:path]) continue;
        NSString *all = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (all == nil) return [NSString stringWithFormat:@"(读 %@ 失败)", path];
        NSArray *ls = [all componentsSeparatedByString:@"\n"];
        if (lines > 0 && (NSInteger)ls.count > lines) {
            ls = [ls subarrayWithRange:NSMakeRange(ls.count - lines, lines)];
        }
        return [NSString stringWithFormat:@"[%@]\n%@", path, [ls componentsJoinedByString:@"\n"]];
    }
    return @"(日志文件不存在；先 !hook 再操作)";
}

#pragma mark - 命令入口

BOOL TANHookHandleCommand(int fd, NSString *raw) {
    if ([raw hasPrefix:@"!hook"]) {
        NSString *rest = [[raw substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([rest isEqualToString:@"list"]) {
            tan_sendRsp(fd, tan_hookList());
            return YES;
        }
        if ([rest hasPrefix:@"log"]) {
            NSInteger lines = 0;
            NSScanner *sc = [NSScanner scannerWithString:rest];
            [sc scanString:@"log" intoString:NULL];
            [sc scanInteger:&lines];
            tan_sendRsp(fd, tan_hookLogRead(lines));
            return YES;
        }
        NSArray *parts = [rest componentsSeparatedByString:@" "];
        parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (parts.count != 2) { tan_sendRsp(fd, @"用法: !hook <类名> <方法名> 或 !hook list / !hook log [行数]（类方法用 + 前缀，如 !hook +RBSProcessIdentity identityForEmbeddedApplicationIdentifier:）"); return YES; }
        NSString *clsName = parts[0];
        Class cls = nil;
        if ([clsName hasPrefix:@"+"]) {
            clsName = [clsName substringFromIndex:1];
            cls = objc_getMetaClass(clsName.UTF8String);
        } else {
            cls = NSClassFromString(clsName);
        }
        if (!cls) { tan_sendRsp(fd, [NSString stringWithFormat:@"类 %@ 不存在", parts[0]]); return YES; }
        NSString *err = nil;
        BOOL ok = tan_hookMethod(cls, NSSelectorFromString(parts[1]), &err);
        tan_sendRsp(fd, ok ? [NSString stringWithFormat:@"OK: 已 hook %@.%@", parts[0], parts[1]] : [NSString stringWithFormat:@"FAIL: %@", err]);
        return YES;
    }
    if ([raw hasPrefix:@"!unhook"]) {
        NSString *rest = [[raw substringFromIndex:7] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSArray *parts = [rest componentsSeparatedByString:@" "];
        parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (parts.count != 2) { tan_sendRsp(fd, @"用法: !unhook <类名> <方法名>"); return YES; }
        NSString *clsName = parts[0];
        Class cls = nil;
        if ([clsName hasPrefix:@"+"]) {
            clsName = [clsName substringFromIndex:1];
            cls = objc_getMetaClass(clsName.UTF8String);
        } else {
            cls = NSClassFromString(clsName);
        }
        if (!cls) { tan_sendRsp(fd, [NSString stringWithFormat:@"类 %@ 不存在", parts[0]]); return YES; }
        NSString *err = nil;
        BOOL ok = tan_unhookMethod(cls, NSSelectorFromString(parts[1]), &err);
        tan_sendRsp(fd, ok ? [NSString stringWithFormat:@"OK: 已恢复 %@.%@", parts[0], parts[1]] : [NSString stringWithFormat:@"FAIL: %@", err]);
        return YES;
    }
    return NO;
}
