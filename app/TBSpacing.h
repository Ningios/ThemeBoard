#import <UIKit/UIKit.h>

// ══════════════════════════════════════════════════════════════════════════
//  ⚠️ 0.15.62 起**不再被任何页面引用** —— 仅为历史记录保留本文件。
//
//  用户确认「间距改回原来的」，所以 0.15.57 / 0.15.59 引入的这套统一间距常量
//  （0.15.58 建档，0.15.59 全量铺开）已经全部撤销，各页面回到 v0.15.56（452859e）
//  的字面量取值：
//    · 主题列表：header 56（「主题」组，含排序按钮）/ 8（按钮行）/ 34（其它），
//      按钮行高 62、三按钮条 head 56 + bar inset 20 / top 8 / 高 44，卡片 TBGlassCellBG(12)
//    · 设置 56 行高；状态 52 行高；缺少图标 60 行高（均无自定义 header/footer 高度）
//    · 详情页 sectionInset = (8, 16, 28, 16)、kTBCardGap 12、分组标题 30
//  需要统一间距时再从这里取，但改之前先确认用户要不要「收紧」。
// ══════════════════════════════════════════════════════════════════════════

static const CGFloat kTBSpacePageSide   = 16.0;  // 页面左右边距
static const CGFloat kTBSpaceSectionTop = 6.0;   // 分区顶部
static const CGFloat kTBSpaceSectionBot = 8.0;   // 分区底部（卡片与下一段之间）
static const CGFloat kTBSpaceHeaderH    = 8.0;   // 空 header/footer 的高度（用来当间隔）
static const CGFloat kTBSpaceGroupTitle = 28.0;  // 分组标题高度
static const CGFloat kTBSpaceCardGap    = 10.0;  // 卡片/行之间
static const CGFloat kTBSpaceRowMin     = 44.0;  // 行高下限

/// 表格 cell 内玻璃卡的左右内缩（0.15.41~0.15.56 的取值是 12；0.15.58 曾改成 -4）
static const CGFloat kTBSpaceTableCellCardInset = 12.0;
