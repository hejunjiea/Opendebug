/**
 * ATLApplicationListSelectionController.h - 应用单选列表控制器
 */

/* 导入基类控制器 */
#import "ATLApplicationListControllerBase.h"

/**
 * ATLApplicationListSelectionController 接口
 * 支持单选并自动保持选中的勾选状态
 */
@interface ATLApplicationListSelectionController : ATLApplicationListControllerBase
{
    /** _selectedApplicationID：当前选中的应用包名 */
    NSString* _selectedApplicationID;
}

@end
