#import "TBBottomSheetController.h"
#import "TBPrefs.h"
#import "TBGlass.h"
#import "TBTheme.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - 遮罩偏好键（键名必须与引擎 / 设置页完全一致）

static NSString *const kTBKeyUseThemeIconMask   = @"UseThemeIconMask";
static NSString *const kTBKeyMaskCornerRadiusOn = @"MaskCornerRadiusOn";
static NSString *const kTBKeyMaskCornerRadius   = @"MaskCornerRadius";
static NSString *const kTBKeyUseThemeIconOverlay = @"UseThemeIconOverlay";
static NSString *const kTBKeyUseThemeIconShadow  = @"UseThemeIconShadow";
static const double  kTBDefaultMaskCornerRadius = 13.42;   // 与设置页 / 引擎默认值一致

/// 抽屉里的三个遮罩选项（按钮 tag 就是这个顺序）
typedef NS_ENUM(NSInteger, TBSheetMaskMode) {
    TBSheetMaskModeSystem = 0,    // 系统形状：UseThemeIconMask=NO、MaskCornerRadiusOn=NO
    TBSheetMaskModeThemeMask,     // 主题遮罩图：UseThemeIconMask=YES、MaskCornerRadiusOn=NO
    TBSheetMaskModeCornerRadius,  // 自定义圆角：MaskCornerRadiusOn=YES、UseThemeIconMask=NO
};

#pragma mark - 几何 / 手感参数

// 高度：抽屉高度 = 内容实际高度（不再按屏高比例撑开，展开态下方不会再有空白）
static const CGFloat kTBSheetMaxRatio       = 0.88;  // 内容过高时的上限（相对屏高）
static const CGFloat kTBSheetTopPad         = 8.0;   // 内容顶部留白
static const CGFloat kTBSheetBottomPad      = 8.0;   // 内容底部留白（另加安全区）
static const CGFloat kTBRubberK             = 0.35;  // 橡皮筋阻尼系数（近处斜率 ≈ 0.35）
static const CGFloat kTBSnapVelocity        = 900.0; // 速度吸附阈值（pt/s）
static const CGFloat kTBSnapProjection      = 0.20;  // 速度投影时间（秒）：用落点预判吸哪个锚点
static const CGFloat kTBSpringDamping       = 0.88;  // 收尾弹簧阻尼比（越高越"稳"，不弹）
static const CGFloat kTBSpringDuration      = 0.34;  // 收尾弹簧时长
static const CGFloat kTBDimMaxAlpha         = 0.42;  // 遮罩最深的不透明度
static const CGFloat kTBSheetRadius         = 22.0;  // 抽屉顶部圆角
static const CGFloat kTBSheetPad            = 20.0;  // 左右内缩（与顶部工具条一致）
static const CGFloat kTBRowHeight           = 44.0;  // 与「重新扫描 / 导入主题 / 清除主题」同高
static const CGFloat kTBRowGap              = 10.0;

/// 把用户选中的图统一重绘成 PNG 当遮罩用：
///   ① 有透明通道 → 原样保留（SnowBoard 遮罩的标准形态）
///   ② 完全没有透明像素（JPG、无 alpha 的 PNG）→ 用亮度当 alpha：白留、黑裁，
///      这样"黑底白形状"的图也能直接当遮罩用
static NSData *TBThemeMaskPNGDataFromImage(UIImage *src) {
    if (!src) return nil;
    CGImageRef cg = src.CGImage;
    if (!cg) return nil;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 1 || h < 1) return nil;

    const size_t kMax = 1024;      // 遮罩不需要大图，顺便限制内存
    if (w > kMax || h > kMax) {
        CGFloat s = MIN((CGFloat)kMax / (CGFloat)w, (CGFloat)kMax / (CGFloat)h);
        w = MAX((size_t)1, (size_t)lround((double)w * s));
        h = MAX((size_t)1, (size_t)lround((double)h * s));
    }

    size_t bytes = w * h * 4;
    uint8_t *buf = (uint8_t *)calloc(bytes, 1);
    if (!buf) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return nil; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);

    BOOL anyTransparent = NO;
    for (size_t i = 0; i < bytes; i += 4) {
        if (buf[i + 3] < 250) { anyTransparent = YES; break; }
    }
    if (!anyTransparent) {
        for (size_t i = 0; i < bytes; i += 4) {
            double lum = 0.299 * buf[i] + 0.587 * buf[i + 1] + 0.114 * buf[i + 2];
            NSInteger a = (NSInteger)lround(lum);
            if (a < 0) a = 0;
            if (a > 255) a = 255;
            buf[i + 3] = (uint8_t)a;
        }
    }

    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!out) { free(buf); return nil; }
    UIImage *img = [UIImage imageWithCGImage:out];
    CGImageRelease(out);
    free(buf);
    return UIImagePNGRepresentation(img);
}

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

@interface TBBottomSheetController () <UIGestureRecognizerDelegate, UIDocumentPickerDelegate>

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
@property (nonatomic, strong) NSMutableArray<UIButton *> *fxButtons;   // 0=叠加层 1=阴影
@property (nonatomic, strong) NSMutableArray<UIImageView *> *fxChecks;
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) UIButton *importMaskButton;
@property (nonatomic, strong) UIButton *detailButton;

@property (nonatomic, strong) UIPanGestureRecognizer *pan;

/// 位移（正数 = 往下移；0 = 展开，sheetHeight = 收起）
@property (nonatomic, assign) CGFloat offset;
@property (nonatomic, assign) CGFloat dragStartOffset;
@property (nonatomic, assign) CGFloat sheetHeight;      // 展开态高度（= 内容高度）
@property (nonatomic, assign) CGFloat contentHeight;    // 内容实际需要的高度
@property (nonatomic, strong) NSArray<NSNumber *> *anchors;  // 位移锚点（升序：展开/中间/收起）
@property (nonatomic, assign) NSInteger anchorIndex;
@property (nonatomic, assign) BOOL appeared;
@property (nonatomic, assign) BOOL closing;

@property (nonatomic, strong) UIViewPropertyAnimator *animator;

/// 等待确认覆盖时暂存的用户选择（import 模式下是沙盒内的临时副本）
@property (nonatomic, strong) NSURL *pendingMaskURL;

@end

@implementation TBBottomSheetController

#pragma mark - 生命周期

- (instancetype)initWithTheme:(TBTheme *)theme {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _theme = theme;
        _optionButtons = [NSMutableArray array];
        _optionChecks = [NSMutableArray array];
        _fxButtons = [NSMutableArray array];
        _fxChecks = [NSMutableArray array];
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
    self.dimView.alpha = 0;   // 透明度只在动画块里改（拖动过程中不动它）
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

    // 5.5) 两个 AnemoneEffects 开关（叠加层 / 阴影）：同款玻璃按钮 + 开/关状态
    NSArray *fxTitles = @[@"叠加层", @"阴影"];
    for (NSInteger i = 0; i < (NSInteger)fxTitles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = i;
        [b setTitle:fxTitles[i] forState:UIControlStateNormal];
        TBApplyToolbarGlass(b, NO);
        [b addTarget:self action:@selector(fxTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.sheet addSubview:b];
        [self.fxButtons addObject:b];

        UIImageView *check = [[UIImageView alloc] initWithImage:
                              [[UIImage systemImageNamed:@"checkmark"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        check.tintColor = [UIColor systemBlueColor];
        check.contentMode = UIViewContentModeScaleAspectFit;
        check.hidden = YES;
        [b addSubview:check];
        [self.fxChecks addObject:check];
    }

    // 6) 底部一行三个入口：应用主题 / 导入遮罩 / 详情
    self.applyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.applyButton setTitle:@"应用主题" forState:UIControlStateNormal];
    TBApplyToolbarGlass(self.applyButton, NO);
    [self.applyButton addTarget:self action:@selector(applyTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.sheet addSubview:self.applyButton];

    self.importMaskButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.importMaskButton setTitle:@"导入遮罩" forState:UIControlStateNormal];
    TBApplyToolbarGlass(self.importMaskButton, NO);
    [self.importMaskButton addTarget:self action:@selector(importMaskTapped)
                            forControlEvents:UIControlEventTouchUpInside];
    [self.sheet addSubview:self.importMaskButton];

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
    for (UIButton *b in self.optionButtons) TBApplyToolbarGlass(b, NO);
    for (UIButton *b in self.fxButtons) TBApplyToolbarGlass(b, NO);
    TBApplyToolbarGlass(self.applyButton, NO);
    TBApplyToolbarGlass(self.importMaskButton, NO);
    TBApplyToolbarGlass(self.detailButton, NO);
    [self refreshOptionSelection];
}

/// 选中态：亮一点的白玻璃 + 蓝色描边 + 右侧对勾（看得出当前是哪一个）
- (void)tb_applySelectionStyle:(UIButton *)b selected:(BOOL)selected {
    UIImageView *check = (b.tag >= 0 && b.tag < (NSInteger)self.optionChecks.count) ? self.optionChecks[b.tag] : nil;
    [self tb_applySelectedLook:b selected:selected check:check];
}

/// 通用"选中"外观（蓝色描边 + 右侧对勾），check 由调用方给
- (void)tb_applySelectedLook:(UIButton *)b selected:(BOOL)selected check:(UIImageView *)check {
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
    check.hidden = !selected;
}

#pragma mark - 布局

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    if (W < 1 || H < 1) return;

    self.dimView.frame = self.view.bounds;

    // ---- 内容：按实际控件尺寸紧凑排布，算完得到内容高度 ----
    CGFloat pad = kTBSheetPad;
    CGFloat innerW = W - pad * 2;
    CGFloat y = kTBSheetTopPad;

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
    y += 12;

    // 叠加层 / 阴影：一行两个，各半宽
    CGFloat half = (innerW - kTBRowGap) / 2.0;
    if (self.fxButtons.count >= 2) {
        for (NSInteger i = 0; i < 2; i++) {
            UIButton *b = self.fxButtons[i];
            b.frame = CGRectMake(pad + i * (half + kTBRowGap), y, half, kTBRowHeight);
            UIImageView *check = self.fxChecks[i];
            check.frame = CGRectMake(half - 24, (kTBRowHeight - 18) / 2.0, 18, 18);
        }
        y += kTBRowHeight + kTBRowGap;
    }

    CGFloat third = (innerW - kTBRowGap * 2) / 3.0;
    self.applyButton.frame = CGRectMake(pad, y, third, kTBRowHeight);
    self.importMaskButton.frame = CGRectMake(pad + third + kTBRowGap, y, third, kTBRowHeight);
    self.detailButton.frame = CGRectMake(pad + (third + kTBRowGap) * 2, y, third, kTBRowHeight);
    y += kTBRowHeight;

    CGFloat safeBottom = MAX(self.view.safeAreaInsets.bottom, 10);
    self.contentHeight = y + safeBottom + kTBSheetBottomPad;

    // ---- 抽屉高度 = 内容高度（不再按屏高比例撑开 → 展开态下方不会剩一大段空白）----
    CGFloat maxH = round(H * kTBSheetMaxRatio);
    CGFloat expandedH = MIN(round(self.contentHeight), maxH);
    expandedH = MAX(expandedH, 200.0);
    self.sheetHeight = expandedH;

    self.sheet.frame = CGRectMake(0, H - expandedH, W, expandedH);
    self.hairline.frame = CGRectMake(0, 0, W, 1.0 / [UIScreen mainScreen].scale);

    // 锚点（位移，正数往下）：
    //   0              展开（抽屉顶贴到内容高度处）—— 就是"缩小后"的常态
    //   expandedH / 2  中间（只露出内容的一半）
    //   expandedH      收起（完全推出屏外）
    self.anchors = @[ @(0.0), @(round(expandedH * 0.5)), @(expandedH) ];

    // 动画中（含收起过程）不做模型回写，避免和弹簧/淡出打架导致闪一下
    if (self.animator || self.closing) return;
    if (!self.appeared) self.offset = expandedH;
    self.sheet.transform = CGAffineTransformMakeTranslation(0, self.offset);
    self.dimView.alpha = [self dimAlphaForOffset:self.offset];
}

#pragma mark - 遮罩选项

/// 当前是哪一个（读偏好，和引擎同一套判断优先级）
- (TBSheetMaskMode)currentMode {
    if ([TBPrefs boolForKey:kTBKeyUseThemeIconMask defaultValue:NO]) return TBSheetMaskModeThemeMask;
    if ([TBPrefs boolForKey:kTBKeyMaskCornerRadiusOn defaultValue:NO]) return TBSheetMaskModeCornerRadius;
    return TBSheetMaskModeSystem;
}

/// 主题里有没有「形状遮罩」（AnemoneEffects 的叠加层/阴影、icon_shortcut_mask 之类不算）
- (BOOL)tb_themeMaskAvailable {
    return [self.theme iconMaskPath].length > 0;
}

- (void)refreshOptionSelection {
    TBSheetMaskMode mode = [self currentMode];
    BOOL hasMask = [self tb_themeMaskAvailable];
    for (UIButton *b in self.optionButtons) {
        BOOL selected = (b.tag == (NSInteger)mode);
        [self tb_applySelectionStyle:b selected:selected];
        if (b.tag == (NSInteger)TBSheetMaskModeThemeMask && !hasMask && !selected) {
            // 主题没自带遮罩 → 这一项灰显（点了会给提示，见 optionTapped:）
            b.alpha = 0.45;
            [b setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
        } else {
            b.alpha = 1.0;
            [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        }
    }

    // 叠加层 / 阴影开关：主题里没有素材就灰显（点了会给提示）
    for (UIButton *b in self.fxButtons) {
        BOOL isOverlay = (b.tag == 0);
        NSString *base = isOverlay ? @"iPhoneOverlay" : @"iPhoneShadow";
        NSString *key = isOverlay ? kTBKeyUseThemeIconOverlay : kTBKeyUseThemeIconShadow;
        BOOL avail = [[self.theme anemoneEffectPath:base] length] > 0;
        BOOL on = [TBPrefs boolForKey:key defaultValue:NO];
        [b setTitle:[NSString stringWithFormat:@"%@：%@", (isOverlay ? @"叠加层" : @"阴影"), (on ? @"开" : @"关")]
            forState:UIControlStateNormal];
        UIImageView *check = (b.tag >= 0 && b.tag < (NSInteger)self.fxChecks.count) ? self.fxChecks[b.tag] : nil;
        if (avail) {
            [self tb_applySelectedLook:b selected:on check:check];
            b.alpha = 1.0;
            [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        } else {
            [self tb_applySelectedLook:b selected:NO check:check];
            b.alpha = 0.45;
            [b setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
        }
    }

    if (mode == TBSheetMaskModeThemeMask && hasMask) {
        self.hintLabel.text = @"图标遮罩：主题遮罩图中（点一下立即生效）";
    } else if (mode == TBSheetMaskModeThemeMask && !hasMask) {
        self.hintLabel.text = @"图标遮罩：主题里没有遮罩图，引擎会落到系统形状";
    } else if (hasMask) {
        self.hintLabel.text = @"图标遮罩：主题里已有遮罩图，可切到「主题遮罩图」";
    } else {
        self.hintLabel.text = @"图标遮罩：点一下立即生效，也可「导入遮罩」";
    }
}

- (void)optionTapped:(UIButton *)sender {
    TBSheetMaskMode mode = (TBSheetMaskMode)sender.tag;
    if (mode == TBSheetMaskModeThemeMask && ![self tb_themeMaskAvailable]) {
        [self tb_alert:@"这个主题没有自带遮罩"
               message:@"它里面没有形状遮罩文件（IconBundles/Icon.png、icon.png、AppIconMask* 等）。\n先点「导入遮罩」选一张图，再切到「主题遮罩图」。"];
        return;
    }
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

/// 叠加层 / 阴影开关：主题里真的没有素材就不动偏好，只给提示
- (void)fxTapped:(UIButton *)sender {
    BOOL isOverlay = (sender.tag == 0);
    NSString *base = isOverlay ? @"iPhoneOverlay" : @"iPhoneShadow";
    NSString *key = isOverlay ? kTBKeyUseThemeIconOverlay : kTBKeyUseThemeIconShadow;
    if ([[self.theme anemoneEffectPath:base] length] == 0) {
        [self tb_alert:(isOverlay ? @"这个主题没有叠加层素材" : @"这个主题没有阴影素材")
               message:[NSString stringWithFormat:
                        @"它里面没有 AnemoneEffects/%@.png（@3x / @2x / 无后缀都找过了）。\n开启也不会有任何变化，所以没有改动设置。", base]];
        return;
    }
    BOOL on = [TBPrefs boolForKey:key defaultValue:NO];
    [TBPrefs setBool:!on forKey:key];
    [TBPrefs notifyChanged];                 // 引擎立刻重画出图
    [self refreshOptionSelection];
}

#pragma mark - 导入遮罩

- (void)tb_alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

/// 大小写不敏感地在 base 下找一个已存在的子目录
static NSString *TBFindExistingSubdirCI(NSString *base, NSString *name) {
    if (!base.length || !name.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *item in [fm contentsOfDirectoryAtPath:base error:NULL]) {
        BOOL d = NO;
        NSString *full = [base stringByAppendingPathComponent:item];
        if ([fm fileExistsAtPath:full isDirectory:&d] && d &&
            [item caseInsensitiveCompare:name] == NSOrderedSame) return full;
    }
    return nil;
}

/// 点「导入遮罩」：选一张 PNG/JPG → 写进当前主题目录（经典 Anemone/WinterBoard 命名）
- (void)importMaskTapped {
    UIDocumentPickerViewController *picker = nil;
    @try {
        if (@available(iOS 14.0, *)) {
            picker = [[UIDocumentPickerViewController alloc]
                      initForOpeningContentTypes:@[UTTypePNG, UTTypeJPEG] asCopy:YES];
        } else {
            picker = [[UIDocumentPickerViewController alloc]
                      initWithDocumentTypes:@[@"public.png", @"public.jpeg"]
                                     inMode:UIDocumentPickerModeImport];
        }
    } @catch (NSException *e) {
        NSLog(@"[ThemeBoard] 遮罩 picker 创建失败: %@", e.reason);
        picker = nil;
    }
    if (!picker) { [self tb_alert:@"打不开" message:@"系统没有可用的图片选择器"]; return; }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    NSString *dir = self.theme.path;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (dir.length == 0 || ![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        [self tb_alert:@"导入失败" message:@"找不到主题目录，无法写入遮罩"];
        return;
    }
    if (![fm isWritableFileAtPath:dir]) {
        [self tb_alert:@"导入失败" message:[NSString stringWithFormat:@"主题目录不可写：\n%@", dir]];
        return;
    }

    // 落盘位置：经典 Anemone / WinterBoard 命名（引擎查找链最高优先级）
    NSArray<NSString *> *paths = [self tb_maskDestinationPaths];
    if (paths.count == 0) {
        [self tb_alert:@"导入失败" message:@"主题目录里建不出 IconBundles，无法写入遮罩"];
        return;
    }

    NSString *old = [self.theme iconMaskPath];   // 主题里已有的遮罩（任意一种命名）
    if (old.length) {                            // 已有旧遮罩 → 先问一句
        __weak typeof(self) wself = self;
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"覆盖已有遮罩？"
            message:[NSString stringWithFormat:@"主题里已经有一个遮罩图：\n%@\n\n继续会覆盖它。", old]
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"覆盖" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
            __strong typeof(self) sself = wself;
            if (sself) [sself tb_writeMaskFromURL:url toPaths:paths];
        }]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }
    [self tb_writeMaskFromURL:url toPaths:paths];
}

/// 导入遮罩的落盘位置（按引擎查找优先级）：
///   ① <主题>/IconBundles/Icon.png   经典 Anemone/WinterBoard 命名，引擎最高优先级
///   ② <主题>/IconBundles/icon.png  同上的小写写法，一起写一份更通用
///   ③ 若主题里已有 Bundles/com.apple.mobileicons.framework/
///      → 再写一份 AppIconMask@2x~iphone.png（经典 AppIconMask）
- (NSArray<NSString *> *)tb_maskDestinationPaths {
    NSString *dir = self.theme.path;
    if (!dir.length) return @[];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *out = [NSMutableArray array];

    NSString *ib = TBFindExistingSubdirCI(dir, @"IconBundles");
    if (!ib.length) {   // 目录不存在就按标准名创建
        ib = [dir stringByAppendingPathComponent:@"IconBundles"];
        [fm createDirectoryAtPath:ib withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    BOOL isDir = NO;
    if (ib.length && [fm fileExistsAtPath:ib isDirectory:&isDir] && isDir) {
        [out addObject:[ib stringByAppendingPathComponent:@"Icon.png"]];
        [out addObject:[ib stringByAppendingPathComponent:@"icon.png"]];
    }

    NSString *bundles = TBFindExistingSubdirCI(dir, @"Bundles");
    if (bundles.length) {
        NSString *fw = TBFindExistingSubdirCI(bundles, @"com.apple.mobileicons.framework");
        if (fw.length) {
            [out addObject:[fw stringByAppendingPathComponent:@"AppIconMask@2x~iphone.png"]];
        }
    }
    return out;
}

- (void)tb_writeMaskFromURL:(NSURL *)url toPaths:(NSArray<NSString *> *)paths {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *raw = [NSData dataWithContentsOfURL:url options:0 error:NULL];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (raw.length == 0) {
        [self tb_alert:@"导入失败" message:@"读不到选中的图片文件"];
        return;
    }
    UIImage *img = [UIImage imageWithData:raw];
    NSData *png = TBThemeMaskPNGDataFromImage(img);
    if (png.length == 0) {
        [self tb_alert:@"导入失败" message:@"这张图没法解析成遮罩（换一张 PNG/JPG 再试）"];
        return;
    }

    NSMutableArray<NSString *> *ok = [NSMutableArray array];
    NSMutableArray<NSString *> *bad = [NSMutableArray array];
    for (NSString *p in paths) {
        NSError *err = nil;
        if ([png writeToFile:p options:NSDataWritingAtomic error:&err]) [ok addObject:p];
        else [bad addObject:p];
    }

    if (ok.count == 0) {
        [self tb_alert:@"导入失败" message:[NSString stringWithFormat:
            @"没法写入主题目录（可能不可写）：\n%@", [bad componentsJoinedByString:@"\n"]]];
        return;
    }

    // 导入成功 → 自动切到「主题遮罩图」（关掉自定义圆角），并通知引擎
    [TBPrefs setBool:YES forKey:kTBKeyUseThemeIconMask];
    [TBPrefs setBool:NO forKey:kTBKeyMaskCornerRadiusOn];
    [TBPrefs notifyChanged];
    [self refreshOptionSelection];
    [self tb_refreshDynamicColors];

    NSMutableString *msg = [NSMutableString stringWithString:@"遮罩已写入当前主题，并已切换为「主题遮罩图」：\n"];
    [msg appendString:[ok componentsJoinedByString:@"\n"]];
    if (bad.count) [msg appendFormat:@"\n\n（以下位置写入失败）\n%@", [bad componentsJoinedByString:@"\n"]];
    [self tb_alert:@"导入成功" message:msg];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // 用户取消：什么都不做
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

/// 收起抽屉（弹簧滑到「收起」锚点，dim 与抽屉同一次动画一起收）→ 动画结束才 dismiss
- (void)closeThen:(void (^)(void))then {
    if (self.closing) return;
    self.closing = YES;
    __weak typeof(self) wself = self;
    [self animateToOffset:self.anchors.lastObject.doubleValue velocity:0 completion:^{
        __strong typeof(self) sself = wself;
        if (!sself) return;
        // 动画已经结束：抽屉和 dim 都在同一次动画里到了终点，这里直接摘掉
        sself.dimView.alpha = 0;
        sself.dimView.hidden = YES;
        [sself dismissViewControllerAnimated:NO completion:^{
            if (then) then();
        }];
    }];
}

#pragma mark - 拖动（橡皮筋 + 速度吸附 + 单一弹簧收尾）

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

/// dim 的不透明度：抽屉越低越淡，完全收起时是 0
- (CGFloat)dimAlphaForOffset:(CGFloat)offset {
    CGFloat hi = self.sheetHeight;
    if (hi < 1) return 0;
    if (offset >= hi - 0.5) return 0;
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
            // 跟手阶段只改 transform：不碰 alpha / hidden，也不做 layoutIfNeeded（保帧率）
            CGFloat raw = self.dragStartOffset + dy;
            self.offset = [self rubberBand:raw];
            self.sheet.transform = CGAffineTransformMakeTranslation(0, self.offset);
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
            sself.dimView.alpha = 0;
            sself.dimView.hidden = YES;
            [sself dismissViewControllerAnimated:NO completion:nil];   // 拖到底 = 关掉抽屉
        }
    }];
}

/// 收尾：一次弹簧动画（UIViewPropertyAnimator），抽屉位移和背景 alpha 在同一个动画块、
/// 同一时长、同一曲线 —— 不会出现「抽屉还在、背景已经透明」的一帧。
- (void)animateToOffset:(CGFloat)to velocity:(CGFloat)vy completion:(void (^)(void))done {
    if (self.animator) {          // 理论上不会重入，保险起见只保留最后一个
        [self.animator stopAnimation:NO];
        self.animator = nil;
        [self.sheet.layer removeAllAnimations];
        [self.dimView.layer removeAllAnimations];
    }
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
    // 高度已经压到内容高度，直接落到「展开」锚点就是紧凑的常态
    self.anchorIndex = 0;
    [self animateToOffset:[self.anchors.firstObject doubleValue] velocity:0 completion:nil];
}

@end
