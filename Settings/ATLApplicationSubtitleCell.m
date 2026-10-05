/**
 * ATLApplicationSubtitleCell.m - 带副标题和自定义值的单元格实现
 *
 * 在 subtitle 样式的基础上增加右侧自定义值标签，布局时自动适配 RTL（从右到左排版）环境。
 */

#import <Foundation/Foundation.h>
#import "ATLApplicationSubtitleCell.h"
/* 导入基类控制器，用于获取副标题 */
#import "ATLApplicationListControllerBase.h"

@implementation ATLApplicationSubtitleCell

/**
 * 自定义初始化方法
 * 使用 UITableViewCellStyleSubtitle 样式创建单元格，
 * 并添加右侧的自定义值标签
 *
 * @param style            单元格样式
 * @param reuseIdentifier  复用标识符
 * @param specifier        设置项描述器
 * @return 初始化完成的单元格
 */
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString*)reuseIdentifier specifier:(PSSpecifier*)specifier
{
    /* 强制使用 Subtitle 样式（主标题 + 副标题） */
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];

    if(self)
    {
        _customValueLabel = [UILabel new];
        /* 使用系统 body 字体大小 */
        _customValueLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];

        /* 根据 RTL 布局设置文本对齐方式 */
        BOOL isRTL = [UIApplication sharedApplication].userInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
        if(isRTL)
        {
            /* RTL 模式下左对齐 */
            _customValueLabel.textAlignment = NSTextAlignmentLeft;
        }
        else
        {
            /* LTR 模式下右对齐 */
            _customValueLabel.textAlignment = NSTextAlignmentRight;
        }

        /* 单行显示 */
        _customValueLabel.numberOfLines = 1;

        /* 根据 iOS 版本设置文本颜色 */
        if(@available(iOS 13, *))
        {
            /* iOS 13+ 使用系统 secondaryLabelColor 自适应 Dark Mode */
            _customValueLabel.textColor = [UIColor secondaryLabelColor];
        }
        else
        {
            /* iOS 12 及以下使用固定的灰色（系统 secondaryLabel 的近似色） */
            _customValueLabel.textColor = [UIColor colorWithRed:0.5568 green:0.5568 blue:0.5764 alpha:1.0];
        }

        [self.contentView addSubview:_customValueLabel];
        /* 默认隐藏，有值时再显示 */
        _customValueLabel.hidden = YES;
    }

    return self;
}

/**
 * 布局子视图
 * 在父类布局完成后，计算自定义值标签的位置：
 * - LTR：放置在标题和副标题右侧，延伸到单元格右边距
 * - RTL：放置在标题和副标题左侧，延伸到单元格左边距
 */
- (void)layoutSubviews
{
    [super layoutSubviews];

    /* 判断当前是否是 RTL（从右到左）布局 */
    BOOL isRTL = [UIApplication sharedApplication].userInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;

    if(isRTL)
    {
        /* RTL 布局：标签靠左放置 */
        /* 获取副标题的最左位置 */
        CGFloat detailTextLeftPos = self.detailTextLabel.frame.origin.x;
        /* 获取标题的最左位置 */
        CGFloat textLeftPos = self.textLabel.frame.origin.x;
        /* 取更靠左的位置 */
        CGFloat width = 0;
        if(detailTextLeftPos < textLeftPos)
        {
            width = detailTextLeftPos;
        }
        else
        {
            width = textLeftPos;
        }

        /* 自定义值标签从左侧延伸到标题/副标题的左侧 */
        _customValueLabel.frame = CGRectMake(0, 0, width, self.contentView.bounds.size.height);
    }
    else
    {
        /* LTR 布局：标签靠右放置 */
        /* 获取副标题的最右位置 */
        CGFloat detailTextRightPos = self.detailTextLabel.frame.origin.x + self.detailTextLabel.bounds.size.width;
        /* 获取标题的最右位置 */
        CGFloat textRightPos = self.textLabel.frame.origin.x + self.textLabel.bounds.size.width;
        /* 取更靠右的位置作为起始 x */
        CGFloat x = 0;
        if(detailTextRightPos > textRightPos)
        {
            x = detailTextRightPos;
        }
        else
        {
            x = textRightPos;
        }
        /* 宽度为内容视图剩余空间 */
        CGFloat width = self.contentView.bounds.size.width - x;
        _customValueLabel.frame = CGRectMake(x, 0, width, self.contentView.bounds.size.height);
    }
}

/**
 * 刷新单元格内容
 * 通过 specifier 的 target 获取副标题文本
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

/**
 * 设置自定义值
 * 当 value 为非空字符串时显示在右侧标签中，否则隐藏标签
 *
 * @param value 要显示的自定义值
 */
- (void)setValue:(id)value
{
    /* 仅处理 NSString 类型的值 */
    if([value isKindOfClass:[NSString class]])
    {
        NSString* valueStr = value;
        if(![valueStr isEqualToString:@""])
        {
            /* 非空字符串：显示自定义值标签 */
            _customValueLabel.hidden = NO;
            _customValueLabel.text = valueStr;
            return;
        }
    }

    /* 空值或非字符串：隐藏自定义值标签 */
    _customValueLabel.hidden = YES;
}

/**
 * 准备重用
 * 清除自定义值文本，避免复用时显示旧数据
 */
- (void)prepareForReuse
{
    [super prepareForReuse];
    _customValueLabel.text = nil;
}

@end
