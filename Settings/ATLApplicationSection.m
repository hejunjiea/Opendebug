/**
 * ATLApplicationSection.m - 应用分区模型实现
 *
 * 实现分区类型的字符串/枚举互转、分区创建、应用筛选和排序等功能。
 */

#import <Foundation/Foundation.h>
#import "ATLApplicationSection.h"

@implementation ATLApplicationSection

/**
 * 将字符串类型转换为枚举值
 *
 * @param typeString 类型字符串
 * @return 对应的枚举值
 */
+ (ApplicationSectionType)sectionTypeFromString:(NSString*)typeString
{
    /* 匹配所有内置类型字符串 */
    if([typeString isEqualToString:kApplicationSectionTypeAll])
    {
        return SECTION_TYPE_ALL;          /* "All" → 所有应用 */
    }
    else if([typeString isEqualToString:kApplicationSectionTypeSystem])
    {
        return SECTION_TYPE_SYSTEM;       /* "System" → 系统应用 */
    }
    else if([typeString isEqualToString:kApplicationSectionTypeUser])
    {
        return SECTION_TYPE_USER;         /* "User" → 用户应用 */
    }
    else if([typeString isEqualToString:kApplicationSectionTypeHidden])
    {
        return SECTION_TYPE_HIDDEN;       /* "Hidden" → 隐藏应用 */
    }
    else if([typeString isEqualToString:kApplicationSectionTypeVisible])
    {
        return SECTION_TYPE_VISIBLE;      /* "Visible" → 可见应用 */
    }

    return SECTION_TYPE_CUSTOM;           /* 无法识别则返回自定义类型 */
}

/**
 * 将枚举值转换为字符串
 *
 * @param sectionType 分区类型枚举
 * @return 对应的字符串表示
 */
+ (NSString*)stringFromSectionType:(ApplicationSectionType)sectionType
{
    switch(sectionType)
    {
        case SECTION_TYPE_ALL:
            return kApplicationSectionTypeAll;       /* 所有应用 */
        case SECTION_TYPE_SYSTEM:
            return kApplicationSectionTypeSystem;    /* 系统应用 */
        case SECTION_TYPE_USER:
            return kApplicationSectionTypeUser;      /* 用户应用 */
        case SECTION_TYPE_HIDDEN:
            return kApplicationSectionTypeHidden;    /* 隐藏应用 */
        case SECTION_TYPE_VISIBLE:
            return kApplicationSectionTypeVisible;   /* 可见应用 */
        default:
            return kApplicationSectionTypeCustom;    /* 自定义 */
    }
}

/**
 * 获取非自定义分区的本地化标题
 *
 * @param sectionType 分区类型
 * @return 本地化标题字符串
 */
+ (NSString*)sectionTitleForNonCustomSectionType:(ApplicationSectionType)sectionType
{
    switch(sectionType)
    {
        case SECTION_TYPE_ALL:
        case SECTION_TYPE_VISIBLE:
            return @"应用";
        case SECTION_TYPE_SYSTEM:
            return @"系统应用";
        case SECTION_TYPE_USER:
            return @"用户应用";
        case SECTION_TYPE_HIDDEN:
            return @"隐藏应用";
        default:
            return nil;                             /* 自定义类型返回 nil */
    }
}

/**
 * 从字典创建分区对象（工厂方法）
 * 如果字典中指定了 customClass，则使用自定义子类创建
 *
 * @param sectionDictionary 分区配置字典
 * @return 创建好的分区对象
 */
+ (__kindof ATLApplicationSection*)applicationSectionWithDictionary:(NSDictionary*)sectionDictionary
{
    NSString* customClassString = sectionDictionary[@"customClass"];
    if(customClassString)
    {
        /* 使用自定义类创建实例 */
        Class customClass = NSClassFromString(customClassString);
        return [[customClass alloc] _initWithDictionary:sectionDictionary];
    }
    else
    {
        /* 使用默认的 ATLApplicationSection 类 */
        return [[ATLApplicationSection alloc] _initWithDictionary:sectionDictionary];
    }
}

/**
 * 内部初始化方法（从字典解析配置）
 *
 * @param sectionDictionary 分区配置字典
 * @return 初始化完成的分区对象，失败返回 nil
 */
- (instancetype)_initWithDictionary:(NSDictionary*)sectionDictionary
{
    NSString* sectionTypeString = sectionDictionary[@"sectionType"];
    if(!sectionTypeString) return nil;  /* 缺少类型字段则返回 nil */

    ApplicationSectionType sectionType = [[self class] sectionTypeFromString:sectionTypeString];

    if(sectionType == SECTION_TYPE_CUSTOM)
    {
        /* 自定义类型：需要 predicate 和 sectionName */
        NSString* predicateString = sectionDictionary[@"sectionPredicate"];
        NSPredicate* predicate = [NSPredicate predicateWithFormat:predicateString];
        NSString* sectionName = sectionDictionary[@"sectionName"];
        self = [self initCustomSectionWithPredicate:predicate sectionName:sectionName];
    }
    else
    {
        /* 非自定义类型：使用内置类型 */
        self = [self initNonCustomSectionWithType:sectionType];
    }

    return self;
}

/**
 * 创建非自定义类型的分区
 * 自动根据类型设置对应的 sectionName
 *
 * @param sectionType 分区类型
 * @return 初始化完成的分区对象
 */
- (instancetype)initNonCustomSectionWithType:(ApplicationSectionType)sectionType
{
    self = [super init];

    /* 设置分区类型（setter 中会自动设置 sectionName） */
    self.sectionType = sectionType;

    return self;
}

/**
 * 创建自定义类型的分区
 *
 * @param predicate   筛选谓词
 * @param sectionName 分区显示名称
 * @return 初始化完成的分区对象
 */
- (instancetype)initCustomSectionWithPredicate:(NSPredicate*)predicate sectionName:(NSString*)sectionName
{
    self = [super init];

    self.sectionType = SECTION_TYPE_CUSTOM;  /* 固定为自定义类型 */
    _customPredicate = predicate;
    _sectionName = sectionName;

    return self;
}

/**
 * 设置分区类型（重写 setter）
 * 当类型改变时自动更新分区名称
 * 自定义类型不自动设置名称
 *
 * @param sectionType 新的分区类型
 */
- (void)setSectionType:(ApplicationSectionType)sectionType
{
    _sectionType = sectionType;
    if(_sectionType != SECTION_TYPE_CUSTOM)
    {
        /* 非自定义类型：自动生成分区标题 */
        _sectionName = [[self class] sectionTitleForNonCustomSectionType:sectionType];
    }
}

/**
 * 获取该分区应用的排序描述器
 * 默认按 atl_fastDisplayName 本地化升序排序
 *
 * @return 排序描述器数组
 */
- (NSArray<NSSortDescriptor*>*)sortDescriptorsForApplications
{
    /* 按应用显示名称的本地化比较进行升序排序 */
    return @[[NSSortDescriptor sortDescriptorWithKey:@"atl_fastDisplayName" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]];
}

/**
 * 从所有应用中筛选并填充当前分区
 * 根据分区类型使用不同的 NSPredicate 筛选条件，
 * 筛选后按排序描述器排序
 *
 * @param allApplications 所有已安装的应用列表
 */
- (void)populateFromAllApplications:(NSArray*)allApplications
{
    /* 根据分区类型确定使用的谓词 */
    NSPredicate* predicateToUse;

    switch(_sectionType)
    {
        case SECTION_TYPE_ALL:
            /* 全部：不使用谓词，包含所有应用 */
            break;

        case SECTION_TYPE_SYSTEM:
            /* 系统应用：筛选 atl_isSystemApplication == YES */
            predicateToUse = [NSPredicate predicateWithFormat:@"atl_isSystemApplication == YES"];
            break;

        case SECTION_TYPE_USER:
            /* 用户应用：筛选 atl_isUserApplication == YES */
            predicateToUse = [NSPredicate predicateWithFormat:@"atl_isUserApplication == YES"];
            break;

        case SECTION_TYPE_HIDDEN:
            /* 隐藏应用：筛选 atl_isHidden == YES */
            predicateToUse = [NSPredicate predicateWithFormat:@"atl_isHidden == YES"];
            break;

        case SECTION_TYPE_VISIBLE:
            /* 可见应用：筛选 atl_isHidden == NO */
            predicateToUse = [NSPredicate predicateWithFormat:@"atl_isHidden == NO"];
            break;

        default:
            /* 自定义类型：使用保存的自定义谓词 */
            predicateToUse = _customPredicate;
            break;
    }

    NSArray* filteredApplications;
    if(predicateToUse)
    {
        /* 使用谓词筛选 */
        filteredApplications = [allApplications filteredArrayUsingPredicate:predicateToUse];
    }
    else
    {
        /* 没有谓词则包含所有 */
        filteredApplications = allApplications;
    }

    /* 排序后保存到 applicationsInSection */
    NSArray* filteredAndSortedApplications = [filteredApplications sortedArrayUsingDescriptors:[self sortDescriptorsForApplications]];
    _applicationsInSection = filteredAndSortedApplications;
}

@end
