#import <UIKit/UIKit.h>

@class TBTheme;

/// 自定义底部抽屉（自己实现，**不用** UISheetPresentationController）：
///   - 阻尼橡皮筋：拖出边界后按 1 - 1/(over*k+1) 衰减（近处斜率 ≈ 0.35）
///   - 松手按手势速度吸附：y 速度大就顺方向吸到下一个锚点，速度小吸最近锚点
///   - 弹簧收尾：UISpringTimingParameters + UIViewPropertyAnimator
///   - 三个锚点：收起（屏外）/ 中间（约屏高 45%）/ 展开（约屏高 85%）
///   - 半透明黑色遮罩，点它收起；顶部一根小拖拽指示条
/// 抽屉内容：遮罩三选一（系统形状 / 主题遮罩图 / 自定义圆角）+ 应用主题 + 详情。
@interface TBBottomSheetController : UIViewController

- (instancetype)initWithTheme:(TBTheme *)theme;

/// 从 host 上弹出（出现/消失动画全在内部做，present 本身用 animated:NO）
- (void)presentOver:(UIViewController *)host;

/// 抽屉完全收起之后才回调：外部负责刷新列表 / 弹提示 / push 详情页
@property (nonatomic, copy) void (^onApply)(TBTheme *theme);
@property (nonatomic, copy) void (^onDetail)(TBTheme *theme);

@end
