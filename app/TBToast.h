#import <UIKit/UIKit.h>

/// 玻璃胶囊 toast（无按钮、无交互）：从底部（Tab 栏上方）弹出，停留 1.5 秒后缩回。
/// 高度固定 48、宽度按文字自适应（左右 padding 22）、圆角 = 高度一半，
/// SystemThinMaterial 模糊 + 白 rim，和 TBGlass 同风格。
@interface TBToast : NSObject

/// 指定文案弹出（icon 传 systemImage 名，可为 nil）
+ (void)show:(NSString *)text icon:(nullable NSString *)systemImageName in:(UIViewController *)host;

/// 「已应用」（带 14pt checkmark）
+ (void)showAppliedIn:(UIViewController *)host;

/// 「已取消」（无图标）
+ (void)showCancelledIn:(UIViewController *)host;

/// 立刻移除当前 toast（切页 / 关闭等场景）
+ (void)dismissNow;

@end