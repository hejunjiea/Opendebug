#import "TANOpenDebugRootController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>

// 与 TANSafeMode.h 保持一致（Settings 是独立二进制，不链接插件本体）
static NSString *const kSafeModeFlagPath = @"/var/mobile/.eksafemode";
static NSString *const kSafeModeDomain = @"com.tanyou.opendebug.settings";
static NSString *const kSafeModeKey = @"safeMode";
static NSString *const kSafeModeOnNote = @"com.tanyou.opendebug.safemode.on";
static NSString *const kSafeModeOffNote = @"com.tanyou.opendebug.safemode.off";

@implementation TANOpenDebugRootController

// 显式加载 Root.plist（对齐 Preferences 标准写法，避免依赖框架默认行为导致空白页）
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// 进页面时用真实标记文件校正开关（退出安全模式后不会残留「开」）
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    BOOL on = [[NSFileManager defaultManager] fileExistsAtPath:kSafeModeFlagPath];
    Boolean cur = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)kSafeModeKey,
                                                 (__bridge CFStringRef)kSafeModeDomain, NULL);
    if ((BOOL)cur != on) {
        CFPreferencesSetAppValue((__bridge CFStringRef)kSafeModeKey,
                                 on ? kCFBooleanTrue : kCFBooleanFalse,
                                 (__bridge CFStringRef)kSafeModeDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kSafeModeDomain);
        [self reloadSpecifiers];
    }
}

// 开关动作：真正读写标记的是 SpringBoard 进程里的插件（mobile 的 Settings App 写不了容器外文件），
// 这里只负责写偏好 + 发 Darwin 通知。
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    if (![[specifier propertyForKey:@"key"] isEqualToString:kSafeModeKey]) return;

    BOOL on = [value boolValue];
    NSString *title = on ? @"进入安全模式？" : @"退出安全模式？";
    NSString *msg = on
        ? @"会写标记 /var/mobile/.eksafemode 并重启 SpringBoard：\n所有插件停止注入（分屏 / 扇形菜单 / Crane / Choicy / AppSync … 全部失效）。\n\n退出办法（安全模式下设置页可能打不开）：打开 Filza 或 DFTerminal，执行\nrm -f /var/mobile/.eksafemode && sbreload"
        : @"会删掉标记 /var/mobile/.eksafemode 并重启 SpringBoard，恢复插件注入。";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                              message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *a) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)(on ? kSafeModeOnNote : kSafeModeOffNote), NULL, NULL, true);
    }]];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"取消"
                                          style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *a) {
        BOOL actual = [[NSFileManager defaultManager] fileExistsAtPath:kSafeModeFlagPath];
        CFPreferencesSetAppValue((__bridge CFStringRef)kSafeModeKey,
                                 actual ? kCFBooleanTrue : kCFBooleanFalse,
                                 (__bridge CFStringRef)kSafeModeDomain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)kSafeModeDomain);
        [weakSelf reloadSpecifiers];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
