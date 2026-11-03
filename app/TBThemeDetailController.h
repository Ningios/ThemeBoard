#import <UIKit/UIKit.h>
#import "TBTheme.h"

/// 详情页：整体「双列方形卡片」（UICollectionView，正方形 cell + 玻璃卡片）。
/// 卡片分区：操作（概览 / 应用 / 取消应用 / 导出）、预览（遮罩预览 + 图标预览）、全部图标。
@interface TBThemeDetailController : UIViewController
- (instancetype)initWithTheme:(TBTheme *)theme;
@end
