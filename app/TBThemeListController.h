#import <UIKit/UIKit.h>
#import "TBTableViewController.h"

@interface TBThemeListController : TBTableViewController

/// 重新扫描 + 刷新列表（AppDelegate 从外部 openURL 导入后调用）
- (void)reload;

@end
