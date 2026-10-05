/**
 * ATLApplicationListSubcontroller.h - 应用列表子控制器
 *
 * 当用户在父列表中点击某个应用时跳转到该子控制器，显示该应用的自定义设置选项。
 */

/* 导入 Preferences 框架的 PSListController 基类 */
#import <Preferences/PSListController.h>

/**
 * ATLApplicationListSubcontroller 接口
 * 用于显示单个应用的详细设置页面
 */
@interface ATLApplicationListSubcontroller : PSListController

/** applicationID：当前正在编辑的应用包名 */
@property (nonatomic) NSString* applicationID;

@end
