/**
 * ATLApplicationListSubcontroller.m - 应用列表子控制器实现
 *
 * 在设置 specifier 时自动提取应用包名和标题，并在返回上级页面时刷新父页面预览文本。
 */

#import <Foundation/Foundation.h>
#import "ATLApplicationListSubcontroller.h"
/* 导入 PSSpecifier 用于设置项构建 */
#import <Preferences/PSSpecifier.h>

@implementation ATLApplicationListSubcontroller

/**
 * 设置 specifier 时提取应用信息
 * 从 specifier 中获取应用包名和标题并保存
 *
 * @param specifier 包含应用信息的 specifier
 */
- (void)setSpecifier:(PSSpecifier*)specifier
{
    [super setSpecifier:specifier];
    self.applicationID = [specifier propertyForKey:@"applicationIdentifier"];
    [self setTitle:specifier.name];
}

/**
 * 从 plist 文件加载 specifiers 列表
 * 重写以确认标题不为空
 *
 * @param plistName plist 文件名
 * @param target    target 对象
 * @return specifiers 的可变数组
 */
- (NSMutableArray*)loadSpecifiersFromPlistName:(NSString*)plistName target:(id)target
{
    NSMutableArray* specifiers = [super loadSpecifiersFromPlistName:plistName target:target];
    /* 确保标题不为空：如果 plist 加载后标题为空，从 specifier 重新获取 */
    if([self.title isEqualToString:@""] || !self.title)
    {
        [self setTitle:[self specifier].name];
    }
    return specifiers;
}

/**
 * 视图即将消失时
 * 刷新父页面的 specifier 以更新预览文本
 *
 * @param animated 是否动画过渡
 */
- (void)viewWillDisappear:(BOOL)animated
{
    /* 自动刷新上级页面的预览字符串 */
    PSListController* topVC = (PSListController*)self.navigationController.topViewController;
    if([topVC respondsToSelector:@selector(reloadSpecifier:)])
    {
        [topVC reloadSpecifier:[self specifier]];
    }
}

@end
