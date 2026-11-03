#import <objc/runtime.h>
#import "TBThemeListController.h"
#import "TBThemeDetailController.h"
#import "TBThemeScanner.h"
#import "TBPrefs.h"
#import "TBGlass.h"
#import "TBBottomSheetController.h"
#import "TBTableViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
// 统一的文件夹选择器：iOS14+ 走 UTType，老系统回退；任何异常都不让它崩
static UIDocumentPickerViewController *TBNewFolderPicker(void) {
    @try {
        // 用旧的 Import 模式：系统会先把文件完整下载并复制到 App 的临时目录
        UIDocumentPickerViewController *p =
            [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.zip-archive", @"public.folder"]
                                                                    inMode:UIDocumentPickerModeImport];
        p.allowsMultipleSelection = NO;
        return p;
    } @catch (NSException *e) {
        NSLog(@"[ThemeBoard] picker 创建失败: %@", e.reason);
        return nil;
    }
}

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TBThemeListController () <UISearchResultsUpdating, UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<TBTheme *> *themes;
@property (nonatomic, strong) NSArray<TBTheme *> *filtered;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, assign) NSInteger sortMode;   // 0 名称 1 图标数
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

    UIBarButtonItem *sort = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                            style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(sortTapped)];
    self.navigationItem.rightBarButtonItems = @[sort];

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
    if (self.sortMode == 1) {
        base = [base sortedArrayUsingComparator:^NSComparisonResult(TBTheme *a, TBTheme *b) {
            [a loadIndex]; [b loadIndex];
            if (a.iconCount == b.iconCount) return [a.name caseInsensitiveCompare:b.name];
            return a.iconCount > b.iconCount ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    self.filtered = base;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    [self applyFilter];
}

- (void)sortTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"排序"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"按名称" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self.sortMode = 0; [self applyFilter];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"按图标数量" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self.sortMode = 1; [self applyFilter];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 导入

- (void)importTapped {
    UIDocumentPickerViewController *picker = TBNewFolderPicker();
    if (!picker) { [self alertTitle:@"打不开" message:@"系统没有可用的文件夹选择器"]; return; }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *err = nil;
    NSString *dst = [TBThemeScanner importFromAnyURL:url error:&err];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (dst) {
        [self reload];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导入完成"
            message:dst preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    } else {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导入失败"
            message:err.localizedDescription ?: @"未知错误" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

#pragma mark - 顶部工具条

- (UIView *)buildToolbarBar {
    CGFloat w = MAX(320.0, self.tableView.bounds.size.width);
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 56)];
    head.backgroundColor = [UIColor clearColor];
    head.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:head.leadingAnchor constant:20],
        [bar.trailingAnchor constraintEqualToAnchor:head.trailingAnchor constant:-20],
        [bar.topAnchor constraintEqualToAnchor:head.topAnchor constant:8],
        [bar.heightAnchor constraintEqualToConstant:44],
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
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:
                             [NSString stringWithFormat:@"清除「%@」？", active]
        message:@"桌面图标会恢复系统原样，主题文件夹不会被删除"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [TBPrefs setString:nil forKey:TBKeyActiveTheme];
        [TBPrefs notifyChanged];
        [self reload];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Table

- (NSString *)activeThemeName {
    return [TBPrefs stringForKey:TBKeyActiveTheme];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"当前使用";
    if (section == 1) return nil;
    return @"已安装主题";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 2) return nil;
    if (self.themes.count == 0) {
        NSArray *roots = [TBThemeScanner themeRoots];
        NSString *where = roots.count ? [roots componentsJoinedByString:@"\n"] : @"（没有可用的主题目录）";
        return [NSString stringWithFormat:@"还没有主题。点上面的「导入主题」，或把包含 IconBundles 的文件夹放到：\n%@", where];
    }
    return [NSString stringWithFormat:@"共 %lu 个 · 兼容 SnowBoard / Anemone 的 IconBundles 结构",
            (unsigned long)self.filtered.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 1) return 1;
    return section == 0 ? 1 : self.filtered.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 ? 62 : 76;
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
            [bar.topAnchor constraintEqualToAnchor:bc.contentView.topAnchor constant:4],
            [bar.heightAnchor constraintEqualToConstant:56],
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
        TBTheme *t = self.filtered[indexPath.row];
        [t loadIndex];
        cell.textLabel.text = t.name;
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个图标 · %lu 个文件",
                                     (unsigned long)t.iconCount, (unsigned long)t.fileCount];
        cell.imageView.image = [self thumbFor:t];
        cell.accessoryType = [[self activeThemeName] isEqualToString:t.name]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (UIImage *)thumbFor:(TBTheme *)theme {
    CGFloat s = 46;
    UIImage *cover = [theme coverImageWithSize:s];
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
        [self.navigationController pushViewController:[[TBThemeDetailController alloc] initWithTheme:t] animated:YES];
        return;
    }
    // 第 2 段「已安装主题」：点主题行 → 弹自定义底部抽屉（详情入口在抽屉里）
    t = self.filtered[indexPath.row];
    [self presentSheetForTheme:t];
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
        [s alertTitle:@"已应用"
               message:@"设置已写入。引擎生效后桌面会立即换图。"];
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
    // 原版：0.05 秒后给这一行套样式（现在 swizzle 也会套，这里保留做兜底）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self styleSwipeForRowAtIndexPath:indexPath tableView:tableView];
    });
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

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 2) return nil;
    TBTheme *t = self.filtered[indexPath.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                     title:@"删除"
                                                                   handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:
                                 [NSString stringWithFormat:@"删除「%@」？", t.name]
            message:@"主题文件夹会被直接删除，不可恢复" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { done(NO); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            NSError *err = nil;
            BOOL ok = [TBThemeScanner deleteTheme:t error:&err];
            if (ok) {
                NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
                if ([active isEqualToString:t.name]) [TBPrefs setString:nil forKey:TBKeyActiveTheme];
                [self reload];
            }
            done(ok);
        }]];
        [self presentViewController:ac animated:YES completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}


- (void)alertTitle:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
