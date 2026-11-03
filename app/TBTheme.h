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

#pragma mark - 素材包（和主题同层放在同一个主题根目录下）

/// 是不是「素材包」：没有任何 IconBundles/<反向域名>.png 形式的应用图标，
/// 但至少有遮罩 / 边框 / 阴影里的一样素材。
/// 判定与目录位置无关 —— 只看内容，所以主题根目录下的任意子目录都能识别。
@property (nonatomic, readonly) BOOL isAssetPack;

/// 素材包里可用的三类素材（绝对路径；没有就返回 nil）
@property (nonatomic, readonly, nullable) NSString *assetMaskPath;     // IconBundles/Icon.png 等
@property (nonatomic, readonly, nullable) NSString *assetOverlayPath;  // AnemoneEffects/iPhoneOverlay*
@property (nonatomic, readonly, nullable) NSString *assetShadowPath;   // AnemoneEffects/iPhoneShadow*

/// 主题自带的角标底板 SBBadgeBG（SpringBoard 通知角标圆形底板）：
///   ① Bundles/SBBadgeBG@3x.png / @2x / 无后缀       （素材包实际就是这个位置）
///   ② Bundles/com.apple.springboard/SBBadgeBG*      （经典 Anemone 位置）
///   ③ 主题根目录 SBBadgeBG*
/// 找不到返回 nil。
- (nullable NSString *)badgePath;

/// 素材包缩略图（取第一张能用的素材），给列表当封面用
- (nullable UIImage *)assetPreviewImage;

/// 这个目录是否在 Assets/ 根下（只用于显示/分组，判定仍以内容为准）
@property (nonatomic, readonly) BOOL inAssetsRoot;

/// 素材包能提供的项，每项：kind(mask/overlay/shadow) / title(遮罩/边框/阴影) / path / key(偏好键)
- (NSArray<NSDictionary<NSString *, NSString *> *> *)availableAssetItems;

/// 2x2 拼图封面（用于列表缩略图）
- (nullable UIImage *)coverImageWithSize:(CGFloat)size;

@end
