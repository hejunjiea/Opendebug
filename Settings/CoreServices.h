/**
 * CoreServices.h - 核心服务私有 API 声明
 */

/* LSApplicationProxy：应用代理类，代表一个已安装的应用 */
#import <MobileCoreServices/LSApplicationProxy.h>
/* LSApplicationWorkspace：应用工作空间，管理所有已安装应用 */
#import <MobileCoreServices/LSApplicationWorkspace.h>

/**
 * LSApplicationRecord - 应用记录类（私有）
 * 在 iOS 14+ 中，应用的部分元数据从 LSApplicationProxy 移到了 LSApplicationRecord
 * 需要通过 -correspondingApplicationRecord 方法获取
 */
@interface LSApplicationRecord : NSObject
/**
 * appTags：应用的标签数组
 * 包含 'hidden' 表示该应用是隐藏应用
 */
@property (nonatomic,readonly) NSArray* appTags;
/**
 * isLaunchProhibited：是否禁止启动
 * 为 YES 时表示该应用由于家长控制等原因被限制启动
 */
@property (getter=isLaunchProhibited,readonly) BOOL launchProhibited;
@end

/**
 * LSApplicationProxy (Additions) - 应用代理扩展
 * 补充声明私有属性，用于获取应用的详细信息
 */
@interface LSApplicationProxy (Additions)
/** localizedName：应用的本地化显示名称 */
@property (nonatomic,readonly) NSString* localizedName;
/** applicationType：应用类型（@"User" 或 @"System"） */
@property (nonatomic,readonly) NSString* applicationType;
/** appTags：应用标签数组（同 LSApplicationRecord.appTags） */
@property (nonatomic,readonly) NSArray* appTags;
/** isLaunchProhibited：是否被禁止启动 */
@property (getter=isLaunchProhibited,nonatomic,readonly) BOOL launchProhibited;
/**
 * applicationProxyForIdentifier：
 * 根据包名获取对应的应用代理对象
 *
 * @param identifier 应用的 bundleIdentifier
 * @return 应用代理实例
 */
+ (instancetype)applicationProxyForIdentifier:(NSString*)identifier;
/**
 * correspondingApplicationRecord：
 * 获取对应的 LSApplicationRecord（iOS 14+）
 *
 * @return 应用记录对象
 */
- (LSApplicationRecord*)correspondingApplicationRecord;
@end

/**
 * LSApplicationWorkspace (Additions) - 应用工作空间扩展
 * 补充声明应用枚举和监听相关的私有方法
 */
@interface LSApplicationWorkspace (Additions)
/**
 * addObserver: / removeObserver:
 * 注册/注销应用安装、卸载的事件监听
 *
 * @param arg1 观察者对象
 */
- (void)addObserver:(id)arg1;
- (void)removeObserver:(id)arg1;
/**
 * enumerateApplicationsOfType:block:
 * 按类型枚举已安装的应用
 *
 * @param type 应用类型（0 = 所有, 1 = 内部）
 * @param block 每个应用的回调
 */
- (void)enumerateApplicationsOfType:(NSUInteger)type block:(void (^)(LSApplicationProxy*))block;
@end
