#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// App 侧日志：追加写 /var/mobile/Library/ThemeBoard/app.log（实现在 TBPanelController.m）
void TBLog2(NSString *fmt, ...);

/// 通用玻璃选择面板（替代系统 action sheet）：
/// 标题 + 说明 + 若干等宽玻璃按钮 + 取消。
/// handler 的 index 与 optionTitles 对应；点取消/点背景回调 -1。
/// 玻璃面板基类：半透明遮罩 + 圆角卡片 + 键盘避让 + 自绘淡入淡出
@interface TBGlassPanelBase : UIViewController

@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, assign) CGFloat keyboardOverlap;
@property (nonatomic, assign) BOOL tbClosing;

- (void)tb_setupBase;
/// 以「无系统动画」的方式覆盖呈现（自己淡入，避免和自绘动画叠加）
- (void)tb_presentOver:(UIViewController *)host;
- (void)tb_closeWithCompletion:(nullable void (^)(void))done;
- (CGFloat)tb_cardWidthForBounds:(CGRect)b;
- (CGFloat)tb_cardHeightForWidth:(CGFloat)w;      // 子类实现
- (void)tb_layoutCardContent:(CGRect)card;        // 子类实现

@end

@interface TBChoicePanelController : TBGlassPanelBase

@property (nonatomic, copy) NSString *panelTitle;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSArray<NSString *> *optionTitles;
@property (nonatomic, copy, nullable) void (^handler)(NSInteger index);

+ (instancetype)panelWithTitle:(NSString *)title
                       message:(NSString *)message
                       options:(NSArray<NSString *> *)options
                       handler:(nullable void (^)(NSInteger index))handler;

- (void)presentOver:(UIViewController *)host;

@property (nonatomic, copy, nullable) NSString *cancelTitle;   // 第三个按钮的标题（默认「取消」）
@end

/// 单按钮提示弹窗（替代系统 UIAlertController alert）：标题 + 正文 + 「好」。
/// 圆角玻璃卡片、自绘淡入，与抽屉里的按钮同款样式。
@interface TBAlertPanelController : TBGlassPanelBase

@property (nonatomic, copy, nullable) NSString *titleText;
@property (nonatomic, copy, nullable) NSString *message;
@property (nonatomic, copy, nullable) NSString *doneTitle;      // 默认「好」

+ (instancetype)panelWithTitle:(nullable NSString *)title
                       message:(nullable NSString *)message
                     doneTitle:(nullable NSString *)doneTitle;

- (void)presentOver:(UIViewController *)host;

@end

/// 两按钮确认弹窗（替代系统 UIAlertController alert）：取消 + 确认（可红字）。
@interface TBConfirmPanelController : TBGlassPanelBase

@property (nonatomic, copy, nullable) NSString *titleText;
@property (nonatomic, copy, nullable) NSString *message;
@property (nonatomic, copy, nullable) NSString *cancelTitle;    // 默认「取消」
@property (nonatomic, copy, nullable) NSString *confirmTitle;   // 默认「确定」
@property (nonatomic, assign) BOOL destructive;                 // YES → 确认按钮红字
@property (nonatomic, copy, nullable) void (^handler)(BOOL confirmed);

+ (instancetype)panelWithTitle:(nullable NSString *)title
                       message:(nullable NSString *)message
                   cancelTitle:(nullable NSString *)cancelTitle
                  confirmTitle:(nullable NSString *)confirmTitle
                   destructive:(BOOL)destructive
                       handler:(nullable void (^)(BOOL confirmed))handler;

- (void)presentOver:(UIViewController *)host;

@end

/// 便捷函数：一行替换系统弹窗
void TBPresentAlert(UIViewController *host, NSString *title, NSString *message);

void TBPresentConfirm(UIViewController *host, NSString *title, NSString *message,
                      NSString *cancelTitle, NSString *confirmTitle, BOOL destructive,
                      void (^handler)(BOOL confirmed));

/// 自定义圆角面板：输入框（数字键盘）+ 滑块双向联动，自动避开键盘
@interface TBRadiusPanelController : TBGlassPanelBase

/// 当前值（0–30）；handler 的 confirmed = NO 表示取消
+ (instancetype)panelWithValue:(double)value
                       handler:(nullable void (^)(BOOL confirmed, double value))handler;

- (void)presentOver:(UIViewController *)host;

@end

NS_ASSUME_NONNULL_END
