#import "TBThemeScanner.h"
#import "TBZip.h"
#import "TBPaths.h"
#import "TBImageUtil.h"
#import <spawn.h>
extern char **environ;

/// 扫描根 = 新结构下的 Themes/（主题包）+ Assets/（素材包）
static NSArray<NSString *> *TBScanRoots(void) {
    TBEnsureThemeBoardDirs();
    NSMutableArray *a = [NSMutableArray array];
    [a addObject:TBThemesRoot()];
    if (![a containsObject:TBAssetsRoot()]) [a addObject:TBAssetsRoot()];
    return a;
}

/// 这个子目录值不值得当条目收进来：
///   - 主题包：有 IconBundles / Bundles / 根目录 icon.png
///   - 素材包：只有 AnemoneEffects 或 AppIconMask 也算
/// 最终「是主题包还是素材包」由 TBTheme.isAssetPack 按内容判定。
static BOOL TBIsThemeLikeDirectory(NSString *dir) {
    if (!dir.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in @[@"IconBundles", @"AnemoneEffects", @"Bundles"]) {
        NSString *p = [dir stringByAppendingPathComponent:sub];
        BOOL d = NO;
        if ([fm fileExistsAtPath:p isDirectory:&d] && d) return YES;
    }
    for (NSString *f in @[@"Icon.png", @"icon.png", @"IconMask.png", @"AppIconMask@3x.png"]) {
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:f]]) return YES;
    }
    return NO;
}

@implementation TBThemeScanner

+ (NSArray<NSString *> *)themeRoots {
    return TBScanRoots();
}

+ (NSString *)writableThemeRoot {
    TBEnsureThemeBoardDirs();
    return TBThemesRoot();
}

+ (NSString *)writableAssetRoot {
    TBEnsureThemeBoardDirs();
    return TBAssetsRoot();
}

+ (NSArray<NSDictionary *> *)rootDiagnostics {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *all = [NSMutableArray array];
    [all addObjectsFromArray:TBScanRoots()];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in all) {
        BOOL isDir = NO;
        BOOL exists = [fm fileExistsAtPath:p isDirectory:&isDir];
        [out addObject:@{@"path": p,
                         @"exists": @(exists),
                         @"writable": @(exists && [fm isWritableFileAtPath:p]),
                         @"count": @(exists ? (NSInteger)[fm contentsOfDirectoryAtPath:p error:NULL].count : 0)}];
    }
    return out;
}

+ (NSString *)containerThemesDir {
    TBEnsureThemeBoardDirs();
    return TBThemesRoot();
}

+ (void)seedDemoThemesIfNeeded {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = TBThemesRoot();
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];

    NSArray *existing = [fm contentsOfDirectoryAtPath:root error:NULL];
    if (existing.count > 0) return;

    NSString *bundle = [[NSBundle mainBundle] pathForResource:@"DemoThemes" ofType:nil];
    NSArray *items = bundle ? [fm contentsOfDirectoryAtPath:bundle error:NULL] : nil;
    for (NSString *item in items) {
        if (![item hasSuffix:@".theme"]) continue;
        [fm copyItemAtPath:[bundle stringByAppendingPathComponent:item]
                    toPath:[root stringByAppendingPathComponent:item] error:NULL];
    }
}

+ (NSArray<TBTheme *> *)scanThemes {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<TBTheme *> *themes = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSString *root in [self themeRoots]) {
        NSArray *names = [fm contentsOfDirectoryAtPath:root error:NULL];
        for (NSString *n in names) {
            if ([n hasPrefix:@"."]) continue;
            NSString *full = [root stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir] || !isDir) continue;

            // 主题包和素材包平级放在同一个根目录下，这里两种都收：
            //   主题包 = 有 IconBundles（Anemone/SnowBoard 图标主题）
            //   素材包 = 只有 AnemoneEffects / AppIconMask / 根目录 icon.png
            if (!TBIsThemeLikeDirectory(full)) continue;

            TBTheme *t = [[TBTheme alloc] initWithPath:full];
            if ([seen containsObject:full]) continue;      // 同一个目录只收一次
            [seen addObject:full];
            [themes addObject:t];
        }
    }
    // 主题包排前面、素材包排后面，各自按名字
    [themes sortUsingComparator:^NSComparisonResult(TBTheme *a, TBTheme *b) {
        BOOL aa = a.isAssetPack, ba = b.isAssetPack;
        if (aa != ba) return aa ? NSOrderedDescending : NSOrderedAscending;
        return [a.name caseInsensitiveCompare:b.name];
    }];
    return themes;
}

+ (TBTheme *)themeNamed:(NSString *)name {
    if (name.length == 0) return nil;
    for (TBTheme *t in [self scanThemes]) {
        if ([t.name isEqualToString:name]) return t;
    }
    return nil;
}

+ (NSString *)uniquePathForName:(NSString *)name inRoot:(NSString *)root {
    NSString *base = name;
    NSString *ext = @"";
    if ([base hasSuffix:@".theme"]) {
        base = [base substringToIndex:base.length - 6];
        ext = @".theme";
    }
    NSString *candidate = [root stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"%@%@", base, ext.length ? ext : @".theme"]];
    int i = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
        candidate = [root stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@ %d.theme", base, i++]];
    }
    return candidate;
}

+ (NSString *)createAssetPackDirectoryNamed:(NSString *)name error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self writableThemeRoot];
    if (!root) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有可写的主题目录"}];
        return nil;
    }
    NSString *base = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!base.length) base = @"素材";
    // 去掉可能带进来的扩展名 / 路径分隔符，只留一个干净的名字
    base = [base stringByDeletingPathExtension];
    base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    if (!base.length) base = @"素材";

    NSString *candidate = [root stringByAppendingPathComponent:base];
    int i = 2;
    while ([fm fileExistsAtPath:candidate]) {
        candidate = [root stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@ %d", base, i++]];
    }
    NSError *err = nil;
    if (![fm createDirectoryAtPath:candidate withIntermediateDirectories:YES attributes:nil error:&err]) {
        if (error) *error = err;
        return nil;
    }
    return candidate;
}

+ (NSString *)importThemeDirectory:(NSURL *)srcURL error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self writableThemeRoot];
    if (!root) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有可写的主题目录"}];
        return nil;
    }

    // 校验：必须含 IconBundles 或 Bundles
    NSString *srcPath = srcURL.path;
    BOOL hasIB = [fm fileExistsAtPath:[srcPath stringByAppendingPathComponent:@"IconBundles"]];
    BOOL hasBundles = [fm fileExistsAtPath:[srcPath stringByAppendingPathComponent:@"Bundles"]];
    if (!hasIB && !hasBundles) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:3
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           @"这个文件夹里没有 IconBundles 或 Bundles"}];
        return nil;
    }

    NSString *dst = [self uniquePathForName:[srcURL lastPathComponent] inRoot:root];
    NSError *err = nil;
    if (![fm copyItemAtPath:srcPath toPath:dst error:&err]) {
        if (error) *error = err;
        return nil;
    }
    return dst;
}

// 在解包目录里找第一个含 IconBundles / Bundles 的文件夹（广度优先，取最浅的）
+ (NSString *)findThemeDirIn:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    // 递归找任何名为 IconBundles 的目录（最多 5 层）
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger guard = 0;
    while (stack.count && guard++ < 20000) {
        NSString *dir = stack.firstObject;
        [stack removeObjectAtIndex:0];

        NSString *ib = [dir stringByAppendingPathComponent:@"IconBundles"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:ib isDirectory:&isDir] && isDir) return dir;

        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if ([item hasPrefix:@"."] || [item isEqualToString:@"__MACOSX"]) continue;
            BOOL d = NO;
            NSString *sub = [dir stringByAppendingPathComponent:item];
            if ([fm fileExistsAtPath:sub isDirectory:&d] && d) [stack addObject:sub];
        }
    }
    return nil;
}

+ (NSString *)describeTree:(NSString *)root limit:(NSInteger)limit {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableString *out = [NSMutableString string];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger n = 0;
    while (stack.count && n < limit) {
        NSString *dir = stack.firstObject;
        [stack removeObjectAtIndex:0];
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if ([item hasPrefix:@"."]) continue;
            NSString *rel = [dir substringFromIndex:MIN(root.length, dir.length)];
            [out appendFormat:@"%@/%@\n", rel, item];
            if (++n >= limit) break;
            BOOL d = NO;
            NSString *sub = [dir stringByAppendingPathComponent:item];
            if ([fm fileExistsAtPath:sub isDirectory:&d] && d) [stack addObject:sub];
        }
    }
    return out;
}

+ (NSString *)importFromAnyURL:(NSURL *)url error:(NSError **)error {
    // iCloud 占位文件：先让文件协调器把它真正下载下来，再走本地流程
    __block NSString *result = nil;
    __block NSError *inner = nil;
    NSError *coordErr = nil;
    NSFileCoordinator *coord = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coord coordinateReadingItemAtURL:url options:0 error:&coordErr byAccessor:^(NSURL *newURL) {
        result = [self importLocalURL:newURL error:&inner];
    }];
    if (result) return result;
    if (error) *error = inner ?: coordErr;
    return nil;
}

+ (NSString *)importLocalURL:(NSURL *)url error:(NSError **)error {
    NSString *ext = [url pathExtension].lowercaseString;
    if ([ext isEqualToString:@"zip"]) {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"unzip-%@", [[NSUUID UUID] UUIDString]]];
        NSError *e = nil;
        BOOL unzipped = [TBZip unzipFileAtPath:url.path toDirectory:tmp error:&e];
        if (!unzipped) {
            [[NSFileManager defaultManager] createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:NULL];
            const char *cands[] = {"/var/jb/usr/bin/unzip", "/usr/bin/unzip"};
            for (int i = 0; i < 2 && !unzipped; i++) {
                if (![[NSFileManager defaultManager] isExecutableFileAtPath:@(cands[i])]) continue;
                const char *argv[] = {cands[i], "-o", "-q", url.path.UTF8String, "-d", tmp.UTF8String, NULL};
                pid_t pid; int st = 0;
                if (posix_spawn(&pid, cands[i], NULL, NULL, (char *const *)argv, environ) == 0) {
                    waitpid(pid, &st, 0);
                    unzipped = (WEXITSTATUS(st) == 0);
                }
            }
        }
        if (!unzipped) {
            if (error) *error = e ?: [NSError errorWithDomain:@"TB" code:5
                userInfo:@{NSLocalizedDescriptionKey: @"解压失败：内置解析与 unzip 都没成功"}];
            return nil;
        }
        NSString *themeDir = [self findThemeDirIn:tmp];
        if (!themeDir) {
            NSString *tree = [self describeTree:tmp limit:12];
            NSString *msg = [NSString stringWithFormat:@"zip 里没找到 IconBundles 目录。解压内容：\n%@", tree];
            if (error) *error = [NSError errorWithDomain:@"TB" code:4
                                                userInfo:@{NSLocalizedDescriptionKey: msg}];
            return nil;
        }
        // 解包出来的名字常常是 "xxx-master"，用 zip 文件名更直观
        NSString *niceName = [[url lastPathComponent] stringByDeletingPathExtension];
        NSString *root = [self writableThemeRoot];
        NSString *dst = [self uniquePathForName:niceName inRoot:root];
        NSError *e2 = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:themeDir toPath:dst error:&e2]) {
            if (error) *error = e2;
            return nil;
        }
        return dst;
    }
    return [self importThemeDirectory:url error:error];
}

+ (NSString *)themeDirInside:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"IconBundles"]]) return root;

    NSArray *items = [fm contentsOfDirectoryAtPath:root error:NULL];
    NSString *fallback = nil;
    for (NSString *it in items) {
        if ([it hasPrefix:@"."] || [it isEqualToString:@"__MACOSX"]) continue;
        NSString *p = [root stringByAppendingPathComponent:it];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) continue;
        if ([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"IconBundles"]]) return p;
        if (!fallback) fallback = p;
    }
    return fallback;
}


+ (NSArray<NSString *> *)zipsInDocuments {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:NULL];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *it in items) {
        if ([[it pathExtension].lowercaseString isEqualToString:@"zip"]) [out addObject:it];
    }
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

+ (NSString *)importZipInDocuments:(NSString *)zipName error:(NSError **)error {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:zipName]];
    return [self importFromAnyURL:url error:error];
}

#pragma mark - 素材包（Assets/）

/// 通用：在 root 下要一个不重名的目录（不带 .theme 后缀）
+ (NSString *)uniqueDirectoryPathForName:(NSString *)name inRoot:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    base = [base stringByDeletingPathExtension];
    base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    if (!base.length) base = @"素材";
    NSString *candidate = [root stringByAppendingPathComponent:base];
    int i = 2;
    while ([fm fileExistsAtPath:candidate]) {
        candidate = [root stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@ %d", base, i++]];
    }
    return candidate;
}

+ (NSString *)assetKindTitle:(NSString *)kind {
    if ([kind isEqualToString:@"overlay"]) return @"边框";
    if ([kind isEqualToString:@"shadow"])  return @"阴影";
    return @"遮罩";
}

/// 素材包里那份标记类型的 Info.plist（App 靠它 + 文件内容双重识别）
+ (void)writeAssetInfoAt:(NSString *)dir kind:(NSString *)kind name:(NSString *)name {
    NSDictionary *info = @{ @"TBKind": kind ?: @"mask",
                            @"TBName": name ?: [dir lastPathComponent],
                            @"TBAssetType": [self assetKindTitle:kind] };
    [info writeToFile:[dir stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
}

+ (NSString *)importAssetDirectory:(NSURL *)url kind:(NSString *)kind error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self writableAssetRoot];
    NSString *dst = [self uniqueDirectoryPathForName:[url lastPathComponent] inRoot:root];
    NSError *err = nil;
    if (![fm copyItemAtPath:url.path toPath:dst error:&err]) {
        if (error) *error = err ?: [NSError errorWithDomain:@"TB" code:6
            userInfo:@{NSLocalizedDescriptionKey: @"复制素材目录失败"}];
        return nil;
    }
    [self writeAssetInfoAt:dst kind:kind name:[url lastPathComponent]];
    return dst;
}

/// 导入素材：图片 → Assets/<名字>/{IconBundles/Icon.png | AnemoneEffects/iPhoneOverlay@3x.png}
/// kind: mask / overlay / shadow
+ (NSString *)importAssetFromURL:(NSURL *)url kind:(NSString *)kind error:(NSError **)error {
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"没有选择文件"}];
        return nil;
    }
    NSString *k = kind.length ? kind : @"mask";
    NSFileManager *fm = [NSFileManager defaultManager];

    // 文件夹：整体搬进来
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:url.path isDirectory:&isDir] && isDir) {
        return [self importAssetDirectory:url kind:k error:error];
    }

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *raw = [NSData dataWithContentsOfURL:url options:0 error:NULL];
    UIImage *img = raw.length ? [[UIImage alloc] initWithData:raw] : nil;
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!img) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:7
            userInfo:@{NSLocalizedDescriptionKey: @"读不到图片（换一张 PNG/JPG 再试）"}];
        return nil;
    }

    NSString *root = [self writableAssetRoot];
    NSString *baseName = [[url lastPathComponent] stringByDeletingPathExtension];
    if (!baseName.length) baseName = @"素材";
    NSString *dst = [self uniqueDirectoryPathForName:baseName inRoot:root];

    NSError *err = nil;
    if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:&err]) {
        if (error) *error = err;
        return nil;
    }

    NSString *rel = nil;
    NSData *png = nil;
    if ([k isEqualToString:@"overlay"]) {
        rel = @"AnemoneEffects/iPhoneOverlay@3x.png";
        png = TBPlainPNGDataFromImage(img);
    } else if ([k isEqualToString:@"shadow"]) {
        rel = @"AnemoneEffects/iPhoneShadow@3x.png";
        png = TBPlainPNGDataFromImage(img);
    } else {
        rel = @"IconBundles/Icon.png";
        png = TBMaskPNGDataFromImage(img);
    }
    NSString *file = [dst stringByAppendingPathComponent:rel];
    [fm createDirectoryAtPath:[file stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:NULL];
    if (!png.length || ![png writeToFile:file options:NSDataWritingAtomic error:&err]) {
        [fm removeItemAtPath:dst error:NULL];
        if (error) *error = err ?: [NSError errorWithDomain:@"TB" code:8
            userInfo:@{NSLocalizedDescriptionKey: @"写不进 Assets 目录"}];
        return nil;
    }
    [self writeAssetInfoAt:dst kind:k name:baseName];
    return dst;
}

+ (BOOL)deleteTheme:(TBTheme *)theme error:(NSError **)error {
    if (!theme.path) return NO;
    return [[NSFileManager defaultManager] removeItemAtPath:theme.path error:error];
}

@end
