#import <UIKit/UIKit.h>
#import "TBTheme.h"

@interface TBThemeScanner : NSObject

/// 需要扫描的根目录：ThemeBoard/Themes（主题包）+ ThemeBoard/Assets（素材包）
+ (NSArray<NSString *> *)themeRoots;

/// 主题包根目录（导入主题用）
+ (nullable NSString *)writableThemeRoot;

/// 素材包根目录（导入素材用）
+ (nullable NSString *)writableAssetRoot;

/// 扫描全部主题 / 素材包（不加载图标索引，快）
+ (NSArray<TBTheme *> *)scanThemes;

/// 按名字找主题（只看主题包，找不到再退回素材包）
+ (nullable TBTheme *)themeNamed:(NSString *)name;

/// 导入一个主题目录（复制到 Themes/，重名自动加序号），返回新主题路径
+ (nullable NSString *)importThemeDirectory:(NSURL *)srcURL error:(NSError **)error;

/// 在 Assets/ 下新建一个「素材包」子目录（重名自动加序号），返回新目录的绝对路径
+ (nullable NSString *)createAssetPackDirectoryNamed:(NSString *)name error:(NSError **)error;

/// 通用：在 root 下要一个不重名的目录
+ (NSString *)uniqueDirectoryPathForName:(NSString *)name inRoot:(NSString *)root;

/// 素材类型显示名：mask→遮罩, overlay→边框, shadow→阴影
+ (NSString *)assetKindTitle:(NSString *)kind;

/// 导入素材：图片 → Assets/<名字>/{IconBundles/Icon.png | AnemoneEffects/iPhoneOverlay@3x.png}
/// 文件夹 → 整个复制进 Assets/<名字>；并写 Info.plist 标记类型。
/// kind: mask / overlay / shadow
+ (nullable NSString *)importAssetFromURL:(NSURL *)url kind:(NSString *)kind error:(NSError **)error;

/// 每个候选目录的存在/可写/条目数，用于状态诊断
+ (NSArray<NSDictionary *> *)rootDiagnostics;

/// 主题根目录（App 写 ThemeRoot 偏好给引擎用）
+ (NSString *)containerThemesDir;

/// 首次启动把包内演示主题复制进 Themes/
+ (void)seedDemoThemesIfNeeded;

/// 真正的导入实现（不做 iCloud 协调）
+ (nullable NSString *)importLocalURL:(NSURL *)url error:(NSError **)error;

/// 导入任意来源：文件夹直接复制，zip 先解包再找主题目录
+ (nullable NSString *)importFromAnyURL:(NSURL *)url error:(NSError **)error;

/// 文档目录里待导入的 zip（用户通过「文件」App 拖进来的）
+ (NSArray<NSString *> *)zipsInDocuments;

/// 导入文档目录里的某个 zip
+ (nullable NSString *)importZipInDocuments:(NSString *)zipName error:(NSError **)error;

/// 删除主题目录（不可恢复）
+ (BOOL)deleteTheme:(TBTheme *)theme error:(NSError **)error;

/// 把 zip 解压到临时目录并找出里面的遮罩图，返回【临时图片路径】（用完自行删除）。
/// 失败时回填 reason（带压缩包里的文件名列表）。
+ (nullable NSString *)extractMaskImageFromZip:(NSURL *)zipURL reason:(NSString *_Nullable *_Nullable)reason;

@end
