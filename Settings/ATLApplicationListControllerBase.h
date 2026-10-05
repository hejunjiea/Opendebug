/**
 * ATLApplicationListControllerBase.h - 应用列表控制器基类
 *
 * 提供应用列表的加载、展示、搜索、分组、图标异步加载等通用功能。
 */

/* 导入 Preferences 框架基类 */
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
/* 导入应用分区模型 */
#import "ATLApplicationSection.h"

@class LSApplicationProxy;

/**
 * PSListController 的私有方法声明
 * 用于检查 specifier 是否已存在
 */
@interface PSListController()
- (BOOL)containsSpecifier:(PSSpecifier*)specifier;
@end

/**
 * LSApplicationWorkspaceObserverProtocol 协议
 * 监听应用的安装和卸载事件，自动刷新列表
 */
@protocol LSApplicationWorkspaceObserverProtocol <NSObject>
@optional
-(void)applicationsDidInstall:(id)arg1;     /* 应用安装完成回调 */
-(void)applicationsDidUninstall:(id)arg1;   /* 应用卸载完成回调 */
@end

/**
 * ATLApplicationListControllerBase - 应用列表控制器基类
 * 遵循 UISearchResultsUpdating 和 LSApplicationWorkspaceObserverProtocol 协议
 */
@interface ATLApplicationListControllerBase : PSListController <UISearchResultsUpdating, LSApplicationWorkspaceObserverProtocol>
{
    /** _iconLoadQueue：异步加载应用图标的串行队列 */
    dispatch_queue_t _iconLoadQueue;
    /** _allSpecifiers：未筛选前的完整 specifier 列表 */
    NSMutableArray* _allSpecifiers;
    /** _specifiersByLetter：按首字母分组的 specifier 字典（如 A → [...], B → [...]） */
    NSMutableDictionary* _specifiersByLetter;
    /** _applicationSections：应用分区配置数组 */
    NSArray<ATLApplicationSection*>* _applicationSections;
    /** _searchController：搜索控制器 */
    UISearchController* _searchController;
    /** _searchKey：当前搜索关键字 */
    NSString* _searchKey;
    /** _isPopulated：是否已完成数据填充 */
    BOOL _isPopulated;
    /** _isReloadingSpecifiers：是否正在重新加载 specifiers（防止重复刷新） */
    BOOL _isReloadingSpecifiers;
    /** _altListBundle：AltList 库的 bundle，用于本地化字符串 */
    NSBundle* _altListBundle;
    /** _placeholderAppIcon：占位应用图标（加载完成前显示） */
    UIImage* _placeholderAppIcon;
}

/** useSearchBar：是否启用搜索栏 */
@property (nonatomic) BOOL useSearchBar;
/** hideSearchBarWhileScrolling：滚动时是否隐藏搜索栏（iOS 11+） */
@property (nonatomic) BOOL hideSearchBarWhileScrolling;
/** includeIdentifiersInSearch：搜索时是否包含包名 */
@property (nonatomic) BOOL includeIdentifiersInSearch;
/** showIdentifiersAsSubtitle：是否在副标题中显示包名 */
@property (nonatomic) BOOL showIdentifiersAsSubtitle;
/** alphabeticIndexingEnabled：是否启用字母索引（仅单分区时有效） */
@property (nonatomic) BOOL alphabeticIndexingEnabled;
/** hideAlphabeticSectionHeaders：是否隐藏字母分区的组标题 */
@property (nonatomic) BOOL hideAlphabeticSectionHeaders;
/** localizationBundle：自定义本地化 bundle */
@property (nonatomic) NSBundle* localizationBundle;

/**
 * 使用预配置的分区数组初始化
 *
 * @param applicationSections 分区配置数组
 * @return 初始化完成的控制器
 */
- (instancetype)initWithSections:(NSArray<ATLApplicationSection*>*)applicationSections;

/** 设置搜索栏（内部方法） */
- (void)_setUpSearchBar;
/** 从 specifier 的 plist 配置中加载分区设置 */
- (void)_loadSectionsFromSpecifier;
/** 从已安装应用填充所有分区 */
- (void)_populateSections;

/** 加载偏好设置（子类重写） */
- (void)loadPreferences;
/** 保存偏好设置（子类重写） */
- (void)savePreferences;
/** 准备填充分区：读取配置属性（子类可重写） */
- (void)prepareForPopulatingSections;
/** 获取本地化字符串 */
- (NSString*)localizedStringForString:(NSString*)string;
/** 重新加载应用列表 */
- (void)reloadApplications;

/** 是否应隐藏所有应用 specifier（搜索激活时返回 YES） */
- (BOOL)shouldHideApplicationSpecifiers;
/** 是否应隐藏某个应用 specifier（在搜索时按关键字匹配） */
- (BOOL)shouldHideApplicationSpecifier:(PSSpecifier*)specifier;

/** 是否应显示副标题 */
- (BOOL)shouldShowSubtitles;
/** 获取应用的副标题（默认返回包名） */
- (NSString*)subtitleForApplicationWithIdentifier:(NSString*)applicationID;
/** 内部方法：获取 specifier 的副标题 */
- (NSString*)_subtitleForSpecifier:(PSSpecifier*)specifier;

/** 获取应用单元格的 PSCellType */
- (PSCellType)cellTypeForApplicationCells;
/** 根据单元格类型获取自定义 cell 类 */
- (Class)customCellClassForCellType:(PSCellType)cellType;
/** 获取应用 specifier 的详细控制器类 */
- (Class)detailControllerClassForSpecifierOfApplicationProxy:(LSApplicationProxy*)applicationProxy;
/** 获取应用 specifier 的 getter 选择子 */
- (SEL)getterForSpecifierOfApplicationProxy:(LSApplicationProxy*)applicationProxy;
/** 获取应用 specifier 的 setter 选择子 */
- (SEL)setterForSpecifierOfApplicationProxy:(LSApplicationProxy*)applicationProxy;

/** 为应用代理创建对应的 PSSpecifier */
- (PSSpecifier*)createSpecifierForApplicationProxy:(LSApplicationProxy*)applicationProxy;
/** 为应用分区创建 specifier 列表 */
- (NSArray*)createSpecifiersForApplicationSection:(ATLApplicationSection*)section;
/** 为应用分区创建组 specifier */
- (PSSpecifier*)createGroupSpecifierForApplicationSection:(ATLApplicationSection*)section;

/** 获取按首字母分组的 specifier 列表 */
- (NSMutableArray*)specifiersGroupedByLetters;
/** 填充 specifiersByLetter 字典 */
- (void)populateSpecifiersByLetter;

/** 根据包名查找对应的 PSSpecifier */
- (PSSpecifier*)specifierForApplicationWithIdentifier:(NSString*)applicationID;
/** 根据包名查找对应的 NSIndexPath */
- (NSIndexPath*)indexPathForApplicationWithIdentifier:(NSString*)applicationID;

@end
