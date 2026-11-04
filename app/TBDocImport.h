#import <UIKit/UIKit.h>

/// 统一的「导入」文件访问层。
/// 关键点：iCloud 云盘里的文件在没下载到本机时只是占位符（.icloud），
/// 直接 contentsOfFile: 一定失败；必须让 NSFileCoordinator 去做协调读取
/// （NSFileCoordinatorReadingWithoutChanges，0.15.59 起照 MarkFont-Ning 的可工作实现），
/// 而且读完要立刻把内容复制/读进 App 自己的沙盒（临时目录），
/// 因为选择器给的安全作用域 URL 一旦 stopAccessing 就失效了。

NS_ASSUME_NONNULL_BEGIN

/// App 侧日志：追加写 /var/mobile/Library/ThemeBoard/app.log（实现在 TBPanelController.m）
void TBLog2(NSString *fmt, ...);

/// 统一文件选择器：
///   iOS14+  → initForOpeningContentTypes:asCopy:NO（open in place，只用具体类型，不带 UTTypeItem）
///   老系统  → initWithDocumentTypes:inMode:UIDocumentPickerModeImport
/// 读取统一走 NSFileCoordinatorReadingWithoutChanges（照 MarkFont-Ning 的可工作实现）
/// contentTypes 传 UTType 数组（只在 iOS14+ 用），legacyTypes 传 UTI 字符串数组。
/// 任何异常都返回 nil，不让调用方崩。
UIDocumentPickerViewController *_Nullable TBNewImportPicker(NSArray *contentTypes,
                                                            NSArray<NSString *> *legacyTypes);

/// 协调读取单个文件 → NSData。0.15.63：coordinator 拿不到就退回
/// 直读原始 URL / 触发 iCloud 下载后重读 / NSFileHandle 读，全都失败才返回 nil。
NSData *_Nullable TBReadCoordinatedData(NSURL *url, NSError *_Nullable *_Nullable error);

/// 协调读取并把条目（文件或整个目录，目录递归）复制到 NSTemporaryDirectory() 下的
/// 独立临时目录，返回副本 URL。0.15.63：不再因「副本不在本机」提前报错，
/// coordinator 失败还有「原始 URL 复制 / 等 iCloud 下载 / 按字节直读」三级兜底。
/// 调用方负责在用完后删除返回值的父目录（用 TBRemoveTempCopy）。
NSURL *_Nullable TBCopyCoordinatedItemToTemp(NSURL *url, NSError *_Nullable *_Nullable error);

/// 删除 TBCopyCoordinatedItemToTemp 产生的整个临时目录
void TBRemoveTempCopy(NSURL *_Nullable tempURL);

/// 这个 URL 是不是 iCloud 云盘路径 —— 0.15.63 起【只用于日志】，
/// 绝不用来提前拒绝导入（iCloud 未下载的文件由 coordinator/直读兜底去拿）
BOOL TBURLIsICloud(NSURL *_Nullable url);

/// 统一的失败提示文案：只写真实错误（描述 + domain/code），不编「先去下载」这类前置文案
NSString *TBImportFailureMessage(NSURL *_Nullable url, NSError *_Nullable error, NSString *fallback);

/// 0.15.54：从 from 沿 presentedViewController 链找到「真正的最顶层」可呈现 VC。
/// 从抽屉/弹层/popover 里 present 文件选择器时必须用它：直接 present 在非顶层 VC 上，
/// picker 能弹出来（UIKit 会自己往上转发 view），但选中回调可能落到一个已经不在窗口里的
/// VC 上，表现就是「点了文件完全没反应、连日志都没有」。
UIViewController *TBTopPresentingViewController(UIViewController *from);

NS_ASSUME_NONNULL_END