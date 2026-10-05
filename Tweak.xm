/**
 * ODebug - TCP 调试控制台独立插件（完全独立，不依赖主插件 Open）
 *
 * 进程门控：
 *   - SpringBoard：TCP 控制台由 TANDebugConsole.m 的 __attribute__((constructor)) 自动启动。
 *   - 注入目标 App：被 roothide loader 按 Filter 注入的非 SpringBoard 进程就是选中目标，
 *     注册 Darwin 监听，收到 com.tanyou.open/dumpVC 后把 keyWindow 视图树打印到 syslog（[open] 前缀）。
 *
 * 注入目标由设置页（Settings/）通过 CFPreferences 写入 Filter，postinst 把 ODebug.plist
 * 软链到偏好域 plist，loader 跟随软链读到最新 Filter——本文件不参与 Filter 改写。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "TANDebugVCDump.h"
#import "TANHookConsole.h"
#import "TANSafeMode.h"

// TANVCDumpRegisterDarwinListener 定义在 .m（C 链接），这里强制 C 链接，避免被 C++ 修饰名污染
extern "C" void TANVCDumpRegisterDarwinListener(void);

/// 判断当前进程是否为 SpringBoard
static BOOL tan_isSpringBoardProcess(void) {
    static BOOL c, r;
    if (!c) { r = [[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]; c = YES; }
    return r;
}

%ctor {
    // 非 SpringBoard 进程 = 注入目标（被注入即被选中）→ 注册 dump 监听
    if (!tan_isSpringBoardProcess()) {
        NSLog(@"[ODebug] 注入 %@，注册 dump 监听",
              [NSBundle mainBundle].bundleIdentifier ?: @"?");
        TANVCDumpRegisterDarwinListener();
    } else {
        // 安全模式开关：设置页开关 → 本进程执行（写标记 + respring），不需要 root 组件
        TANSafeModeRegisterDarwinListener();

        // SpringBoard：延迟恢复上次挂载的动态 hooks。6 秒后等 FB 系类全部加载 + SB 启动早期
        // 事务稳定再挂（2 秒过早曾在 SB 启动早期触发崩溃循环 20409→20442）。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            TANHookAutoRestore();
        });
    }
}
