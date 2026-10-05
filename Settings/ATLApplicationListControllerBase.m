/**
 * ATLApplicationListControllerBase.m - 应用列表控制器基类实现
 */

#import <Foundation/Foundation.h>
#import "ATLApplicationListControllerBase.h"
/* 私有 API 声明 */
#import "CoreServices.h"
/* AltList 扩展方法 */
#import "LSApplicationProxy+AltList.h"
/* 自定义单元格类型 */
#import "ATLApplicationSubtitleSwitchCell.h"
#import "ATLApplicationSubtitleCell.h"

/**
 * UIImage 的私有方法声明
 * 用于从系统获取应用图标
 */
@interface UIImage (Private)
/**
 * _applicationIconImageForBundleIdentifier:format:scale:
 * 根据包名获取应用的图标
 *
 * @param bundleIdentifier 应用包名
 * @param format 图标格式（0 = 小图标, 2 = 中等, 5 = 大图标, 10 = 主屏幕大小）
 * @param scale 屏幕缩放比例
 * @return 应用图标 UIImage
 */
+ (instancetype)_applicationIconImageForBundleIdentifier:(NSString*)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

@implementation ATLApplicationListControllerBase

/**
 * 初始化方法
 * 设置占位图标、创建图标加载队列、注册应用安装/卸载监听
 *
 * @return 初始化完成的控制器
 */
- (instancetype)init
{
    self = [super init];
    /* 设置占位图标：使用 WebSheet（Safari 无页面状态）的图标作为默认占位 */
    _placeholderAppIcon = [UIImage _applicationIconImageForBundleIdentifier:@"com.apple.WebSheet" format:0 scale:[UIScreen mainScreen].scale];
    /* 创建串行队列，顺序加载应用图标，避免 UI 卡顿 */
    _iconLoadQueue = dispatch_queue_create("com.opa334.AltList.IconLoadQueue", DISPATCH_QUEUE_SERIAL);

    /* 获取 AltList 框架的 bundle，用于本地化 */
    _altListBundle = [NSBundle bundleForClass:[ATLApplicationListControllerBase class]];
    /* 注册为 LSApplicationWorkspace 的观察者，监听应用安装/卸载 */
    [[LSApplicationWorkspace defaultWorkspace] addObserver:self];
    return self;
}

/**
 * 使用预配置的分区数组初始化
 *
 * @param applicationSections 分区配置数组
 * @return 初始化完成的控制器
 */
- (instancetype)initWithSections:(NSArray<ATLApplicationSection*>*)applicationSections
{
    self = [self init];
    _applicationSections = applicationSections;
    return self;
}

/**
 * 析构方法
 * 移除 LSApplicationWorkspace 的观察者
 */
- (void)dealloc
{
    [[LSApplicationWorkspace defaultWorkspace] removeObserver:self];
}

/**
 * 视图加载完成后的处理
 * 从 specifier 读取搜索栏相关配置并设置搜索栏
 */
- (void)viewDidLoad
{
    [super viewDidLoad];

    PSSpecifier* specifier = [self specifier];

    NSNumber* useSearchBarNum = [specifier propertyForKey:@"useSearchBar"];
    if(useSearchBarNum)
    {
        self.useSearchBar = [useSearchBarNum boolValue];
    }
    if(self.useSearchBar)
    {
        /* 读取滚动时是否隐藏搜索栏（仅 iOS 11+） */
        NSNumber* hideSearchBarWhileScrollingNum = [specifier propertyForKey:@"hideSearchBarWhileScrolling"];
        if(hideSearchBarWhileScrollingNum)
        {
            self.hideSearchBarWhileScrolling = [hideSearchBarWhileScrollingNum boolValue];
        }

        NSNumber* includeIdentifiersInSearchNum = [specifier propertyForKey:@"includeIdentifiersInSearch"];
        if(includeIdentifiersInSearchNum)
        {
            self.includeIdentifiersInSearch = [includeIdentifiersInSearchNum boolValue];
        }
    }

    /* 设置搜索栏 */
    [self _setUpSearchBar];
}

#pragma mark - UITableViewDelegate

/**
 * 设置分区头部高度
 * 如果启用了 hidAlphabeticSectionHeaders，将字母分区头部高度压缩到几乎为零
 *
 * @param tableView 表格视图
 * @param section   分区索引
 * @return 头部高度
 */
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if(self.hideAlphabeticSectionHeaders)
    {
        /* 检查是否为字母分区 */
        PSSpecifier* specifier = [self specifierAtIndex:[self indexOfGroup:section]];
        if([[specifier propertyForKey:@"isLetterSection"] boolValue])
        {
            return 0.00000000001;  /* 极小值，实际不可见但保留布局 */
        }
    }

    return [super tableView:tableView heightForHeaderInSection:section];
}

/**
 * 设置分区头部标题
 * 如果启用了 hidAlphabeticSectionHeaders，字母分区返回 nil
 *
 * @param tableView 表格视图
 * @param section   分区索引
 * @return 头部标题
 */
- (NSString*)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if(self.hideAlphabeticSectionHeaders)
    {
        PSSpecifier* specifier = [self specifierAtIndex:[self indexOfGroup:section]];
        if([[specifier propertyForKey:@"isLetterSection"] boolValue])
        {
            return nil;  /* 隐藏字母分区标题 */
        }
    }

    return [super tableView:tableView titleForHeaderInSection:section];
}

/**
 * 设置分区尾部高度
 * 字母索引分组时，压缩分区尾部到几乎为零
 *
 * @param tableView 表格视图
 * @param section   分区索引
 * @return 尾部高度
 */
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    if(self.alphabeticIndexingEnabled)
    {
        PSSpecifier* specifier = [self specifierAtIndex:[self indexOfGroup:section]];
        if([[specifier propertyForKey:@"isLetterSection"] boolValue] || [[specifier propertyForKey:@"isFirstLetterSection"] boolValue])
        {
            return 0.00000000001;
        }
    }

    return [super tableView:tableView heightForFooterInSection:section];
}

/**
 * 设置分区尾部标题
 *
 * @param tableView 表格视图
 * @param section   分区索引
 * @return 尾部标题
 */
- (NSString*)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if(self.hideAlphabeticSectionHeaders)
    {
        PSSpecifier* specifier = [self specifierAtIndex:[self indexOfGroup:section]];
        if([[specifier propertyForKey:@"isLetterSection"] boolValue])
        {
            return nil;  /* 隐藏字母分区尾部 */
        }
    }

    return [super tableView:tableView titleForFooterInSection:section];
}

/**
 * 返回右侧字母索引条的内容
 * 仅当 alphabeticIndexingEnabled 启用时返回字母列表
 *
 * @param tableView 表格视图
 * @return 索引标题数组
 */
- (NSArray<NSString*>*)sectionIndexTitlesForTableView:(UITableView *)tableView
{
    if(self.alphabeticIndexingEnabled)
    {
        NSMutableArray* firstLetters = [_specifiersByLetter allKeys].mutableCopy;
        [firstLetters sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

        /* 将 "#" 部分（非字母开头的应用）移到最后 */
        if([firstLetters.firstObject isEqualToString:@"#"])
        {
            [firstLetters removeObjectAtIndex:0];
            [firstLetters addObject:@"#"];
        }

        return firstLetters;
    }
    return nil;
}

#pragma mark - LSApplicationWorkspaceObserverProtocol

/**
 * 应用安装完成回调
 * 在主队列中重新加载应用列表
 *
 * @param arg1 安装信息（未使用）
 */
- (void)applicationsDidInstall:(id)arg1
{
    dispatch_async(dispatch_get_main_queue(), ^(void){
        [self reloadApplications];
    });
}

/**
 * 应用卸载完成回调
 * 在主队列中重新加载应用列表
 *
 * @param arg1 卸载信息（未使用）
 */
- (void)applicationsDidUninstall:(id)arg1
{
    dispatch_async(dispatch_get_main_queue(), ^(void){
        [self reloadApplications];
    });
}

#pragma mark - 配置方法

/**
 * 设置是否启用字母索引
 * 仅当只有一个分区时才允许启用字母索引
 * 多分区情况下禁用（因为字母分区的标题和分组会冲突）
 *
 * @param enabled 是否启用
 */
- (void)setAlphabeticIndexingEnabled:(BOOL)enabled
{
    if(_applicationSections.count == 1)
    {
        _alphabeticIndexingEnabled = enabled;
        return;
    }

    _alphabeticIndexingEnabled = NO;  /* 多分区强制禁用 */
}

/**
 * 创建并配置搜索栏
 * 支持 iOS 11+ 的原生导航栏集成，以及旧版本的表格头部视图方式
 */
- (void)_setUpSearchBar
{
    if(self.useSearchBar)
    {
        _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
        _searchController.searchResultsUpdater = self;
        if (@available(iOS 9.1, *)) _searchController.obscuresBackgroundDuringPresentation = NO;  /* 不模糊背景 */
        if (@available(iOS 11.0, *))
        {
            /* iOS 11+：控制搜索时是否隐藏导航栏 */
            if(@available(iOS 13.0, *))
            {
                _searchController.hidesNavigationBarDuringPresentation = YES;  /* iOS 13+ 隐藏导航栏 */
            }
            else
            {
                _searchController.hidesNavigationBarDuringPresentation = NO;   /* iOS 11-12 不隐藏 */
            }

            /* 将搜索控制器集成到导航栏 */
            self.navigationItem.searchController = _searchController;
            self.navigationItem.hidesSearchBarWhenScrolling = self.hideSearchBarWhileScrolling;  /* 滚动时隐藏 */
        }
        else
        {
            /* iOS 10 及以下：将搜索栏作为表格的头部视图 */
            self.table.tableHeaderView = _searchController.searchBar;
            [self.table setContentOffset:CGPointMake(0,44) animated:NO];  /* 默认偏移 44pt 以显示搜索栏 */
        }
    }
}

/**
 * UISearchResultsUpdating 协议方法
 * 搜索关键字变化时的回调
 * 在后台队列更新搜索关键字，然后在主队列重新加载 specifiers
 *
 * @param searchController 搜索控制器
 */
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    /* 在后台队列更新搜索关键字，避免阻塞 UI */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        _searchKey = searchController.searchBar.text;
        /* 在主队列刷新 UI */
        dispatch_async(dispatch_get_main_queue(), ^(void){
            [self reloadSpecifiers];
        });
    });
}

/**
 * 从 specifier 的 plist 配置中加载分区设置
 * 如果在 specifier 的 property 中没有找到 sections 配置，
 * 则使用默认分区：所有可见应用
 */
- (void)_loadSectionsFromSpecifier
{
    NSArray* plistSections = [[self specifier] propertyForKey:@"sections"];
    if(plistSections)
    {
        /* 解析每个分区的字典配置 */
        NSMutableArray* applicationSectionsM = [NSMutableArray new];
        [plistSections enumerateObjectsUsingBlock:^(NSDictionary* dict, NSUInteger idx, BOOL *stop)
        {
            if(![dict isKindOfClass:[NSDictionary class]]) return;  /* 跳过非字典项 */
            ATLApplicationSection* section = [ATLApplicationSection applicationSectionWithDictionary:dict];
            [applicationSectionsM addObject:section];
        }];
        _applicationSections = applicationSectionsM.copy;
    }
    else
    {
        /* 未配置分区：默认显示所有可见应用 */
        _applicationSections = @[[[ATLApplicationSection alloc] initNonCustomSectionWithType:SECTION_TYPE_VISIBLE]];
    }
}

/**
 * 从已安装应用填充所有分区
 * 获取所有已安装的应用，然后让每个分区自行筛选和排序
 */
- (void)_populateSections
{
    NSArray<LSApplicationProxy*>* allInstalledApplications = [[LSApplicationWorkspace defaultWorkspace] atl_allInstalledApplications];
    /* 遍历所有分区，各自填充应用数据 */
    [_applicationSections enumerateObjectsUsingBlock:^(ATLApplicationSection* section, NSUInteger idx, BOOL *stop)
    {
        [section populateFromAllApplications:allInstalledApplications];
    }];
}

/** 加载偏好设置（子类重写） */
- (void)loadPreferences { }

/** 保存偏好设置（子类重写） */
- (void)savePreferences { }

/**
 * 准备填充分区
 * 读取 specifier 中的配置属性：是否显示包名、字母索引等
 */
- (void)prepareForPopulatingSections
{
    NSNumber* showIdentifiersAsSubtitleNum = [[self specifier] propertyForKey:@"showIdentifiersAsSubtitle"];
    if(showIdentifiersAsSubtitleNum)
    {
        self.showIdentifiersAsSubtitle = [showIdentifiersAsSubtitleNum boolValue];
    }

    NSNumber* alphabeticIndexingEnabledNum = [[self specifier] propertyForKey:@"alphabeticIndexingEnabled"];
    self.alphabeticIndexingEnabled = [alphabeticIndexingEnabledNum boolValue];
    if(self.alphabeticIndexingEnabled)
    {
        NSNumber* hideAlphabeticSectionHeadersNum = [[self specifier] propertyForKey:@"hideAlphabeticSectionHeaders"];
        self.hideAlphabeticSectionHeaders = [hideAlphabeticSectionHeadersNum boolValue];
    }

    NSString* localizationBundlePathString = [[self specifier] propertyForKey:@"localizationBundlePath"];
    if(localizationBundlePathString)
    {
        self.localizationBundle = [NSBundle bundleWithPath:localizationBundlePathString];
    }
}

/**
 * 获取本地化字符串
 * 优先使用自定义本地化 bundle，其次使用 AltList 内置的本地化
 *
 * @param string 原始字符串
 * @return 本地化后的字符串
 */
- (NSString*)localizedStringForString:(NSString*)string
{
    /* 优先使用自定义本地化 bundle */
    if(self.localizationBundle)
    {
        NSString* localizedString = [self.localizationBundle localizedStringForKey:string value:nil table:nil];
        if(localizedString)
        {
            return localizedString;
        }
    }

    /* 回退到 AltList 框架的本地化文件 */
    if(!_altListBundle)
    {
        return string;  /* 没有可用的 bundle，返回原字符串 */
    }

    return [_altListBundle localizedStringForKey:string value:string table:nil];
}

/**
 * 获取应用单元格的 PSCellType
 * 默认为 PSStaticTextCell（静态文本样式）
 * 子类可重写以使用开关、链接等其他单元格类型
 *
 * @return 单元格类型
 */
- (PSCellType)cellTypeForApplicationCells
{
    return PSStaticTextCell;
}

/**
 * 根据单元格类型获取自定义 cell 类
 * 如果启用了副标题，返回对应的带副标题的自定义 cell 类
 *
 * @param cellType 单元格类型
 * @return 自定义 cell 类，无自定义则返回 nil
 */
- (Class)customCellClassForCellType:(PSCellType)cellType
{
    if([self shouldShowSubtitles])
    {
        if(cellType == PSSwitchCell)
        {
            return [ATLApplicationSubtitleSwitchCell class];  /* 开关类型使用带副标题的开关 cell */
        }
        else
        {
            return [ATLApplicationSubtitleCell class];        /* 其他类型使用带副标题的普通 cell */
        }
    }

    return nil;  /* 不显示副标题，使用默认 cell */
}

/**
 * 获取应用 specifier 的详细控制器类
 * 子类重写以在点击应用时跳转到自定义控制器
 *
 * @param applicationProxy 应用代理
 * @return 详细控制器类，nil 表示不跳转
 */
- (Class)detailControllerClassForSpecifierOfApplicationProxy:(LSApplicationProxy*)applicationProxy
{
    return nil;
}

/**
 * 获取应用 specifier 的 getter 选择子
 * 子类重写以从偏好设置中读取应用的状态
 *
 * @param applicationProxy 应用代理
 * @return getter 选择子，nil 表示没有
 */
- (SEL)getterForSpecifierOfApplicationProxy:(LSApplicationProxy*)applicationProxy
{
    return nil;
}

/**
 * 获取应用 specifier 的 setter 选择子
 * 子类重写以保存应用到偏好设置中的状态
 *
 * @param applicationProxy 应用代理
 * @return setter 选择子，nil 表示没有
 */
- (SEL)setterForSpecifierOfApplicationProxy:(LSApplicationProxy*)applicationProxy
{
    return nil;
}

/**
 * 为应用代理创建对应的 PSSpecifier
 * 设置应用名称、图标、标识符等信息
 * 图标采用异步加载方式，避免主线程卡顿
 *
 * @param applicationProxy 应用代理
 * @return 配置好的 PSSpecifier
 */
- (PSSpecifier*)createSpecifierForApplicationProxy:(LSApplicationProxy*)applicationProxy
{
    SEL setter = [self setterForSpecifierOfApplicationProxy:applicationProxy];
    SEL getter = [self getterForSpecifierOfApplicationProxy:applicationProxy];
    PSCellType cellType = [self cellTypeForApplicationCells];

    /* 创建 specifier，使用应用名称作为标题 */
    PSSpecifier* specifier = [PSSpecifier preferenceSpecifierNamed:[applicationProxy atl_nameToDisplay]
        target:self                  /* target 设置为控制器自身 */
        set:setter                   /* 保存值的选择子 */
        get:getter                   /* 读取值的选择子 */
        detail:nil                   /* 详细控制器（稍后设置） */
        cell:cellType                /* 单元格类型 */
        edit:nil];

    /* 设置 specifier 的标识符为包名 */
    NSString* bundleIdentifier = applicationProxy.atl_bundleIdentifier;
    specifier.identifier = bundleIdentifier;
    [specifier setProperty:bundleIdentifier forKey:@"applicationIdentifier"];

    /* 先设置占位图标，避免空占位 */
    [specifier setProperty:_placeholderAppIcon forKey:@"iconImage"];

    /* 如果有自定义 cell 类，设置到 specifier */
    Class customCellClass = [self customCellClassForCellType:cellType];
    if(customCellClass)
    {
        [specifier setProperty:customCellClass forKey:@"cellClass"];
    }

    /* 设置详细控制器类（点击后跳转的目标控制器） */
    Class detailControllerClass = [self detailControllerClassForSpecifierOfApplicationProxy:applicationProxy];
    if(detailControllerClass)
    {
        specifier.detailControllerClass = detailControllerClass;
    }

    /* 异步加载应用图标，提升列表滚动流畅性 */
    if(_iconLoadQueue)
    {
        UITableView* tableView = [self valueForKey:@"_table"];  /* 获取 tableView 引用 */
        dispatch_async(_iconLoadQueue, ^{
            /* 在后台队列加载应用图标（耗时约 1-3ms 的 IPC 调用） */
            UIImage* iconImage = [UIImage _applicationIconImageForBundleIdentifier:applicationProxy.atl_bundleIdentifier format:0 scale:[UIScreen mainScreen].scale];
            dispatch_async(dispatch_get_main_queue(), ^{
                /* 回到主队列更新 UI */
                [specifier setProperty:iconImage forKey:@"iconImage"];
                /* 检查 specifier 是否仍然在列表中（防止卸载后刷新已移除的 cell） */
                if([self containsSpecifier:specifier])
                {
                    NSIndexPath* specifierIndexPath = [self indexPathForIndex:[self indexOfSpecifier:specifier]];
                    /* 只在 cell 可见时刷新，减少不必要的重绘 */
                    if([[tableView indexPathsForVisibleRows] containsObject:specifierIndexPath])
                    {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if(!_isReloadingSpecifiers)
                            {
                                [self reloadSpecifier:specifier];
                            }
                        });
                    }
                }
            });
        });
    }
    else
    {
        /* 没有异步队列：在主线程同步加载图标（备用方案） */
        UIImage* iconImage = [UIImage _applicationIconImageForBundleIdentifier:applicationProxy.atl_bundleIdentifier format:0 scale:[UIScreen mainScreen].scale];
        [specifier setProperty:iconImage forKey:@"iconImage"];
    }

    /* 默认启用 */
    [specifier setProperty:@YES forKey:@"enabled"];

    return specifier;
}

/**
 * 是否应隐藏所有应用 specifier
 * 搜索激活且有搜索关键字时返回 YES（将显示筛选后的列表）
 *
 * @return YES 表示搜索模式应隐藏所有未匹配的应用
 */
- (BOOL)shouldHideApplicationSpecifiers
{
    if(_searchKey)
    {
        return ![_searchKey isEqualToString:@""];  /* 有搜索关键字时启用隐藏 */
    }
    return NO;
}

/**
 * 是否应隐藏某个应用 specifier
 * 在搜索模式下，检查应用名称和包名是否匹配搜索关键字
 *
 * @param specifier 要检查的 specifier
 * @return YES 表示该应用不匹配搜索关键字，应被隐藏
 */
- (BOOL)shouldHideApplicationSpecifier:(PSSpecifier*)specifier
{
    /* 按名称匹配（忽略大小写、使用本地化比较） */
    BOOL nameMatch = [specifier.name rangeOfString:_searchKey options:NSCaseInsensitiveSearch range:NSMakeRange(0, [specifier.name length]) locale:[NSLocale currentLocale]].location != NSNotFound;

    /* 按包名匹配 */
    BOOL identifierMatch = NO;
    if(self.includeIdentifiersInSearch)
    {
        NSString* applicationID = [specifier propertyForKey:@"applicationIdentifier"];
        identifierMatch = [applicationID rangeOfString:_searchKey options:NSCaseInsensitiveSearch].location != NSNotFound;
    }

    /* 名称和包名都不匹配时，应隐藏 */
    return !identifierMatch && !nameMatch;
}

/**
 * 是否应显示副标题
 * 当启用了 showIdentifiersAsSubtitle 时返回 YES
 *
 * @return YES 表示需要显示副标题
 */
- (BOOL)shouldShowSubtitles
{
    if(self.showIdentifiersAsSubtitle)
    {
        return YES;
    }
    return NO;
}

/**
 * 获取应用的副标题
 * 默认显示应用包名（当 showIdentifiersAsSubtitle 启用时）
 *
 * @param applicationID 应用包名
 * @return 副标题字符串
 */
- (NSString*)subtitleForApplicationWithIdentifier:(NSString*)applicationID
{
    if(self.showIdentifiersAsSubtitle)
    {
        return applicationID;  /* 显示包名作为副标题 */
    }
    return nil;
}

/**
 * 内部方法：获取 specifier 的副标题
 *
 * @param specifier 设置项描述器
 * @return 副标题字符串
 */
- (NSString*)_subtitleForSpecifier:(PSSpecifier*)specifier
{
    return [self subtitleForApplicationWithIdentifier:[specifier propertyForKey:@"applicationIdentifier"]];
}

/**
 * 为应用分区创建 specifier 列表
 * 遍历分区中的应用列表，为每个应用创建 specifier
 *
 * @param section 应用分区
 * @return specifier 数组
 */
- (NSArray*)createSpecifiersForApplicationSection:(ATLApplicationSection*)section
{
    NSMutableArray* sectionSpecifiers = [NSMutableArray new];

    /* 遍历分区中的每个应用并创建对应的 specifier */
    [section.applicationsInSection enumerateObjectsUsingBlock:^(LSApplicationProxy* appProxy, NSUInteger idx, BOOL *stop)
    {
        PSSpecifier* appSpecifier = [self createSpecifierForApplicationProxy:appProxy];
        if(appSpecifier)
        {
            [sectionSpecifiers addObject:appSpecifier];
        }
    }];

    return sectionSpecifiers;
}

/**
 * 填充 specifiersByLetter 字典
 * 遍历所有 specifiers，根据名称的首字母(A-Z)或 #（非字母开头）进行分组
 * 特殊处理：过滤掉 RTL/LTR 控制字符（WhatsApp 名称前包含这些字符）
 */
- (void)populateSpecifiersByLetter
{
    _specifiersByLetter = [NSMutableDictionary new];

    [_specifiers enumerateObjectsUsingBlock:^(PSSpecifier* specifier, NSUInteger idx, BOOL *stop)
    {
        /* 去除首尾空白 */
        NSString* trimmedName = [specifier.name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        /* 去除 RTL/LTR 控制字符（U+200E/U+200F），某些应用名称包含这些字符 */
        trimmedName = [trimmedName stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"‎‏"]];

        /* 确定首字母 */
        NSString* firstLetter = @"#";  /* 默认使用 #（非字母开头） */
        if(trimmedName.length > 0)
        {
            unichar firstLetterChar = [trimmedName.uppercaseString characterAtIndex:0];
            if(firstLetterChar >= 'A' && firstLetterChar <= 'Z')
            {
                firstLetter = [NSString stringWithFormat:@"%c", firstLetterChar];  /* A-Z */
            }
        }

        /* 将 specifier 加入对应的分组 */
        NSMutableArray* letterSpecifiers = [_specifiersByLetter objectForKey:firstLetter];
        if(!letterSpecifiers)
        {
            letterSpecifiers = [NSMutableArray new];
            [_specifiersByLetter setObject:letterSpecifiers forKey:firstLetter];
        }
        [letterSpecifiers addObject:specifier];
    }];
}

/**
 * 获取按首字母分组的 specifier 列表
 * 遍历 A-Z 和 #，为每个有应用的字母创建组 specifier，
 * 组 specifier 的标题为对应的字母
 *
 * @return 分组后的 specifier 列表
 */
- (NSMutableArray*)specifiersGroupedByLetters
{
    BOOL firstSpecifier = YES;  /* 标记是否是第一个字母组 */
    NSMutableArray* letterGroupedSpecifiers = [NSMutableArray new];
    /* 遍历 A-Z + 额外的一次 # */
    for(char c = 'A'; c <= 'Z'+1; c++)
    {
        NSString* cString;
        if(c == ('Z'+1))
        {
            cString = @"#";  /* 非字母开头的应用放在最后 */
        }
        else
        {
            cString = [NSString stringWithFormat:@"%c", c];
        }
        NSMutableArray* letterSpecifiers = [_specifiersByLetter objectForKey:cString];
        if(letterSpecifiers)
        {
            /* 创建该字母的组 specifier */
            PSSpecifier* groupSpecifier = [PSSpecifier emptyGroupSpecifier];
            if(firstSpecifier && self.hideAlphabeticSectionHeaders)
            {
                /* 第一个字母组使用本地化的 "Applications" 标题 */
                groupSpecifier.name = [self localizedStringForString:@"Applications"];
                [groupSpecifier setProperty:@YES forKey:@"isFirstLetterSection"];
            }
            else
            {
                groupSpecifier.name = cString;  /* 显示字母作为标题 */
                [groupSpecifier setProperty:@YES forKey:@"isLetterSection"];
            }
            [letterGroupedSpecifiers addObject:groupSpecifier];
            [letterGroupedSpecifiers addObjectsFromArray:letterSpecifiers];
            firstSpecifier = NO;
        }
    }

    return letterGroupedSpecifiers;
}

/**
 * 为应用分区创建组 specifier
 *
 * @param section 应用分区
 * @return 组 specifier
 */
- (PSSpecifier*)createGroupSpecifierForApplicationSection:(ATLApplicationSection*)section
{
    PSSpecifier* groupSpecifier = [PSSpecifier emptyGroupSpecifier];
    groupSpecifier.name = [self localizedStringForString:section.sectionName];  /* 使用本地化的分区名称 */
    return groupSpecifier;
}

/**
 * 重新加载应用列表
 * 清空缓存的 specifier 并触发 reloadSpecifiers
 */
- (void)reloadApplications
{
    _allSpecifiers = nil;
    [self reloadSpecifiers];
}

/**
 * 重写 reloadSpecifiers
 * 设置 _isReloadingSpecifiers 标记，防止图标加载完成回调中的重复刷新
 */
- (void)reloadSpecifiers
{
    _isReloadingSpecifiers = YES;
    [super reloadSpecifiers];
    _isReloadingSpecifiers = NO;
}

/**
 * 核心方法：获取 specifiers 列表
 * 实现了完整的加载、筛选、搜索过滤和字母分组的逻辑：
 * 1. 首次调用时加载配置、填充数据、创建 specifiers
 * 2. 搜索模式下根据关键字过滤应用
 * 3. 启用字母索引时按首字母重新分组
 *
 * @return specifiers 的可变数组
 */
- (NSMutableArray*)specifiers
{
    if(!_specifiers)
    {
        /* 首次访问：加载偏好设置 */
        [self loadPreferences];

        /* 如果还没有分区配置，从 specifier 加载 */
        if(!_applicationSections)
        {
            [self _loadSectionsFromSpecifier];
        }

        /* 如果还没有完整的 specifier 列表，构建之 */
        if(!_allSpecifiers)
        {
            [self prepareForPopulatingSections];
            [self _populateSections];

            _allSpecifiers = [NSMutableArray new];

            /* 遍历每个分区，创建 specifier */
            [_applicationSections enumerateObjectsUsingBlock:^(ATLApplicationSection* section, NSUInteger idx, BOOL *stop)
            {
                PSSpecifier* groupSpecifier = [self createGroupSpecifierForApplicationSection:section];
                NSArray* specifiersForSection = [self createSpecifiersForApplicationSection:section];
                if(specifiersForSection && specifiersForSection.count > 0)
                {
                    if(!self.alphabeticIndexingEnabled)
                    {
                        /* 非字母索引模式：添加组标题 */
                        [_allSpecifiers addObject:groupSpecifier];
                    }
                    [_allSpecifiers addObjectsFromArray:specifiersForSection];
                }
            }];
        }

        if(![self shouldHideApplicationSpecifiers])
        {
            /* 非搜索模式：直接使用完整列表 */
            _specifiers = _allSpecifiers;
        }
        else
        {
            /* 搜索模式：从后往前遍历，仅保留匹配的应用和其组标题 */
            _specifiers = [NSMutableArray new];
            [_allSpecifiers enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(PSSpecifier* specifier, NSUInteger idx, BOOL *stop)
            {
                if(specifier.cellType != PSGroupCell)
                {
                    /* 应用 cell：检查是否应隐藏 */
                    if([self shouldHideApplicationSpecifier:specifier])
                    {
                        return;  /* 不匹配搜索，跳过 */
                    }
                }
                else
                {
                    /* 组 cell：隐藏空的分区 */
                    if(_specifiers.count == 0)
                    {
                        return;  /* 这个组是空的，跳过 */
                    }
                    PSSpecifier* firstSpecifier = _specifiers.firstObject;
                    if(firstSpecifier.cellType == PSGroupCell)
                    {
                        return;  /* 避免连续的两个组标题 */
                    }
                }

                /* 插入到开头（因为是从后往前遍历） */
                [_specifiers insertObject:specifier atIndex:0];
            }];
        }

        /* 如果启用了字母索引，重新按字母分组 */
        if(self.alphabeticIndexingEnabled)
        {
            [self populateSpecifiersByLetter];
            _specifiers = [self specifiersGroupedByLetters];
        }
    }

    return _specifiers;
}

/**
 * 根据包名查找 PSSpecifier
 *
 * @param applicationID 应用包名
 * @return 对应的 PSSpecifier，未找到返回 nil
 */
- (PSSpecifier*)specifierForApplicationWithIdentifier:(NSString*)applicationID
{
    __block PSSpecifier* specifierToReturn;
    [_specifiers enumerateObjectsUsingBlock:^(PSSpecifier* specifier, NSUInteger idx, BOOL *stop)
    {
        NSString* specifierApplicationID = [specifier propertyForKey:@"applicationIdentifier"];
        if([applicationID isEqualToString:specifierApplicationID])
        {
            specifierToReturn = specifier;
            *stop = YES;
        }
    }];
    return specifierToReturn;
}

/**
 * 根据包名查找 NSIndexPath
 *
 * @param applicationID 应用包名
 * @return 对应的 NSIndexPath，未找到返回 nil
 */
- (NSIndexPath*)indexPathForApplicationWithIdentifier:(NSString*)applicationID
{
    PSSpecifier* specifier = [self specifierForApplicationWithIdentifier:applicationID];
    return [self indexPathForIndex:[self indexOfSpecifier:specifier]];
}

@end
