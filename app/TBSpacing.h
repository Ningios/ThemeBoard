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

/// 表格（UITableViewStyleInsetGrouped）的 cell 本身左右自带约 20pt 内缩；
/// 玻璃卡再补 -4pt，最终卡片边缘距屏幕 = 16pt（= kTBSpacePageSide）。
/// 这是全 App 表格页统一卡片边距的唯一写法，别再写 12 / 8 之类的魔法数。
static const CGFloat kTBSpaceTableCellCardInset = kTBSpacePageSide - 20.0;  // -4
