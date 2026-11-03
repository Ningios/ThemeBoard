#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

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

@end

/// 自定义圆角面板：输入框（数字键盘）+ 滑块双向联动，自动避开键盘
@interface TBRadiusPanelController : TBGlassPanelBase

/// 当前值（0–30）；handler 的 confirmed = NO 表示取消
+ (instancetype)panelWithValue:(double)value
                       handler:(nullable void (^)(BOOL confirmed, double value))handler;

- (void)presentOver:(UIViewController *)host;

@end

NS_ASSUME_NONNULL_END
