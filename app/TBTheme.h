#import <UIKit/UIKit.h>

@interface TBTheme : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *iconBundlesPath;
@property (nonatomic, assign) NSUInteger iconCount;      // 覆盖的 bundleID 数
@property (nonatomic, assign) NSUInteger fileCount;      // IconBundles 内文件数
@property (nonatomic, assign) BOOL hasBundles;           // 是否含 Bundles/（整包替换）

- (instancetype)initWithPath:(NSString *)path;

- (void)loadIndex;                                        // 幂等；扫描 IconBundles
- (NSArray<NSString *> *)bundleIdentifiers;               // 已排序
- (nullable NSString *)imagePathForBundleID:(NSString *)bid;
- (nullable UIImage *)imageForBundleID:(NSString *)bid;   // 带缓存
- (BOOL)hasIconForBundleID:(NSString *)bid;

/// 主题自带的图标遮罩图路径（按引擎同一顺序找第一个，大小写不敏感）：
///   ① IconBundles/Icon.png（含小写 icon.png）—— 经典 Anemone / WinterBoard 命名
///   ② 主题根目录 icon.png
///   ③ Bundles/com.apple.mobileicons.framework/AppIconMask*.png
///   ④ 旧写法兜底：IconMask.png → @3x → @2x → IconBundles/IconMask.png
///      → Bundles/com.apple.springboard/IconMask.png
/// 找不到返回 nil。不缓存（导入遮罩后立即能读到新文件）。
- (nullable NSString *)iconMaskPath;

/// AnemoneEffects 里的素材（叠加层 iPhoneOverlay / 阴影 iPhoneShadow）：
/// 依次找 @3x → @2x → 无后缀，大小写不敏感；找不到返回 nil。
/// 注意：AnemoneEffects 是"叠加层 / 阴影"，**不是**形状遮罩。
- (nullable NSString *)anemoneEffectPath:(NSString *)base;

/// 2x2 拼图封面（用于列表缩略图）
- (nullable UIImage *)coverImageWithSize:(CGFloat)size;

@end
