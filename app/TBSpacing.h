#import <UIKit/UIKit.h>

// ══════════════════════════════════════════════════════════════════════════
//  全 App 统一间距 —— 唯一来源
//  所有页面（主题列表 / 主题详情 / 设置 / 状态 / 缺少图标）只准引用这里的常量，
//  不要再各写各的数字。0.15.58 起生效。
// ══════════════════════════════════════════════════════════════════════════

static const CGFloat kTBSpacePageSide   = 16.0;  // 页面左右边距
static const CGFloat kTBSpaceSectionTop = 6.0;   // 分区顶部
static const CGFloat kTBSpaceSectionBot = 8.0;   // 分区底部（卡片与下一段之间）
static const CGFloat kTBSpaceHeaderH    = 8.0;   // 空 header/footer 的高度（用来当间隔）
static const CGFloat kTBSpaceGroupTitle = 28.0;  // 分组标题高度
static const CGFloat kTBSpaceCardGap    = 10.0;  // 卡片/行之间
static const CGFloat kTBSpaceRowMin     = 44.0;  // 行高下限

/// 表格（UITableViewStyleInsetGrouped）的 cell 左右自带 section inset，实测在不同屏幕
/// / 系统上是 20 或 24（iPhone 15 Pro Max + iOS 17 实测是 24）。0.15.59 写死
/// "16 - 20 = -4" 时，在 24pt 的机器上卡片落在 20pt —— 这就是「部分页面卡片边距不对」。
/// 0.15.60 起表格页统一改用 TBGlassCellAtPageSide(kTBSpacePageSide)（TBGlass.h）：
/// 运行时把 cell 换算到表格坐标再反推外扩量，任何 section inset 下卡片边缘都精确 = 16。
/// 不要再写 12 / 8 / -4 之类的魔法数。
