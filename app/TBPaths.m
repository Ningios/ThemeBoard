#import "TBPaths.h"
#import <UIKit/UIKit.h>

#pragma mark - 日志（App 自己的小日志，和崩溃日志放一起）

static void TBPathLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[ThemeBoard] %@", msg);
    NSString *dir = @"/var/mobile/Library/ThemeBoard";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg ?: @""];
    NSString *path = [dir stringByAppendingPathComponent:@"paths.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *e) { }
        [fh closeFile];
    }
}

#pragma mark - 根目录

/// 首选：真正的共享目录 /var/mobile/Documents/ThemeBoard（引擎也读这里）
static NSString *const kTBCanonicalRoot = @"/var/mobile/Documents/ThemeBoard";

static NSString *TBAppContainerRoot(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) return nil;
    return [docs stringByAppendingPathComponent:@"ThemeBoard"];
}

NSString *TBThemeBoardRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *err = nil;
        // 父目录 /var/mobile/Documents 由系统保证存在（越狱环境）
        if (![fm fileExistsAtPath:kTBCanonicalRoot]) {
            [fm createDirectoryAtPath:kTBCanonicalRoot withIntermediateDirectories:YES
                           attributes:nil error:&err];
        }
        BOOL isDir = NO;
        BOOL ok = [fm fileExistsAtPath:kTBCanonicalRoot isDirectory:&isDir] && isDir &&
                  [fm isWritableFileAtPath:kTBCanonicalRoot];
        if (ok) {
            root = kTBCanonicalRoot;
        } else {
            root = TBAppContainerRoot() ?: kTBCanonicalRoot;
            [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
            TBPathLog(@"⚠️ %@ 不可写（%@），回退到 %@", kTBCanonicalRoot,
                      err.localizedDescription ?: @"不可写", root);
        }
        TBPathLog(@"根目录 = %@", root);
    });
    return root;
}

NSString *TBThemesRoot(void) {
    return [TBThemeBoardRoot() stringByAppendingPathComponent:@"Themes"];
}

NSString *TBAssetsRoot(void) {
    return [TBThemeBoardRoot() stringByAppendingPathComponent:@"Assets"];
}

BOOL TBEnsureThemeBoardDirs(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *themes = TBThemesRoot();
    NSString *assets = TBAssetsRoot();
    for (NSString *p in @[themes, assets]) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) {
            [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:NULL];
        }
    }
    BOOL isDir = NO;
    return [fm fileExistsAtPath:themes isDirectory:&isDir] && isDir && [fm isWritableFileAtPath:themes];
}

NSArray<NSString *> *TBLegacyThemeRoots(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length) [out addObject:[docs stringByAppendingPathComponent:@"Themes"]];   // 0.15.41 及以前真正在用的
    [out addObject:@"/var/mobile/Documents/Themes"];                                   // 需求点名的旧位置
    [out addObject:TBThemeBoardRoot()];                                                // 早前有人直接丢在根下
    [out addObject:@"/var/mobile/Library/Themes"];
    [out addObject:@"/var/jb/Library/Themes"];
    [out addObject:@"/var/jb/var/Library/Themes"];
    [out addObject:@"/Library/Themes"];
    return out;
}

BOOL TBPathEqualToPath(NSString *a, NSString *b) {
    if (!a.length || !b.length) return NO;
    NSString *x = [a stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *y = [b stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    return [x isEqualToString:y];
}

/// 目录看起来像主题 / 素材包（迁移时只搬这种，别把乱七八糟的东西搬进来）
static BOOL TBPathLooksLikeThemeDir(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in @[@"IconBundles", @"AnemoneEffects", @"Bundles"]) {
        BOOL d = NO;
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:sub] isDirectory:&d] && d) return YES;
    }
    for (NSString *f in @[@"Icon.png", @"icon.png", @"IconMask.png", @"AppIconMask@3x.png", @"Info.plist"]) {
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:f]]) {
            // Info.plist 只有配合上面的素材目录才算（避免把随便一个带 plist 的目录当主题）
            if ([f isEqualToString:@"Info.plist"]) continue;
            return YES;
        }
    }
    return NO;
}

#pragma mark - 启动迁移

NSString *TBMigrateLegacyThemeDirectories(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    TBEnsureThemeBoardDirs();

    NSString *themesRoot = TBThemesRoot();
    NSMutableString *summary = [NSMutableString string];
    NSInteger copied = 0, skipped = 0, failed = 0;

    for (NSString *legacy in TBLegacyThemeRoots()) {
        if (!legacy.length) continue;
        if (TBPathEqualToPath(legacy, themesRoot) || TBPathEqualToPath(legacy, TBAssetsRoot())) continue;

        BOOL isDir = NO;
        if (![fm fileExistsAtPath:legacy isDirectory:&isDir] || !isDir) continue;

        NSArray *items = [fm contentsOfDirectoryAtPath:legacy error:NULL];
        for (NSString *item in items) {
            if ([item hasPrefix:@"."]) continue;
            if ([item isEqualToString:@"Themes"] || [item isEqualToString:@"Assets"]) continue;   // 就是新结构本身
            if ([item isEqualToString:@"Exports"]) continue;                                       // 详情页导出目录，不是主题

            NSString *src = [legacy stringByAppendingPathComponent:item];
            BOOL d = NO;
            if (![fm fileExistsAtPath:src isDirectory:&d] || !d) continue;
            if (!TBPathLooksLikeThemeDir(src)) { continue; }

            NSString *dst = [themesRoot stringByAppendingPathComponent:item];
            if ([fm fileExistsAtPath:dst]) { skipped++; continue; }   // 已迁移过 / 同名已存在 → 跳过，绝不覆盖

            NSError *err = nil;
            if ([fm copyItemAtPath:src toPath:dst error:&err]) {
                copied++;
                TBPathLog(@"迁移主题：%@ → %@", src, dst);
            } else {
                failed++;
                // 失败只记录，不动源目录（用户主题不能丢）
                TBPathLog(@"⚠️ 迁移失败（跳过）：%@ → %@（%@）", src, dst,
                          err.localizedDescription ?: @"未知错误");
            }
        }
    }

    if (copied || failed) {
        [summary appendFormat:@"迁移：复制 %ld 个，跳过 %ld 个，失败 %ld 个", (long)copied, (long)skipped, (long)failed];
        TBPathLog(@"%@ → %@", summary, themesRoot);
    } else {
        [summary appendString:(skipped ? [NSString stringWithFormat:@"迁移：无新增（%ld 个已存在）", (long)skipped]
                                        : @"迁移：没有需要迁移的旧目录")];
    }
    return summary;
}

#pragma mark - 外部打开

BOOL TBOpenPathExternally(NSString *path) {
    if (!path.length) return NO;
    NSArray *cands = @[ [NSString stringWithFormat:@"filza://view%@", path],
                        [NSString stringWithFormat:@"shareddocuments://%@", path],
                        [NSString stringWithFormat:@"filza://%@", path] ];
    for (NSString *s in cands) {
        NSURL *u = [NSURL URLWithString:s];
        if (!u) continue;
        if ([[UIApplication sharedApplication] canOpenURL:u]) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            return YES;
        }
    }
    return NO;
}
