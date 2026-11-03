#import "TBThemeScanner.h"
#import "TBZip.h"
#import "TBPaths.h"
#import "TBImageUtil.h"
#import "TBDocImport.h"
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
    // 校验：必须含 IconBundles / Bundles（主题）或 AnemoneEffects / IconMask / Icon.png（素材包）
    NSString *srcPath = srcURL.path;
    BOOL looks = [self dirLooksLikeThemeOrAsset:srcPath];
    TBLog2(@"[导入][目录] src=%@ 像主题/素材=%d 有应用图标=%d",
           srcPath ?: @"(nil)", looks, [self dirHasAppIcons:srcPath]);
    if (!looks) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:3
                                            userInfo:@{NSLocalizedDescriptionKey:
                @"这个文件夹里既没有 IconBundles / Bundles（主题），也没有 AnemoneEffects / IconMask / Icon.png（素材包）"}];
        TBLog2(@"[导入][目录] ❌ 不是主题也不是素材包：%@", srcPath ?: @"(nil)");
        return nil;
    }
    // 目录里可能还套了一层（例如用户选的是解压出来的父文件夹）
    NSString *contentDir = srcPath;
    if (![self dirLooksLikeThemeOrAsset:srcPath]) contentDir = [self findContentDirIn:srcPath] ?: srcPath;
    NSString *niceName = [srcURL lastPathComponent];
    if (!niceName.length) niceName = @"导入";
    return [self placeImportedDir:contentDir niceName:niceName error:error];
}

// 在解包目录里找第一个含 IconBundles / Bundles 的文件夹（广度优先，取最浅的）
+ (NSString *)findThemeDirIn:(NSString *)root {
    return [self findContentDirIn:root];
}

/// 解包目录里找「内容目录」：主题包看 IconBundles / Bundles，
/// 素材包看 AnemoneEffects / Info.plist(TBKind) / Icon.png，两者都认（取最浅的）
+ (NSString *)findContentDirIn:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger guard = 0;
    while (stack.count && guard++ < 20000) {
        NSString *dir = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([self dirLooksLikeThemeOrAsset:dir]) return dir;
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if ([item hasPrefix:@"."] || [item isEqualToString:@"__MACOSX"]) continue;
            BOOL d = NO;
            NSString *sub = [dir stringByAppendingPathComponent:item];
            if ([fm fileExistsAtPath:sub isDirectory:&d] && d) [stack addObject:sub];
        }
    }
    return nil;
}

/// 这个目录像主题包或素材包（大小写不敏感地找子目录/文件）
+ (BOOL)dirLooksLikeThemeOrAsset:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!dir.length) return NO;
    NSArray *subs = [fm contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableSet<NSString *> *lower = [NSMutableSet set];
    for (NSString *s in subs) [lower addObject:s.lowercaseString];
    for (NSString *d in @[@"iconbundles", @"bundles", @"anemoneeffects", @"appiconmask"]) {
        if ([lower containsObject:d]) {
            BOOL isDir = NO;
            NSString *p = [dir stringByAppendingPathComponent:d];
            if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) return YES;
        }
    }
    for (NSString *f in @[@"icon.png", @"iconmask.png", @"icon@3x.png",
                          @"appiconmask@3x.png", @"info.plist"]) {
        if ([lower containsObject:f]) return YES;
    }
    return NO;
}

/// 目录里有「真正的应用图标」吗（IconBundles 里带点的 bundleID .png）
+ (BOOL)dirHasAppIcons:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *ib = nil;
    for (NSString *s in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([s caseInsensitiveCompare:@"IconBundles"] == NSOrderedSame) {
            BOOL d = NO;
            NSString *p = [dir stringByAppendingPathComponent:s];
            if ([fm fileExistsAtPath:p isDirectory:&d] && d) ib = p;
            break;
        }
    }
    if (!ib) return NO;
    for (NSString *f in [fm contentsOfDirectoryAtPath:ib error:NULL]) {
        if (![[f pathExtension].lowercaseString isEqualToString:@"png"]) continue;
        NSString *s = [f stringByDeletingPathExtension];
        if ([s hasSuffix:@"@2x"] || [s hasSuffix:@"@3x"]) s = [s substringToIndex:s.length - 3];
        if ([s rangeOfString:@"."].location != NSNotFound) return YES;
    }
    return NO;
}

/// 目录里的素材种类（mask / overlay / shadow / badge），找不到返回 nil
+ (NSString *)detectAssetKindIn:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *fx = nil;
    for (NSString *s in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([s caseInsensitiveCompare:@"AnemoneEffects"] == NSOrderedSame) {
            BOOL d = NO;
            NSString *p = [dir stringByAppendingPathComponent:s];
            if ([fm fileExistsAtPath:p isDirectory:&d] && d) fx = p;
            break;
        }
    }
    if (fx) {
        NSArray *files = [fm contentsOfDirectoryAtPath:fx error:NULL];
        for (NSString *f in files) {
            if ([f.lowercaseString hasPrefix:@"iphoneshadow"]) return @"shadow";
            if ([f.lowercaseString hasPrefix:@"iphoneoverlay"]) return @"overlay";
        }
    }
    for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([f.lowercaseString hasPrefix:@"sbbadgebg"]) return @"badge";
    }
    // 主题包里也有遮罩（IconBundles/Icon.png）→ 兜底算遮罩
    if ([self dirLooksLikeThemeOrAsset:dir]) return @"mask";
    return nil;
}

/// 把解包/复制出来的目录放到正确的位置：主题 → Themes/，素材包 → Assets/（并写 Info.plist）
+ (NSString *)placeImportedDir:(NSString *)srcDir niceName:(NSString *)niceName error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isAsset = ![self dirHasAppIcons:srcDir];
    NSString *name = niceName.length ? niceName : srcDir.lastPathComponent;
    NSString *dst = nil;
    if (isAsset) {
        NSString *root = [self writableAssetRoot];
        if (!root) {
            if (error) *error = [NSError errorWithDomain:@"TB" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"没有可写的素材目录（Assets）"}];
            return nil;
        }
        dst = [self uniqueDirectoryPathForName:name inRoot:root];
    } else {
        NSString *root = [self writableThemeRoot];
        if (!root) {
            if (error) *error = [NSError errorWithDomain:@"TB" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"没有可写的主题目录（Themes）"}];
            return nil;
        }
        dst = [self uniquePathForName:name inRoot:root];
    }
    TBLog2(@"[导入][放置] 判定=%@ 源=%@ → 目标=%@", isAsset ? @"素材包" : @"主题包", srcDir, dst);

    NSError *mvErr = nil;
    BOOL placed = NO;
    // 只有来自临时目录（iCloud 协调副本 / 解包目录）的才直接 move；
    // 用户自己选的目录一律 copy，绝不搬走用户的东西。
    NSString *tmpRoot = [NSTemporaryDirectory() stringByStandardizingPath];
    BOOL inTmp = [srcDir hasPrefix:tmpRoot];
    if (inTmp) placed = [fm moveItemAtPath:srcDir toPath:dst error:&mvErr];
    if (!placed) {
        // 跨卷 / 权限：退回"复制"（原目录在临时区时再删源）
        NSError *cpErr = nil;
        if (![fm copyItemAtPath:srcDir toPath:dst error:&cpErr]) {
            if (error) *error = cpErr ?: mvErr;
            TBLog2(@"[导入][放置] ❌ 移动失败(%@) 复制也失败(%@)",
                   mvErr.localizedDescription ?: @"-", cpErr.localizedDescription ?: @"-");
            return nil;
        }
        if (inTmp) [fm removeItemAtPath:srcDir error:NULL];
    }
    if (isAsset) {
        NSString *kind = [self detectAssetKindIn:dst] ?: @"mask";
        if (![fm fileExistsAtPath:[dst stringByAppendingPathComponent:@"Info.plist"]]) {
            [self writeAssetInfoAt:dst kind:kind name:name];
        }
        TBLog2(@"[导入][放置] ✅ 素材包已放入 Assets：%@（kind=%@）", dst, kind);
    } else {
        TBLog2(@"[导入][放置] ✅ 主题包已放入 Themes：%@", dst);
    }
    return dst;
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
    if (!url) {
        TBLog2(@"[导入][主题] ❌ 没有选择文件（url=nil）");
        if (error) *error = [NSError errorWithDomain:@"TB" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有选择文件"}];
        return nil;
    }
    TBLog2(@"[导入][主题] 入口 url=%@（%@）",
           url.absoluteString ?: @"(nil)", TBURLIsICloud(url) ? @"iCloud" : @"本地/其它 provider");
    // iCloud 云盘的文件在没下载时只是占位符（.icloud），直接 contentsOfFile: 拿到空数据。
    // 统一走 TBCopyCoordinatedItemToTemp：
    //   ① startAccessingSecurityScopedResource
    //   ② NSFileCoordinator + NSFileCoordinatorReadingForUploading（会触发 iCloud 下载）
    //   ③ 在 accessor 里把文件 / 整个目录递归复制到 NSTemporaryDirectory()
    // 之后再在副本上跑原来的本地导入流程。
    NSError *copyErr = nil;
    NSURL *tmp = TBCopyCoordinatedItemToTemp(url, &copyErr);
    if (!tmp) {
        TBLog2(@"[导入][主题] ❌ 复制到临时目录失败：%@", copyErr.localizedDescription ?: @"(无错误信息)");
        if (error) *error = copyErr ?: [NSError errorWithDomain:@"TB" code:7
            userInfo:@{NSLocalizedDescriptionKey: @"复制到临时目录失败"}];
        return nil;
    }
    TBLog2(@"[导入][主题] 临时副本=%@", tmp.path);

    __block NSString *result = nil;
    __block NSError *inner = nil;
    @try {
        result = [self importLocalURL:tmp error:&inner];
    } @catch (NSException *ex) {
        inner = [NSError errorWithDomain:@"TB" code:9
                                userInfo:@{NSLocalizedDescriptionKey:
                                               [NSString stringWithFormat:@"导入异常：%@", ex.reason ?: ex.name]}];
    }
    TBRemoveTempCopy(tmp);   // 临时副本用完即删（成功失败都删）

    if (result) {
        TBLog2(@"[导入][主题] ✅ 成功 → %@", result);
        return result;
    }
    TBLog2(@"[导入][主题] ❌ 本地导入失败：%@", (inner ?: copyErr).localizedDescription ?: @"(无错误信息)");
    if (error) *error = inner ?: copyErr;
    return nil;
}

+ (NSString *)importLocalURL:(NSURL *)url error:(NSError **)error {
    NSString *ext = [url pathExtension].lowercaseString;
    TBLog2(@"[导入][本地] url=%@ ext=%@", url.path ?: @"(nil)", ext ?: @"(无)");
    if ([ext isEqualToString:@"zip"]) {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"unzip-%@", [[NSUUID UUID] UUIDString]]];
        NSError *e = nil;
        TBLog2(@"[导入][zip] 开始解包 %@ → %@", url.path, tmp);
        BOOL unzipped = [TBZip unzipFileAtPath:url.path toDirectory:tmp error:&e];
        if (!unzipped) {
            TBLog2(@"[导入][zip] 内置解压失败（%@），改试系统 unzip", e.localizedDescription ?: @"-");
            [[NSFileManager defaultManager] createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:NULL];
            const char *cands[] = {"/var/jb/usr/bin/unzip", "/usr/bin/unzip"};
            for (int i = 0; i < 2 && !unzipped; i++) {
                if (![[NSFileManager defaultManager] isExecutableFileAtPath:@(cands[i])]) continue;
                const char *argv[] = {cands[i], "-o", "-q", url.path.UTF8String, "-d", tmp.UTF8String, NULL};
                pid_t pid; int st = 0;
                if (posix_spawn(&pid, cands[i], NULL, NULL, (char *const *)argv, environ) == 0) {
                    waitpid(pid, &st, 0);
                    unzipped = (WEXITSTATUS(st) == 0);
                    TBLog2(@"[导入][zip] %s 退出码=%d → %@", cands[i], WEXITSTATUS(st), unzipped ? @"成功" : @"失败");
                } else {
                    TBLog2(@"[导入][zip] 起不了 %s（沙盒/权限）", cands[i]);
                }
            }
        } else {
            TBLog2(@"[导入][zip] ✅ 内置解压成功");
        }
        if (!unzipped) {
            NSString *why = e.localizedDescription ?: @"未知原因";
            if (error) *error = [NSError errorWithDomain:@"TB" code:5 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"解压失败：内置解析与 unzip 都没成功（%@）。\n可以把 zip 先在「文件」App 里解压成文件夹，再用「导入」选那个文件夹。", why]}];
            TBLog2(@"[导入][zip] ❌ 解压最终失败：%@", why);
            return nil;
        }
        NSString *contentDir = [self findContentDirIn:tmp];
        TBLog2(@"[导入][zip] 解包内容：\n%@", [self describeTree:tmp limit:20]);
        if (!contentDir) {
            NSString *tree = [self describeTree:tmp limit:12];
            if (error) *error = [NSError errorWithDomain:@"TB" code:4 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"zip 里既没有主题资源（IconBundles / Bundles），也没有素材资源（AnemoneEffects / IconMask / Icon.png）。\n解压内容：\n%@", tree]}];
            TBLog2(@"[导入][zip] ❌ 没找到主题/素材目录");
            return nil;
        }
        if ([contentDir isEqualToString:tmp]) {
            // 解包出来的内容直接铺在临时根目录上（zip 里没有顶层文件夹）→ 先收进一个子目录
            NSString *holder = [tmp stringByAppendingPathComponent:@"tb-pack"];
            NSError *mk = nil;
            if ([[NSFileManager defaultManager] createDirectoryAtPath:holder withIntermediateDirectories:YES
                                                                    attributes:nil error:&mk]) {
                NSFileManager *fm = [NSFileManager defaultManager];
                NSMutableArray *move = [NSMutableArray array];
                for (NSString *it in [fm contentsOfDirectoryAtPath:tmp error:NULL]) {
                    if ([it hasPrefix:@"."] || [it isEqualToString:@"tb-pack"]) continue;
                    [move addObject:it];
                }
                for (NSString *it in move) {
                    [fm moveItemAtPath:[tmp stringByAppendingPathComponent:it]
                                toPath:[holder stringByAppendingPathComponent:it] error:NULL];
                }
                contentDir = holder;
                TBLog2(@"[导入][zip] zip 内容没有顶层文件夹 → 收进 %@", holder);
            }
        }
        // 用 zip 文件名更直观（解包出来的名字常常是 "xxx-master"）
        NSString *niceName = [[url lastPathComponent] stringByDeletingPathExtension];
        if (!niceName.length) niceName = @"导入";
        return [self placeImportedDir:contentDir niceName:niceName error:error];
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

    // 文件夹：整体搬进来（先经文件协调器复制到沙盒临时目录，iCloud 上的目录也能下载下来）
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:url.path isDirectory:&isDir] && isDir) {
        NSError *cpErr = nil;
        NSURL *tmp = TBCopyCoordinatedItemToTemp(url, &cpErr);
        if (!tmp) {
            if (error) *error = cpErr;
            return nil;
        }
        NSString *r = [self importAssetDirectory:tmp kind:k error:error];
        TBRemoveTempCopy(tmp);
        return r;
    }

    // 单个图片：必须走 NSFileCoordinator（iCloud 未下载的文件直接读会是占位符）
    NSError *readErr = nil;
    NSData *raw = TBReadCoordinatedData(url, &readErr);
    if (!raw.length) {
        if (error) *error = readErr ?: [NSError errorWithDomain:@"TB" code:7
            userInfo:@{NSLocalizedDescriptionKey: @"读不到图片（换一张 PNG/JPG 再试）"}];
        return nil;
    }
    UIImage *img = [[UIImage alloc] initWithData:raw];
    if (!img) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:7
            userInfo:@{NSLocalizedDescriptionKey:
                           TBImportFailureMessage(url, nil, @"读不到图片（换一张 PNG/JPG 再试）")}];
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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = theme.path;
    TBLog2(@"[删除] 请求删除「%@」path=%@ 素材包=%d", theme.name ?: @"?",
           path ?: @"(nil)", theme ? (int)theme.isAssetPack : 0);
    if (!path.length) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:10 userInfo:@{
            NSLocalizedDescriptionKey: @"这个条目没有可删除的目录（path 为空）"}];
        TBLog2(@"[删除] ❌ path 为空，无法删除");
        return NO;
    }
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:11 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"目录已经不存在：%@", path]}];
        TBLog2(@"[删除] ❌ 目录不存在：%@", path);
        return NO;
    }
    // 安全护栏：绝不删「主题根 / 素材根」本身
    for (NSString *root in @[ TBThemesRoot(), TBAssetsRoot() ]) {
        if ([path isEqualToString:root] || [root hasPrefix:[path stringByAppendingString:@"/"]]) {
            if (error) *error = [NSError errorWithDomain:@"TB" code:12 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"拒绝删除根目录：%@", path]}];
            TBLog2(@"[删除] ❌ 拒绝删除根目录：%@", path);
            return NO;
        }
    }
    BOOL underKnownRoot = NO;
    for (NSString *root in @[ TBThemesRoot(), TBAssetsRoot() ]) {
        if ([path hasPrefix:[root stringByAppendingString:@"/"]]) { underKnownRoot = YES; break; }
    }
    if (!underKnownRoot) TBLog2(@"[删除] ⚠️ 不在已知根目录下，仍然按 path 删除：%@", path);

    NSError *err = nil;
    BOOL ok = [fm removeItemAtPath:path error:&err];
    // 二次确认：有些路径 removeItemAtPath 返回 YES 但目录还在（文件系统写入延迟）
    if (ok && [fm fileExistsAtPath:path]) {
        ok = NO;
        if (!err) err = [NSError errorWithDomain:@"TB" code:13 userInfo:@{
            NSLocalizedDescriptionKey: @"删除后目录仍然存在（可能没有权限）"}];
    }
    TBLog2(@"[删除] %@ path=%@（%@）", ok ? @"✅ 成功" : @"❌ 失败", path,
           err.localizedDescription ?: @"无错误");
    if (!ok && error) *error = err ?: [NSError errorWithDomain:@"TB" code:14 userInfo:@{
        NSLocalizedDescriptionKey: @"删除失败（未知原因）"}];
    return ok;
}

@end
