/**
 * ATLApplicationSelectionCell.h - 应用选择单元格
 *
 * 会自动将包名转换为对应的本地化应用名称显示。
 */

/* 导入 Preferences 框架的 PSTableCell 基类 */
#import <Preferences/PSTableCell.h>

/**
 * ATLApplicationSelectionCell 接口
 * 重写 setValue: 方法实现包名到显示名的自动转换
 */
@interface ATLApplicationSelectionCell : PSTableCell

@end
