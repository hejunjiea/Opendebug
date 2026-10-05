#import "ATLApplicationListMultiSelectionController.h"

/**
 * OpenDebug 的应用多选列表控制器（继承 AltList 库），
 * 覆写 savePreferences 把选择结果写进 com.tanyou.opendebug.settings/debugInjectedApps。
 */
@interface TANOpenDebugAltListController : ATLApplicationListMultiSelectionController
@end
