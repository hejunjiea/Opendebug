/**
 * ATLApplicationSection.h - 应用分区模型
 *
 * 定义应用列表的分区方式，支持将已安装应用按类型分组展示。
 */

#import <Foundation/Foundation.h>

/**
 * ApplicationSectionType - 应用分区类型枚举
 * 定义了六种内置的分区方式
 */
typedef NS_ENUM(NSInteger, ApplicationSectionType) {
    SECTION_TYPE_ALL,      /* 所有应用，不做任何筛选 */
    SECTION_TYPE_SYSTEM,   /* 仅系统应用（applicationType == @"System"） */
    SECTION_TYPE_USER,     /* 仅用户应用（applicationType == @"User"） */
    SECTION_TYPE_HIDDEN,   /* 仅隐藏应用（appTags 包含 "hidden"） */
    SECTION_TYPE_VISIBLE,  /* 仅可见应用（非隐藏） */
    SECTION_TYPE_CUSTOM    /* 自定义谓词筛选 */
};

/* 分区类型对应的字符串常量，用于在 plist 中配置 */
#define kApplicationSectionTypeAll @"All"         /* 全部应用 */
#define kApplicationSectionTypeSystem @"System"   /* 系统应用 */
#define kApplicationSectionTypeUser @"User"       /* 用户应用 */
#define kApplicationSectionTypeHidden @"Hidden"   /* 隐藏应用 */
#define kApplicationSectionTypeVisible @"Visible" /* 可见应用 */
#define kApplicationSectionTypeCustom @"Custom"   /* 自定义 */

/**
 * ATLApplicationSection - 应用分区模型类
 * 管理一个分区中的应用列表，提供类型转换、筛选和排序功能
 */
@interface ATLApplicationSection : NSObject

/** sectionType：分区类型 */
@property (nonatomic) ApplicationSectionType sectionType;
/** customPredicate：自定义筛选谓词（仅 SECTION_TYPE_CUSTOM 时使用） */
@property (nonatomic) NSPredicate* customPredicate;
/** sectionName：分区显示名称 */
@property (nonatomic) NSString* sectionName;

/** applicationsInSection：该分区包含的应用列表 */
@property (nonatomic) NSArray* applicationsInSection;

/**
 * 将字符串类型转换为枚举值
 *
 * @param typeString 类型字符串（如 @"User"、@"System"）
 * @return 对应的枚举值，无法识别时返回 SECTION_TYPE_CUSTOM
 */
+ (ApplicationSectionType)sectionTypeFromString:(NSString*)typeString;

/**
 * 将枚举值转换为字符串
 *
 * @param sectionType 分区类型枚举
 * @return 对应的字符串表示
 */
+ (NSString*)stringFromSectionType:(ApplicationSectionType)sectionType;

/**
 * 从字典创建分区对象（工厂方法）
 * 支持通过 customClass 字段指定自定义分区子类
 *
 * @param sectionDictionary 包含分区配置的字典（来自 plist）
 * @return 创建好的分区对象
 */
+ (__kindof ATLApplicationSection*)applicationSectionWithDictionary:(NSDictionary*)sectionDictionary;

/**
 * 内部初始化方法（从字典）
 *
 * @param sectionDictionary 分区配置字典
 * @return 初始化完成的分区对象
 */
- (instancetype)_initWithDictionary:(NSDictionary*)sectionDictionary;

/**
 * 创建非自定义类型的分区
 *
 * @param sectionType 分区类型
 * @return 初始化完成的分区对象
 */
- (instancetype)initNonCustomSectionWithType:(ApplicationSectionType)sectionType;

/**
 * 创建自定义类型的分区
 *
 * @param predicate   筛选谓词
 * @param sectionName 分区名称
 * @return 初始化完成的分区对象
 */
- (instancetype)initCustomSectionWithPredicate:(NSPredicate*)predicate sectionName:(NSString*)sectionName;

/**
 * 获取应用于该分区应用的排序描述器
 * 默认按应用名称的本地化字符串升序排序
 *
 * @return 排序描述器数组
 */
- (NSArray<NSSortDescriptor*>*)sortDescriptorsForApplications;

/**
 * 从所有应用中筛选并填充当前分区
 * 根据分区类型应用不同的 NSPredicate 筛选条件
 *
 * @param allApplications 所有已安装的应用列表
 */
- (void)populateFromAllApplications:(NSArray*)allApplications;

@end
