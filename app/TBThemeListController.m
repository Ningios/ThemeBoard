#import <objc/runtime.h>
#import "TBThemeListController.h"
#import "TBThemeDetailController.h"
#import "TBThemeScanner.h"
#import "TBPrefs.h"
#import "TBGlass.h"
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

@interface TBThemeListController () <UISearchResultsUpdating, UIDocumentPickerDelegate,
                                   UIGestureRecognizerDelegate>
@property (nonatomic, strong) NSArray<TBTheme *> *themes;
@property (nonatomic, strong) NSArray<TBTheme *> *filtered;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, assign) NSInteger sortMode;   // 0 名称 1 图标数
@end

static char kTBSwipeKey;

@interface TBSwipeState : NSObject
@property (nonatomic, weak) UITableViewCell *cell;
@property (nonatomic, weak) UIView *pill;
@property (nonatomic, copy) NSString *themeName;
@property (nonatomic, assign) CGFloat offset;
@end
@implementation TBSwipeState
@end

/// 把卡片（背景视图）和内容一起平移；删除块固定在 cell 上，不跟着走
static void TBApplySwipeOffset(TBSwipeState *st, CGFloat x) {
    if (!st.cell) return;
    st.offset = x;
    st.pill.hidden = (x > -6);
    CGAffineTransform tr = CGAffineTransformMakeTranslation(x, 0);
    st.cell.contentView.transform = tr;
    st.cell.backgroundView.transform = tr;
}


@implementation TBThemeListController

- (void)viewDidLoad {
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
        cell.backgroundView = TBGlassCellBG(12);
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
        [self tb_swipeAttachToCell:cell theme:t];
    } else {
        [self tb_swipeDetachFromCell:cell];
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
    // 滑开状态下的点击 = 收起，不跳详情
    UITableViewCell *sc = [tableView cellForRowAtIndexPath:indexPath];
    TBSwipeState *sst = sc ? objc_getAssociatedObject(sc, &kTBSwipeKey) : nil;
    if (sst && sst.offset < -1) {
        [UIView animateWithDuration:0.25 animations:^{ TBApplySwipeOffset(sst, 0); }];
        return;
    }
    TBTheme *t = nil;
    if (indexPath.section == 0) {
        NSString *active = [self activeThemeName];
        t = active ? [TBThemeScanner themeNamed:active] : nil;
        if (!t) return;
    } else {
        t = self.filtered[indexPath.row];
    }
    [self.navigationController pushViewController:[[TBThemeDetailController alloc] initWithTheme:t] animated:YES];
}

#pragma mark - 玻璃左滑删除（参考 MarkFont：自己做平移手势 + 圆角玻璃块，不碰系统滑动）

- (void)tb_swipeAttachToCell:(UITableViewCell *)cell theme:(TBTheme *)theme {
    TBSwipeState *st = objc_getAssociatedObject(cell, &kTBSwipeKey);
    if (!st) {
        st = [[TBSwipeState alloc] init];
        st.cell = cell;
        objc_setAssociatedObject(cell, &kTBSwipeKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 删除块：尺寸/圆角/位置都跟左边卡片一致 —— 高 = 行高 - 4（卡片上下各缩 2pt）、
        // 右边缩 12pt、圆角 20（TBGlassCellBG 的规格），玻璃底 + 真模糊 + 红字
        UIView *pill = [[UIView alloc] initWithFrame:CGRectZero];
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        pill.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                              [UIColor colorWithWhite:1 alpha:0.14]);
        pill.layer.cornerRadius = 20;
        pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        pill.layer.borderColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                                [UIColor colorWithWhite:1 alpha:0.20]).CGColor;
        [cell addSubview:pill];

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        blur.translatesAutoresizingMaskIntoConstraints = NO;
        blur.layer.cornerRadius = 20;
        blur.layer.cornerCurve = kCACornerCurveContinuous;
        blur.clipsToBounds = YES;
        blur.userInteractionEnabled = NO;
        [pill addSubview:blur];

        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
        lab.translatesAutoresizingMaskIntoConstraints = NO;
        lab.text = @"删除";
        lab.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        lab.textColor = [UIColor systemRedColor];
        [pill addSubview:lab];

        [NSLayoutConstraint activateConstraints:@[
            [blur.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor],
            [blur.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor],
            [blur.topAnchor constraintEqualToAnchor:pill.topAnchor],
            [blur.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor],
            [lab.centerXAnchor constraintEqualToAnchor:pill.centerXAnchor],
            [lab.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
            [pill.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [pill.heightAnchor constraintEqualToAnchor:cell.contentView.heightAnchor constant:-4],
            [pill.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12],
            [pill.widthAnchor constraintEqualToConstant:92],
        ]];
        pill.hidden = YES;
        st.pill = pill;

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tb_pillTapped:)];
        [pill addGestureRecognizer:tap];

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(tb_cardPan:)];
        pan.delegate = self;
        [cell.contentView addGestureRecognizer:pan];
    }
    st.themeName = theme.name;
    TBApplySwipeOffset(st, 0);   // 复用的 cell 先归位
}

- (void)tb_swipeDetachFromCell:(UITableViewCell *)cell {
    TBSwipeState *st = objc_getAssociatedObject(cell, &kTBSwipeKey);
    if (!st) return;
    st.themeName = nil;
    TBApplySwipeOffset(st, 0);
    st.pill.hidden = YES;
}

#pragma mark - 手势

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if ([g isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:g.view];
        return fabs(v.x) > fabs(v.y);   // 只接横向滑动，纵向留给表格滚动
    }
    return YES;
}

- (void)tb_cardPan:(UIPanGestureRecognizer *)pan {
    UIView *cv = pan.view;
    UITableViewCell *cell = (UITableViewCell *)cv.superview;
    if (![cell isKindOfClass:[UITableViewCell class]]) return;
    TBSwipeState *st = objc_getAssociatedObject(cell, &kTBSwipeKey);
    if (!st) return;

    CGPoint t = [pan translationInView:cv];
    [pan setTranslation:CGPointZero inView:cv];
    CGFloat x = st.offset + t.x;
    if (x > 0) x = 0;
    if (x < -110) x = -110;

    if (pan.state == UIGestureRecognizerStateChanged) {
        TBApplySwipeOffset(st, x);
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat target = (x < -46) ? -104.0 : 0.0;
        [UIView animateWithDuration:0.28 delay:0
             usingSpringWithDamping:0.85 initialSpringVelocity:0.3
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ TBApplySwipeOffset(st, target); }
                         completion:nil];
    }
}

- (void)tb_pillTapped:(UITapGestureRecognizer *)g {
    UIView *pill = g.view;
    UITableViewCell *cell = (UITableViewCell *)pill.superview;
    TBSwipeState *st = cell ? objc_getAssociatedObject(cell, &kTBSwipeKey) : nil;
    if (!st.themeName.length) return;
    TBTheme *t = [TBThemeScanner themeNamed:st.themeName];
    if (!t) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:
                             [NSString stringWithFormat:@"删除「%@」？", t.name]
        message:@"主题文件夹会被直接删除，不可恢复" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        NSError *err = nil;
        BOOL ok = [TBThemeScanner deleteTheme:t error:&err];
        if (ok) {
            NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
            if ([active isEqualToString:t.name]) [TBPrefs setString:nil forKey:TBKeyActiveTheme];
            [self reload];
        }
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

/// 系统自带的滑动删除整个关掉（灰底/方角/时机问题都来自它）
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    return nil;
}


- (void)alertTitle:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
