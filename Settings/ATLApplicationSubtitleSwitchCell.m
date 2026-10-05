/**
 * ATLApplicationSubtitleSwitchCell.m - 副标题开关单元格实现
 *
 * 使用 Subtitle 样式创建开关单元格，在刷新内容时从控制器的 _subtitleForSpecifier: 方法获取副标题文本。
 */

#import <Foundation/Foundation.h>
#import "ATLApplicationSubtitleSwitchCell.h"
/* 导入基类控制器，用于获取副标题 */
#import "ATLApplicationListControllerBase.h"

@implementation ATLApplicationSubtitleSwitchCell

/**
 * 自定义初始化方法
 * 强制使用 UITableViewCellStyleSubtitle 样式
 *
 * @param style            单元格样式（会被 Subtitle 覆盖）
 * @param reuseIdentifier  复用标识符
 * @param specifier        设置项描述器
 * @return 初始化完成的单元格
 */
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString*)reuseIdentifier specifier:(PSSpecifier*)specifier
{
    /* 强制使用 Subtitle 样式，让标题和副标题同时显示 */
    return [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];
}

/**
 * 刷新单元格内容
 * 通过 specifier 的 target 获取副标题文本并设置到 detailTextLabel
 *
 * @param specifier 当前设置项描述器
 */
- (void)refreshCellContentsWithSpecifier:(PSSpecifier*)specifier
{
    [super refreshCellContentsWithSpecifier:specifier];
    id target = specifier.target;
    /* 如果 target 实现了 _subtitleForSpecifier: 方法，获取副标题文本 */
    if([target respondsToSelector:@selector(_subtitleForSpecifier:)])
    {
        self.detailTextLabel.text = [(ATLApplicationListControllerBase*)target _subtitleForSpecifier:specifier];
    }
}

@end
