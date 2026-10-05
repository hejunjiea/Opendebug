/**
 * ATLApplicationListMultiSelectionController.m - 应用多选列表控制器实现
 */

#import <Foundation/Foundation.h>
#import "ATLApplicationListMultiSelectionController.h"
/* AltList 的 PSSpecifier 扩展 */
#import "PSSpecifier+AltList.h"

@implementation ATLApplicationListMultiSelectionController

/**
 * 加载偏好设置
 * 通过 specifier 的 getter 读取已选中的应用包名数组，
 * 如果没有已选中的应用则使用默认值或空集合
 */
- (void)loadPreferences
{
    PSSpecifier* specifier = [self specifier];
    /* 使用 AltList 扩展的安全 getter 调用 */
    if([specifier atl_hasValidGetter])
    {
        _selectedApplications = [NSMutableSet setWithArray:[specifier atl_performGetter]];
    }

    if(!_selectedApplications)
    {
        /* 没有已选中的应用：尝试使用默认值 */
        NSArray* defaultValue = [specifier propertyForKey:@"default"];
        if(defaultValue && [defaultValue isKindOfClass:[NSArray class]])
        {
            _selectedApplications = [NSMutableSet setWithArray:defaultValue];
        }
        else
        {
            _selectedApplications = [NSMutableSet new];
        }
    }
}

/**
 * 保存偏好设置
 * 通过 specifier 的 setter 保存已选中的应用包名数组
 */
- (void)savePreferences
{
    PSSpecifier* specifier = [self specifier];
    if([specifier atl_hasValidSetter])
    {
        NSArray *existingOrder = nil;
        if([specifier atl_hasValidGetter])
        {
            existingOrder = [specifier atl_performGetter];
        }

        NSMutableArray *orderedResult = [NSMutableArray array];
        NSMutableSet *remaining = [_selectedApplications mutableCopy];

        if(existingOrder && [existingOrder isKindOfClass:[NSArray class]])
        {
            for(NSString *bid in existingOrder)
            {
                if([remaining containsObject:bid])
                {
                    [orderedResult addObject:bid];
                    [remaining removeObject:bid];
                }
            }
        }

        for(NSString *bid in remaining)
        {
            [orderedResult addObject:bid];
        }

        [specifier atl_performSetterWithValue:orderedResult];
    }
}

/**
 * 准备填充分区
 * 读取 specifier 中的自定义开关默认值配置
 */
- (void)prepareForPopulatingSections
{
    [super prepareForPopulatingSections];
    /* 读取开关的默认值（默认为 NO） */
    NSNumber* defaultApplicationValueNum = [[self specifier] propertyForKey:@"defaultApplicationSwitchValue"];
    _defaultApplicationSwitchValue = [defaultApplicationValueNum boolValue];
}

/**
 * 设置应用的启用状态（UISwitch 回调）
 * 当开关值不等于默认值时，将应用加入已选集合；
 * 等于默认值时，从已选集合中移除
 *
 * @param enabledNum 开关当前值（@YES 或 @NO）
 * @param specifier  对应的应用 specifier
 */
- (void)setApplicationEnabled:(NSNumber*)enabledNum specifier:(PSSpecifier*)specifier
{
    NSString* applicationID = [specifier propertyForKey:@"applicationIdentifier"];
    if([enabledNum boolValue] != _defaultApplicationSwitchValue)
    {
        /* 开关值与默认值不同 → 应用被用户选中 */
        [_selectedApplications addObject:applicationID];
    }
    else
    {
        /* 开关值与默认值相同 → 应用未被选中 */
        [_selectedApplications removeObject:applicationID];
    }

    [self savePreferences];
}

/**
 * 读取应用的启用状态
 * 返回的 BOOL 值会根据 _defaultApplicationSwitchValue 反转，
 * 确保 UISwitch 的 ON 状态表示"已选中"的语义
 *
 * @param specifier 对应的应用 specifier
 * @return @YES 或 @NO
 */
- (id)readApplicationEnabled:(PSSpecifier*)specifier
{
    NSString* applicationID = [specifier propertyForKey:@"applicationIdentifier"];
    /* 检查应用是否在已选集合中 */
    BOOL applicationSelected = [_selectedApplications containsObject:applicationID];

    if(applicationSelected)
    {
        /* 已选中：返回与默认值相反的值（使 UISwitch 显示为 ON） */
        return @(!_defaultApplicationSwitchValue);
    }

    /* 未选中：返回默认值（使 UISwitch 显示为 OFF） */
    return @(_defaultApplicationSwitchValue);
}

/**
 * 获取应用单元格的 PSCellType
 * 多选模式下使用 PSSwitchCell（带 UISwitch 开关的单元格）
 *
 * @return PSSwitchCell 类型
 */
- (PSCellType)cellTypeForApplicationCells
{
    return PSSwitchCell;
}

/**
 * 获取应用 specifier 的 getter 选择子
 * 绑定到 readApplicationEnabled: 方法
 *
 * @param applicationProxy 应用代理
 * @return @selector(readApplicationEnabled:)
 */
- (SEL)getterForSpecifierOfApplicationProxy:(LSApplicationProxy*)applicationProxy
{
    return @selector(readApplicationEnabled:);
}

/**
 * 获取应用 specifier 的 setter 选择子
 * 绑定到 setApplicationEnabled:specifier: 方法
 *
 * @param applicationProxy 应用代理
 * @return @selector(setApplicationEnabled:specifier:)
 */
- (SEL)setterForSpecifierOfApplicationProxy:(LSApplicationProxy*)applicationProxy
{
    return @selector(setApplicationEnabled:specifier:);
}

@end
