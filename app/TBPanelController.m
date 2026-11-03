#import "TBPanelController.h"
#import "TBGlass.h"

#pragma mark - 玻璃面板基类（遮罩 + 卡片 + 键盘避让 + 自绘淡入淡出）




/// 简单日志：写 /var/mobile/Library/ThemeBoard/app.log（便于真机排查）
void TBLog2(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *dir = @"/var/mobile/Library/ThemeBoard";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    NSString *path = [dir stringByAppendingPathComponent:@"app.log"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m ?: @""];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]; }
    else { @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (id e) {} [fh closeFile]; }
}

@implementation TBGlassPanelBase

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    if ((self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil])) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;   // 不用系统 sheet
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self tb_setupBase];      // 必须在这里建 dimView / cardView，早于子类 viewDidLoad 的 addSubview
}

- (void)tb_setupBase {
    self.view.backgroundColor = [UIColor clearColor];
    if (self.cardView) return;      // 幂等

    _dimView = [[UIView alloc] initWithFrame:CGRectZero];
    _dimView.backgroundColor = [UIColor blackColor];
    _dimView.alpha = 0;
    [self.view addSubview:_dimView];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(tb_dimTapped)];
    [_dimView addGestureRecognizer:tap];

    _cardView = [[UIView alloc] initWithFrame:CGRectZero];
    _cardView.layer.cornerRadius = 22;
    _cardView.layer.cornerCurve = kCACornerCurveContinuous;
    _cardView.clipsToBounds = YES;
    _cardView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_cardView];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
                                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [_cardView addSubview:blur];

    UIView *fill = [[UIView alloc] initWithFrame:CGRectZero];
    fill.tag = 2001;
    fill.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    fill.userInteractionEnabled = NO;
    fill.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.60],
                                          [UIColor colorWithWhite:0.10 alpha:0.62]);
    [_cardView addSubview:fill];
    TBApplyRim(_cardView, 0.55);

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tb_keyboardWillChange:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tb_keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)tb_dimTapped {
    if (self.tbClosing) return;
    [self tb_closeWithCompletion:nil];
}

#pragma mark 键盘

- (void)tb_keyboardWillChange:(NSNotification *)n {
    CGRect end = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect inView = [self.view convertRect:end fromView:nil];
    CGFloat overlap = MAX(0.0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(inView));
    self.keyboardOverlap = overlap;
    [self tb_animateKeyboard];
}

- (void)tb_keyboardWillHide:(NSNotification *)n {
    self.keyboardOverlap = 0;
    [self tb_animateKeyboard];
}

- (void)tb_animateKeyboard {
    // 让卡片跟着键盘走：不吃掉输入框，也不把它顶出屏幕
    if (self.tbClosing) return;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        if (!self.tbClosing) [self.view layoutIfNeeded];
    } completion:nil];
}

#pragma mark 呈现 / 收起

- (void)tb_presentOver:(UIViewController *)host {
    if (!host) return;
    // ★ 先隐藏、先把卡片摆到最终位置，再 present —— 否则会有一帧"卡片全亮"的闪烁
    self.dimView.alpha = 0;
    self.cardView.alpha = 0;
    self.cardView.transform = CGAffineTransformMakeScale(0.96, 0.96);
    self.view.hidden = YES;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    self.view.hidden = NO;
    [host presentViewController:self animated:NO completion:^{   // 系统动画关掉，自己淡入
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.dimView.alpha = 0.44;
            self.cardView.alpha = 1;
            self.cardView.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
}

- (void)tb_closeWithCompletion:(void (^)(void))done {
    if (self.tbClosing) return;
    self.tbClosing = YES;
    __weak typeof(self) wself = self;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        __strong typeof(self) s = wself;
        if (!s) return;
        s.dimView.alpha = 0;
        s.cardView.alpha = 0;
        s.cardView.transform = CGAffineTransformMakeScale(0.97, 0.97);
    } completion:^(BOOL finished) {
        __strong typeof(self) s = wself;
        if (!s) { if (done) done(); return; }
        [s dismissViewControllerAnimated:NO completion:done];
    }];
}

#pragma mark 布局

- (CGFloat)tb_cardWidthForBounds:(CGRect)b {
    return MIN(MAX(b.size.width - 44.0, 240.0), 340.0);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    if (b.size.width < 1 || b.size.height < 1) return;
    self.dimView.frame = b;

    CGFloat w = [self tb_cardWidthForBounds:b];
    CGFloat h = [self tb_cardHeightForWidth:w];
    CGFloat top = (b.size.height - h) / 2.0;

    // 键盘避让：卡片底边要让开键盘，顶边不越过安全区
    CGFloat bottomLimit = b.size.height - self.keyboardOverlap - 12.0;
    if (top + h > bottomLimit) top = bottomLimit - h;
    CGFloat topLimit = self.view.safeAreaInsets.top + 12.0;
    if (top < topLimit) top = topLimit;

    CGRect card = CGRectMake(round((b.size.width - w) / 2.0), round(top), round(w), round(h));
    self.cardView.frame = card;
    UIView *fill = [self.cardView viewWithTag:2001];
    fill.frame = self.cardView.bounds;
    [self tb_layoutCardContent:card];
}

- (CGFloat)tb_cardHeightForWidth:(CGFloat)w { return 200; }
- (void)tb_layoutCardContent:(CGRect)card { }

#pragma mark 文本测量

static CGFloat TBTextHeight(NSString *text, UIFont *font, CGFloat width) {
    if (!text.length) return 0;
    CGRect r = [text boundingRectWithSize:CGSizeMake(width, 9999)
                                  options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                               attributes:@{ NSFontAttributeName: font }
                                  context:nil];
    return ceil(r.size.height);
}

@end

#pragma mark - 通用选择面板

@interface TBChoicePanelController ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *msgLabel;
@property (nonatomic, strong) NSMutableArray<UIButton *> *buttons;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, assign) CGFloat titleH, msgH;
@end

@implementation TBChoicePanelController

+ (instancetype)panelWithTitle:(NSString *)title
                       message:(NSString *)message
                       options:(NSArray<NSString *> *)options
                       handler:(void (^)(NSInteger))handler {
    TBChoicePanelController *p = [[TBChoicePanelController alloc] init];
    p.panelTitle = title ?: @"";
    p.message = message ?: @"";
    p.optionTitles = options ?: @[];
    p.handler = handler;
    return p;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.buttons = [NSMutableArray array];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 0;
    self.titleLabel.text = self.panelTitle;
    [self.cardView addSubview:self.titleLabel];

    self.msgLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.msgLabel.font = [UIFont systemFontOfSize:12.5];
    self.msgLabel.textColor = [UIColor secondaryLabelColor];
    self.msgLabel.numberOfLines = 0;
    self.msgLabel.text = self.message;
    self.msgLabel.hidden = (self.message.length == 0);
    [self.cardView addSubview:self.msgLabel];

    for (NSUInteger i = 0; i < self.optionTitles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.tag = (NSInteger)i;
        b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [b setTitle:self.optionTitles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        b.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                           [UIColor colorWithWhite:1 alpha:0.14]);
        b.layer.cornerRadius = 13;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        TBApplyRim(b, 0.55);
        [b addTarget:self action:@selector(tb_optionTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.cardView addSubview:b];
        [self.buttons addObject:b];
    }

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cancelButton setTitle:@"取消" forState:UIControlStateNormal];
    self.cancelButton.titleLabel.font = [UIFont systemFontOfSize:16];
    [self.cancelButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [self.cancelButton addTarget:self action:@selector(tb_cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.cardView addSubview:self.cancelButton];
}

- (void)tb_optionTapped:(UIButton *)sender {
    void (^h)(NSInteger) = self.handler;
    NSInteger idx = sender.tag;
    [self tb_closeWithCompletion:^{
        if (h) h(idx);
    }];
}

- (void)tb_cancelTapped {
    void (^h)(NSInteger) = self.handler;
    [self tb_closeWithCompletion:^{
        if (h) h(-1);
    }];
}

- (CGFloat)tb_cardHeightForWidth:(CGFloat)w {
    CGFloat innerW = w - 40.0;
    self.titleH = TBTextHeight(self.panelTitle, self.titleLabel.font ?: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], innerW);
    self.msgH = self.message.length ? TBTextHeight(self.message, self.msgLabel.font ?: [UIFont systemFontOfSize:12.5], innerW) : 0;
    CGFloat h = 20.0 + self.titleH + 4.0;
    if (self.msgH > 0) h += 8.0 + self.msgH;
    h += 16.0;
    h += self.buttons.count * 46.0 + (self.buttons.count > 1 ? (self.buttons.count - 1) * 10.0 : 0);
    h += 10.0 + 40.0 + 14.0;
    return h;
}

- (void)tb_layoutCardContent:(CGRect)card {
    CGFloat pad = 20.0;
    CGFloat innerW = card.size.width - pad * 2.0;
    CGFloat y = 20.0;
    self.titleLabel.frame = CGRectMake(pad, y, innerW, self.titleH);
    y += self.titleH + 4.0;
    if (self.msgH > 0) {
        y += 8.0;
        self.msgLabel.frame = CGRectMake(pad, y, innerW, self.msgH);
        y += self.msgH;
    }
    y += 16.0;
    for (UIButton *b in self.buttons) {
        b.frame = CGRectMake(pad, y, innerW, 46);
        y += 46 + 10;
    }
    if (self.buttons.count) y -= 10;
    y += 10;
    self.cancelButton.frame = CGRectMake(pad, y, innerW, 40);
}

- (void)presentOver:(UIViewController *)host {
    [self tb_presentOver:host];
}

@end

#pragma mark - 自定义圆角面板（输入框 + 滑块双向联动）

@interface TBRadiusPanelController () <UITextFieldDelegate>
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *fieldCaption;   // 「半径（0–30）」
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIButton *okButton;
@property (nonatomic, assign) double value;
@property (nonatomic, copy) void (^handler)(BOOL, double);
@property (nonatomic, assign) BOOL syncingFromField;
@property (nonatomic, assign) CGFloat titleH, descH;
@property (nonatomic, assign) BOOL didFocus;
@end

@implementation TBRadiusPanelController

+ (instancetype)panelWithValue:(double)value handler:(void (^)(BOOL, double))handler {
    TBRadiusPanelController *p = [[TBRadiusPanelController alloc] init];
    if (!(value >= 0.0) || value > 30.0) value = 13.42;
    p.value = value;
    p.handler = handler;
    return p;
}

static NSString *TBRadiusText(double v) {
    NSString *s = [NSString stringWithFormat:@"%.2f", v];
    return s;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.cardView) [self tb_setupBase];      // 兜底：确保卡片与遮罩已创建
    TBLog2(@"圆角面板 viewDidLoad card=%@ subviews=%lu",
           self.cardView ? NSStringFromCGRect(self.cardView.frame) : @"(nil)",
           (unsigned long)self.cardView.subviews.count);

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.text = @"自定义圆角";
    [self.cardView addSubview:self.titleLabel];

    self.descLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.descLabel.font = [UIFont systemFontOfSize:12.5];
    self.descLabel.textColor = [UIColor secondaryLabelColor];
    self.descLabel.numberOfLines = 0;
    self.descLabel.text = @"半径=(数值/60)×图标宽度；默认 13.42 ≈ 宽度的 22.37%；"
                          @"越小越方、越大越圆，上限为宽度的一半。";
    [self.cardView addSubview:self.descLabel];

    self.fieldCaption = [[UILabel alloc] initWithFrame:CGRectZero];
    self.fieldCaption.font = [UIFont systemFontOfSize:14];
    self.fieldCaption.textColor = [UIColor labelColor];
    self.fieldCaption.text = @"半径（0–30）";
    [self.cardView addSubview:self.fieldCaption];

    self.field = [[UITextField alloc] initWithFrame:CGRectZero];
    self.field.keyboardType = UIKeyboardTypeDecimalPad;
    self.field.textAlignment = NSTextAlignmentCenter;
    self.field.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightMedium];
    self.field.textColor = [UIColor labelColor];
    self.field.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.72],
                                                [UIColor colorWithWhite:1 alpha:0.18]);
    self.field.layer.cornerRadius = 9;
    self.field.layer.cornerCurve = kCACornerCurveContinuous;
    self.field.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    self.field.layer.borderColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.60],
                                                  [UIColor colorWithWhite:1 alpha:0.24]).CGColor;
    self.field.text = TBRadiusText(self.value);
    self.field.delegate = self;
    self.field.inputAccessoryView = nil;
    [self.field addTarget:self action:@selector(tb_fieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [self.cardView addSubview:self.field];

    self.slider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.slider.minimumValue = 0.0;
    self.slider.maximumValue = 30.0;
    self.slider.value = (float)self.value;
    self.slider.continuous = YES;
    [self.slider addTarget:self action:@selector(tb_sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.cardView addSubview:self.slider];

    self.percentLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.percentLabel.font = [UIFont systemFontOfSize:12];
    self.percentLabel.textColor = [UIColor secondaryLabelColor];
    self.percentLabel.textAlignment = NSTextAlignmentRight;
    [self.cardView addSubview:self.percentLabel];
    [self tb_updatePercent];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cancelButton setTitle:@"取消" forState:UIControlStateNormal];
    self.cancelButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [self.cancelButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.cancelButton.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                                       [UIColor colorWithWhite:1 alpha:0.14]);
    self.cancelButton.layer.cornerRadius = 13;
    self.cancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    TBApplyRim(self.cancelButton, 0.55);
    [self.cancelButton addTarget:self action:@selector(tb_cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.cardView addSubview:self.cancelButton];

    self.okButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.okButton setTitle:@"确定" forState:UIControlStateNormal];
    self.okButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [self.okButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.okButton.backgroundColor = [UIColor systemBlueColor];
    self.okButton.layer.cornerRadius = 13;
    self.okButton.layer.cornerCurve = kCACornerCurveContinuous;
    [self.okButton addTarget:self action:@selector(tb_okTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.cardView addSubview:self.okButton];

    // 兜底：把所有内容视图提到最上层（blur / fill 都在 cardView 里，避免被盖住看不到）
    for (UIView *v in @[self.titleLabel, self.descLabel, self.fieldCaption, self.field,
                        self.slider, self.percentLabel, self.cancelButton, self.okButton]) {
        [self.cardView bringSubviewToFront:v];
    }
    // 先按一个合理宽度算一次高度，保证首帧就有正确尺寸（不依赖 viewDidLayoutSubviews 时机）
    CGFloat w0 = [self tb_cardWidthForBounds:self.view.bounds];
    if (w0 > 1) { [self tb_cardHeightForWidth:w0]; }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didFocus) return;
    self.didFocus = YES;
    // 自动聚焦并全选，方便直接改数字
    [self.field becomeFirstResponder];
    [self.field selectAll:nil];
}

#pragma mark 联动

- (void)tb_updatePercent {
    double pct = (self.value / 60.0) * 100.0;
    self.percentLabel.text = [NSString stringWithFormat:@"≈ 图标宽度的 %.2f%%", pct];
}

- (void)tb_sliderChanged:(UISlider *)s {
    double v = round((double)s.value * 100.0) / 100.0;
    self.value = v;
    self.field.text = TBRadiusText(v);       // 拖滑块 → 输入框实时更新
    [self tb_updatePercent];
}

- (void)tb_fieldChanged:(UITextField *)f {
    NSString *t = f.text ?: @"";
    // 允许空 / "1." 这种输入过程中的中间态，不强行回写
    double v = t.doubleValue;
    if (t.length && v >= 0.0) {
        if (v > 30.0) v = 30.0;
        self.value = v;
        self.slider.value = (float)v;        // 输入框改值 → 滑块同步
        [self tb_updatePercent];
    }
}

- (BOOL)textField:(UITextField *)textField
shouldChangeCharactersInRange:(NSRange)range
replacementString:(NSString *)string {
    if (!string.length) return YES;          // 删除永远允许
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        if ((c < '0' || c > '9') && c != '.') return NO;
    }
    NSString *new = [textField.text stringByReplacingCharactersInRange:range withString:string];
    if ([new componentsSeparatedByString:@"."].count > 2) return NO;   // 只允许一个小数点
    NSRange dot = [new rangeOfString:@"."];
    if (dot.location != NSNotFound && new.length - dot.location - 1 > 2) return NO;  // 最多两位小数
    if (new.length > 5) return NO;
    return YES;
}

- (double)tb_clampedValue {
    double v = self.field.text.length ? self.field.text.doubleValue : self.value;
    if (!(v == v)) v = self.value;           // NaN
    if (v < 0.0) v = 0.0;
    if (v > 30.0) v = 30.0;                  // 非法/超范围 → 夹到 0–30
    return round(v * 100.0) / 100.0;
}

- (void)tb_okTapped {
    double v = [self tb_clampedValue];
    self.value = v;
    self.field.text = TBRadiusText(v);
    self.slider.value = (float)v;
    void (^h)(BOOL, double) = self.handler;
    [self tb_closeWithCompletion:^{
        if (h) h(YES, v);
    }];
}

- (void)tb_cancelTapped {
    void (^h)(BOOL, double) = self.handler;
    [self tb_closeWithCompletion:^{
        if (h) h(NO, 0);
    }];
}

#pragma mark 布局

- (CGFloat)tb_cardHeightForWidth:(CGFloat)w {
    CGFloat innerW = w - 40.0;
    self.titleH = TBTextHeight(self.titleLabel.text, self.titleLabel.font, innerW);
    self.descH = TBTextHeight(self.descLabel.text, self.descLabel.font, innerW);
    CGFloat h = 20.0 + self.titleH + 8.0 + self.descH;
    h += 18.0 + 34.0;          // 输入行
    h += 14.0 + 31.0;          // 滑块
    h += 4.0 + 16.0;           // 百分比说明
    h += 16.0 + 44.0 + 16.0;   // 按钮行
    return h;
}

- (void)tb_layoutCardContent:(CGRect)card {
    CGFloat pad = 20.0;
    CGFloat innerW = card.size.width - pad * 2.0;
    CGFloat y = 20.0;
    self.titleLabel.frame = CGRectMake(pad, y, innerW, self.titleH);
    y += self.titleH + 8.0;
    self.descLabel.frame = CGRectMake(pad, y, innerW, self.descH);
    y += self.descH + 18.0;

    CGFloat fieldW = 92.0;
    self.fieldCaption.frame = CGRectMake(pad, y, innerW - fieldW - 10.0, 34);
    self.field.frame = CGRectMake(pad + innerW - fieldW, y, fieldW, 34);
    y += 34.0 + 14.0;

    self.slider.frame = CGRectMake(pad, y, innerW, 31);
    y += 31.0 + 4.0;
    self.percentLabel.frame = CGRectMake(pad, y, innerW, 16);
    y += 16.0 + 16.0;

    CGFloat half = (innerW - 10.0) / 2.0;
    self.cancelButton.frame = CGRectMake(pad, y, half, 44);
    self.okButton.frame = CGRectMake(pad + half + 10.0, y, half, 44);
}

- (void)presentOver:(UIViewController *)host {
    [self tb_presentOver:host];
}

@end
