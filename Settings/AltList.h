/**
 * AltList.h - AltList 库统一头文件
 *
 * 集中导入 AltList 库的所有公开组件头文件，供其他代码一次性引用。
 */

/* 应用列表基类控制器：管理应用列表的加载、展示、搜索和分组 */
#import <AltList/ATLApplicationListControllerBase.h>
/* 应用列表多选控制器：支持多个应用的同时选择/取消选择 */
#import <AltList/ATLApplicationListMultiSelectionController.h>
/* 应用列表单选控制器：支持单个应用的选择（带勾选标记） */
#import <AltList/ATLApplicationListSelectionController.h>
/* 应用列表子控制器容器：允许点击应用跳转到子设置页 */
#import <AltList/ATLApplicationListSubcontroller.h>
/* 应用列表子控制器管理控制器：为每个应用关联一个子控制器类 */
#import <AltList/ATLApplicationListSubcontrollerController.h>
/* 应用分区模型：定义如何对应用列表进行分区（系统/用户/隐藏等） */
#import <AltList/ATLApplicationSection.h>
/* 应用选择单元格：显示应用名，支持选中状态 */
#import <AltList/ATLApplicationSelectionCell.h>
/* 应用副标题单元格：带副标题的自定义单元格 */
#import <AltList/ATLApplicationSubtitleCell.h>
/* 应用副标题开关单元格：带副标题和开关的单元格 */
#import <AltList/ATLApplicationSubtitleSwitchCell.h>
