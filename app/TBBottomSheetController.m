#import "TBBottomSheetController.h"
#import "TBPrefs.h"
#import "TBGlass.h"
#import "TBTheme.h"

#pragma mark - 遮罩偏好键（键名必须与引擎 / 设置页完全一致）

static NSString *const kTBKeyUseThemeIconMask   = @"UseThemeIconMask";
static NSString *const kTBKeyMaskCornerRadiusOn = @"MaskCornerRadiusOn";
static NSString *const kTBKeyMaskCornerRadius   = @"MaskCornerRadius";
static const double  kTBDefaultMaskCornerRadius = 13.42;   // 与设置页 / 引擎默认值一致

/// 抽屉里的三个遮罩选项（按钮 tag 就是这个顺序）
typedef NS_ENUM(NSInteger, TBSheetMaskMode) {
    TBSheetMaskModeSystem = 0,    // 系统形状：UseThemeIconMask=NO、MaskCornerRadiusOn=NO
    TBSheetMaskModeThemeMask,     // 主题遮罩图：UseThemeIconMask=YES、MaskCornerRadiusOn=NO
    TBSheetMaskModeCornerRadius,  // 自定义圆角：MaskCornerRadiusOn=YES、UseThemeIconMask=NO
};

#pragma mark - 几何 / 手感参数

static const CGFloat kTBSheetExpandedRatio  = 0.85;  // 展开锚点：屏高 85%
static const CGFloat kTBSheetMiddleRatio    = 0.45;  // 中间锚点：屏高 45%（内容更高时按内容撑开）
static const CGFloat kTBRubberK             = 0.35;  // 橡皮筋阻尼系数（近处斜率 ≈ 0.35）
static const CGFloat kTBSnapVelocity        = 900.0; // 速度吸附阈值（pt/s）
static const CGFloat kTBSnapProjection      = 0.22;  // 速度投影时间（秒）：用落点预判吸哪个锚点
static const CGFloat kTBSpringDamping       = 0.78;  // 收尾弹簧阻尼比
static const CGFloat kTBSpringDuration      = 0.40;  // 收尾弹簧时长
static const CGFloat kTBDimMaxAlpha         = 0.42;  // 遮罩最深的不透明度
static const CGFloat kTBSheetRadius         = 22.0;  // 抽屉顶部圆角
static const CGFloat kTBSheetPad            = 20.0;  // 左右内缩（与顶部工具条一致）
static const CGFloat kTBRowHeight           = 44.0;  // 与「重新扫描 / 导入主题 / 清除主题」同高
static const CGFloat kTBRowGap              = 10.0;

#pragma mark - 同款玻璃按钮

/// 和顶部工具条那三个按钮完全同款：圆角 13、高 44、16 号半粗、白色玻璃底 + 细白边
static void TBApplyToolbarGlass(UIButton *b, BOOL danger) {
    b.translatesAutoresizingMaskIntoConstraints = YES;   // 抽屉里走手动布局
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [b setTitleColor:(danger ? [UIColor systemRedColor] : [UIColor labelColor])
            forState:UIControlStateNormal];
    b.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                       [UIColor colorWithWhite:1 alpha:0.14]);
    b.layer.cornerRadius = 13;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    TBApplyRim(b, 0.55);
}

@interface TBBottomSheetController () <UIGestureRecognizerDelegate>

@property (nonatomic, strong) TBTheme *theme;

@property (nonatomic, strong) UIView *dimView;      // 半透明黑色遮罩（点它收起）
@property (nonatomic, strong) UIView *sheet;        // 抽屉本体（位置靠 transform 位移控制）
@property (nonatomic, strong) UIView *sheetFillView;
@property (nonatomic, strong) UIView *hairline;

@property (nonatomic, strong) UIView *handle;       // 顶部拖拽指示条
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *hintLabel;

@property (nonatomic, strong) NSMutableArray<UIButton *> *optionButtons;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *optionChecks;
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) UIButton *detailButton;

@property (nonatomic, strong) UIPanGestureRecognizer *pan;

/// 位移（正数 = 往下移；0 = 展开，sheetHeight = 收起）
@property (nonatomic, assign) CGFloat offset;
@property (nonatomic, assign) CGFloat dragStartOffset;
@property (nonatomic, assign) CGFloat sheetHeight;      // 展开态高度
@property (nonatomic, assign) CGFloat contentHeight;    // 内容实际需要的高度
@property (nonatomic, strong) NSArray<NSNumber *> *anchors;  // 位移锚点（升序：展开/中间/收起）
@property (nonatomic, assign) NSInteger anchorIndex;
@property (nonatomic, assign) BOOL appeared;
@property (nonatomic, assign) BOOL closing;

@property (nonatomic, strong) UIViewPropertyAnimator *animator;

@end

@implementation TBBottomSheetController

#pragma mark - 生命周期

- (instancetype)initWithTheme:(TBTheme *)theme {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _theme = theme;
        _optionButtons = [NSMutableArray array];
        _optionChecks = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.clipsToBounds = YES;

    // 1) 遮罩：半透明黑，点一下收起抽屉
    self.dimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimView.backgroundColor = [UIColor blackColor];
    self.dimView.alpha = 0;   // 透明度跟着抽屉位移走
    [self.view addSubview:self.dimView];
    [self.dimView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(dimTapped)]];

    // 2) 抽屉本体：磨砂 + 半透明填充 + 顶部圆角
    self.sheet = [[UIView alloc] initWithFrame:CGRectZero];
    self.sheet.backgroundColor = [UIColor clearColor];
    self.sheet.layer.cornerRadius = kTBSheetRadius;
    self.sheet.layer.cornerCurve = kCACornerCurveContinuous;
    self.sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.sheet.clipsToBounds = YES;
    [self.view addSubview:self.sheet];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
                                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    blur.frame = self.sheet.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [self.sheet addSubview:blur];

    self.sheetFillView = [[UIView alloc] initWithFrame:self.sheet.bounds];
    self.sheetFillView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.sheetFillView.userInteractionEnabled = NO;
    [self.sheet addSubview:self.sheetFillView];

    self.hairline = [[UIView alloc] initWithFrame:CGRectZero];
    self.hairline.userInteractionEnabled = NO;
    [self.sheet addSubview:self.hairline];

    // 3) 拖拽指示条
    self.handle = [[UIView alloc] initWithFrame:CGRectZero];
    self.handle.userInteractionEnabled = NO;
    self.handle.layer.cornerRadius = 2.5;
    [self.sheet addSubview:self.handle];

    // 4) 标题 + 说明
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.sheet addSubview:self.titleLabel];

    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    self.hintLabel.text = @"图标遮罩：点一下立即生效";
    [self.sheet addSubview:self.hintLabel];

    // 5) 三个遮罩选项（同款玻璃按钮，选中态用蓝色描边 + 右侧对勾）
    NSArray *titles = @[@"系统形状", @"主题遮罩图", @"自定义圆角"];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = i;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        TBApplyToolbarGlass(b, NO);
        [b addTarget:self action:@selector(optionTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.sheet addSubview:b];
        [self.optionButtons addObject:b];

        UIImageView *check = [[UIImageView alloc] initWithImage:
                              [[UIImage systemImageNamed:@"checkmark"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        check.tintColor = [UIColor systemBlueColor];
        check.contentMode = UIViewContentModeScaleAspectFit;
        check.hidden = YES;
        [b addSubview:check];
        [self.optionChecks addObject:check];
    }

    // 6) 两个必要入口：应用主题（沿用详情页那套写法）/ 详情
    self.applyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.applyButton setTitle:@"应用主题" forState:UIControlStateNormal];
    TBApplyToolbarGlass(self.applyButton, NO);
    [self.applyButton addTarget:self action:@selector(applyTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.sheet addSubview:self.applyButton];

    self.detailButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.detailButton setTitle:@"详情" forState:UIControlStateNormal];
    TBApplyToolbarGlass(self.detailButton, NO);
    [self.detailButton addTarget:self action:@selector(detailTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.sheet addSubview:self.detailButton];

    // 7) 拖拽手势：作用在抽屉整块上（落在按钮上也算，拖动会顺手取消按钮的高亮）
    self.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    self.pan.delegate = self;
    [self.sheet addGestureRecognizer:self.pan];

    self.titleLabel.text = self.theme.name.length ? self.theme.name : @"主题";
    self.offset = 10000.0;      // 出场前先藏在屏外，首帧不会闪
    self.sheet.transform = CGAffineTransformMakeTranslation(0, self.offset);

    [self refreshOptionSelection];
    [self tb_refreshDynamicColors];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self tb_refreshDynamicColors];
}

/// 深浅色切换时重新解一次动态色（按钮底、玻璃填充、指示条等）
- (void)tb_refreshDynamicColors {
    self.sheetFillView.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                                        [UIColor colorWithWhite:0.10 alpha:0.62]);
    self.hairline.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                                   [UIColor colorWithWhite:1 alpha:0.20]);
    self.handle.backgroundColor = TBDynamicColor([UIColor colorWithWhite:0 alpha:0.18],
                                                 [UIColor colorWithWhite:1 alpha:0.35]);
    for (UIButton *b in self.optionButtons) {
        BOOL selected = (b.tag == (NSInteger)[self currentMode]);
        TBApplyToolbarGlass(b, NO);
        [self tb_applySelectionStyle:b selected:selected];
    }
    TBApplyToolbarGlass(self.applyButton, NO);
    TBApplyToolbarGlass(self.detailButton, NO);
}

/// 选中态：亮一点的白玻璃 + 蓝色描边 + 右侧对勾（看得出当前是哪一个）
- (void)tb_applySelectionStyle:(UIButton *)b selected:(BOOL)selected {
    if (selected) {
        b.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.88],
                                           [UIColor colorWithWhite:1 alpha:0.26]);
        b.layer.borderWidth = 2.0;
        b.layer.borderColor = [UIColor systemBlueColor].CGColor;
    } else {
        b.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                           [UIColor colorWithWhite:1 alpha:0.14]);
        b.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        b.layer.borderColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                             [UIColor colorWithWhite:1 alpha:0.20]).CGColor;
    }
    UIImageView *check = (b.tag >= 0 && b.tag < (NSInteger)self.optionChecks.count) ? self.optionChecks[b.tag] : nil;
    check.hidden = !selected;
}

#pragma mark - 布局

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    if (W < 1 || H < 1) return;

    self.dimView.frame = self.view.bounds;

    // 抽屉固定按「展开」高度摆好，上下移动全靠 transform（拖动时不会牵扯内容重排）
    CGFloat expandedH = round(H * kTBSheetExpandedRatio);
    self.sheetHeight = expandedH;
    self.sheet.frame = CGRectMake(0, H - expandedH, W, expandedH);
    self.hairline.frame = CGRectMake(0, 0, W, 1.0 / [UIScreen mainScreen].scale);

    CGFloat pad = kTBSheetPad;
    CGFloat innerW = W - pad * 2;
    CGFloat y = 8;

    self.handle.frame = CGRectMake((W - 36) / 2.0, y, 36, 5);
    y += 5 + 12;

    self.titleLabel.frame = CGRectMake(pad, y, innerW, 20);
    y += 22;

    self.hintLabel.frame = CGRectMake(pad, y, innerW, 16);
    y += 20;

    for (UIButton *b in self.optionButtons) {
        b.frame = CGRectMake(pad, y, innerW, kTBRowHeight);
        UIImageView *check = self.optionChecks[b.tag];
        check.frame = CGRectMake(innerW - 30, (kTBRowHeight - 18) / 2.0, 18, 18);
        y += kTBRowHeight + kTBRowGap;
    }
    y -= kTBRowGap;
    y += 14;

    CGFloat half = (innerW - kTBRowGap) / 2.0;
    self.applyButton.frame = CGRectMake(pad, y, half, kTBRowHeight);
    self.detailButton.frame = CGRectMake(pad + half + kTBRowGap, y, half, kTBRowHeight);
    y += kTBRowHeight;

    CGFloat bottom = MAX(self.view.safeAreaInsets.bottom, 10) + 8;
    self.contentHeight = y + bottom;

    // 锚点（位移，正数往下）：
    //   0        展开（抽屉顶贴到屏高 15% 处）
    //   midOff   中间（可见高度 ≈ 屏高 45%，内容更高时按内容撑开）
    //   expH     收起（完全推出屏外）
    CGFloat midVis = MAX(H * kTBSheetMiddleRatio, self.contentHeight);
    midVis = MIN(midVis, expandedH);
    self.anchors = @[ @(0.0), @(expandedH - midVis), @(expandedH) ];

    // 动画中不做布局回写，避免和弹簧打架；静止时才把模型对齐到当前锚点
    if (!self.animator) {
        if (!self.appeared) self.offset = expandedH;
        self.sheet.transform = CGAffineTransformMakeTranslation(0, self.offset);
        self.dimView.alpha = [self dimAlphaForOffset:self.offset];
    }
}

#pragma mark - 遮罩选项

/// 当前是哪一个（读偏好，和引擎同一套判断优先级）
- (TBSheetMaskMode)currentMode {
    if ([TBPrefs boolForKey:kTBKeyUseThemeIconMask defaultValue:NO]) return TBSheetMaskModeThemeMask;
    if ([TBPrefs boolForKey:kTBKeyMaskCornerRadiusOn defaultValue:NO]) return TBSheetMaskModeCornerRadius;
    return TBSheetMaskModeSystem;
}

- (void)refreshOptionSelection {
    TBSheetMaskMode mode = [self currentMode];
    for (UIButton *b in self.optionButtons) {
        [self tb_applySelectionStyle:b selected:(b.tag == (NSInteger)mode)];
    }
}

- (void)optionTapped:(UIButton *)sender {
    TBSheetMaskMode mode = (TBSheetMaskMode)sender.tag;
    switch (mode) {
        case TBSheetMaskModeSystem:
            [TBPrefs setBool:NO forKey:kTBKeyUseThemeIconMask];
            [TBPrefs setBool:NO forKey:kTBKeyMaskCornerRadiusOn];
            break;
        case TBSheetMaskModeThemeMask:
            [TBPrefs setBool:YES forKey:kTBKeyUseThemeIconMask];
            [TBPrefs setBool:NO forKey:kTBKeyMaskCornerRadiusOn];
            break;
        case TBSheetMaskModeCornerRadius: {
            [TBPrefs setBool:NO forKey:kTBKeyUseThemeIconMask];
            [TBPrefs setBool:YES forKey:kTBKeyMaskCornerRadiusOn];
            // 半径必须有合法值，没设过就补默认 13.42（引擎自己会夹到 宽/2）
            double r = [TBPrefs doubleForKey:kTBKeyMaskCornerRadius defaultValue:kTBDefaultMaskCornerRadius];
            if (!(r > 0.0)) r = kTBDefaultMaskCornerRadius;
            [TBPrefs setDouble:r forKey:kTBKeyMaskCornerRadius];
            break;
        }
    }
    [TBPrefs notifyChanged];      // 立刻通知引擎重画
    [self refreshOptionSelection];
}

#pragma mark - 应用 / 详情

- (void)applyTapped {
    // 与详情页「应用这个主题」完全一致：写主题名 + 总开关，然后通知引擎
    [TBPrefs setString:self.theme.name forKey:TBKeyActiveTheme];
    [TBPrefs setBool:YES forKey:TBKeyEnabled];
    [TBPrefs notifyChanged];
    __weak typeof(self) wself = self;
    [self closeThen:^{
        if (wself.onApply) wself.onApply(wself.theme);
    }];
}

- (void)detailTapped {
    __weak typeof(self) wself = self;
    [self closeThen:^{
        if (wself.onDetail) wself.onDetail(wself.theme);
    }];
}

- (void)dimTapped {
    [self closeThen:nil];
}

/// 收起抽屉（弹簧滑到「收起」锚点）→ dismiss → 再回调
- (void)closeThen:(void (^)(void))then {
    if (self.closing) return;
    self.closing = YES;
    __weak typeof(self) wself = self;
    [self animateToOffset:self.anchors.lastObject.doubleValue velocity:0 completion:^{
        __strong typeof(self) sself = wself;
        if (!sself) return;
        [sself dismissViewControllerAnimated:NO completion:^{
            if (then) then();
        }];
    }];
}

#pragma mark - 拖动（橡皮筋 + 速度吸附 + 弹簧）

/// 阻尼橡皮筋：越过边界后按经典 1 - 1/(over*k+1) 衰减，
/// 近处斜率 ≈ k(0.35)，越拖越沉、永远拖不飞
- (CGFloat)rubberBand:(CGFloat)raw {
    CGFloat lo = self.anchors.firstObject.doubleValue;   // 展开
    CGFloat hi = self.anchors.lastObject.doubleValue;    // 收起
    CGFloat dim = MAX(1.0, self.sheetHeight);
    if (raw < lo) {
        CGFloat over = lo - raw;
        return lo - (over * dim * kTBRubberK) / (dim + kTBRubberK * over);
    }
    if (raw > hi) {
        CGFloat over = raw - hi;
        return hi + (over * dim * kTBRubberK) / (dim + kTBRubberK * over);
    }
    return raw;
}

- (NSInteger)nearestAnchorForOffset:(CGFloat)offset {
    NSInteger best = 0;
    CGFloat bestDist = CGFLOAT_MAX;
    for (NSInteger i = 0; i < (NSInteger)self.anchors.count; i++) {
        CGFloat d = fabs(self.anchors[i].doubleValue - offset);
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

- (CGFloat)dimAlphaForOffset:(CGFloat)offset {
    CGFloat hi = self.sheetHeight;
    if (hi < 1) return 0;
    if (offset >= hi - 0.5) return 0;                       // 完全收起 → 遮罩一起淡掉
    CGFloat p = 1.0 - MAX(0.0, MIN(1.0, offset / hi));      // 0=收起 1=展开
    return kTBDimMaxAlpha * (0.55 + 0.45 * p);
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint v = [pan velocityInView:self.view];
    CGFloat dy = [pan translationInView:self.view].y;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            // 动画中途接管：先冻结在「看得见的那个位置」
            [self freezeAtVisualOffset];
            self.dragStartOffset = self.offset;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGFloat raw = self.dragStartOffset + dy;
            self.offset = [self rubberBand:raw];
            [self applyOffsetToSheet];
            break;
        }
        default: {   // ended / cancelled / failed
            CGFloat vy = v.y;
            CGFloat projected = self.offset + vy * kTBSnapProjection;   // 用落点预判
            NSInteger cur = [self nearestAnchorForOffset:self.offset];
            NSInteger want = [self nearestAnchorForOffset:projected];
            // 速度大 → 至少顺方向走一格（"甩"出去）；速度小 → 就近吸附
            if (vy > kTBSnapVelocity && want <= cur) want = MIN(cur + 1, (NSInteger)self.anchors.count - 1);
            if (vy < -kTBSnapVelocity && want >= cur) want = MAX(cur - 1, 0);
            [self settleToAnchor:want velocity:vy];
            break;
        }
    }
}

/// 停止在飞的动画，并把模型值对齐到当前视觉位置（避免接管瞬间跳变）
- (void)freezeAtVisualOffset {
    if (self.animator) {
        [self.animator stopAnimation:NO];
        self.animator = nil;
    }
    CALayer *pl = self.sheet.layer.presentationLayer;
    CALayer *dl = self.dimView.layer.presentationLayer;
    CGFloat visualOffset = pl ? pl.transform.m42 : self.offset;
    CGFloat visualAlpha  = dl ? dl.opacity : self.dimView.alpha;

    self.offset = visualOffset;
    self.sheet.transform = CGAffineTransformMakeTranslation(0, visualOffset);
    self.dimView.alpha = visualAlpha;
    [self.sheet.layer removeAllAnimations];
    [self.dimView.layer removeAllAnimations];
}

- (void)applyOffsetToSheet {
    self.sheet.transform = CGAffineTransformMakeTranslation(0, self.offset);
    self.dimView.alpha = [self dimAlphaForOffset:self.offset];
}

- (void)settleToAnchor:(NSInteger)idx velocity:(CGFloat)vy {
    idx = MAX(0, MIN(idx, (NSInteger)self.anchors.count - 1));
    self.anchorIndex = idx;
    BOOL collapsing = (idx == (NSInteger)self.anchors.count - 1);
    __weak typeof(self) wself = self;
    [self animateToOffset:self.anchors[idx].doubleValue velocity:vy completion:^{
        __strong typeof(self) sself = wself;
        if (!sself) return;
        if (collapsing && !sself.closing) {
            sself.closing = YES;
            [sself dismissViewControllerAnimated:NO completion:nil];   // 拖到底 = 关掉抽屉
        }
    }];
}

/// 弹簧收尾：UISpringTimingParameters + UIViewPropertyAnimator
/// 初速度用「每秒剩余距离的比例」表达，方向跟随 vy
- (void)animateToOffset:(CGFloat)to velocity:(CGFloat)vy completion:(void (^)(void))done {
    [self freezeAtVisualOffset];
    CGFloat from = self.offset;
    CGFloat dist = to - from;
    CGFloat normalized = (fabs(dist) > 1.0) ? (vy / fabs(dist)) : 0.0;
    normalized = MAX(-24.0, MIN(24.0, normalized));

    UISpringTimingParameters *spring =
        [[UISpringTimingParameters alloc] initWithDampingRatio:kTBSpringDamping
                                               initialVelocity:CGVectorMake(0, normalized)];
    UIViewPropertyAnimator *an = [[UIViewPropertyAnimator alloc] initWithDuration:kTBSpringDuration
                                                                 timingParameters:spring];
    self.animator = an;
    [an addAnimations:^{
        self.offset = to;
        self.sheet.transform = CGAffineTransformMakeTranslation(0, to);
        self.dimView.alpha = [self dimAlphaForOffset:to];
    }];
    __weak typeof(self) wself = self;
    [an addCompletion:^(UIViewAnimatingPosition position) {
        __strong typeof(self) sself = wself;
        if (!sself) return;
        sself.animator = nil;
        if (position == UIViewAnimatingPositionEnd) {
            sself.offset = to;
            if (done) done();
        }
    }];
    [an startAnimation];
}

#pragma mark - 出现 / 消失

- (void)presentOver:(UIViewController *)host {
    if (!host) return;
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;   // 不用 UISheetPresentationController
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [host presentViewController:self animated:NO completion:^{
        [self animateIn];
    }];
}

- (void)animateIn {
    [self.view layoutIfNeeded];       // 先把几何算出来（锚点在这里生成）
    self.appeared = YES;
    self.offset = self.sheetHeight;   // 从屏外开始
    self.sheet.transform = CGAffineTransformMakeTranslation(0, self.offset);
    self.dimView.alpha = 0;
    self.anchorIndex = 1;
    [self animateToOffset:[self.anchors[1] doubleValue] velocity:0 completion:nil];   // 落到「中间」锚点
}

@end
