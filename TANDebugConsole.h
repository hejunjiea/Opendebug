/**
 * TANDebugConsole - TCP 远程调试控制台 (端口 4321)
 * 支持命令：!eval, !class, !mem, !icons, !plist, !vc [ClassName], !vcapp [bundleId]
 * 仅在 SpringBoard 进程启动（TANDebugConsoleStart 内部有进程守卫）。
 */

#ifndef TANDebugConsole_h
#define TANDebugConsole_h

#import <Foundation/Foundation.h>

/// 启动 TCP 调试控制台（port 4321），auto-runs via __attribute__((constructor))
void TANDebugConsoleStart(void);

#endif /* TANDebugConsole_h */
