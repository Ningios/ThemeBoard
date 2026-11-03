#import "TBToast.h"
#import "TBGlass.h"

// 高度 / 内边距（设计参数固定）
static const CGFloat kTBToastHeight     = 48.0;
static const CGFloat kTBToastPadX       = 22.0;
static const CGFloat kTBToastIconSize   = 14.0;
static const CGFloat kTBToastIconGap    = 7.0;
static const CGFloat kTBToastDockH      = 64.0;   // 与 TBRootController 的 dock 一致
static const CGFloat kTBToastDockBottom = 34.0;   // 与 TBRootController 的 dock 下边距一致
static const CGFloat kTBToastDockGap    = 16.0;   // Tab 栏上方再留 16

static const NSTimeInterval kTBToastInDuration  = 0.32;
static const CGFloat        kTBToastInDamping   = 0.78;
static const NSTimeInterval kTBToastHold        = 1.5;
static const NSTimeInterval kTBToastOutDuration = 0.25;
static const CGFloat        kTBToastOutDamping  = 0.90;

static TBToast *_gToast = nil;
static NSInteger _gToastGen = 0;

@interface TBToastView : UIView
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, assign) NSInteger gen;
@end

@implementation TBToastView

- (instancetype)initWithText:(NSString *)text icon:(NSString *)iconName {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = kTBToastHeight / 2.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;   // 只有提示，不挡点击

        self.blur = [[UIVisualEffectView alloc] initWithEffect:
                     [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        self.blur.userInteractionEnabled = NO;
        [self addSubview:self.blur];

        self.fill = [[UIView alloc] initWithFrame:CGRectZero];
        self.fill.userInteractionEnabled = NO;
        self.fill.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.58],
                                                   [UIColor colorWithWhite:1 alpha:0.14]);
        [self addSubview:self.fill];

        UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        CGSize ts = [text sizeWithAttributes:@{ NSFontAttributeName: font }];
        CGFloat textW = ceil(ts.width) + 2.0;   // 抗锯齿余量

        CGFloat w = textW + kTBToastPadX * 2;
        CGFloat x = kTBToastPadX;
        if (iconName.length) {
            self.icon = [[UIImageView alloc] initWithImage:
                         [[UIImage systemImageNamed:iconName]
                          imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
            self.icon.tintColor = [UIColor labelColor];
            self.icon.contentMode = UIViewContentModeScaleAspectFit;
            self.icon.frame = CGRectMake(kTBToastPadX,
                                         (kTBToastHeight - kTBToastIconSize) / 2.0,
                                         kTBToastIconSize, kTBToastIconSize);
            [self addSubview:self.icon];
            w += kTBToastIconSize + kTBToastIconGap;
            x = kTBToastPadX + kTBToastIconSize + kTBToastIconGap;
        }

        self.label = [[UILabel alloc] initWithFrame:
                      CGRectMake(x, 0, textW, kTBToastHeight)];
        self.label.font = font;
        self.label.text = text;
        self.label.textColor = [UIColor labelColor];
        self.label.textAlignment = NSTextAlignmentLeft;
        self.label.backgroundColor = [UIColor clearColor];
        [self addSubview:self.label];

        self.bounds = CGRectMake(0, 0, ceil(w), kTBToastHeight);   // 宽度只由内容决定
        TBApplyRim(self, 0.55);
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.blur.frame = self.bounds;
    self.fill.frame = self.bounds;
}

@end

@implementation TBToast

+ (void)show:(NSString *)text icon:(NSString *)systemImageName in:(UIViewController *)host {
    if (!text.length) return;
    UIView *root = host.view.window ?: host.view;
    if (!root) return;

    // 同一时间只留一个：旧的直接摘掉（不做退场动画，避免两个叠在一起）
    [TBToast dismissNow];

    TBToastView *t = [[TBToastView alloc] initWithText:text icon:systemImageName];
    _gToastGen++;
    t.gen = _gToastGen;

    CGFloat W = root.bounds.size.width;
    CGFloat H = root.bounds.size.height;
    CGFloat topSafe = root.safeAreaInsets.top;
    CGFloat y = H - kTBToastDockBottom - kTBToastDockH - kTBToastDockGap - kTBToastHeight;
    if (y < topSafe + 8) y = topSafe + 8;      // 小屏兜底
    t.center = CGPointMake(W / 2.0, y + kTBToastHeight / 2.0);
    t.alpha = 0.0;
    t.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.94, 0.94),
                                          CGAffineTransformMakeTranslation(0, 18));
    [root addSubview:t];

    UISpringTimingParameters *inP =
        [[UISpringTimingParameters alloc] initWithDampingRatio:kTBToastInDamping];
    UIViewPropertyAnimator *inA = [[UIViewPropertyAnimator alloc] initWithDuration:kTBToastInDuration
                                                                  timingParameters:inP];
    [inA addAnimations:^{
        t.alpha = 1.0;
        t.transform = CGAffineTransformIdentity;
    }];
    [inA startAnimation];

    NSInteger gen = t.gen;
    __weak TBToastView *weakT = t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kTBToastInDuration + kTBToastHold) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TBToastView *tv = weakT;
        if (!tv || tv.gen != gen || _gToastGen != gen || !tv.superview) return;

        UISpringTimingParameters *outP =
            [[UISpringTimingParameters alloc] initWithDampingRatio:kTBToastOutDamping];
        UIViewPropertyAnimator *outA = [[UIViewPropertyAnimator alloc] initWithDuration:kTBToastOutDuration
                                                                      timingParameters:outP];
        [outA addAnimations:^{
            tv.alpha = 0.0;
            tv.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.94, 0.94),
                                                   CGAffineTransformMakeTranslation(0, 14));
        }];
        [outA addCompletion:^(UIViewAnimatingPosition pos) {
            [tv removeFromSuperview];
        }];
        [outA startAnimation];
    });
}

+ (void)showAppliedIn:(UIViewController *)host {
    [TBToast show:@"已应用" icon:@"checkmark" in:host];
}

+ (void)showCancelledIn:(UIViewController *)host {
    [TBToast show:@"已取消" icon:nil in:host];
}

+ (void)dismissNow {
    _gToastGen++;   // 让所有在途的 hold 定时器失效
    for (UIView *v in [UIApplication sharedApplication].windows) {
        [self removeToastsIn:v];
    }
}

+ (void)removeToastsIn:(UIView *)v {
    NSArray *kids = [[v subviews] copy];
    NSUInteger i, n = [kids count];
    for (i = 0; i < n; i++) {
        UIView *child = [kids objectAtIndex:i];
        if ([child isKindOfClass:[TBToastView class]]) {
            [child removeFromSuperview];
        } else {
            [self removeToastsIn:child];
        }
    }
}

@end