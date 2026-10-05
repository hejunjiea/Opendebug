/**
 * ATLApplicationListSubcontrollerController.m - 子控制器管理控制器实现
 *
 * 从 specifier 中读取 subcontrollerClass 配置，为每个应用创建 PSLinkListCell 单元格。
 */

#import <Foundation/Foundation.h>
#import "ATLApplicationListSubcontrollerController.h"
/* 私有 API 声明 */
#import "CoreServices.h"
/* AltList 扩展 */
#import "LSApplicationProxy+AltList.h"

@implementation ATLApplicationListSubcontrollerController

/**
 * 获取应用的预览字符串（默认返回 nil）
 * 子类应重写此方法以提供实际的预览内容
 *
 * @param applicationID 应用包名
 * @return nil（默认无预览）
 */
- (NSString*)previewStringForApplicationWithIdentifier:(NSString*)applicationID
{
    return nil;  /* 子类重写以提供预览 */
}

/**
 * 内部方法：获取 specifier 的预览字符串
 *
 * @param specifier 设置项描述器
 * @return 预览字符串
 */
- (NSString*)_previewStringForSpecifier:(PSSpecifier*)specifier
{
    NSString* previewString = [self previewStringForApplicationWithIdentifier:[specifier propertyForKey:@"applicationIdentifier"]];
    return previewString;
}

/**
 * 准备填充分区
 * 读取 specifier 中配置的子控制器类名
 */
- (void)prepareForPopulatingSections
{
    [super prepareForPopulatingSections];
    /* 从 specifier 属性读取子控制器类名字符串 */
    NSString* subcontrollerClassString = [[self specifier] propertyForKey:@"subcontrollerClass"];
    if(subcontrollerClassString)
    {
        /* 通过类名获取 Class 对象 */
        self.subcontrollerClass = NSClassFromString(subcontrollerClassString);
    }
}

/**
 * 获取应用 specifier 的 getter 选择子
 * 绑定到 _previewStringForSpecifier: 方法以显示预览文本
 *
 * @param applicationProxy 应用代理
 * @return @selector(_previewStringForSpecifier:)
 */
- (SEL)getterForSpecifierOfApplicationProxy:(LSApplicationProxy*)applicationProxy
{
    return @selector(_previewStringForSpecifier:);
}

/**
 * 获取应用单元格的 PSCellType
 * 使用 PSLinkListCell（带箭头指示器，点击可跳转的列表项）
 *
 * @return PSLinkListCell 类型
 */
- (PSCellType)cellTypeForApplicationCells
{
    return PSLinkListCell;
}

/**
 * 获取应用 specifier 的详细控制器类
 * 返回配置的子控制器类，点击该行时跳转到子控制器
 *
 * @param applicationProxy 应用代理
 * @return 配置的子控制器类
 */
- (Class)detailControllerClassForSpecifierOfApplicationProxy:(LSApplicationProxy*)applicationProxy
{
    return self.subcontrollerClass;
}

@end
