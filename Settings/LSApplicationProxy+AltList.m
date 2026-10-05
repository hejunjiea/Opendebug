/**
 * LSApplicationProxy+AltList.m - LSApplicationProxy AltList 分类实现
 *
 * 实现了应用类型判断、隐藏检测、名称获取等核心功能。
 */

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
/* 私有 API 声明：LSApplicationRecord、LSApplicationProxy 扩展等 */
#import "CoreServices.h"
#import "LSApplicationProxy+AltList.h"

/* 获取当前进程的可执行文件路径，避免依赖外部 AltList.framework 提供该符号 */
NSString *safe_getExecutablePath(void)
{
    char executablePathC[PATH_MAX];
    uint32_t executablePathCSize = sizeof(executablePathC);
    _NSGetExecutablePath(&executablePathC[0], &executablePathCSize);
    return [NSString stringWithUTF8String:executablePathC];
}

@implementation LSApplicationProxy (AltList)

/**
 * 判断是否为可见的系统应用
 * 条件：applicationType 为 @"System" 且没有被隐藏
 *
 * @return YES 表示是可见的系统应用
 */
- (BOOL)atl_isSystemApplication
{
    /* applicationType 为 @"System" 且非隐藏，才被认为是系统应用 */
    return [self.applicationType isEqualToString:@"System"] && ![self atl_isHidden];
}

/**
 * 判断是否为可见的用户应用
 * 条件：applicationType 为 @"User" 且没有被隐藏
 *
 * @return YES 表示是可见的用户应用
 */
- (BOOL)atl_isUserApplication
{
    /* applicationType 为 @"User" 且非隐藏，才被认为是用户应用 */
    return [self.applicationType isEqualToString:@"User"] && ![self atl_isHidden];
}

/**
 * 检查标签数组中是否包含指定的标记
 * " hidden " 格式的标签也是有效的，因此使用 rangeOfString 进行子串匹配
 *
 * @param tagArr 标签数组
 * @param tag    要查找的标记字符串（如 "hidden"）
 * @return YES 表示找到匹配的标记
 */
BOOL tagArrayContainsTag(NSArray* tagArr, NSString* tag)
{
    /* 入参保护：数组或目标字符串为空则直接返回 NO */
    if(!tagArr || !tag) return NO;

    __block BOOL found = NO;

    [tagArr enumerateObjectsUsingBlock:^(NSString* tagToCheck, NSUInteger idx, BOOL* stop)
    {
        /* 确保元素是 NSString 类型 */
        if(![tagToCheck isKindOfClass:[NSString class]])
        {
            return;
        }

        /* 使用 rangeOfString 判断是否包含目标子串（处理带空格的变体） */
        if([tagToCheck rangeOfString:tag options:0].location != NSNotFound)
        {
            found = YES;
            *stop = YES;
        }
    }];

    return found;
}

/**
 * 判断应用是否隐藏
 * 在 iOS 7 上始终返回 NO（不支持隐藏功能）
 * 检查多个来源的 appTags 是否包含 "hidden"：
 * - LSApplicationProxy 本身的 appTags（iOS 14 上可能为空）
 * - LSApplicationRecord 的 appTags（iOS 14+）
 * - Info.plist 中的 SBAppTags
 * - 是否是 Web 应用（com.apple.webapp.*）
 * - 是否禁止启动（launchProhibited）
 *
 * @return YES 表示应用被隐藏
 */
- (BOOL)atl_isHidden
{
    /* 声明变量：来自不同来源的标签数组 */
    NSArray* appTags;          /* LSApplicationProxy 的 appTags */
    NSArray* recordAppTags;    /* LSApplicationRecord 的 appTags */
    NSArray* sbAppTags;        /* Info.plist 中的 SBAppTags */

    BOOL launchProhibited = NO;

    /* iOS 14+：从 LSApplicationRecord 获取更准确的 appTags */
    if([self respondsToSelector:@selector(correspondingApplicationRecord)])
    {
        /* 在 iOS 14 上，self.appTags 始终为空，但 application record 有正确的值 */
        LSApplicationRecord* record = [self correspondingApplicationRecord];
        recordAppTags = record.appTags;
        launchProhibited = record.launchProhibited;
    }
    /* 检查 LSApplicationProxy 是否响应 appTags 方法 */
    if([self respondsToSelector:@selector(appTags)])
    {
        appTags = self.appTags;
    }
    /* 检查 launchProhibited 属性 */
    if(!launchProhibited && [self respondsToSelector:@selector(isLaunchProhibited)])
    {
        launchProhibited = self.launchProhibited;
    }

    /* 从应用的 Info.plist 中读取 SBAppTags */
    NSURL* bundleURL = self.bundleURL;
    if(bundleURL && [bundleURL checkResourceIsReachableAndReturnError:nil])
    {
        /* 如果 bundle 路径可达，读取 Info.plist 中的 SBAppTags */
        NSBundle* bundle = [NSBundle bundleWithURL:bundleURL];
        sbAppTags = [bundle objectForInfoDictionaryKey:@"SBAppTags"];
    }

    /* 判断是否是 Web 应用（以 com.apple.webapp 开头的包名） */
    BOOL isWebApplication = ([self.atl_bundleIdentifier rangeOfString:@"com.apple.webapp" options:NSCaseInsensitiveSearch].location != NSNotFound);
    /* 综合判断：只要任一来源包含 "hidden" 或为 Web 应用或禁止启动，就认为是隐藏应用 */
    return tagArrayContainsTag(appTags, @"hidden") || tagArrayContainsTag(recordAppTags, @"hidden") || tagArrayContainsTag(sbAppTags, @"hidden") || isWebApplication || launchProhibited;
}

/**
 * 快速获取应用的显示名称
 * 常规的 localizedName 获取方式使用 IPC 调用（约 2ms），
 * 在遍历大量应用时性能开销较大（排序约 230ms）。
 * 本方法通过缓存和直接读取 Info.plist 来优化性能（约 0.5ms），
 * 将排序时间降低到约 120ms。
 *
 * @return 应用的本地化显示名称
 */
- (NSString*)atl_fastDisplayName
{
    /* 尝试从缓存中读取：_localizedName 是 LSApplicationProxy 的内部缓存属性 */
    NSString* cachedDisplayName = [self valueForKey:@"_localizedName"];
    if(cachedDisplayName && ![cachedDisplayName isEqualToString:@""])
    {
        return cachedDisplayName;  /* 命中缓存，直接返回 */
    }

    /* 缓存未命中，需要自行获取 */
    NSString* localizedName;

    NSURL* bundleURL = self.bundleURL;
    if(!bundleURL || ![bundleURL checkResourceIsReachableAndReturnError:nil])
    {
        /* bundle 路径不可达：回退使用慢速 IPC 调用 */
        localizedName = self.localizedName;
    }
    else
    {
        /* bundle 可达：直接从 Info.plist 读取，避免 IPC */
        NSBundle* bundle = [NSBundle bundleWithURL:bundleURL];

        /* 优先读取 CFBundleDisplayName（完整的显示名） */
        localizedName = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
        if(![localizedName isKindOfClass:[NSString class]]) localizedName = nil;
        if(!localizedName || [localizedName isEqualToString:@""])
        {
            /* 回退到 CFBundleName（简短名称） */
            localizedName = [bundle objectForInfoDictionaryKey:@"CFBundleName"];
            if(![localizedName isKindOfClass:[NSString class]]) localizedName = nil;
            if(!localizedName || [localizedName isEqualToString:@""])
            {
                /* 再回退到 CFBundleExecutable（可执行文件名） */
                localizedName = [bundle objectForInfoDictionaryKey:@"CFBundleExecutable"];
                if(![localizedName isKindOfClass:[NSString class]]) localizedName = nil;
                if(!localizedName || [localizedName isEqualToString:@""])
                {
                    /* 最终回退：使用慢速 IPC 调用获取 */
                    localizedName = self.localizedName;
                }
            }
        }
    }

    /* 将结果写入缓存，下次可直接读取 */
    [self setValue:localizedName forKey:@"_localizedName"];
    return localizedName;
}

/**
 * 获取用于在 UI 上展示的应用名称
 * 对 CarPlay 相关应用特殊处理：如果名称中不包含 "CarPlay" 字样，自动追加
 *
 * @return 格式化后的展示名称
 */
- (NSString*)atl_nameToDisplay
{
    /* 先获取快速显示名称 */
    NSString* localizedName = [self atl_fastDisplayName];

    /* 对 CarPlay 应用特殊处理 */
    if([self.atl_bundleIdentifier rangeOfString:@"carplay" options:NSCaseInsensitiveSearch].location != NSNotFound)
    {
        /* 如果名称中不包含 "carplay"，追加 "(CarPlay)" 后缀以明确标识 */
        if([localizedName rangeOfString:@"carplay" options:NSCaseInsensitiveSearch range:NSMakeRange(0, localizedName.length) locale:[NSLocale currentLocale]].location == NSNotFound)
        {
            return [localizedName stringByAppendingString:@" (CarPlay)"];
        }
    }

    /* 非 CarPlay 应用直接返回本地化名称 */
    return localizedName;
}

/**
 * 获取应用的包名（bundleIdentifier）
 * 兼容 iOS 7（使用 applicationIdentifier）和 iOS 8+（使用 bundleIdentifier）
 *
 * @return 应用的包名字符串
 */
-(id)atl_bundleIdentifier
{
    /* iOS 8-14：使用 bundleIdentifier 属性 */
    if([self respondsToSelector:@selector(bundleIdentifier)])
    {
        return [self bundleIdentifier];
    }
    /* iOS 7：使用 applicationIdentifier 属性 */
    else
    {
        return [self applicationIdentifier];
    }
}

@end

/**
 * LSApplicationWorkspace (AltList) 实现
 */
@implementation LSApplicationWorkspace (AltList)

/**
 * 获取所有已安装应用的安全方法
 * 使用 iOS 10+ 的 enumerateApplicationsOfType:block: 枚举所有应用，
 * 避免在 lsd 进程中调用 allInstalledApplications（可能崩溃）。
 * 在 iOS 10+ 上分别枚举类型 0（所有应用）和类型 1（内部应用），
 * 在旧版本上回退到 allInstalledApplications。
 *
 * @return 所有已安装应用的 LSApplicationProxy 数组
 */
- (NSArray*)atl_allInstalledApplications
{
    NSString *selfExecutable = safe_getExecutablePath();
    if ([selfExecutable isEqualToString:@"/usr/libexec/lsd"]) {
        /* 防止在 lsd 进程中调用此方法，否则可能导致崩溃 */
        return nil;
    }

    /* 检查是否支持 iOS 10+ 的枚举方法 */
    if(![self respondsToSelector:@selector(enumerateApplicationsOfType:block:)])
    {
        /* 旧版本系统：使用已废弃的 allInstalledApplications 方法 */
        return [self allInstalledApplications];
    }

    NSMutableArray* installedApplications = [NSMutableArray new];
    /* 枚举类型 0（用户 + 系统应用） */
    [self enumerateApplicationsOfType:0 block:^(LSApplicationProxy* appProxy)
    {
        [installedApplications addObject:appProxy];
    }];
    /* 枚举类型 1（内部/幽灵应用，如 com.apple.webapp.*） */
    [self enumerateApplicationsOfType:1 block:^(LSApplicationProxy* appProxy)
    {
        [installedApplications addObject:appProxy];
    }];
    return installedApplications;
}

@end
