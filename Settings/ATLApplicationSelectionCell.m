/**
 * ATLApplicationSelectionCell.m - 应用选择单元格实现
 *
 * 在 setValue: 时检测传入的是否为应用包名字符串，若是则自动转换为对应的本地化应用名称。
 */

#import <Foundation/Foundation.h>
#import "ATLApplicationSelectionCell.h"
/* 私有 API 声明：LSApplicationProxy 等 */
#import "CoreServices.h"
/* AltList 扩展：atl_nameToDisplay 等方法 */
#import "LSApplicationProxy+AltList.h"

/**
 * PSTableCell 的私有接口声明
 * 暴露 setValue: 方法供重写
 */
@interface PSTableCell()
- (void)setValue:(id)value;
@end

@implementation ATLApplicationSelectionCell

/**
 * 重写 setValue: 方法
 * 当 value 是 NSString 类型时，尝试将其作为应用包名，
 * 获取对应的本地化应用名称后调用父类的 setValue:。
 * 如果不是字符串或转换失败，则直接调用父类实现。
 *
 * @param value 要设置的值（可能是包名字符串或其他类型）
 */
- (void)setValue:(id)value
{
    if([value isKindOfClass:[NSString class]])
    {
        NSString* strValue = value;
        LSApplicationProxy* appProxy = [LSApplicationProxy applicationProxyForIdentifier:strValue];
        if(appProxy)
        {
            /* 将包名转换为本地化应用名称后传递给父类 */
            [super setValue:[appProxy atl_nameToDisplay]];
            return;
        }
    }

    /* 非字符串类型或转换失败时直接调用父类实现 */
    [super setValue:value];
}

@end
