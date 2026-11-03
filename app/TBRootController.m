#import "TBRootController.h"
#import "TBThemeListController.h"
#import "TBSettingsController.h"
#import "TBStatusController.h"
#import "TBGlass.h"
#import "TBToast.h"

// ---- Tab 切换动画参数（水滴胶囊，总时长 400ms）----
static const NSTimeInterval kTBTabTotal       = 0.40;   // 胶囊总时长
static const NSTimeInterval kTBTabStretch     = 0.26;   // 前段：拉伸 + 位移到目标中心
static const NSTimeInterval kTBTabCollect     = 0.14;   // 后段：收宽 + 回弹（合计 400ms）
static const CGFloat        kTBTabStretchDamp = 1.00;   // 前段不弹（匀速到位，前沿先到）
static const CGFloat        kTBTabSettleDamp  = 0.82;   // 后段轻微回弹
static const CGFloat        kTBTabSquash      = 0.92;   // 高度变扁 8%
static const CGFloat        kTBTabIconPeak    = 0.86;   // 新图标先缩到 0.86
static const CGFloat        kTBTabIconDamp    = 0.75;   // 图标回弹阻尼
static const NSTimeInterval kTBTabTextDur     = 0.40;   // 文字颜色渐变
static const NSTimeInterval kTBTabPageDur     = 0.35;   // 页面移入/移出
static const CGFloat        kTBTabPageShift   = 12.0;   // 页面水平位移（pt）

@interface TBRootController ()
@property (nonatomic, strong) NSArray<UIViewController *> *pages;
@property (nonatomic, strong) UIView *dock;
@property (nonatomic, strong) NSArray<UIButton *> *dockButtons;
@property (nonatomic, strong) UIView *pill;              // 选中的「水滴」胶囊色块
@property (nonatomic, assign) NSInteger current;
@property (nonatomic, strong) UIViewPropertyAnimator *pillAnimator;
@property (nonatomic, assign) BOOL switching;
@end

@implementation TBRootController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    TBThemeListController *themes = [[TBThemeListController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav1 = [[UINavigationController alloc] initWithRootViewController:themes];

    TBSettingsController *settings = [[TBSettingsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav2 = [[UINavigationController alloc] initWithRootViewController:settings];

    TBStatusController *status = [[TBStatusController alloc] init];
    UINavigationController *nav3 = [[UINavigationController alloc] initWithRootViewController:status];

    // 导航栏全透明，磨砂从 window 透上来
    UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
    [ap configureWithTransparentBackground];
    ap.backgroundColor = [UIColor clearColor];
    ap.shadowColor = [UIColor clearColor];
    for (UINavigationController *nav in @[nav1, nav2, nav3]) {
        nav.navigationBar.standardAppearance = ap;
        nav.navigationBar.scrollEdgeAppearance = ap;
        nav.navigationBar.compactAppearance = ap;
        nav.navigationBar.translucent = YES;
    }

    for (UINavigationController *nav in @[nav1, nav2, nav3]) {
        nav.view.backgroundColor = [UIColor clearColor];
        TBAttachFrostContainer(nav.view);
    }

    self.pages = @[nav1, nav2, nav3];

    for (UIViewController *vc in self.pages) {
        [self addChildViewController:vc];
        vc.view.frame = self.view.bounds;
        vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        vc.view.hidden = YES;
        [self.view addSubview:vc.view];
        [vc didMoveToParentViewController:self];
    }
    self.pages.firstObject.view.hidden = NO;
    self.current = 0;

    [self buildDock];
    [self relayout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self relayout];
}

- (void)relayout {
    CGFloat bottomInset = 86;
    for (UIViewController *vc in self.pages) {
        vc.additionalSafeAreaInsets = UIEdgeInsetsMake(0, 0, bottomInset, 0);
        vc.view.frame = self.view.bounds;
    }
    // 胶囊色块跟着 dock 的尺寸走（旋转 / 尺寸变化时直接落到当前 Tab，不做动画）
    if (self.pill && self.dockButtons.count) {
        self.pill.frame = [self pillFrameForTab:self.current];
    }
}

#pragma mark - 底部 dock

- (void)buildDock {
    CGFloat h = 64, margin = 18;
    UIView *dock = [[UIView alloc] initWithFrame:CGRectMake(margin, self.view.bounds.size.height - h - 34,
                                                          self.view.bounds.size.width - margin * 2, h)];
    dock.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    dock.layer.cornerRadius = h / 2;
    dock.layer.cornerCurve = kCACornerCurveContinuous;
    dock.clipsToBounds = YES;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    blur.frame = dock.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [dock addSubview:blur];

    UIView *fill = [[UIView alloc] initWithFrame:dock.bounds];
    fill.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    fill.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                          [UIColor colorWithWhite:1 alpha:0.12]);
    fill.userInteractionEnabled = NO;
    [dock addSubview:fill];
    TBApplyRim(dock, 0.55);

    NSArray *titles = @[@"主题", @"设置", @"状态"];
    NSArray *icons = @[@"square.grid.2x2.fill", @"slider.horizontal.3", @"waveform.path.ecg"];
    NSMutableArray *btns = [NSMutableArray array];

    // 「水滴」胶囊色块：垫在图标/文字下面，随 Tab 移动
    CGFloat w = dock.bounds.size.width / titles.count;
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(4, 4, w - 8, h - 8)];
    pill.layer.cornerRadius = (h - 8) / 2.0;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.42],
                                           [UIColor colorWithWhite:1 alpha:0.13]);
    pill.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    pill.layer.borderColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                            [UIColor colorWithWhite:1 alpha:0.18]).CGColor;
    pill.userInteractionEnabled = NO;
    [dock addSubview:pill];
    self.pill = pill;

    for (NSInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(i * w, 0, w, h);
        b.tag = i;
        [b addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icons[i]]];
        iv.tag = 101;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.frame = CGRectMake(w / 2 - 11, 12, 22, 22);
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 36, w, 14)];
        lb.tag = 102;
        lb.text = titles[i];
        lb.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.userInteractionEnabled = NO;
        [b addSubview:lb];

        [dock addSubview:b];
        [btns addObject:b];
    }

    self.dock = dock;
    self.dockButtons = btns;
    [self.view addSubview:dock];
    [self refreshDock];
}

/// 某个 Tab 的胶囊色块目标 frame（dock 内坐标）
- (CGRect)pillFrameForTab:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.dockButtons.count) idx = 0;
    UIButton *b = self.dockButtons[idx];
    if (!self.dock) return b.frame;
    return CGRectMake(CGRectGetMinX(b.frame) + 4, 4,
                      CGRectGetWidth(b.frame) - 8, CGRectGetHeight(self.dock.bounds) - 8);
}

/// 静止态刷新：选中项亮、其余暗（首帧 / 旋转时用，不带动画）
- (void)refreshDock {
    for (UIButton *b in self.dockButtons) {
        BOOL on = (b.tag == self.current);
        UIColor *c = on ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        ((UIImageView *)[b viewWithTag:101]).tintColor = c;
        ((UILabel *)[b viewWithTag:102]).textColor = c;
        b.alpha = on ? 1.0 : 0.75;
        ((UIImageView *)[b viewWithTag:101]).transform = CGAffineTransformIdentity;
    }
}

#pragma mark - Tab 切换（水滴：前沿先到、后沿慢半拍 + 轻微回弹，共 400ms）

- (void)tabTapped:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx == self.current) {
        UINavigationController *nav = (UINavigationController *)self.pages[idx];
        [nav popToRootViewControllerAnimated:YES];
        return;
    }
    [self tb_switchToTab:idx];
}

- (void)tb_switchToTab:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.pages.count) return;
    NSInteger from = self.current;
    if (idx == from) return;

    [TBToast dismissNow];        // 切页时不要留旧 toast

    UIViewController *old = self.pages[from];
    UIViewController *now = self.pages[idx];
    CGFloat dir = (idx > from) ? 1.0 : -1.0;    // 新页面从点击方向进来

    // 快速连点时先归一化其他页，避免上一次动画留下的半透明/位移残留
    for (UIViewController *vc in self.pages) {
        if (vc == now || vc == old) continue;
        vc.view.hidden = YES;
        vc.view.alpha = 1.0;
        vc.view.transform = CGAffineTransformIdentity;
    }

    // ---- 1) 新页面：从点击方向偏移 12pt 移入并淡入（0.35s）；旧页面反向轻推淡出 ----
    now.view.hidden = NO;
    [now.view setNeedsLayout];
    [now.view layoutIfNeeded];
    now.view.alpha = 0.0;
    now.view.transform = CGAffineTransformMakeTranslation(kTBTabPageShift * dir, 0);

    __weak typeof(self) wself = self;
    [UIView animateWithDuration:kTBTabPageDur
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        __strong typeof(self) s = wself;
        if (!s) return;
        now.view.alpha = 1.0;
        now.view.transform = CGAffineTransformIdentity;
        old.view.alpha = 0.0;
        old.view.transform = CGAffineTransformMakeTranslation(-kTBTabPageShift * dir, 0);
    } completion:^(BOOL finished) {
        __strong typeof(self) s = wself;
        if (!s) return;
        // 连点时上一轮的旧页可能已经是当前页，别再把它藏起来
        if (s.pages[s.current].view != old.view) old.view.hidden = YES;
        old.view.alpha = 1.0;
        old.view.transform = CGAffineTransformIdentity;
    }];

    // ---- 2) 文字颜色：旧 → 未选中色，新 → 选中色，400ms 交叉渐变 ----
    for (UIButton *b in self.dockButtons) {
        BOOL on = (b.tag == idx);
        UILabel *lb = (UILabel *)[b viewWithTag:102];
        UIImageView *iv = (UIImageView *)[b viewWithTag:101];
        UIColor *c = on ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        [UIView transitionWithView:lb duration:kTBTabTextDur
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionBeginFromCurrentState
                        animations:^{ lb.textColor = c; } completion:nil];
        [UIView transitionWithView:iv duration:kTBTabTextDur
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionBeginFromCurrentState
                        animations:^{ iv.tintColor = c; } completion:nil];
        [UIView animateWithDuration:kTBTabTotal
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ b.alpha = on ? 1.0 : 0.75; }
                         completion:nil];
    }

    // ---- 3) 图标：新选中图标先缩到 0.86 再弹回 1.0（damping 0.75，与胶囊同步）----
    UIImageView *newIcon = (UIImageView *)[self.dockButtons[idx] viewWithTag:101];
    newIcon.transform = CGAffineTransformMakeScale(kTBTabIconPeak, kTBTabIconPeak);
    UISpringTimingParameters *iconSpring =
        [[UISpringTimingParameters alloc] initWithDampingRatio:kTBTabIconDamp];
    UIViewPropertyAnimator *iconAnim =
        [[UIViewPropertyAnimator alloc] initWithDuration:kTBTabTotal timingParameters:iconSpring];
    [iconAnim addAnimations:^{
        newIcon.transform = CGAffineTransformIdentity;
    }];
    [iconAnim startAnimation];

    // ---- 4) 胶囊色块：前沿先到、后沿慢半拍（宽度先拉长再收回）、高度压扁 8%、回弹停稳 ----
    [self tb_animatePillFromTab:from toTab:idx];

    self.current = idx;
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [g impactOccurred];
}

/// 胶囊两段式动画：
///   前段 260ms —— 从旧位置拉伸到「旧 ∪ 新」的合并区间，并整体位移到新 Tab 中心（高度压扁 8%）
///   后段 140ms —— 宽度收回到目标胶囊、高度回弹（damping 0.82）
/// 合计 400ms，全程用系统 UIViewPropertyAnimator + 弹簧时序，无第三方库。
- (void)tb_animatePillFromTab:(NSInteger)from toTab:(NSInteger)to {
    if (!self.pill || ![self.dockButtons count]) return;

    CGRect a = [self pillFrameForTab:from];
    CGRect b = [self pillFrameForTab:to];
    CALayer *pres = self.pill.layer.presentationLayer;
    CGRect nowFrame = pres ? pres.frame : self.pill.frame;

    // 打断上一次（快速连点）：先落到看得见的位置，避免跳变
    if (self.pillAnimator) {
        [self.pillAnimator stopAnimation:NO];
        self.pillAnimator = nil;
    }
    [self.pill.layer removeAllAnimations];
    self.pill.frame = nowFrame;      // 落到看得见的位置再重新起跑
    self.switching = YES;

    // 合并区间（拉伸段）：取两者并集，保证「前沿先到、后沿慢半拍」
    CGFloat left  = MIN(CGRectGetMinX(nowFrame), MIN(CGRectGetMinX(a), CGRectGetMinX(b)));
    CGFloat right = MAX(CGRectGetMaxX(nowFrame), MAX(CGRectGetMaxX(a), CGRectGetMaxX(b)));
    CGFloat midY  = CGRectGetMidY(b);
    CGFloat h     = CGRectGetHeight(b) * kTBTabSquash;   // 高度压扁 8%
    CGRect stretch = CGRectMake(left, midY - h / 2.0, right - left, h);

    __weak typeof(self) wself = self;
    UISpringTimingParameters *p1 =
        [[UISpringTimingParameters alloc] initWithDampingRatio:kTBTabStretchDamp];
    UIViewPropertyAnimator *a1 = [[UIViewPropertyAnimator alloc] initWithDuration:kTBTabStretch
                                                               timingParameters:p1];
    self.pillAnimator = a1;
    [a1 addAnimations:^{
        __strong typeof(self) s = wself;
        if (!s) return;
        s.pill.frame = stretch;    // 前沿先冲到目标、后沿还在原地 → 视觉上拉长
    }];
    [a1 addCompletion:^(UIViewAnimatingPosition pos) {
        __strong typeof(self) s = wself;
        if (!s) return;
        if (pos != UIViewAnimatingPositionEnd) { s.switching = NO; return; }

        UISpringTimingParameters *p2 =
            [[UISpringTimingParameters alloc] initWithDampingRatio:kTBTabSettleDamp];
        UIViewPropertyAnimator *a2 = [[UIViewPropertyAnimator alloc] initWithDuration:kTBTabCollect
                                                                   timingParameters:p2];
        s.pillAnimator = a2;
        [a2 addAnimations:^{
            s.pill.frame = b;      // 收宽 + 高度回弹，轻微停稳
        }];
        [a2 addCompletion:^(UIViewAnimatingPosition p) {
            __strong typeof(self) ss = s;
            if (!ss) return;
            ss.switching = NO;
            if (ss.pillAnimator == a2) ss.pillAnimator = nil;
            ss.pill.frame = b;
        }];
        [a2 startAnimation];
    }];
    [a1 startAnimation];
}

@end