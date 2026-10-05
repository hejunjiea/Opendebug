/**
 * LSApplicationProxy+AltList.h - LSApplicationProxy 的 AltList 扩展分类
 *
 * 为 LSApplicationProxy 和 LSApplicationWorkspace 添加判断应用类型、快速获取显示名称等便捷方法。
 */

/* 导入 LSApplicationProxy 和 LSApplicationWorkspace 的基类声明 */
#import <MobileCoreServices/LSApplicationProxy.h>
#import <MobileCoreServices/LSApplicationWorkspace.h>

/**
 * LSApplicationProxy (AltList) - 应用代理的 AltList 分类
 * 提供应用类型判断和名称获取的便捷方法
 */
@interface LSApplicationProxy (AltList)

/**
 * 判断是否为系统应用
 * 条件：applicationType 为 @"System" 且非隐藏
 *
 * @return YES 表示是可见的系统应用
 */
- (BOOL)atl_isSystemApplication;

/**
 * 判断是否为用户应用
 * 条件：applicationType 为 @"User" 且非隐藏
 *
 * @return YES 表示是可见的用户应用
 */
- (BOOL)atl_isUserApplication;

/**
 * 判断应用是否被隐藏
 * 检查 appTags、SBAppTags 等是否包含 "hidden" 标记
 *
 * @return YES 表示应用被隐藏
 */
- (BOOL)atl_isHidden;

/**
 * 快速获取应用的显示名称
 * 使用缓存机制避免重复 IPC 调用，提升性能
 * 从约 2ms 优化到约 0.5ms
 *
 * @return 应用的本地化显示名称
 */
- (NSString*)atl_fastDisplayName;

/**
 * 获取用于展示的应用名称
 * 对 CarPlay 应用特殊处理，自动追加 "(CarPlay)" 后缀
 *
 * @return 格式化后的展示名称
 */
- (NSString*)atl_nameToDisplay;

/**
 * 应用的包名（bundleIdentifier）
 * 兼容 iOS 7（bundleIdentifier 方法）和 iOS 8+（applicationIdentifier 方法）
 */
@property (nonatomic,readonly) NSString* atl_bundleIdentifier;

@end

/**
 * LSApplicationWorkspace (AltList) - 应用工作空间的 AltList 分类
 * 提供获取所有已安装应用的安全方法
 */
@interface LSApplicationWorkspace (AltList)

/**
 * 获取所有已安装的应用列表
 * 使用 iOS 10+ 的 enumerateApplicationsOfType:block: 方法枚举类型 0 和类型 1
 * 避免在 lsd 进程中调用（防止崩溃）
 *
 * @return 所有已安装的 LSApplicationProxy 对象数组
 */
- (NSArray*)atl_allInstalledApplications;

@end
