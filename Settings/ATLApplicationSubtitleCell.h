/**
 * ATLApplicationSubtitleCell.h - 带副标题和自定义值的应用单元格
 *
 * 在原有标题和副标题的基础上增加右侧的自定义值标签，支持 RTL 布局。
 */

/* 导入基类 PSTableCell 和 PSSpecifier */
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>

/**
 * ATLApplicationSubtitleCell 接口
 * 包含一个右侧的自定义值标签，用于显示附加值信息
 */
@interface ATLApplicationSubtitleCell : PSTableCell
{
    /** _customValueLabel：右侧自定义值标签，用于显示附加文本 */
    UILabel* _customValueLabel;
}

@end
