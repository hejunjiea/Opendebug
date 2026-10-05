/**
 * ATLApplicationListSubcontrollerController.h - 子控制器管理控制器
 *
 * 为列表中的每个应用关联一个子控制器类，点击应用时跳转到对应的子控制器页面。
 */

/* 导入基类控制器 */
#import "ATLApplicationListControllerBase.h"

/**
 * ATLApplicationListSubcontrollerController 接口
 * 为每个应用关联一个子控制器，并提供预览字符串
 */
@interface ATLApplicationListSubcontrollerController : ATLApplicationListControllerBase

/** subcontrollerClass：点击应用时跳转的目标子控制器类 */
@property (nonatomic) Class subcontrollerClass;

/**
 * 获取应用的预览字符串（显示在列表右侧）
 * 子类重写以提供自定义预览文本
 *
 * @param applicationID 应用包名
 * @return 预览字符串
 */
- (NSString*)previewStringForApplicationWithIdentifier:(NSString*)applicationID;

@end
