#import <UIKit/UIKit.h>

@class TBTheme;

/// 自定义底部抽屉（自己实现，**不用** UISheetPresentationController）：
///   - 高度：等于内容实际高度（紧凑排布，展开态下方不留空白），不再按屏高比例撑开
///   - 阻尼橡皮筋：拖出边界后按 1 - 1/(over*k+1) 衰减（近处斜率 ≈ 0.35）
///   - 松手按手势速度投影吸附：offset + vy×0.20 选最近锚点，甩得够快就顺方向走一格
///   - 收尾只用**一个** UIViewPropertyAnimator（弹簧 damping 0.88 / 0.34s），
///     抽屉位移与背景 alpha 在同一次动画块里一起走，收起动画结束后才 dismiss
///   - 三个锚点：收起（屏外）/ 中间（露出内容一半）/ 展开（= 内容高度）
///   - 半透明黑色遮罩，点它收起；顶部一根小拖拽指示条
/// 抽屉内容：遮罩三选一（系统形状 / 主题遮罩图 / 自定义圆角）
///          + AnemoneEffects 开关两个（叠加层 / 阴影，主题里没有就灰显）
///          + 应用主题 / 导入遮罩 / 详情。
@interface TBBottomSheetController : UIViewController

- (instancetype)initWithTheme:(TBTheme *)theme;

/// 从 host 上弹出（出现/消失动画全在内部做，present 本身用 animated:NO）
- (void)presentOver:(UIViewController *)host;

/// 抽屉完全收起之后才回调：外部负责刷新列表 / 弹提示 / push 详情页
@property (nonatomic, copy) void (^onApply)(TBTheme *theme);
@property (nonatomic, copy) void (^onDetail)(TBTheme *theme);

@end
