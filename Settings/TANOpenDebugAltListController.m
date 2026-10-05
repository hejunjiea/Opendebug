#import "TANOpenDebugAltListController.h"
#import "PSSpecifier+AltList.h"

@implementation TANOpenDebugAltListController

// 覆写 savePreferences：直接从 _selectedApplications 重建有序列表，写 OpenDebug 自己的域
- (void)savePreferences
{
    [super savePreferences];

    PSSpecifier *spec = [self specifier];
    NSArray *existingOrder = nil;
    if ([spec atl_hasValidGetter]) {
        existingOrder = [spec atl_performGetter];
    }
    NSMutableArray *orderedResult = [NSMutableArray array];
    NSMutableSet *remaining = [_selectedApplications mutableCopy];
    if (existingOrder) {
        for (NSString *bid in existingOrder) {
            if ([remaining containsObject:bid]) {
                [orderedResult addObject:bid];
                [remaining removeObject:bid];
            }
        }
    }
    for (NSString *bid in remaining) {
        [orderedResult addObject:bid];
    }

    // 只写 OpenDebug 自己的域（不写主插件域、不写镜像文件、不发通知）
    CFPreferencesSetAppValue(CFSTR("debugInjectedApps"),
                             (__bridge CFPropertyListRef)orderedResult,
                             CFSTR("com.tanyou.opendebug.settings"));

    // 把 Filter 也写进同一域：CFPreferences 经 cfprefsd 写真实文件（NSFileManager 会被沙盒容器虚拟化）
    // ODebug.plist 是软链 → 该域 plist 文件，loader 读软链即读到最新 Filter
    NSMutableArray *bundles = [NSMutableArray arrayWithObject:@"com.apple.springboard"];
    for (NSString *bid in orderedResult) {
        if ([bid isKindOfClass:[NSString class]] && bid.length && ![bundles containsObject:bid]) {
            [bundles addObject:bid];
        }
    }
    NSDictionary *filterDict = @{@"Bundles": bundles};
    CFPreferencesSetAppValue(CFSTR("Filter"), (__bridge CFPropertyListRef)filterDict,
                             CFSTR("com.tanyou.opendebug.settings"));
    CFPreferencesAppSynchronize(CFSTR("com.tanyou.opendebug.settings"));
    NSLog(@"[OpenDebugSettings] Filter 已写入 -> %@", bundles);
}

@end
