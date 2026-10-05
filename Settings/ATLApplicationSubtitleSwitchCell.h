/**
 * ATLApplicationSubtitleSwitchCell.h - 带副标题的开关单元格
 *
 * 继承自 PSSwitchTableCell，使用 Subtitle 样式，在开关按钮上方同时显示标题和副标题。
 */

/* 导入基类 PSSwitchTableCell（带 UISwitch 的单元格）和 PSSpecifier */
#import <Preferences/PSSwitchTableCell.h>
#import <Preferences/PSSpecifier.h>

/**
 * ATLApplicationSubtitleSwitchCell 接口
 * 使用 Subtitle 样式，支持和开关并存的标题+副标题显示
 */
@interface ATLApplicationSubtitleSwitchCell : PSSwitchTableCell

@end
