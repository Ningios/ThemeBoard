#import "TBPanelController.h"
#import <objc/runtime.h>
#import "TBThemeListController.h"
#import "TBThemeDetailController.h"
#import "TBThemeScanner.h"
#import "TBPrefs.h"
#import "TBGlass.h"
#import "TBBottomSheetController.h"
#import "TBTableViewController.h"
#import "TBDocImport.h"
#import "TBToast.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TBThemeListController () <UISearchResultsUpdating, UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<TBTheme *> *themes;
@property (nonatomic, strong) NSArray<TBTheme *> *filtered;
/// 分组后：主题包（有应用图标）/ 素材包（遮罩·边框·阴影·角标）
@property (nonatomic, strong) NSArray<TBTheme *> *themePacks;
@property (nonatomic, strong) NSArray<TBTheme *> *assetPacks;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, assign) NSInteger sortMode;   // 0 名称 1 图标数
/// 0.15.54：强引用当前 picker —— 之前是局部变量，虽然有 present 持有，
/// 但一旦被提前 dismiss（比如 search 控制器抢了呈现）就会连回调一起消失，
/// 表现正是「点了文件完全没反应」。留住它 + delegate 自查日志。
@property (nonatomic, strong) UIDocumentPickerViewController *activePicker;
- (void)tb_dismissSearch;
@end

static UIView *TBFindSwipePullView(UIView *root, NSInteger depth) {
    if (depth > 4) return nil;
    for (UIView *v in root.subviews) {
        if ([NSStringFromClass(v.class) containsString:@"UISwipeActionPullView"]) return v;
        UIView *r = TBFindSwipePullView(v, depth + 1);
        if (r) return r;
    }
    return nil;
}

static void TBPaintRedLabels(UIView *v, NSInteger depth);

static void TBStyleSwipePullView(UIView *pull) {
    CGFloat scale = [UIScreen mainScreen].scale;
    pull.backgroundColor = [UIColor clearColor];
    pull.layer.cornerRadius = 20;
    pull.layer.cornerCurve = kCACornerCurveContinuous;
    pull.clipsToBounds = YES;

    for (UIView *btn in pull.subviews) {
        btn.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                             [UIColor colorWithWhite:1 alpha:0.14]);
        btn.layer.cornerRadius = 20;
        btn.layer.cornerCurve = kCACornerCurveContinuous;
        btn.clipsToBounds = YES;
        btn.layer.borderWidth = 1.0 / scale;
        btn.layer.borderColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                               [UIColor colorWithWhite:1 alpha:0.20]).CGColor;
        TBPaintRedLabels(btn, 0);
    }
}

/// 只把删除按钮里的文字染红；不设 tintColor（会向下继承，染红整张表）
static void TBPaintRedLabels(UIView *v, NSInteger depth) {
    if (!v || depth > 3) return;
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            ((UILabel *)sub).textColor = [UIColor systemRedColor];
        } else {
            TBPaintRedLabels(sub, depth + 1);
        }
    }
}

/// 滑动容器每次布局都重新套样式：样式和原来一模一样，只是时机提前到首帧之前，
/// 不会先闪一下系统灰底，也不会因为「那次没抓到」而整行变灰。
static void (*o_swipePullLayout)(id, SEL);
static void tb_swipePullLayout(id self, SEL _cmd) {
    if (o_swipePullLayout) o_swipePullLayout(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) TBStyleSwipePullView((UIView *)self);
}


@implementation TBThemeListController

- (void)viewDidLoad {
    [TBThemeListController tb_installSwipeStyle];
    [super viewDidLoad];
    self.title = @"主题";
    self.tableView.rowHeight = 76;

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    // 0.15.53：0.15.50 删了系统「取消」按钮后，激活的搜索没有退路（点屏幕/滑动都收不回去）。
    // 三条退出路径：
    // ① 点列表任意处（含空白）→ 收起；cancelsTouchesInView=NO，不影响 cell 点击
    UITapGestureRecognizer *dismissTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tb_dismissSearch)];
    dismissTap.cancelsTouchesInView = NO;
    [self.tableView addGestureRecognizer:dismissTap];
    // ③ 键盘收起（下拉隐藏键盘 / 系统收起）→ 同步退出搜索态
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tb_dismissSearch)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    // 排序按钮已从导航栏挪进列表（「主题」分组标题右侧），见 viewForHeaderInSection:

    // 三个操作按钮放在「当前使用」下面（见 tableView:cellForRowAtIndexPath: 第 1 段）

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    [TBThemeScanner seedDemoThemesIfNeeded];
    [TBPrefs setString:[TBThemeScanner containerThemesDir] forKey:@"ThemeRoot"];
    [TBPrefs synchronize];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}


#pragma mark - 数据

/// 收起搜索（0.15.53：搜索栏删了系统「取消」按钮后的退出路径）
- (void)tb_dismissSearch {
    if (self.search && self.search.active) {
        self.search.active = NO;   // searchBar 会跟着失焦收起
        [self applyFilter];
    }
}

/// ② 开始拖动列表 → 收起搜索（用户往下滑是明确的「退出搜索」意图）
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self tb_dismissSearch];
}

/// ② 兜底：大位移滚动（只在用户真实拖动/惯性时触发；搜索激活动画也会改 contentOffset，别误收）
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!self.search.active) return;
    BOOL userScrolling = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating;
    if (userScrolling && fabs(scrollView.contentOffset.y) > 10.0) [self tb_dismissSearch];
}

- (void)reload {
    self.themes = [TBThemeScanner scanThemes];
    [self applyFilter];
    [self.refreshControl endRefreshing];
}

- (void)applyFilter {
    NSArray *base = self.themes;
    NSString *q = self.search.searchBar.text;
    if (q.length) {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(TBTheme *t, NSDictionary *b) {
            return [t.name rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        base = [base filteredArrayUsingPredicate:p];
    }
    NSArray *sorted = base;
    if (self.sortMode == 1) {
        sorted = [base sortedArrayUsingComparator:^NSComparisonResult(TBTheme *a, TBTheme *b) {
            [a loadIndex]; [b loadIndex];
            if (a.iconCount == b.iconCount) return [a.name caseInsensitiveCompare:b.name];
            return a.iconCount > b.iconCount ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    self.filtered = sorted;

    // 分组：主题包（有 IconBundles/<反向域名>.png 等应用图标）/ 素材包（只有遮罩、边框、阴影、角标）
    NSMutableArray<TBTheme *> *packs = [NSMutableArray array];
    NSMutableArray<TBTheme *> *assets = [NSMutableArray array];
    for (TBTheme *t in sorted) {
        if (t.isAssetPack) [assets addObject:t];
        else               [packs addObject:t];
    }
    self.themePacks = packs;
    self.assetPacks = assets;

    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    [self applyFilter];
}

- (void)sortTapped {
    // 自绘玻璃选择弹窗（TBChoicePanelController），不再用系统 action sheet
    __weak typeof(self) wself = self;
    TBChoicePanelController *p = [TBChoicePanelController
        panelWithTitle:@"排序方式"
               message:nil
               options:@[ @"按名称", @"按图标数量" ]
               handler:^(NSInteger idx) {
        __strong typeof(self) s = wself;
        if (!s || idx < 0) return;
        s.sortMode = (idx == 0) ? 0 : 1;      // 排序逻辑不变
        [s applyFilter];
    }];
    [p presentOver:self];
}

#pragma mark - 导入

- (void)importTapped {
    // iOS14+：initForOpeningContentTypes:asCopy:YES（系统先把文件/目录复制进 App 临时区）
    // 老系统：initWithDocumentTypes:inMode:UIDocumentPickerModeImport
    // 搜索态下 self.presentedViewController 是搜索控制器，会抢走呈现 → 先退出搜索
    if (self.search.isActive) [self tb_dismissSearch];

    UIDocumentPickerViewController *picker =
        TBNewImportPicker(@[ UTTypeZIP, UTTypeFolder ],
                          @[ @"public.zip-archive", @"public.folder", @"public.data" ]);
    if (!picker) { [self alertTitle:@"打不开" message:@"系统没有可用的文件夹选择器"]; return; }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    self.activePicker = picker;                 // 强持有，防提前释放

    // ★ 0.15.54：从「真正的最顶层 VC」present。之前在 self 上 present，若 self 上面
    //   还挂着弹层/搜索控制器，picker 是弹出来了，但选中回调落不到 self 上（用户实测：
    //   跳到文件选择器后点文件完全没反应，且 didPickDocumentsAtURLs / WasCancelled 一行日志都没有）。
    UIViewController *host = TBTopPresentingViewController(self);
    NSLog(@"[ThemeBoard] 导入 picker: self=%@ host=%@ delegate==self?%d",
          NSStringFromClass([self class]), NSStringFromClass([host class]),
          (picker.delegate == (id)self) ? 1 : 0);
    TBLog2(@"[导入][picker] 即将 present self=%@ host=%@ delegate==self?%d",
           NSStringFromClass([self class]), NSStringFromClass([host class]),
           (picker.delegate == (id)self) ? 1 : 0);
    [host presentViewController:picker animated:YES completion:^{
        TBLog2(@"[导入][picker] present 完成 picker.presenting=%@",
               NSStringFromClass([picker.presentingViewController class]));
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    // ★ 0.15.54：这里是回调的「第一行」。用户实测 app.log 里连这一行都没有，
    //   说明要么回调没进（呈现层级/delegate 问题），要么日志被前面 return 掉。
    //   先无条件打，定位用。
    NSLog(@"[ThemeBoard] ★进入 didPickDocumentsAtURLs urls.count=%lu", (unsigned long)urls.count);
    TBLog2(@"[导入][picker] ★进入回调 didPickDocumentsAtURLs urls.count=%lu delegate=%@",
           (unsigned long)urls.count, NSStringFromClass([controller.delegate class]));
    self.activePicker = nil;

    NSURL *url = urls.firstObject;
    TBLog2(@"[导入] 主题列表：didPickDocumentsAtURLs 入口，选中 %lu 个，第一个=%@ isICloud=%d",
           (unsigned long)urls.count, url.absoluteString ?: @"(nil)",
           TBURLIsICloud(url) ? 1 : 0);
    if (!url) return;

    // 真正的读取/复制在 TBThemeScanner 里用 NSFileCoordinator 做（会触发 iCloud 下载）
    NSError *err = nil;
    NSString *dst = [TBThemeScanner importFromAnyURL:url error:&err];
    TBLog2(@"[导入] 主题列表：结果 dst=%@ err=%@", dst ?: @"(nil)", err.localizedDescription ?: @"-");

    if (dst) {
        [self reload];
        TBPresentAlert(self, @"导入完成", dst);
    } else {
        NSString *msg = err.localizedDescription
            ?: TBImportFailureMessage(url, nil, @"导入失败：读不到选中的内容");
        TBLog2(@"[导入] 主题列表：失败弹窗内容：%@", msg);
        TBPresentAlert(self, @"导入失败", msg);
    }
}

/// 老系统的单 URL 回调（iOS 11 起已废弃，个别系统版本只回这一条）→ 统一转给复数版本
- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentAtURL:(NSURL *)url {
    TBLog2(@"[导入][picker] 旧回调 didPickDocumentAtURL=%@", url.absoluteString ?: @"(nil)");
    if (!url) return;
    [self documentPicker:controller didPickDocumentsAtURLs:@[ url ]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // 0.15.54：取消也要有日志，否则排障时无法区分「没回调」和「用户取消」
    NSLog(@"[ThemeBoard] documentPickerWasCancelled");
    TBLog2(@"[导入][picker] 用户取消 documentPickerWasCancelled");
    self.activePicker = nil;
}

#pragma mark - 顶部工具条

- (UIView *)buildToolbarBar {
    CGFloat w = MAX(320.0, self.tableView.bounds.size.width);
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 50)];
    head.backgroundColor = [UIColor clearColor];
    head.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:head.leadingAnchor constant:20],
        [bar.trailingAnchor constraintEqualToAnchor:head.trailingAnchor constant:-20],
        [bar.topAnchor constraintEqualToAnchor:head.topAnchor constant:2],
        [bar.heightAnchor constraintEqualToConstant:44],   // 按钮本体仍是 44，只收外留白
    ]];

    // 与主题详情页的按钮同款：圆角 13、高 44、16 号半粗、白色玻璃底 + 细边
    NSArray *titles = @[@"重新扫描", @"导入主题", @"清除主题"];
    NSMutableArray *all = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [b setTitleColor:(i == 2 ? [UIColor systemRedColor] : [UIColor labelColor])
                forState:UIControlStateNormal];
        b.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                           [UIColor colorWithWhite:1 alpha:0.14]);
        b.layer.cornerRadius = 13;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        TBApplyRim(b, 0.55);
        b.tag = i;
        [all addObject:b];
    }
    UIButton *scan = all[0], *imp = all[1], *clr = all[2];

    for (UIButton *b in all) [bar addSubview:b];
    for (UIButton *b in all) {
        [b addTarget:self action:@selector(toolbarTapped:) forControlEvents:UIControlEventTouchUpInside];
    }

    [NSLayoutConstraint activateConstraints:@[
        [scan.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [scan.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [scan.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],

        [imp.leadingAnchor constraintEqualToAnchor:scan.trailingAnchor constant:10],
        [imp.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [imp.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [imp.widthAnchor constraintEqualToAnchor:scan.widthAnchor multiplier:1.61],

        [clr.leadingAnchor constraintEqualToAnchor:imp.trailingAnchor constant:10],
        [clr.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [clr.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [clr.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [clr.widthAnchor constraintEqualToAnchor:imp.widthAnchor],
    ]];
    return head;
}

- (void)toolbarTapped:(UIButton *)b {
    switch (b.tag) {
        case 0: [self rescanTapped]; break;   // 重新扫描
        case 1: [self importTapped]; break;   // 导入主题
        default: [self clearTapped]; break;   // 清除主题
    }
}

- (void)rescanTapped {
    [self reload];
    [self alertTitle:@"扫描完成"
             message:[NSString stringWithFormat:@"找到 %lu 个主题", (unsigned long)self.themes.count]];
}

- (void)clearTapped {
    NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
    if (!active.length) {
        [self alertTitle:@"当前没有应用主题" message:@"桌面已经是系统原样"];
        return;
    }
    // 自绘玻璃确认弹窗（TBConfirmPanelController），不再用系统 UIAlertController
    __weak typeof(self) wself = self;
    TBPresentConfirm(self, [NSString stringWithFormat:@"清除「%@」？", active],
                     @"桌面图标会恢复系统原样，主题文件夹不会被删除",
                     @"取消", @"清除", YES, ^(BOOL ok) {
        if (!ok) return;
        __strong typeof(self) s = wself;
        if (!s) return;
        [TBPrefs setString:nil forKey:TBKeyActiveTheme];
        [TBPrefs notifyChanged];
        [s reload];
    });
}

#pragma mark - Table

- (NSString *)activeThemeName {
    return [TBPrefs stringForKey:TBKeyActiveTheme];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"当前使用";
    if (section == 1) return nil;
    if (section == 2) return self.themePacks.count ? @"主题" : nil;      // 组 1：有应用图标的主题包
    return self.assetPacks.count ? @"素材" : nil;                        // 组 2：素材包
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 3) return nil;
    if (self.themes.count == 0) {
        NSArray *roots = [TBThemeScanner themeRoots];
        NSString *where = roots.count ? [roots componentsJoinedByString:@"\n"] : @"（没有可用的主题目录）";
        return [NSString stringWithFormat:@"还没有主题。点上面的「导入主题」，或把包含 IconBundles 的文件夹放到：\n%@", where];
    }
    return [NSString stringWithFormat:@"共 %lu 个（主题 %lu · 素材 %lu）· 兼容 SnowBoard / Anemone 的 IconBundles 结构",
            (unsigned long)self.filtered.count,
            (unsigned long)self.themePacks.count,
            (unsigned long)self.assetPacks.count];
}

#pragma mark - 分组标题（「主题」右侧挂排序按钮）

/// 分组标题的左缩进：和玻璃卡片左边对齐（系统内缩 20 + 卡片自身 12）
static const CGFloat kTBListHeaderInset = 32.0;

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    // 0.15.57 间距收紧：分组标题 56→50、普通分组 34→28（按钮行上方保持最小 8）
    if (section == 2) return 50.0;   // 「主题」标题 + 右侧排序按钮
    if (section == 1) return 8.0;    // 按钮行上方的小间距（这一组本来就没有标题）
    return 28.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    CGFloat w = tableView.bounds.size.width;
    if (w < 1) w = [UIScreen mainScreen].bounds.size.width;
    CGFloat h = [self tableView:tableView heightForHeaderInSection:section];
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    head.backgroundColor = [UIColor clearColor];

    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (title.length) {
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
        lab.text = title;
        lab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        lab.textColor = [UIColor secondaryLabelColor];
        lab.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        if (section == 2) {
            lab.frame = CGRectMake(kTBListHeaderInset, (h - 20.0) / 2.0,
                                   w - kTBListHeaderInset * 2 - 64.0, 20.0);
        } else {
            lab.frame = CGRectMake(kTBListHeaderInset, h - 20.0 - 4.0, w - kTBListHeaderInset * 2, 20.0);
        }
        [head addSubview:lab];
    }

    if (section == 2) {
        // 排序按钮：从导航栏挪到这里（「主题」分组标题右侧）。
        // 0.15.53：58×44 → 40×32（圆角 10 / 图标 18pt）——之前和三操作按钮一样大，喧宾夺主
        UIButton *sort = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *sc =
            [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightRegular];
        [sort setImage:[UIImage systemImageNamed:@"arrow.up.arrow.down" withConfiguration:sc]
              forState:UIControlStateNormal];
        sort.tintColor = [UIColor labelColor];
        sort.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                              [UIColor colorWithWhite:1 alpha:0.14]);
        sort.layer.cornerRadius = 10;
        sort.layer.cornerCurve = kCACornerCurveContinuous;
        TBApplyRim(sort, 0.55);
        sort.frame = CGRectMake(w - kTBListHeaderInset - 40.0, (h - 32.0) / 2.0, 40.0, 32.0);
        sort.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [sort addTarget:self action:@selector(sortTapped) forControlEvents:UIControlEventTouchUpInside];
        [head addSubview:sort];
    }
    return head;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 1;
    if (section == 2) return self.themePacks.count;
    return self.assetPacks.count;
}

/// 当前 section 对应的数据源（2=主题包，3=素材包）
- (NSArray<TBTheme *> *)themesInSection:(NSInteger)section {
    return section == 2 ? self.themePacks : self.assetPacks;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 ? 50 : 76;   // 按钮行 62→50
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 第 1 段：三个操作按钮（在「当前使用」下面）
    if (indexPath.section == 1) {
        UITableViewCell *bc = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                     reuseIdentifier:nil];
        bc.backgroundColor = [UIColor clearColor];
        bc.contentView.backgroundColor = [UIColor clearColor];
        bc.selectionStyle = UITableViewCellSelectionStyleNone;
        UIView *bar = [self buildToolbarBar];
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        [bc.contentView addSubview:bar];
        [NSLayoutConstraint activateConstraints:@[
            [bar.leadingAnchor constraintEqualToAnchor:bc.contentView.leadingAnchor],
            [bar.trailingAnchor constraintEqualToAnchor:bc.contentView.trailingAnchor],
            [bar.topAnchor constraintEqualToAnchor:bc.contentView.topAnchor constant:0],
            [bar.heightAnchor constraintEqualToConstant:50],
        ]];
        return bc;
    }

    static NSString *cid = @"theme";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        // 卡片必须放进 contentView：系统左滑只平移 contentView，挂在 backgroundView
        // 上的卡片不会跟着走（表现就是内容左移、卡片留在原地，内容跑到卡片外面）。
        UIView *bg = TBGlassCellBG(12);
        bg.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView insertSubview:bg atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [bg.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
            // 注意贴 cell 而不是 contentView：contentView 不含右侧附件区，
            // 贴它卡片会变窄，✓ 就露到卡片外面去了
            [bg.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
            [bg.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
            [bg.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
        ]];
        cell.selectedBackgroundView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.imageView.layer.cornerRadius = 11;
        cell.imageView.layer.cornerCurve = kCACornerCurveContinuous;
        cell.imageView.clipsToBounds = YES;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    if (indexPath.section == 0) {
        NSString *active = [self activeThemeName];
        TBTheme *t = active ? [TBThemeScanner themeNamed:active] : nil;
        [t loadIndex];   // 缺这行导致“当前使用”显示 0 个图标
        cell.textLabel.text = t ? t.name : @"未应用主题";
        cell.textLabel.textColor = t ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = t ? [NSString stringWithFormat:@"%lu 个图标 · 已应用", (unsigned long)t.iconCount]
                                      : @"从下方选择一个主题";
        cell.imageView.image = t ? [self thumbFor:t] : [UIImage systemImageNamed:@"circle.dashed"];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 2) {
        NSArray<TBTheme *> *list = self.themePacks;
        if (indexPath.row >= (NSInteger)list.count) return cell;
        TBTheme *t = list[indexPath.row];
        [t loadIndex];
        cell.textLabel.text = t.name;
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个图标 · %lu 个文件",
                                     (unsigned long)t.iconCount, (unsigned long)t.fileCount];
        cell.imageView.image = [self thumbFor:t];
        cell.accessoryType = [[self activeThemeName] isEqualToString:t.name]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSArray<TBTheme *> *list = self.assetPacks;
        if (indexPath.row >= (NSInteger)list.count) return cell;
        TBTheme *t = list[indexPath.row];
        cell.textLabel.text = t.name;
        cell.textLabel.textColor = [UIColor labelColor];
        // 副标题只列这个人素材包实际提供的项：遮罩 / 边框 / 阴影 / 角标
        cell.detailTextLabel.text = [self tb_assetSubtitleFor:t];
        cell.imageView.image = [self thumbFor:t];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

/// 素材包副标题：「遮罩 · 边框 · 阴影 · 角标」里实际有的项
- (NSString *)tb_assetSubtitleFor:(TBTheme *)t {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *it in [t availableAssetItems]) {
        NSString *title = it[@"title"];
        if (title.length) [names addObject:title];
    }
    if (!names.count) return @"素材包";
    return [names componentsJoinedByString:@" · "];
}

- (UIImage *)thumbFor:(TBTheme *)theme {
    CGFloat s = 46;
    // 0.15.57：2×2 拼图抽成公共函数（主页视觉与之前完全一致，详情页「图标预览」卡共用同一份）
    UIImage *cover = TBThemeFourUpImage(theme, s);
    if (!cover) return [UIImage systemImageNamed:@"square.grid.2x2"];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:s * 0.2237];
        [p addClip];
        [cover drawInRect:CGRectMake(0, 0, s, s)];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) return;   // 按钮行
    TBTheme *t = nil;
    if (indexPath.section == 0) {
        // 「当前使用」保持原样：直接进详情页（这一版不动它）
        NSString *active = [self activeThemeName];
        t = active ? [TBThemeScanner themeNamed:active] : nil;
        if (!t) return;
        @try {
            [self.navigationController pushViewController:[[TBThemeDetailController alloc] initWithTheme:t] animated:YES];
        } @catch (NSException *e) {
            [self alertTitle:[NSString stringWithFormat:@"详情页失败：%@", e.name ?: @"异常"]
                     message:[NSString stringWithFormat:@"%@", e.reason ?: @"(无原因)"]];
        }
        return;
    }
    // 组 1「主题」/ 组 2「素材」：点行 → 弹自定义底部抽屉（详情入口在抽屉里）
    NSArray<TBTheme *> *list = [self themesInSection:indexPath.section];
    t = (indexPath.row < (NSInteger)list.count) ? list[indexPath.row] : nil;
    if (!t) return;
    // 崩溃诊断：把异常原因直接弹出来（这段时间点卡片若闪退，这里能抓到真凶）
    @try {
        [self presentSheetForTheme:t];
    } @catch (NSException *e) {
        [self alertTitle:[NSString stringWithFormat:@"打开失败：%@", e.name ?: @"异常"]
                 message:[NSString stringWithFormat:@"%@", e.reason ?: @"(无原因)"]];
    }
}

#pragma mark - 底部抽屉

/// 点主题卡片：弹出抽屉（遮罩三选一 + 应用主题 + 详情）
- (void)presentSheetForTheme:(TBTheme *)theme {
    if (!theme) return;
    TBBottomSheetController *sheet = [[TBBottomSheetController alloc] initWithTheme:theme];
    __weak typeof(self) weakSelf = self;
    sheet.onApply = ^(TBTheme *t) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s.tableView reloadData];            // 刷新「当前使用」和右侧 ✓
        [TBToast showAppliedIn:s];           // 玻璃胶囊 toast（无按钮，1.5s 自动收起）
    };
    sheet.onCancelApply = ^(TBTheme *t) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s.tableView reloadData];
        [TBToast showCancelledIn:s];         // 「已取消」同一套胶囊
    };
    sheet.onDetail = ^(TBTheme *t) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s.navigationController pushViewController:[[TBThemeDetailController alloc] initWithTheme:t] animated:YES];
    };
    [sheet presentOver:self];
}

#pragma mark - 删除

/// 给这一行套上样式；找不到滑动容器返回 NO（外观与原来完全一致，只是把
/// 「找容器」这件事做得更彻底：cell / cell 的父视图 / 表格 / 整个窗口都试一遍）
+ (void)tb_installSwipeStyle {
    // ★★ 0.15.56：整段禁用。我们曾在 UISwipeActionPullView -layoutSubviews 里改它的子视图
    //    （想把左滑按钮做成玻璃），只要改动让 UIKit 数出来的按钮数对不上，就会抛
    //    NSInternalInconsistencyException: The swipe action count does not match the number
    //    of swipe action buttons —— 用户"任何一行左滑直接闪退"的真凶（换成原生
    //    editingStyle 也照样崩，因为崩的是这个 hook，不是 swipe action 本身）。
    TBLog2(@"[左滑] 已停用 UISwipeActionPullView 样式 hook（避免动作数校验崩溃）");
    return;
    static BOOL done = NO;
    if (done) return;
    done = YES;
    Class pull = NSClassFromString(@"UISwipeActionPullView");
    if (!pull) return;
    Method m = class_getInstanceMethod(pull, @selector(layoutSubviews));
    if (m) {
        o_swipePullLayout = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)tb_swipePullLayout);
    }
}

- (BOOL)styleSwipeForRowAtIndexPath:(NSIndexPath *)indexPath tableView:(UITableView *)tableView {
    // ★ 0.15.57：整个方法停用（只保留函数体做考古）。改滑动容器的子视图 = 左滑必崩，
    //   见上面 trailingSwipeActionsConfiguration 的注释。调用点也已删除，这里再加一道闸。
    TBLog2(@"[左滑] styleSwipeForRowAtIndexPath 已停用（不再改滑动容器）");
    return NO;
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UIView *root = cell ? (cell.superview ?: cell) : tableView;
    UIView *pull = nil;
    if (root) pull = TBFindSwipePullView(root, 0);
    if (!pull && cell) pull = TBFindSwipePullView(cell, 0);
    if (!pull) pull = TBFindSwipePullView(tableView, 0);
    if (!pull) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            pull = TBFindSwipePullView(w, 0);
            if (pull) break;
        }
    }
    if (!pull) return NO;
    TBStyleSwipePullView(pull);
    return YES;
}

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    // 右侧 ✓ 是 cell 的附件，不跟着 contentView 一起平移 → 滑开时会露在卡片外面，
    // 先收起来，滑完再恢复
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (cell) {
        static char kAccKey;
        objc_setAssociatedObject(cell, &kAccKey, @(cell.accessoryType),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    // ★ 0.15.57：这里原来还有一段「0.05 秒后调 styleSwipeForRowAtIndexPath 给滑动容器套玻璃」
    //   已经删掉。它会去改 UISwipeActionPullView 的子视图（改背景/圆角/字体色），而 UIKit 在
    //   swipe 事务收尾时会重新数按钮 —— 只要它数到的子视图和当初建 action 时不一致，就抛
    //   NSInternalInconsistencyException: The swipe action count does not match…
    //   左滑按钮现在就是系统原生的红色「删除」，不碰滑动容器，彻底消除这条崩溃路径。
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) return;
    static char kAccKey;
    NSNumber *acc = objc_getAssociatedObject(cell, &kAccKey);
    if (acc) {
        cell.accessoryType = (UITableViewCellAccessoryType)acc.integerValue;
        objc_setAssociatedObject(cell, &kAccKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// ── 左滑删除 ────────────────────────────────────────────────────────────────
// 崩溃根因（0.15.48 起）：在 swipe action 的 handler 里 present 模态（哪怕先用
// dispatch_async 推迟一拍）会打断 UIKit 的 swipe 提交事务，事务收尾时算出来的按钮数
// 对不上，抛 NSInternalInconsistencyException: The swipe action count does not match
// the number of swipe action buttons。后来换成原生 editingStyle + commitEditingStyle
// （里面 setEditing:NO）同样打断事务，一样崩。
//
// 现在这版必须同时满足三条，缺一不可：
//   ① handler 里【先同步】completionHandler(YES) ——  UIKit 当场把这次 swipe 事务收尾；
//   ② 真正的删除再 dispatch_async 到下一拍 —— 那时事务已结束，reloadData 不会打断它；
//   ③ 全程不 present 任何 VC（不用 UIAlertController，也不用 TBConfirmPanelController），
//      成功/失败都只用 TBToast 玻璃胶囊 + TBLog2。
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 2 && indexPath.section != 3) return nil;
    NSArray<TBTheme *> *list = [self themesInSection:indexPath.section];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)list.count) return nil;

    TBTheme *t = list[indexPath.row];
    NSString *identity = t.path.length ? t.path : (t.name ?: @"");
    NSInteger section = indexPath.section;
    NSInteger row = indexPath.row;
    TBLog2(@"[删除] 左滑 action「%@」section=%ld row=%ld path=%@",
           t.name ?: @"?", (long)section, (long)row, identity ?: @"(空)");

    __weak typeof(self) wself = self;
    UIContextualAction *del =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:@"删除"
                                              handler:^(UIContextualAction *action,
                                                        UIView *sourceView,
                                                        void (^completionHandler)(BOOL)) {
        // ① 先同步收尾：这一行必须在任何其它事情之前，且绝不能等 UI
        completionHandler(YES);
        // ② 下一拍再真正删除：那时 swipe 事务已经结束
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) s = wself;
            if (!s) return;
            [s tb_deleteThemeAtSection:section row:row identity:identity];
        });
    }];
    del.backgroundColor = [UIColor systemRedColor];

    UISwipeActionsConfiguration *cfg =
        [UISwipeActionsConfiguration configurationWithActions:@[del]];
    cfg.performsFirstActionWithFullSwipe = NO;   // 不做「整条滑到底直接删」，防误触
    return cfg;
}

/// 真正执行删除：跑在 swipe 事务结束后的那一拍；本方法绝不 present 任何 VC
- (void)tb_deleteThemeAtSection:(NSInteger)section row:(NSInteger)row identity:(NSString *)identity {
    // 行号可能已经变了（搜索 / 排序 / 刚删过一行），先用 row 取 + path 校验，再按 path 兜底找
    NSArray<TBTheme *> *now = [self themesInSection:section];
    TBTheme *cur = nil;
    if (row >= 0 && row < (NSInteger)now.count) {
        TBTheme *cand = now[row];
        if (!identity.length || [(cand.path ?: @"") isEqualToString:identity]) cur = cand;
    }
    if (!cur && identity.length) {
        for (TBTheme *cand in now) {
            if ([(cand.path ?: @"") isEqualToString:identity]) { cur = cand; break; }
        }
    }
    if (!cur) {
        TBLog2(@"[删除] 目标已不在列表（section=%ld row=%ld identity=%@），跳过",
               (long)section, (long)row, identity ?: @"(空)");
        [TBToast show:@"删除失败" icon:@"exclamationmark.triangle" in:self];
        return;
    }

    NSError *err = nil;
    BOOL deleted = [TBThemeScanner deleteTheme:cur error:&err];
    TBLog2(@"[删除] 结果 ok=%d err=%@（%@） path=%@", deleted,
           err.domain ?: @"-", err.localizedDescription ?: @"-", cur.path ?: @"-");
    if (!deleted) {
        // 失败也不弹模态：只 toast + 把完整原因写进日志（原来的自绘「删除失败」弹窗 0.15.57 移除）
        TBLog2(@"[删除] ❌ 失败详情 theme=%@ path=%@ errno=%@ userInfo=%@",
               cur.name ?: @"?", cur.path ?: @"-",
               err.userInfo[@"errno"] ?: @"-", err.userInfo ?: @{});
        [TBToast show:@"删除失败" icon:@"exclamationmark.triangle" in:self];
        return;
    }

    [self tb_clearPrefsPointingInto:cur.path];
    NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
    if ([active isEqualToString:cur.name]) [TBPrefs setString:nil forKey:TBKeyActiveTheme];
    [TBPrefs notifyChanged];
    [self reload];
    [TBToast show:@"已删除" icon:@"trash" in:self];
}

/// 删除后：把指向这个目录里的 Custom*Path 清掉并把对应开关关掉（否则设置里留着死路径）
- (void)tb_clearPrefsPointingInto:(NSString *)dir {
    if (!dir.length) return;
    NSString *prefix = [dir hasSuffix:@"/"] ? dir : [dir stringByAppendingString:@"/"];
    NSArray<NSArray<NSString *> *> *table = @[ @[@"CustomMaskPath", TBKeyUseThemeIconMask],
                                               @[@"CustomOverlayPath", TBKeyUseThemeIconOverlay],
                                               @[@"CustomShadowPath", TBKeyUseThemeIconShadow],
                                               @[@"CustomBadgePath", TBKeyUseThemeBadge] ];
    for (NSArray<NSString *> *row in table) {
        NSString *cur = [TBPrefs stringForKey:row[0]];
        if (cur.length && [cur hasPrefix:prefix]) {
            TBLog2(@"[删除] 清理偏好 %@（原值 %@）", row[0], cur);
            [TBPrefs setString:nil forKey:row[0]];
            [TBPrefs setBool:NO forKey:row[1]];
        }
    }
}


/// 主题包（2）和素材包（3）都可删除；其它行（当前使用 / 按钮行）不可

- (void)alertTitle:(NSString *)title message:(NSString *)msg {
    TBPresentAlert(self, title, msg);      // 自绘玻璃提示弹窗
}

@end
