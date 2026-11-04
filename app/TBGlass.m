#import "TBGlass.h"
#import <objc/runtime.h>

// 前置声明（这些函数定义在文件后半部分，视图子类要用）
static UIColor *TBPageTopColor(void);
static UIColor *TBPageBottomColor(void);
static UIColor *TBFillColor(void);
static UIColor *TBRimColor(CGFloat alpha);
void TBApplyRim(UIView *v, CGFloat alpha);

#pragma mark - 动态色视图（深浅色切换即时生效）

@interface TBGradientView : UIView
@end
@implementation TBGradientView {
    CAGradientLayer *_g;
    NSArray<UIView *> *_blobs;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _g = [CAGradientLayer layer];
        _g.startPoint = CGPointMake(0, 0);
        _g.endPoint = CGPointMake(1, 1);
        [self.layer addSublayer:_g];

        NSMutableArray *b = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectZero];
            dot.userInteractionEnabled = NO;
            dot.layer.cornerRadius = 220;
            dot.autoresizingMask = UIViewAutoresizingNone;
            [self addSubview:dot];
            [b addObject:dot];
        }
        _blobs = b;
        [self tb_update];
    }
    return self;
}

- (void)tb_update {
    _g.colors = @[ (id)TBPageTopColor().CGColor, (id)TBPageBottomColor().CGColor ];

    // 三个柔光斑（沿用旧版配色）
    NSArray *specs = @[ @[@(-0.15), @(-0.05), @(0.98), @(0.78), @(0.62)],
                        @[@( 0.55), @( 0.30), @(0.62), @(0.86), @(0.95)],
                        @[@( 0.15), @( 0.55), @(0.55), @(0.72), @(1.00)] ];
    for (NSUInteger i = 0; i < _blobs.count; i++) {
        NSArray *sp = specs[i];
        UIView *dot = _blobs[i];
        dot.backgroundColor = TBDynamicColor(
            [UIColor colorWithRed:[sp[2] doubleValue] green:[sp[3] doubleValue] blue:[sp[4] doubleValue] alpha:0.22],
            [UIColor colorWithRed:[sp[2] doubleValue] green:[sp[3] doubleValue] blue:[sp[4] doubleValue] alpha:0.14]);
        dot.tag = 1000 + (NSInteger)i;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    [super traitCollectionDidChange:prev];
    [self tb_update];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _g.frame = self.bounds;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    NSArray *specs = @[ @[@(-0.15), @(-0.05)], @[@(0.55), @(0.30)], @[@(0.15), @(0.55)] ];
    for (NSUInteger i = 0; i < _blobs.count; i++) {
        CGFloat x = [specs[i][0] doubleValue] * W;
        CGFloat y = [specs[i][1] doubleValue] * H;
        _blobs[i].frame = CGRectMake(x - 220, y - 220, 440, 440);
    }
}
@end

@interface TBGlassCardView : UIView
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) UIView *hl;
@end
@implementation TBGlassCardView
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    [super traitCollectionDidChange:prev];
    [self tb_refresh];
}
- (void)tb_refresh {
    self.fill.backgroundColor = TBFillColor();
    TBApplyRim(self, 0.92);
}
@end



UIColor *TBDynamicColor(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}


static UIColor *TBPageBaseColor(void) {
    return TBDynamicColor([UIColor colorWithRed:0.870 green:0.858 blue:0.843 alpha:1],
                           [UIColor colorWithRed:0.110 green:0.104 blue:0.120 alpha:1]);
}

// MarkFont 色板：浅色暖米白 / 深色 #1B191E
static UIColor *TBPageTopColor(void) {
    return TBDynamicColor([UIColor colorWithRed:0.898 green:0.886 blue:0.867 alpha:1],
                           [UIColor colorWithRed:0.125 green:0.118 blue:0.137 alpha:1]);
}
static UIColor *TBPageBottomColor(void) {
    return TBDynamicColor([UIColor colorWithRed:0.855 green:0.843 blue:0.827 alpha:1],
                           [UIColor colorWithRed:0.098 green:0.090 blue:0.110 alpha:1]);
}

static UIColor *TBFillColor(void) {
    return TBDynamicColor([UIColor colorWithWhite:1 alpha:0.34],
                          [UIColor colorWithWhite:1 alpha:0.10]);
}

static UIColor *TBRimColor(CGFloat alpha) {
    return TBDynamicColor([UIColor colorWithWhite:1 alpha:alpha],
                          [UIColor colorWithWhite:1 alpha:alpha * 0.30]);
}

void TBApplyRim(UIView *v, CGFloat alpha) {
    CGFloat scale = [UIScreen mainScreen].scale;
    v.layer.borderWidth = 1.0 / scale;
    v.layer.borderColor = TBRimColor(alpha).CGColor;
}

UIView *TBGlassCard(CGFloat radius) {
    TBGlassCardView *card = [[TBGlassCardView alloc] init];
    card.layer.cornerRadius = radius;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    card.backgroundColor = [UIColor clearColor];

    UIVisualEffectView *blur =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.userInteractionEnabled = NO;
    [card insertSubview:blur atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [blur.topAnchor constraintEqualToAnchor:card.topAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    UIView *fill = [[UIView alloc] init];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.userInteractionEnabled = NO;
    [card addSubview:fill];
    [NSLayoutConstraint activateConstraints:@[
        [fill.topAnchor constraintEqualToAnchor:card.topAnchor],
        [fill.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [fill.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    card.fill = fill;
    card.hl = nil;
    [card tb_refresh];
    return card;
}

UIButton *TBGlassButton(NSString *title, BOOL danger) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [b setTitleColor:danger ? [UIColor systemRedColor] : [UIColor labelColor] forState:UIControlStateNormal];
    b.backgroundColor = danger
        ? TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55], [UIColor colorWithWhite:1 alpha:0.10])
        : TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62], [UIColor colorWithWhite:1 alpha:0.14]);
    b.layer.cornerRadius = 24;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    TBApplyRim(b, 0.55);
    return b;
}

static UIImage *TBPagePatternImage(void) {
    static UIImage *light = nil, *dark = nil;
    BOOL isDark = (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    UIImage *cached = isDark ? dark : light;
    if (cached) return cached;

    CGSize size = [UIScreen mainScreen].bounds.size;
    if (size.width < 1) size = CGSizeMake(390, 844);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        UIColor *top = isDark ? [UIColor colorWithRed:0.125 green:0.118 blue:0.137 alpha:1]
                              : [UIColor colorWithRed:0.898 green:0.886 blue:0.867 alpha:1];
        UIColor *bot = isDark ? [UIColor colorWithRed:0.098 green:0.090 blue:0.110 alpha:1]
                              : [UIColor colorWithRed:0.855 green:0.843 blue:0.827 alpha:1];
        CGColorSpaceRef sp = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[8] = {0,0,0,0,0,0,0,0};
        const CGFloat *t = CGColorGetComponents(top.CGColor);
        const CGFloat *b = CGColorGetComponents(bot.CGColor);
        comps[0]=t[0]; comps[1]=t[1]; comps[2]=t[2]; comps[3]=1;
        comps[4]=b[0]; comps[5]=b[1]; comps[6]=b[2]; comps[7]=1;
        CGGradientRef grad = CGGradientCreateWithColorComponents(sp, comps, NULL, 2);
        CGContextDrawLinearGradient(c, grad, CGPointMake(0, 0), CGPointMake(size.width, size.height), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(sp);

        CGFloat alpha = isDark ? 0.18 : 0.30;
        CGColorSpaceRef sp2 = CGColorSpaceCreateDeviceRGB();
        NSArray *blobs = @[@[@(-0.15), @(-0.05), @(0.98), @(0.78), @(0.62)],
                           @[@( 0.55), @( 0.30), @(0.62), @(0.86), @(0.95)],
                           @[@( 0.15), @( 0.55), @(0.55), @(0.72), @(1.00)]];
        for (NSArray *bl in blobs) {
            CGPoint ctr = CGPointMake([bl[0] doubleValue] * size.width, [bl[1] doubleValue] * size.height);
            UIColor *col = [UIColor colorWithRed:[bl[2] doubleValue] green:[bl[3] doubleValue]
                                            blue:[bl[4] doubleValue] alpha:alpha];
            UIColor *clear = [col colorWithAlphaComponent:0.0];
            const CGFloat *cc = CGColorGetComponents(col.CGColor);
            const CGFloat *c0 = CGColorGetComponents(clear.CGColor);
            CGFloat comps[8] = { cc[0], cc[1], cc[2], cc[3], c0[0], c0[1], c0[2], 0.0 };
            CGGradientRef grad2 = CGGradientCreateWithColorComponents(sp2, comps, NULL, 2);
            CGContextDrawRadialGradient(c, grad2, ctr, 0, ctr, 260, 0);
            CGGradientRelease(grad2);
        }
        CGColorSpaceRelease(sp2);
    }];
    if (isDark) dark = img; else light = img;
    return img;
}

void TBApplyPageBackground(UIView *host) {
    if (!host) return;
    host.backgroundColor = TBPageBaseColor();
}

void TBSetPageBackground(UIViewController *vc) {
    if (!vc) return;
    vc.view.backgroundColor = TBPageBaseColor();
    if ([vc isKindOfClass:[UITableViewController class]]) {
        ((UITableViewController *)vc).tableView.backgroundColor = [UIColor clearColor];
    }
}

void TBAttachFrostContainer(UIView *host) {
    if (!host) return;
    host.backgroundColor = TBPageBaseColor();
}

void TBAttachWindowFrost(UIWindow *window) {
    if (!window) return;
    window.backgroundColor = TBPageBaseColor();
}

void TBAttachFrost(UIView *host) {
    host.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

UIView *TBGlassCellBG(CGFloat inset) {
    UIView *bg = [[UIView alloc] init];
    bg.backgroundColor = [UIColor clearColor];
    UIView *card = TBGlassCard(20);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [bg addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:bg.topAnchor constant:2],
        [card.bottomAnchor constraintEqualToAnchor:bg.bottomAnchor constant:-2],
        [card.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:inset],
        [card.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-inset],
    ]];
    return bg;
}

void TBGlassTable(UITableView *tv) {
    // 表格背景必须透明，否则它会盖住页面底色（默认是白色）
    // 页面底色由 TBSetPageBackground / TBTableViewController 的背景视图提供
    tv.backgroundColor = [UIColor clearColor];
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    tv.backgroundView = nil;
}

#pragma mark - 毛玻璃搜索框

/// 递归找 UISearchBar 里的输入框（层级随系统版本会变，所以按类找而不是按下标）
static UIView *TBFindSearchField(UIView *v, NSInteger depth) {
    if (!v || depth > 6) return nil;
    NSArray *kids = [[v subviews] copy];
    for (UIView *s in kids) {
        if ([s isKindOfClass:[UITextField class]]) return s;
        UIView *r = TBFindSearchField(s, depth + 1);
        if (r) return r;
    }
    return nil;
}

static const void *kTBSearchGlassKey = &kTBSearchGlassKey;
static const void *kTBSBStyledKey = &kTBSBStyledKey;   // searchBar 级外观只设一次的标记
static const void *kTBSearchPHKey = &kTBSearchPHKey;   // placeholder 颜色只设一次的标记

void TBStyleSearchBarGlass(UISearchBar *sb) {
    if (!sb) return;
    // ① 干掉系统那块灰底（背景图 + material 底）。
    // ★ 改成「变化才写」：本函数由 layoutSubviews swizzle 驱动，每帧都会进来；
    //   每帧重设 backgroundImage/searchBarStyle 这类属性会让 UISearchBar 在自己的
    //   layoutSubviews 里再触发布局（聚焦动画宽度变化时轻则抖动，重则布局循环），
    //   UISearchBar 子类继承 swizzle 后还会被反复放大。背景图没法比较，用关联标记只设一次。
    NSNumber *styled = objc_getAssociatedObject(sb, kTBSBStyledKey);
    if (!styled.boolValue) {
        sb.backgroundImage = [UIImage new];
        objc_setAssociatedObject(sb, kTBSBStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (sb.searchBarStyle != UISearchBarStyleMinimal) sb.searchBarStyle = UISearchBarStyleMinimal;
    if (![sb.barTintColor isEqual:[UIColor clearColor]]) sb.barTintColor = [UIColor clearColor];
    if (![sb.backgroundColor isEqual:[UIColor clearColor]]) sb.backgroundColor = [UIColor clearColor];
    if (sb.showsCancelButton) sb.showsCancelButton = NO;   // ★ 不要系统的「取消」按钮（用户要求删掉；万一系统在聚焦流程里再打开也能随时压回去）
    if ([sb respondsToSelector:@selector(setShowsScopeBar:)] && sb.showsScopeBar) sb.showsScopeBar = NO;

    UITextField *tf = (UITextField *)TBFindSearchField(sb, 0);
    if (!tf) return;                       // 还没建出输入框 → 等下一次布局
    tf.backgroundColor = [UIColor clearColor];
    tf.borderStyle = UITextBorderStyleNone;
    tf.textColor = [UIColor labelColor];
    // ★ 0.15.54：彻底不动 leftView / rightView / paddingLeft / paddingRight。
    //   之前的 KVC 改内边距方案会在聚焦动画期间和系统自己的内边距动画互相覆盖，
    //   文字照样会「动一下」（本轮用户实测的最后一个问题）。现在文字布局 100% 交给系统，
    //   我们只在底下垫一层玻璃，视觉不变、也不可能有跳动。
    // 0.15.53：placeholder 用次要标签色（之前跟随系统默认灰，玻璃底上显得又黑又挤）。
    // attributedPlaceholder 带动态色，深浅色模式自动跟随；关联标记保证只设一次不每帧重建。
    if (tf.placeholder.length && !objc_getAssociatedObject(tf, kTBSearchPHKey)) {
        NSDictionary *attrs = @{NSForegroundColorAttributeName: [UIColor secondaryLabelColor]};
        tf.attributedPlaceholder =
            [[NSAttributedString alloc] initWithString:tf.placeholder attributes:attrs];
        objc_setAssociatedObject(tf, kTBSearchPHKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    UIView *glass = objc_getAssociatedObject(tf, kTBSearchGlassKey);
    if (!glass) {
        // ② 自绘玻璃底：SystemThinMaterial + 白填充 + 1px 亮边（与玻璃卡片同一套观感）
        glass = [[UIView alloc] initWithFrame:tf.frame];
        glass.userInteractionEnabled = NO;
        glass.clipsToBounds = YES;
        glass.backgroundColor = [UIColor clearColor];
        glass.layer.cornerCurve = kCACornerCurveContinuous;

        UIVisualEffectView *mat = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        mat.translatesAutoresizingMaskIntoConstraints = NO;
        mat.userInteractionEnabled = NO;
        [glass addSubview:mat];

        UIView *fill = [[UIView alloc] init];
        fill.translatesAutoresizingMaskIntoConstraints = NO;
        fill.userInteractionEnabled = NO;
        fill.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                              [UIColor colorWithWhite:1 alpha:0.12]);
        [glass addSubview:fill];

        [NSLayoutConstraint activateConstraints:@[
            [mat.topAnchor constraintEqualToAnchor:glass.topAnchor],
            [mat.leadingAnchor constraintEqualToAnchor:glass.leadingAnchor],
            [mat.trailingAnchor constraintEqualToAnchor:glass.trailingAnchor],
            [mat.bottomAnchor constraintEqualToAnchor:glass.bottomAnchor],
            [fill.topAnchor constraintEqualToAnchor:glass.topAnchor],
            [fill.leadingAnchor constraintEqualToAnchor:glass.leadingAnchor],
            [fill.trailingAnchor constraintEqualToAnchor:glass.trailingAnchor],
            [fill.bottomAnchor constraintEqualToAnchor:glass.bottomAnchor],
        ]];
        TBApplyRim(glass, 0.55);
        objc_setAssociatedObject(tf, kTBSearchGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (tf.superview) [tf.superview insertSubview:glass belowSubview:tf];
    }
    if (tf.superview && glass.superview != tf.superview) {   // 换过父视图 → 跟着搬
        [glass removeFromSuperview];
        [tf.superview insertSubview:glass belowSubview:tf];
    }

    // ③ 每帧贴合输入框：圆角 = 高/2
    CGRect f = tf.frame;
    if (f.size.height < 2) return;
    // ★ 搜索框"文字会动"的真凶：glass 跟随 tf.frame 时落在系统的聚焦动画 block 里，
    //   隐式动画让玻璃底从旧位置滑到新位置，视觉上就像"字在动"。这里禁掉隐式动画。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    glass.frame = f;
    glass.layer.cornerRadius = f.size.height / 2.0;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [CATransaction commit];
}

static void (*o_searchBarLayout)(id, SEL);
static void tb_searchBarLayout(id self, SEL _cmd) {
    if (o_searchBarLayout) o_searchBarLayout(self, _cmd);
    if ([self isKindOfClass:[UISearchBar class]]) TBStyleSearchBarGlass((UISearchBar *)self);
}

void TBInstallGlassSearchBars(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    Method m = class_getInstanceMethod([UISearchBar class], @selector(layoutSubviews));
    if (m) {
        o_searchBarLayout = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)tb_searchBarLayout);
    }
}
