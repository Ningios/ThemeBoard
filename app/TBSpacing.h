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

/// 表格（UITableViewStyleInsetGrouped）cell 内玻璃卡的左右内缩 —— v0.15.41 的取值：12。
/// 卡片左边 = 系统 section inset（约 20）+ 12，即距屏幕约 32pt；与 0.15.41 完全一致。
///
/// ★ 0.15.62：水平方向整体退回 0.15.41（12），纵向间距仍用下面这套收紧值。
///   历史：0.15.58 起改成 kTBSpacePageSide-20 = -4（卡片外扩、几乎贴屏幕边）；
///   0.15.60 又换成 TBGlassCellAtPageSide() 运行时反推（已撤，调用点已清零）。
///   现在就是旧版那个 12，不要再写 -4 / 运行时换算。
static const CGFloat kTBSpaceTableCellCardInset = 12.0;   // = v0.15.41 的 TBGlassCellBG(12)
