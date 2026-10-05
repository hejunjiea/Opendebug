/**
 * ATLApplicationListSelectionController.m - 应用单选列表控制器实现
 */

#import <Foundation/Foundation.h>
#import "ATLApplicationListSelectionController.h"
/* AltList 的 PSSpecifier 扩展 */
#import "PSSpecifier+AltList.h"

/**
 * PSTableCell 的私有接口声明
 * 暴露 setChecked: 方法用于设置勾选状态
 */
@interface PSTableCell()
- (void)setChecked:(BOOL)checked;
@end

@implementation ATLApplicationListSelectionController

/**
 * 加载偏好设置
 * 通过 specifier 的 getter 读取已选中的应用包名，
 * 如果没有已选中的应用则使用默认值
 */
- (void)loadPreferences
{
    PSSpecifier* specifier = [self specifier];
    /* 使用 AltList 扩展的安全 getter 调用 */
    if([specifier atl_hasValidGetter])
    {
        _selectedApplicationID = [specifier atl_performGetter];
    }
    /* 如果没有已选中的应用，使用默认值 */
    if(!_selectedApplicationID)
    {
        NSString* defaultValue = [specifier propertyForKey:@"default"];
        if(defaultValue && [defaultValue isKindOfClass:[NSString class]])
        {
            _selectedApplicationID = defaultValue;
        }
    }
}

/**
 * 保存偏好设置
 * 通过 specifier 的 setter 保存选中的应用包名
 */
- (void)savePreferences
{
    PSSpecifier* specifier = [self specifier];
    /* 使用 AltList 扩展的安全 setter 调用 */
    if([specifier atl_hasValidSetter])
    {
        [specifier atl_performSetterWithValue:_selectedApplicationID];
    }
}

/**
 * 配置单元格的显示
 * 根据是否是已选中的应用设置勾选标记
 *
 * @param tableView 表格视图
 * @param indexPath 索引路径
 * @return 配置好的单元格
 */
- (PSTableCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath
{
    PSTableCell* tableCell = (PSTableCell*)[super tableView:tableView cellForRowAtIndexPath:indexPath];

    PSSpecifier* specifier = [tableCell specifier];
    NSString* applicationID = [specifier propertyForKey:@"applicationIdentifier"];

    /* 如果是已选中的应用，显示勾选标记 */
    [tableCell setChecked:[_selectedApplicationID isEqualToString:applicationID]];

    return tableCell;
}

/**
 * 点击行的回调
 * 取消之前选中应用的勾选，标记新选中的应用，并保存
 *
 * @param tableView 表格视图
 * @param indexPath 点击的行索引
 */
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
    if(_selectedApplicationID)
    {
        /* 取消之前选中的应用的勾选（如果它在可见区域） */
        NSIndexPath* previousIndexPath = [self indexPathForApplicationWithIdentifier:_selectedApplicationID];
        if([[tableView indexPathsForVisibleRows] containsObject:previousIndexPath])
        {
            [tableView cellForRowAtIndexPath:previousIndexPath].accessoryType = UITableViewCellAccessoryNone;
        }
    }

    /* 获取新选中的应用的 specifier */
    PSSpecifier* specifierOfCell = [self specifierAtIndex:[self indexForIndexPath:indexPath]];
    _selectedApplicationID = [specifierOfCell propertyForKey:@"applicationIdentifier"];

    /* 在新选中的行上显示勾选标记 */
    [tableView cellForRowAtIndexPath:indexPath].accessoryType = UITableViewCellAccessoryCheckmark;

    [self savePreferences];
}

/**
 * 视图即将消失时
 * 通知父页面刷新对应 specifier 的显示（如预览文本）
 *
 * @param animated 是否动画过渡
 */
- (void)viewWillDisappear:(BOOL)animated
{
    /* 获取导航栈顶部的控制器（返回的目标页面） */
    PSListController* topVC = (PSListController*)self.navigationController.topViewController;
    /* 如果支持 reloadSpecifier:，刷新当前 specifier 以更新预览值 */
    if([topVC respondsToSelector:@selector(reloadSpecifier:)])
    {
        [topVC reloadSpecifier:[self specifier]];
    }
}

@end
