/**
 * TANHookConsole - ODebug 动态方法观察（log-only hook）
 *
 * 用法（控制台）：
 *   !hook <ClassName> <selector>     动态 hook 一个实例方法，调用时记录参数到日志
 *                                   （类方法加 + 前缀：!hook +RBSProcessIdentity identityForEmbeddedApplicationIdentifier:）
 *   !hook list                       列出当前活跃 hooks
 *   !unhook <ClassName> <selector>   恢复原实现（移除 hook）
 *   !hooklog [行数]                  读取 hook 调用日志（默认全部）
 *
 * 设计要点：
 *  - hook body 纯 C（class_getName + 指针 %p + POSIX write），零对象方法调用，防悬垂 SIGSEGV。
 *  - hook 函数通过 (类名,selector) 在全局注册表查 orig IMP，支持任意多个同签名 hook。
 *  - 日志写文件 /var/jb/tmp/ODebugHook.log（多路径 fallback）。
 *  - hook 列表持久化到 CFPreferences，ODebug 每次注入（含 SpringBoard 重启后）自动恢复挂载。
 *  - !unhook 用 hook 前保存的原 IMP 恢复（method_setImplementation）。
 */
#ifndef TANHookConsole_h
#define TANHookConsole_h

#import <Foundation/Foundation.h>

// C 链接：本头文件同时被 ObjC(.m) 和 ObjC++(.xm) 引用，函数必须保持 C 符号
// （否则 .xm 里声明被 mangle 成 _Z*，而 .m 里定义是 _TANHook*，运行时 dyld 解析失败）
#ifdef __cplusplus
extern "C" {
#endif

/// 处理 !hook / !unhook / !hooklog 命令；非 hook 命令返回 NO（不处理）
BOOL TANHookHandleCommand(int fd, NSString *raw);

/// ODebug 注入时调用：自动恢复上次挂载的 hook 列表（SpringBoard 重启后不丢）
void TANHookAutoRestore(void);

#ifdef __cplusplus
}
#endif

#endif /* TANHookConsole_h */
