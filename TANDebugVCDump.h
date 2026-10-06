//
//  TANDebugVCDump.h
//  共享的 view → controller dump 工具：可被 SpringBoard 控制台与注入目标 App 复用。
//
//  ⚠️ 必须用 extern "C" 守卫：这些函数定义在 .m（C 链接），而 Tweak.xm 是 ObjC++，
//  不加守卫会被 C++ 修饰名污染（__Z31TANVCDump...），导致 dlopen 找不到符号、插件不加载。
//

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 沿 nextResponder 链向上找最近的 UIViewController
UIViewController *TANVCDumpViewControllerForView(UIView *view);

/// 遍历 keyWindow 的 view→controller 树，返回字符串；filter 非空时只输出类名包含 filter 的 view
NSString *TANVCDumpKeyWindowToStringFiltered(NSString *filter);

/// 遍历 keyWindow 全量输出
NSString *TANVCDumpKeyWindowToString(void);

/// 遍历所有 window 的 view→controller 树（含悬浮窗/overlay 等非 keyWindow）；
/// filter 非空时只输出类名包含 filter 的 view。修复 !vc 只走 keyWindow 看不到菜单的问题。
NSString *TANVCDumpAllWindowsToStringFiltered(NSString *filter);

/// 只输出最上层控制器：类名 + 内存地址 + title + view 信息（沿 presented/容器链找到当前页面）
NSString *TANVCDumpTopViewControllerString(void);

/// 注册 Darwin 通知 `com.tanyou.open/dumpVC`（全量树）与 `com.tanyou.open/dumpVCTop`（仅最上层控制器）：
/// 收到后把当前进程的 keyWindow 视图树打印到 syslog（[open] 前缀）
/// 供注入目标 App 进程使用（由 Tweak.xm 构造器在选中 App 里调用）。
void TANVCDumpRegisterDarwinListener(void);
/// 把文本回传给 odebugd(4322)（VCDUMP 通道，WLAN 下视图树靠它显示）
void tan_sendVcDumpToDaemon(NSString *text);

#ifdef __cplusplus
}
#endif
