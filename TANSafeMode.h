/**
 * ODebug 安全模式开关（禁用全部 tweak 注入 / 进安全模式）
 *
 * 机制（2026-10-06 真机单变量实测）：
 *   1) 本机注入器在**进程启动时**判定一次安全模式，之后写标记不会影响已在跑的进程；
 *   2) 判定依据 = <jbroot>/basebin/.safe_mode 是否存在 —— postinst 把它软链到
 *      /var/mobile/.eksafemode，且注入器检查时**跟随软链**（实测悬空软链 = 不生效）；
 *   3) ★ 注入器解析该软链用的是 **jbroot 侧**的 /var/mobile，所以真正必须被创建的文件是
 *        <jbroot>/var/mobile/.eksafemode
 *      = /private/var/mobile/Containers/Shared/AppGroup/<jbroot 名>/var/mobile/.eksafemode
 *      实测：写这里 + 重启 SpringBoard ⇒ 新 SpringBoard 0 个 tweak（安全模式）；
 *            写真实 /var/mobile/.eksafemode ⇒ 新 SpringBoard 仍 47 个 tweak（无效）。
 *      该目录是 mobile:mobile 0755 ⇒ SpringBoard（mobile）可写 ⇒ 开关不需要 root 组件。
 *   ⇒ 标记路径**一律**用 TANSafeModeFlagPath()，不要硬编码 /var/mobile/.eksafemode。
 *
 * 注意：标记只在**进程启动时**生效 ⇒ 进安全模式必须让目标进程重启：respring 只清
 * SpringBoard，其它已在跑的守护进程要等自己重启（或 jbctl reboot_userspace）。
 */
#import <Foundation/Foundation.h>

// Tweak.xm（Objective-C++）按 C++ 链接规则引用，必须固定成 C 符号名，
// 否则 dyld 报 symbol not found in flat namespace '_Z33TANSafeModeRegisterDarwinListenerv'。
#ifdef __cplusplus
extern "C" {
#endif

/// 设置页开关 → SpringBoard 执行（Darwin 通知，跨进程无需额外权限）
extern NSString *const TANSafeModeDarwinOnNotification;  // com.tanyou.opendebug.safemode.on
extern NSString *const TANSafeModeDarwinOffNotification; // com.tanyou.opendebug.safemode.off

/// 当前 jbroot（从自身 dylib 路径推导）；失败返回 nil
NSString *TANJbrootPath(void);
/// 注入器检查的软链 = <jbroot>/basebin/.safe_mode（postinst 建成软链，指向 /var/mobile/.eksafemode）
NSString *TANSafeModeMarkerLinkPath(void);
/// ★ 真正要创建/删除的标记文件 = <jbroot>/var/mobile/.eksafemode（jbroot 未知时退回 /var/mobile/.eksafemode）
NSString *TANSafeModeFlagPath(void);

/// 标记文件是否存在（= 处于安全模式）
BOOL TANSafeModeIsOn(void);
/// 写标记（幂等）。detail 返回人话结果（含软链是否就绪）；NO = 写入失败
BOOL TANSafeModeEnable(NSString **detail);
/// 删标记（幂等）。NO = 删除失败
BOOL TANSafeModeDisable(NSString **detail);
/// 只读状态文本（!safe status）
NSString *TANSafeModeStatusText(void);

/// 自我 SIGKILL（= respring）。必须 SIGKILL：SIGTERM 可能被别的处理器接住
void TANSafeModeRespring(void);
/// 用 <jbroot>/basebin/jbctl reboot_userspace（setuid root）重启用户空间 ⇒ 所有进程都干净。
/// NO = spawn 失败，调用方应退回 respring
BOOL TANSafeModeSpawnUreboot(NSString **detail);
/// 在 SpringBoard 进程里注册开关监听（设置页开关触发；tweaks 不注入时不注册也不影响退出）
void TANSafeModeRegisterDarwinListener(void);

#ifdef __cplusplus
}
#endif
