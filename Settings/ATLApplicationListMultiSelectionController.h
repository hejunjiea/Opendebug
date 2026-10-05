/**
 * ATLApplicationListMultiSelectionController.h - 应用多选列表控制器
 */

/* 导入基类控制器 */
#import "ATLApplicationListControllerBase.h"

/**
 * ATLApplicationListMultiSelectionController 接口
 * 支持多选操作和自定义开关默认值
 */
@interface ATLApplicationListMultiSelectionController : ATLApplicationListControllerBase
{
    /** _selectedApplications：已选中的应用包名集合 */
    NSMutableSet* _selectedApplications;
    /** _defaultApplicationSwitchValue：应用开关的默认值（ON/OFF） */
    BOOL _defaultApplicationSwitchValue;
}

/**
 * 设置某个应用的启用状态
 * 子类可重写以自定义保存逻辑
 *
 * @param enabledNum @YES（启用）或 @NO（禁用）
 * @param specifier 对应的应用 specifier
 */
- (void)setApplicationEnabled:(NSNumber*)enabledNum specifier:(PSSpecifier*)specifier;

/**
 * 读取某个应用的启用状态
 *
 * @param specifier 对应的应用 specifier
 * @return @YES 或 @NO
 */
- (id)readApplicationEnabled:(PSSpecifier*)specifier;

@end
