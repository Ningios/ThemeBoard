// ThemeBoardEngine v0.2 — 按 iOS 17.2 真实私有头文件重写
// 依据：headers/17.2/{SBHIconImageCache,SBIcon,SBLeafIcon,SBApplicationIcon,SBHIconManager}.h
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <ImageIO/ImageIO.h>

static NSString *const kDomain = @"com.ning.themeboard";
static NSString *const kNotify = @"com.ning.themeboard.changed";
static NSString *const kRespring = @"com.ning.themeboard.respring";
static NSString *const kActiveTheme = @"ActiveTheme";
static NSString *const kEnabled = @"Enabled";

#pragma mark - 结构（照头文件抄，ABI 必须一致）

typedef struct {
    CGSize size;      // 16B
    double scale;     // 8B
    double ratio;     // 8B
} TBImageInfo;        // 32B，HFA(4×double)，走 d0-d3

#pragma mark - 状态

static NSString *gLogPath;
static BOOL gIsPrimary = NO;      // 只有 SpringBoard 类进程写日志文件，避免多进程互相咬行
static dispatch_queue_t gLogQueue;
static NSMutableDictionary<NSString *, NSString *> *gIndex;
static NSString *gIndexTheme;
static NSMutableSet<NSValue *> *gCaches;
static NSCache *gImageCache;      // 已生成的图标缓存
static NSMutableDictionary *gFitCache;   // 已按尺寸适配过的图（避免每次调用都重画）
static NSMutableDictionary<NSString *, NSString *> *gBundleRes;   // 文件名 -> Bundles 里的路径
static NSLock *gLock;
static int gProbeCount = 0;      // 探针日志计数（每进程上限）
static NSUInteger gServe, gMiss;

#pragma mark - 日志

/// 运行时获取 iOS 版本主版本号（例如 17、26）
static int TBGetIOSVersion(void) {
    static int version = 17;  // 默认值为 17
    @try {
        NSProcessInfo *info = [NSProcessInfo processInfo];
        NSString *vstr = [info operatingSystemVersionString];
        NSArray *parts = [vstr componentsSeparatedByString:@"."];
        if (parts.count > 0) {
            NSString *firstPart = [parts objectAtIndex:0];
            version = [firstPart intValue];
            if (version <= 0) version = 17;  // 解析失败时回退
        }
    } @catch (...) { }
    return version;
}

/// 检测某个类是否有指定方法（运行时自适应）
static BOOL TBHasMethod(Class cls, NSString *selName) {
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(selName);
    return [cls instancesRespondToSelector:sel] || [cls respondsToSelector:sel];
}

static BOOL TBUIKitIconEnabled(void);
static NSString *TBBIDFromISIcon(id icon);
static NSString *TBProcName(void) {
    static NSString *name = nil;
    if (!name) name = [[NSProcessInfo processInfo] processName] ?: @"?";
    return name;
}

/// 用 C 文件 API 探测可写路径（NSFileManager 的 isWritable 在 SpringBoard 里会误报 NO）
static const char *TBLogFilePath(void) {
    static char path[256] = {0};
    if (path[0]) return path;
    const char *cands[] = {
        "/var/mobile/Library/ThemeBoard/engine.log",
        "/var/jb/var/mobile/Library/ThemeBoard/engine.log",
        // 守护进程（如 iconservicesagent）可能没有 /var/mobile 写权限，退到 /tmp
        "/tmp/themeboard-engine.log",
        "/var/tmp/themeboard-engine.log",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        FILE *f = fopen(cands[i], "a");
        if (f) {
            fclose(f);
            strncpy(path, cands[i], sizeof(path) - 1);
            return path;
        }
    }
    return NULL;
}

/// 探针：用于排查"某个界面到底走哪条取图接口"。
/// 与 TBLog 不同，它在所有进程里都写，且按进程名分文件，避免互相覆盖。
static void TBProbe(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *name = [[NSProcessInfo processInfo] processName] ?: @"unknown";
    NSString *dir = @"/var/mobile/Library/ThemeBoard";
    NSString *path = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"probe-%@.log", name]];
    FILE *f = fopen(path.UTF8String, "a+");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    if (size < 200 * 80) {          // 每进程最多约 200 行
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        fprintf(f, "%s %s\n", [[df stringFromDate:[NSDate date]] UTF8String], body.UTF8String);
    }
    fclose(f);
}

/// 日志超过 512KB 时截断，只保留后半，避免无限增长
static void TBTrimLog(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    if (sz < 512 * 1024) { fclose(f); return; }
    long keep = 256 * 1024;
    fseek(f, sz - keep, SEEK_SET);
    NSMutableData *d = [NSMutableData data];
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) [d appendBytes:buf length:n];
    fclose(f);
    [d writeToFile:@(path) atomically:YES];
}

static void TBLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *msg = [NSString stringWithFormat:@"[%@] %@", TBProcName(), body];
    NSLog(@"[ThemeBoard] %@", msg);

    // 所有进程都写，但每进程限量 60 行（用于观察 Preferences / iconservicesagent 等进程的行为）
    static int sPerProcLines = 0;
    if (sPerProcLines >= 2000) return;
    sPerProcLines++;
    const char *lp = TBLogFilePath();
    if (!lp) return;
    if (!gLogQueue) gLogQueue = dispatch_queue_create("themeboard.log", DISPATCH_QUEUE_SERIAL);
    TBTrimLog(lp);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];

    dispatch_async(gLogQueue, ^{
        FILE *f = fopen(lp, "a");
        if (!f) return;
        fprintf(f, "%s", [line UTF8String]);
        fclose(f);
    });
}

/// 同一 key 只记一次（启动时上百个图标会把日志配额吃光，导致后面的事件记不上）
static void TBLogOnce(NSString *key, NSString *fmt, ...) {
    static NSMutableSet *seen = nil;
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; lock = [[NSLock alloc] init]; });
    if (!key.length) return;
    [lock lock];
    BOOL first = ![seen containsObject:key];
    if (first && seen.count < 2000) [seen addObject:key];
    [lock unlock];
    if (!first) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    TBLog(@"%@", body);
}

#pragma mark - 设置 / 索引

static id TBPref(NSString *key) {
    // CFPreferences 在多进程间缓存不同步（曾导致 Spotlight/Preferences 里读到"无主题"）。
    // 直接读 plist 文件兜底，保证每个进程都能拿到当前设置。
    static NSDictionary *sCache = nil;
    static NSDate *sCacheTime = nil;
    NSDate *now = [NSDate date];
    if (!sCache || !sCacheTime || [now timeIntervalSinceDate:sCacheTime] > 2.0) {
        for (NSString *p in @[@"/var/mobile/Library/Preferences/com.ning.themeboard.plist",
                              @"/var/jb/var/mobile/Library/Preferences/com.ning.themeboard.plist"]) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            if (d) { sCache = d; break; }
        }
        sCacheTime = now;
    }
    if (sCache[key]) return sCache[key];

    return (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                           (__bridge CFStringRef)kDomain);
}
static BOOL TBSafeMode(void) {
    id v = TBPref(@"SafeMode");
    return v ? [v boolValue] : NO;
}

static BOOL TBEnabled(void) { id v = TBPref(kEnabled); return v ? [v boolValue] : YES; }
/// 分项开关（默认全开）。关掉某一项，对应位置保持系统原样。
static BOOL TBApplyEnabled(NSString *key) {
    id v = TBPref(key);
    return v ? [v boolValue] : YES;
}
/// 程序坞 / 文件夹预览 / App 切换器共用系统图标缓存，三开关任一开即允许替换。
static BOOL TBApplyIconForDesktop(void) {
    // 桌面图标：Dock、文件夹预览、App 切换器共用（打开任一即替换）
    return TBApplyEnabled(@"ApplyDock") || TBApplyEnabled(@"ApplyFolder") || TBApplyEnabled(@"ApplySwitcher");
}

static BOOL TBApplyIconForDock(void) {
    // Dock 独立开关
    return TBApplyEnabled(@"ApplyDock");
}

static BOOL TBApplyIconForFolder(void) {
    // 文件夹预览独立开关
    return TBApplyEnabled(@"ApplyFolder");
}

static BOOL TBApplyIconForSwitcher(void) {
    // App 切换器独立开关
    return TBApplyEnabled(@"ApplySwitcher");
}
static NSString *TBActiveTheme(void) {
    id v = TBPref(kActiveTheme);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSArray<NSString *> *TBRoots(void) {
    // App 容器路径优先（RootHide 下 App 只能写自己的容器，引擎在这里读）
    id root = TBPref(@"ThemeRoot");
    NSMutableArray *a = [NSMutableArray array];
    if ([root isKindOfClass:[NSString class]] && [root length]) [a addObject:root];
    [a addObjectsFromArray:@[@"/var/jb/Library/Themes", @"/var/mobile/Library/Themes",
                             @"/Library/Themes", @"/var/jb/var/Library/Themes"]];
    return a;
}

static NSString *TBThemeDir(NSString *name) {
    if (!name.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = @[ name, [name stringByAppendingString:@".theme"] ];
    for (NSString *root in TBRoots()) {
        for (NSString *n in names) {
            NSString *p = [root stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) return p;
        }
        // 再退一步：扫描该根目录，做包含匹配（大小写/空格差异也能命中）
        for (NSString *item in [fm contentsOfDirectoryAtPath:root error:NULL]) {
            BOOL isDir = NO;
            NSString *p = [root stringByAppendingPathComponent:item];
            if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) continue;
            NSString *base = [item hasSuffix:@".theme"] ? [item substringToIndex:item.length - 6] : item;
            if ([base caseInsensitiveCompare:name] == NSOrderedSame) return p;
        }
    }
    return nil;
}

static NSString *TBStripName(NSString *file) {
    NSString *s = [file stringByDeletingPathExtension];
    if ([s hasSuffix:@"@2x"] || [s hasSuffix:@"@3x"]) s = [s substringToIndex:s.length - 3];
    for (NSString *suf in @[@"-large", @"-small", @"-76", @"-60", @"-40"])
        if ([s hasSuffix:suf]) s = [s substringToIndex:s.length - suf.length];
    NSRange t = [s rangeOfString:@"~"];
    if (t.location != NSNotFound) s = [s substringToIndex:t.location];
    return s;
}

static void TBLoadIndex(void);          // 前置声明：TBResourceImage 会用到

static NSString *gBundleResTheme;
static void TBLoadBundleResources(NSString *themeDir);

/// 取当前主题的 Bundles 资源表。
/// 关键：**没有主题时必须清空** —— 之前只在有主题时重建，切回默认后表里还留着
/// 上一个主题的素材，于是"主题没有 ClockIconBackgroundSquare"永远判成有 → 时钟残留。
static NSMutableDictionary *TBThemeBundleRes(void) {
    NSString *theme = TBActiveTheme();
    NSString *dir = theme.length ? TBThemeDir(theme) : nil;
    if (!dir) {
        gBundleRes = nil;
        gBundleResTheme = nil;
        return nil;
    }
    TBLoadBundleResources(dir);
    return gBundleRes;
}

static void TBLoadBundleResources(NSString *themeDir) {
    // 之前只要建过一次就永不重建 —— 换主题后会一直用旧主题的资源表，
    // 导致「主题无此图」的假阴性（时钟底图就是这么丢的）。改为按主题目录缓存。
    if (gBundleRes && gBundleResTheme && [gBundleResTheme isEqualToString:themeDir]) return;
    gBundleRes = [NSMutableDictionary dictionary];
    gBundleResTheme = themeDir ?: @"";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [themeDir stringByAppendingPathComponent:@"Bundles"];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger guard = 0;
    while (stack.count && guard++ < 3000) {
        NSString *dir = stack.firstObject;
        [stack removeObjectAtIndex:0];
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            NSString *full = [dir stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) { [stack addObject:full]; continue; }
            if (![[item pathExtension].lowercaseString isEqualToString:@"png"]) continue;
            gBundleRes[item.lowercaseString] = full;
            NSString *base = [item.stringByDeletingPathExtension lowercaseString];
            if ([base hasSuffix:@"@2x"] || [base hasSuffix:@"@3x"])
                base = [base substringToIndex:base.length - 3];
            if (!gBundleRes[base]) gBundleRes[base] = full;
        }
    }
    TBLog(@"Bundles 资源 %lu 个", (unsigned long)gBundleRes.count);
}

/// 时钟底图这类素材自带「透明圆角」，直接交给系统会在四角透出壁纸。
/// 这里把透明像素用表盘底色填满（圆角交给图标遮罩去切）。
static UIImage *TBResourceImage(NSString *name);
static BOOL TBImageIsMostlyOpaque(CGImageRef cg);
static UIImage *TBMatchSystemGeometry(UIImage *img, UIImage *sys);
static UIImage *TBImageForBundle(NSString *bid);      // 前置：时钟判定要用
static UIImage *TBClockRoundedFace(UIImage *img);
static UIImage *TBClockMaterialFace(UIView *v);
static UIImage *TBClockMaterialFaceCached(UIView *v);
static BOOL TBThemeHasClockMaterial(void);
static UIImage *TBKeyOutCornerColor(UIImage *img);

/// 素材是否带透明像素（粗略判断：抽样看有没有 alpha 明显偏低的像素）
static BOOL TBImageHasTransparency(CGImageRef cg) {
    if (!cg) return YES;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 2 || h < 2) return YES;
    enum { N = 48 };
    unsigned char buf[N * N * 4];
    memset(buf, 0, sizeof(buf));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, N, N, 8, N * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) return YES;
    CGContextDrawImage(c, CGRectMake(0, 0, N, N), cg);
    CGContextRelease(c);
    for (int i = 0; i < N * N; i++) if (buf[i * 4 + 3] < 200) return YES;
    return NO;
}

/// 完全没透明的素材 → 把四角颜色当背景抠掉（作者导出时忘了去白底）
static UIImage *TBKeyOutCornerColor(UIImage *img) {
    if (!img || !img.CGImage) return img;
    if (TBImageHasTransparency(img.CGImage)) return img;   // 已有透明通道，不动
    size_t w = CGImageGetWidth(img.CGImage), h = CGImageGetHeight(img.CGImage);
    if (w < 4 || h < 4 || w * h > 8 * 1024 * 1024) return img;
    size_t bytes = w * h * 4;
    unsigned char *buf = malloc(bytes);
    if (!buf) return img;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) { free(buf); return img; }
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), img.CGImage);
    CGContextRelease(c);

    // 四角颜色
    long sr = 0, sg = 0, sb = 0;
    size_t corners[4] = {0, (w - 1) * 4, (h - 1) * w * 4, ((h - 1) * w + w - 1) * 4};
    for (int i = 0; i < 4; i++) { sr += buf[corners[i]]; sg += buf[corners[i] + 1]; sb += buf[corners[i] + 2]; }
    int cr = (int)(sr / 4), cg2 = (int)(sg / 4), cb = (int)(sb / 4);
    const int tol = 26;
    for (size_t i = 0; i < w * h; i++) {
        unsigned char *px = buf + i * 4;
        if (abs((int)px[0] - cr) < tol && abs((int)px[1] - cg2) < tol && abs((int)px[2] - cb) < tol) {
            px[0] = px[1] = px[2] = 0;
            px[3] = 0;
        }
    }
    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, buf, bytes, NULL);
    CGImageRef outCg = prov ? CGImageCreate(w, h, 8, 32, w * 4, CGColorSpaceCreateDeviceRGB(),
                                            kCGImageAlphaLast | kCGBitmapByteOrderDefault,
                                            prov, NULL, false, kCGRenderingIntentDefault) : NULL;
    if (prov) CGDataProviderRelease(prov);
    if (!outCg) { free(buf); return img; }
    UIImage *out = [UIImage imageWithCGImage:outCg];
    CGImageRelease(outCg);
    TBLogOnce(@"keyout", @"指针素材无透明通道，已按四角颜色抠底（rgb %d,%d,%d）", cr, cg2, cb);
    return out ?: img;
}

/// 把主题素材统一到「系统原本那张图」的尺寸与 scale。
/// 否则素材点数（800pt）与系统（180pt）不一致，系统会放大铺开 → 表盘看着歪掉/花纹不对。
static UIImage *TBMatchSystemGeometry(UIImage *img, UIImage *sys) {
    if (!img) return img;
    if (!sys || sys.size.width < 2 || sys.size.height < 2) return img;
    CGSize want = sys.size;
    CGFloat scale = sys.scale > 0 ? sys.scale : 3.0;
    if (fabs(img.size.width - want.width) < 1.0 && fabs(img.size.height - want.height) < 1.0) return img;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:want format:fmt];
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, want.width, want.height)];
    }];
    TBLogOnce(@"facescale", @"表盘几何归一：素材 %.0fpt scale=%.1f → 系统 %.0fpt scale=%.1f",
              img.size.width, img.scale, want.width, scale);
    return out ?: img;
}

/// 玻璃素材缓存（主体高度透明 = 玻璃层）
static NSMutableSet *gGlassNames;
static BOOL TBIsGlassResource(NSString *name) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gGlassNames = [NSMutableSet set]; });
    NSString *key = name.lowercaseString;
    if ([gGlassNames containsObject:key]) return YES;
    UIImage *img = TBResourceImage(name);
    if (!img || !img.CGImage) return NO;
    BOOL glass = !TBImageIsMostlyOpaque(img.CGImage);
    if (glass) [gGlassNames addObject:key];
    return glass;
}

/// 把半透明玻璃层垫上白色底盘，输出一张「完整表盘」用于真替换。
/// 不能直接拿玻璃当底图（透明处会露出时钟视图的深色底盘 → 变黑）。
static UIImage *TBFlattenOverWhite(UIImage *overlay) {
    if (!overlay) return nil;
    CGSize size = overlay.size;
    if (size.width < 1) return overlay;
    if (TBImageIsMostlyOpaque(overlay.CGImage)) return overlay;
    UIImage *base = [UIImage imageWithCGImage:overlay.CGImage
                                        scale:overlay.scale
                                  orientation:UIImageOrientationUp];
    CGFloat scale = overlay.scale > 0 ? overlay.scale : 3.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef gc = ctx.CGContext;
        CGContextSetRGBFillColor(gc, 1, 1, 1, 1);
        CGContextFillRect(gc, CGRectMake(0, 0, size.width, size.height));
        [base drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

/// 判断素材是否「主体不透明」（只有圆角透明）还是「半透明玻璃层」。
/// 玻璃类素材绝不能填白，否则玻璃感会被抹成白板。
static BOOL TBImageIsMostlyOpaque(CGImageRef cg) {
    if (!cg) return NO;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 4 || h < 4) return NO;
    enum { N = 32 };
    unsigned char buf[N * N * 4];
    memset(buf, 0, sizeof(buf));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, N, N, 8, N * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) return NO;
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextDrawImage(c, CGRectMake(0, 0, N, N), cg);
    CGContextRelease(c);
    long sum = 0;
    for (int i = 0; i < N * N; i++) sum += buf[i * 4 + 3];
    double mean = (double)sum / (double)(N * N) / 255.0;
    return mean > 0.70;   // 主体基本不透明才算「不透明素材」
}

static UIImage *TBMakeOpaqueOnBodyColor(UIImage *img) {
    if (!img || !img.CGImage) return img;
    CGImageRef cg = img.CGImage;
    if (!TBImageIsMostlyOpaque(cg)) {
        TBLogOnce(@"clockglass", @"时钟底图是半透明玻璃层：保持透明，不做填白");
        return img;
    }
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 2 || h < 2) return img;

    // 取中心附近像素作为底色（表盘主体色）
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    static unsigned char px[4]; px[0]=255; px[1]=255; px[2]=255; px[3]=255;
    CGContextRef probe = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast);
    if (probe) {
        CGContextDrawImage(probe, CGRectMake(-(CGFloat)w * 0.5, -(CGFloat)h * 0.5, (CGFloat)w, (CGFloat)h), cg);
        CGContextRelease(probe);
    }

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    fmt.opaque = YES;
    UIColor *body = [UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1.0];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, h) format:fmt];
    // 注意：必须用 UIKit 的绘制 API。在 UIKit 上下文里直接 CGContextDrawImage
    // 是 y 轴向上的语义，会把图上下翻转（表盘歪/镜像的元凶）。
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [body setFill];
        UIRectFill(CGRectMake(0, 0, w, h));
        [img drawInRect:CGRectMake(0, 0, w, h)];
    }];
    CGColorSpaceRelease(cs);
    return out ?: img;
}

/// 主题里是否有同名资源（表盘/指针/文件夹底等）
static UIImage *TBResourceImage(NSString *name) {
    if (!name.length || TBSafeMode() || !TBEnabled()) return nil;

    // 同一主题同一素材只解码一次（原来每次取图都重新读盘 + 解码 PNG）
    static NSMutableDictionary *gResCache = nil;
    static NSString *gResTheme = nil;
    static dispatch_once_t onceRes;
    dispatch_once(&onceRes, ^{ gResCache = [NSMutableDictionary dictionary]; });
    NSString *themeKey = TBActiveTheme() ?: @"";
    if (![themeKey isEqualToString:gResTheme ?: @""]) {
        [gResCache removeAllObjects];
        gResTheme = [themeKey copy];
    }
    NSString *ck = [themeKey stringByAppendingFormat:@"|%@", name];
    id cached = gResCache[ck];
    if (cached) return (cached == [NSNull null]) ? nil : cached;

    [gLock lock];
    TBLoadIndex();
    NSString *dir = nil;
    {
        NSString *theme = TBActiveTheme();
        dir = theme.length ? TBThemeDir(theme) : nil;
    }
    NSMutableDictionary *res = TBThemeBundleRes();   // 无主题 → 清空并返回 nil
    [gLock unlock];
    if (!res.count) { gResCache[ck] = [NSNull null]; return nil; }

    NSString *key = name.lastPathComponent.lowercaseString;
    NSString *path = res[key];
    if ([key hasPrefix:@"clockicon"]) {
        TBLogOnce([@"clocksrc|" stringByAppendingString:(TBActiveTheme() ?: @"")],
                  @"时钟素材来源[%@] %@ → %@",
                  TBActiveTheme() ?: @"?", key,
                  path ? [path stringByReplacingOccurrencesOfString:dir ?: @"" withString:@""] : @"(无)");
    }
    if (!path) {
        NSString *base = [key stringByDeletingPathExtension];
        if ([base hasSuffix:@"@2x"] || [base hasSuffix:@"@3x"])
            base = [base substringToIndex:base.length - 3];
        path = res[base];
    }
    // 必须用 init 方法：imageWithContentsOfFile: 已被本引擎 hook，
    // 在此调用会形成无限递归（栈溢出 → SpringBoard 崩溃循环）。
    if (!path) { gResCache[ck] = [NSNull null]; return nil; }
    UIImage *img = [[UIImage alloc] initWithContentsOfFile:path];
    gResCache[ck] = img ?: (id)[NSNull null];
    return img;
}

static void TBLoadIndex(void) {
    NSString *theme = TBActiveTheme();
    if (!theme) { gIndex = nil; gIndexTheme = nil; return; }
    if (gIndex && [gIndexTheme isEqualToString:theme]) return;

    NSString *dir = [TBThemeDir(theme) stringByAppendingPathComponent:@"IconBundles"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSMutableDictionary *rank = [NSMutableDictionary dictionary];
    for (NSString *f in files) {
        if (![[f pathExtension].lowercaseString isEqualToString:@"png"]) continue;
        NSString *bid = TBStripName(f);
        if (!bid.length) continue;
        NSInteger r = [f hasSuffix:@"@3x.png"] ? 3 : ([f hasSuffix:@"-large.png"] ? 3 : ([f hasSuffix:@"@2x.png"] ? 2 : 1));
        if ([rank[bid] integerValue] >= r) continue;
        map[bid] = [dir stringByAppendingPathComponent:f];
        rank[bid] = @(r);
    }
    BOOL first = (gIndex == nil);
    gIndex = map;
    gIndexTheme = theme;
    if (first) {
        TBLog(@"索引 %@ → %lu 个图标 (%@)", theme, (unsigned long)map.count, dir);
        if (map.count == 0) {
            TBLog(@"⚠️ 主题目录里没有 PNG：dir=%@", dir ?: @"(未找到目录)");
            TBLog(@"   候选根目录：%@", [TBRoots() componentsJoinedByString:@" | "]);
        }
    }
}

typedef struct { CGSize size; double scale; double ratio; } TBInfo;
typedef TBInfo (*TBInfoFn)(id, SEL);

/// 把主题图缩放成系统期望的尺寸（关键：否则会因 size 不匹配把 SpringBoard 弄崩）
static NSMutableDictionary<NSString *, UIImage *> *gFitCache;

static UIImage *TBFitImage(UIImage *img, TBInfo info) {
    if (!img) return nil;
    CGSize pt = info.size;
    CGFloat scale = info.scale > 0.5 ? info.scale : 3.0;
    if (pt.width < 1 || pt.height < 1) return img;
    if (fabs(img.size.width - pt.width) < 0.6 && fabs(img.size.height - pt.height) < 0.6) return img;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, pt.width, pt.height)];
    }];
}

static TBInfo TBInfoOfCache(id cache) {
    TBInfo info = {{60, 60}, 3.0, 0};
    if (!cache || ![cache respondsToSelector:NSSelectorFromString(@"iconImageInfo")]) return info;
    @try {
        TBInfoFn fn = (TBInfoFn)objc_msgSend;
        info = fn(cache, NSSelectorFromString(@"iconImageInfo"));
    } @catch (NSException *e) {}
    if (info.size.width < 1) { info.size = CGSizeMake(60, 60); info.scale = 3.0; }
    return info;
}

static CGFloat TBAverageLuma(UIImage *img) {
    if (!img.CGImage) return 0.5;
    unsigned char px[16 * 4];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 4, 4, 8, 16, cs, kCGImageAlphaPremultipliedLast);
    if (!ctx) { CGColorSpaceRelease(cs); return 0.5; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, 4, 4), img.CGImage);
    CGFloat sum = 0;
    for (int i = 0; i < 16; i++)
        sum += 0.299 * px[i*4] + 0.587 * px[i*4+1] + 0.114 * px[i*4+2];
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return sum / 16.0 / 255.0;
}

/// 日历 / 时钟这类动态图标：在主题底图上重绘实时内容
static UIImage *TBDynamicIcon(UIImage *base, NSString *bid) {
    // 主题图仅作为背景底图，日期/指针由系统动态绘制
    // 因此这里直接返回底图，不做任何重绘
    return base;
}

static BOOL TBIsDynamicBID(NSString *bid);
static NSString *TBDynamicResourcePath(NSString *bid);

/// 图标中央偏下区域是否已经有内容（主题自己画好了日期/数字）
/// 日期区指标：*ink 返回"墨"占比，*op 返回不透明占比（用来判断主题图标是否已画日期）
static BOOL TBImageDateAreaMetrics(UIImage *img, CGFloat *ink, CGFloat *op) {
    if (ink) *ink = 0; if (op) *op = 0;
    if (!img) return NO;
    if (!img) return NO;
    const size_t W = 64, H = 64;
    unsigned char *buf = calloc(W * H * 4, 1);
    if (!buf) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NO; }
    UIGraphicsPushContext(ctx);
    [img drawInRect:CGRectMake(0, 0, W, H)];
    UIGraphicsPopContext();
    CGContextRelease(ctx);

    NSInteger dark = 0, total = 0, opaque = 0;
    for (size_t y = (size_t)(H * 0.30); y < (size_t)(H * 0.85); y++) {
        for (size_t x = (size_t)(W * 0.25); x < (size_t)(W * 0.75); x++) {
            unsigned char *p = buf + (y * W + x) * 4;
            if (p[3] < 40) continue;
            CGFloat luma = 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
            total++;
            if (p[3] > 200) opaque++;
            if (luma < 110) dark++;
        }
    }
    free(buf);
    if (total < 10) return NO;
    CGFloat inkPct = dark * 100.0 / total;
    CGFloat opPct = opaque * 100.0 / total;
    if (ink) *ink = inkPct;
    if (op) *op = opPct;
    // 半透明（玻璃）底图不算"已画日期"：它没有日期可看，必须自己写上去
    if (opPct < 80) return NO;
    return inkPct > 3;
}

static BOOL TBImageHasContentInDateArea(UIImage *img) {
    return TBImageDateAreaMetrics(img, NULL, NULL);
}

/// 主题只给了 IconBundles 静态图标（Bundles 里没有整套动态素材）→
/// 图标自己就画了日期/指针，我们不该再叠一层
static BOOL TBThemeHasClockMaterial(void) {
    return TBResourceImage(@"ClockIconBackgroundSquare") != nil;
}

/// 日历合成（SnowBoard 同款）：主题底图 + 红色星期 + 黑色日期
/// 主题给的 com.apple.mobilecal.png 是空白日历底图，日期必须自己画上去
static UIImage *TBCalendarCompositeImage(UIImage *bg) {
    if (!bg) return nil;
    CGFloat w = bg.size.width > 1 ? bg.size.width : 180.0;
    CGFloat scale = bg.scale > 0 ? bg.scale : 3.0;

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDateComponents *comp = [cal components:(NSCalendarUnitDay | NSCalendarUnitWeekday) fromDate:now];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.locale = [NSLocale currentLocale];
    // 星期：短格式（周三 / Wed）
    // 用完整的「星期X」而不是缩写（周一）
    NSArray *weekdaySymbols = df.weekdaySymbols;
    NSString *weekText = @"";
    NSInteger wd = comp.weekday - 1;
    if (wd >= 0 && wd < (NSInteger)weekdaySymbols.count) weekText = weekdaySymbols[wd];
    NSString *dayText = [NSString stringWithFormat:@"%ld", (long)comp.day];

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, w) format:fmt];
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [bg drawInRect:CGRectMake(0, 0, w, w)];

        // 星期（红），字号 = 宽 × 0.1667
        UIFont *weekFont = [UIFont systemFontOfSize:w * 0.190000 weight:UIFontWeightSemibold];
        UIColor *red = [UIColor colorWithRed:1.0 green:0.23137 blue:0.18824 alpha:1.0];
        NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
        center.alignment = NSTextAlignmentCenter;
        NSDictionary *weekAttr = @{
            NSFontAttributeName: weekFont,
            NSForegroundColorAttributeName: red,
            NSParagraphStyleAttributeName: center,
        };
        CGFloat weekH = weekFont.lineHeight;
        [weekText drawInRect:CGRectMake(0, w * 0.115, w, weekH) withAttributes:weekAttr];

        // 日期数字（黑），字号 = 宽 × 0.6583
        UIFont *numFont = [UIFont systemFontOfSize:w * 0.658333 weight:UIFontWeightRegular];
        NSDictionary *numAttr = @{
            NSFontAttributeName: numFont,
            NSForegroundColorAttributeName: [UIColor blackColor],
            NSParagraphStyleAttributeName: center,
        };
        CGFloat numH = numFont.lineHeight;
        [dayText drawInRect:CGRectMake(0, w * 0.30, w, numH) withAttributes:numAttr];
    }];
    return out;
}

/// 取主题图：锁内只做字典查找，读盘/绘制都在锁外，避免 SpringBoard 被拖死
/// 图标圆角遮罩：系统图标是超椭圆遮罩（不是普通圆角矩形）。主题里方角素材
/// （WPS / 设置 / 相机 / 备忘录这些）不打遮罩就是方块，这里统一按超椭圆裁。
static UIImage *gSystemMaskTemplate;                 // 系统遮罩形状（学到后全用它）
static UIImage *TBMaskWithSystemShape(UIImage *art);
static UIImage *TBMaskWithThemeMask(UIImage *art, UIImage *mask);      // 用主题自带遮罩图裁
static UIImage *TBApplyIconShape(UIImage *img, BOOL skipIfRounded);    // 三种模式的统一入口

typedef id (*ContentsImgFn)(id, SEL);
static ContentsImgFn o_contentsImageLive, o_squareContentsImageLive;

typedef struct { double w, h, scale, ratio; } TBClockInfo;   // SBIconImageInfo 的等价布局
typedef TBClockInfo (*TBInfoGetFn)(id, SEL);
typedef void (*TBInfoSetFn)(id, SEL, TBClockInfo);


// 完全照 SnowBoard：roundedRectImageFromImage:withRadius:withCrop:YES
//   radius = (CustomCornerRadius / 60.0) * 图片宽度；上限 = 宽度的一半
//   SB 的 CustomCornerRadius 默认值 = 60 × 22.37% ≈ 13.42
// 我们自己那套（SB 的固定半径公式会"裁多了"）：
//   ① 已学到系统遮罩形状 → 按系统形状裁（最准）
//   ② 素材四角本来就透明（作者已做圆角）→ 跳过裁剪
//   ③ 兜底：按 22.37% 圆角裁
static BOOL TBIconArtAlreadyRounded(UIImage *img) {
    if (!img || !img.CGImage) return NO;
    const size_t W = 16, H = 16;
    unsigned char *buf = calloc(W * H * 4, 1);
    if (!buf) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NO; }
    UIGraphicsPushContext(ctx);
    [img drawInRect:CGRectMake(0, 0, W, H)];
    UIGraphicsPopContext();
    CGContextRelease(ctx);
    BOOL rounded = (buf[3] <= 24) && (buf[(W - 1) * 4 + 3] <= 24) &&
                   (buf[(H - 1) * W * 4 + 3] <= 24) &&
                   (buf[((H - 1) * W + W - 1) * 4 + 3] <= 24);
    free(buf);
    return rounded;
}

// ---- 图标形状：三种模式（优先级从高到低）----
//   ① UseThemeIconMask   主题自带遮罩图 IconMask.png 当 alpha 遮罩（作者明确要的形状）
//   ② MaskCornerRadiusOn 按 SnowBoard 的 CustomCornerRadius 算法裁圆角
//   ③ 现状              gSystemMaskTemplate → 已是圆角素材就跳过 → MIN(宽,高)×22.37% 兜底
static BOOL TBUseThemeIconMask(void) {
    id v = TBPref(@"UseThemeIconMask");
    return v ? [v boolValue] : NO;
}
static BOOL TBMaskCornerRadiusOn(void) {
    id v = TBPref(@"MaskCornerRadiusOn");
    return v ? [v boolValue] : NO;
}
/// AnemoneEffects：玻璃叠加层 / 图标阴影（都必须主题里真的有素材才生效）
static BOOL TBUseThemeIconOverlay(void) {
    id v = TBPref(@"UseThemeIconOverlay");
    return v ? [v boolValue] : NO;
}
static BOOL TBUseThemeIconShadow(void) {
    id v = TBPref(@"UseThemeIconShadow");
    return v ? [v boolValue] : NO;
}
/// CustomCornerRadius：SB 默认 60 × 22.37% ≈ 13.42（60 == 半径等于半宽）
static double TBMaskCornerRadius(void) {
    id v = TBPref(@"MaskCornerRadius");
    double r = 13.42;
    if ([v respondsToSelector:@selector(doubleValue)]) {
        double d = [v doubleValue];
        if (d == d && d >= 0.0) r = d;      // NaN / 负数 → 回到默认
    }
    return r;
}

/// 在一个目录里按名字找文件（大小写不敏感，命中第一个）
static NSString *TBFindFileCI(NSString *dir, NSString *name) {
    if (!dir.length || !name.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([item caseInsensitiveCompare:name] != NSOrderedSame) continue;
        NSString *p = [dir stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && !isDir) return p;
    }
    return nil;
}

/// 逐段解析相对目录（每段都大小写不敏感），任一段不存在就返回 nil
static NSString *TBResolveDirCI(NSString *base, NSString *rel) {
    if (!base.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *cur = base;
    for (NSString *comp in [rel componentsSeparatedByString:@"/"]) {
        if (!comp.length) continue;
        NSString *next = nil;
        for (NSString *item in [fm contentsOfDirectoryAtPath:cur error:NULL]) {
            NSString *full = [cur stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir &&
                [item caseInsensitiveCompare:comp] == NSOrderedSame) { next = full; break; }
        }
        if (!next) return nil;
        cur = next;
    }
    return cur;
}

/// 在目录里找「名字以 prefix 开头、以 .png 结尾」的文件（大小写不敏感），
/// 优先 @3x → @2x → 其它（~iphone / ~ipad 之类的后缀都照收）
static NSString *TBFindBestScaledPNG(NSString *dir, NSString *prefix) {
    if (!dir.length || !prefix.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *lp = prefix.lowercaseString;
    NSString *best = nil;
    NSInteger bestRank = -1;
    for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        NSString *li = item.lowercaseString;
        if (![li hasPrefix:lp] || ![li hasSuffix:@".png"]) continue;
        NSString *p = [dir stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir] || isDir) continue;
        NSInteger rank = [li rangeOfString:@"@3x"].location != NSNotFound ? 30
                       : ([li rangeOfString:@"@2x"].location != NSNotFound ? 20 : 10);
        if (rank > bestRank) { bestRank = rank; best = p; }
    }
    return best;
}

/// 遮罩图 alpha 分布统计（全部 0~1）：
///   p90 = 90 分位；solid = alpha>200 的占比；cov = alpha>=18 的占比（二值化后会保留的面积）
///   core = alpha >= 峰值一半 的占比（"核心"面积）
/// 用来区分「很淡的玻璃/渐变遮罩」和「真实形状遮罩」（0.15.47 一刀切二值化把两类都搞坏了）
typedef struct { double p90, solid, cov, core; } TBMaskStats;

static TBMaskStats TBMaskAlphaStats(UIImage *mask) {
    TBMaskStats st = { 1.0, 1.0, 1.0, 1.0 };
    if (!mask) return st;
    const size_t W = 64, H = 64;
    unsigned char *buf = calloc(W * H * 4, 1);
    if (!buf) return st;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return st; }
    UIGraphicsPushContext(ctx);
    [mask drawInRect:CGRectMake(0, 0, W, H)];
    UIGraphicsPopContext();
    CGContextRelease(ctx);

    int hist[256] = {0};
    const int total = (int)(W * H);
    int solid = 0, cov = 0, peak = 0;
    for (int i = 0; i < total; i++) {
        unsigned char a = buf[i * 4 + 3];
        hist[a]++;
        if (a > peak) peak = a;
        if (a > 200) solid++;
        if (a >= 18) cov++;
    }
    int core = 0;
    for (int a = peak / 2; a < 256; a++) core += hist[a];
    int acc = 0, p90 = 255;
    for (int a = 0; a < 256; a++) {
        acc += hist[a];
        if (acc * 10 >= total * 9) { p90 = a; break; }
    }
    free(buf);
    st.p90   = p90 / 255.0;
    st.solid = (double)solid / total;
    st.cov   = (double)cov / total;
    st.core  = (double)core / total;
    return st;
}

/// 「很淡」= 整体 alpha 偏低（p90 < 0.45）或几乎没有实心区（实心占比 < 0.5）
static BOOL TBMaskStatsLookFaint(TBMaskStats st) {
    return (st.p90 < 0.45) || (st.solid < 0.5);
}

/// 「淡玻璃 / 渐变玻璃层」——**不是形状遮罩**，应该当叠加层用。
/// 比 faint 更严一点，避免把"形状只占画布一小块"的真形状遮罩误判：
///   p90 < 0.45，或者（几乎没有实心区 且 p90 也不高）
static BOOL TBMaskStatsLookGlass(TBMaskStats st) {
    return (st.p90 < 0.45) || (st.solid < 0.15 && st.p90 < 0.75);
}

/// 主题自带遮罩图（大小写不敏感，按顺序命中第一个）。
/// 前三个是经典 Anemone / WinterBoard 的遮罩命名（真实主题里就是这个），
/// 我们自己的 IconMask.png 系列保留为最低优先级兜底：
///   ① IconBundles/Icon.png（含小写 icon.png）
///   ② 主题根目录 icon.png
///   ③ Bundles/com.apple.mobileicons.framework/AppIconMask*.png
///      （同目录还有 TableIconMask / SpotlightAppIconMask，这里只认 AppIconMask）
///   ④ IconMask.png → IconMask@3x.png → IconMask@2x.png
///      → IconBundles/IconMask.png → Bundles/com.apple.springboard/IconMask.png
/// 结果按主题名缓存：同一主题只扫一次盘，换主题或设置变更自动失效
/// （TBReload 里会清这个缓存，这样 App 导入遮罩后不用重启就生效）。
static UIImage *gMaskThemeImg;
static NSString *gMaskThemeKey;      // 缓存对应的主题名
static BOOL gMaskThemeChecked;
static UIImage *gMaskGlassImg;       // 淡玻璃遮罩（不当形状用，改当叠加层用）
static NSString *gMaskGlassKey;

/// 判定一张遮罩图到底是「形状」还是「淡玻璃层」：
///   淡玻璃/渐变玻璃 → 返回 nil（不当形状用），同时把它记到 gMaskGlassImg 给叠加层用；
///   真实形状（硬边 / 柔边都算）→ 原样返回。
static UIImage *TBGlassMaskOrShape(UIImage *img, NSString *key, NSString *label) {
    gMaskGlassImg = nil;
    gMaskGlassKey = nil;
    if (!img) return nil;
    TBMaskStats st = TBMaskAlphaStats(img);
    if (TBMaskStatsLookGlass(st)) {
        gMaskGlassImg = img;
        gMaskGlassKey = key;
        TBLogOnce([@"glassmask|" stringByAppendingString:key],
                  @"遮罩：%@ 偏淡/是渐变玻璃层（p90=%.2f 实心占比=%.2f 覆盖=%.2f）"
                  @"→ 不当形状遮罩用，改按玻璃叠加层处理（形状回落到自定义圆角 / 系统形状）",
                  label, st.p90, st.solid, st.cov);
        return nil;
    }
    TBLogOnce([@"shapemask|" stringByAppendingString:key],
              @"遮罩：%@ 用作形状遮罩（p90=%.2f 实心占比=%.2f 覆盖=%.2f 核心=%.2f）",
              label, st.p90, st.solid, st.cov, st.core);
    return img;
}

/// 淡玻璃遮罩改当玻璃叠加层：画在图标之上，alpha 乘 GlassOverlayStrength
static UIImage *TBThemeGlassFromFaintMask(void) {
    if (TBSafeMode() || !TBEnabled()) return nil;
    if (!TBUseThemeIconMask()) return nil;   // 只有在「遮罩」模式 / 素材包遮罩开关打开时才用
    if (!gMaskGlassImg || !gMaskGlassKey || !gMaskThemeKey) return nil;
    if (![gMaskGlassKey isEqualToString:gMaskThemeKey]) return nil;   // 缓存对不上就不冒险
    return gMaskGlassImg;
}

static UIImage *TBThemeMaskImage(void) {
    if (TBSafeMode() || !TBEnabled()) return nil;
    // 素材包（独立素材）优先：CustomMaskPath
    id cmp = TBPref(@"CustomMaskPath");
    if ([cmp isKindOfClass:[NSString class]] && [(NSString *)cmp length]) {
        NSString *k = [@"cmask:" stringByAppendingString:(NSString *)cmp];
        if (gMaskThemeChecked && gMaskThemeKey && [gMaskThemeKey isEqualToString:k]) return gMaskThemeImg;
        gMaskThemeKey = k; gMaskThemeChecked = YES;
        gMaskThemeImg = [[UIImage alloc] initWithContentsOfFile:(NSString *)cmp];
        TBLogOnce(k, @"遮罩：用独立素材 %@（%.0fx%.0f）", [(NSString *)cmp lastPathComponent],
                  gMaskThemeImg.size.width, gMaskThemeImg.size.height);
        gMaskThemeImg = TBGlassMaskOrShape(gMaskThemeImg, k, [(NSString *)cmp lastPathComponent]);
        return gMaskThemeImg;
    }
    NSString *theme = TBActiveTheme();
    if (!theme.length) return nil;
    if (gMaskThemeChecked && gMaskThemeKey && [gMaskThemeKey isEqualToString:theme]) return gMaskThemeImg;
    gMaskThemeKey = theme;
    gMaskThemeChecked = YES;
    gMaskThemeImg = nil;

    NSString *dir = TBThemeDir(theme);
    if (!dir.length) return nil;

    NSString *path = nil;
    NSString *iconBundles = TBResolveDirCI(dir, @"IconBundles");
    if (iconBundles.length) path = TBFindFileCI(iconBundles, @"Icon.png");        // ①
    if (!path) path = TBFindFileCI(dir, @"Icon.png");                             // ②
    if (!path) {                                                                  // ③
        NSString *fw = TBResolveDirCI(dir, @"Bundles/com.apple.mobileicons.framework");
        if (fw.length) path = TBFindBestScaledPNG(fw, @"AppIconMask");
    }
    if (!path) {                                                                  // ④ 旧写法兜底
        NSArray *cands = @[ @[@"",                             @"IconMask.png"],
                            @[@"",                             @"IconMask@3x.png"],
                            @[@"",                             @"IconMask@2x.png"],
                            @[@"IconBundles",                  @"IconMask.png"],
                            @[@"Bundles/com.apple.springboard", @"IconMask.png"] ];
        for (NSArray *c in cands) {
            NSString *sub = c[0], *name = c[1];
            NSString *d = sub.length ? TBResolveDirCI(dir, sub) : dir;
            if (!d.length) continue;
            NSString *p = TBFindFileCI(d, name);
            if (p) { path = p; break; }
        }
    }

    if (path.length) {
        // 必须用 init：imageWithContentsOfFile: 已被本引擎 hook（递归会爆栈）
        UIImage *img = [[UIImage alloc] initWithContentsOfFile:path];
        if (img) {
            TBLogOnce([@"thememask|" stringByAppendingString:theme],
                      @"图标形状：用主题遮罩图 %@（%.0fx%.0f pt）",
                      [path stringByReplacingOccurrencesOfString:dir withString:@""],
                      img.size.width, img.size.height);
            gMaskThemeImg = TBGlassMaskOrShape(img, theme,
                                               [path stringByReplacingOccurrencesOfString:dir withString:@""]);
            return gMaskThemeImg;
        }
    }
    TBLogOnce([@"thememask|none|" stringByAppendingString:theme],
              @"图标形状：主题里没有遮罩图（IconBundles/Icon.png、icon.png、AppIconMask*、IconMask.png 都没有），落到自定义圆角 / 系统形状");
    return nil;
}

/// 用主题遮罩图裁素材：遮罩图缩放到素材尺寸 → DestinationIn 只留遮罩不透明处
/// （和 TBMaskWithSystemShape 同一套做法，只是把"系统遮罩模板"换成"主题遮罩图"）
/// 遮罩图只取「形状」：把很淡的玻璃遮罩（alpha 0.1~0.5）二值化成 0/1。
/// 不处理的话 DestinationIn 会按 alpha 相乘 → 整个图标被压淡，就是用户说的「看不清」。
static UIImage *TBMaskShapeOnly(UIImage *mask) {
    if (!mask || !mask.CGImage) return mask;
    const size_t W = CGImageGetWidth(mask.CGImage), H = CGImageGetHeight(mask.CGImage);
    if (W < 8 || H < 8 || W > 1600 || H > 1600) return mask;
    size_t bpr = W * 4;
    unsigned char *buf = calloc(H * bpr, 1);
    if (!buf) return mask;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, bpr, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return mask; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), mask.CGImage);

    // ---- 先统计 alpha 分布，决定"要不要归一化" ----
    // 0.15.47 一刀切二值化把两类都搞坏了：
    //   ① 真实形状/软边遮罩（「虚化蒙版」）被压成满幅实心方块 → 看起来"没生效/形状坏了"
    //   ② 渐变玻璃遮罩（「透明遮罩」，下半部更淡）下半部被判成透明 → 图标下半截消失
    // 现在：只有"很淡的玻璃遮罩"才归一化；有大幅柔和渐变的（虚化）原样保留柔边。
    int hist[256] = {0};
    const size_t total = W * H;
    size_t solid = 0, cov = 0;
    int peak = 0;
    for (size_t i = 0; i < total; i++) {
        unsigned char a = buf[i * 4 + 3];
        hist[a]++;
        if (a > peak) peak = a;
        if (a > 200) solid++;
        if (a >= 18) cov++;
    }
    size_t core = 0;
    for (int a = peak / 2; a < 256; a++) core += hist[a];
    size_t acc = 0; int p90 = 255;
    for (int a = 0; a < 256; a++) { acc += hist[a]; if (acc * 10 >= total * 9) { p90 = a; break; } }
    double dp90 = p90 / 255.0, dsolid = (double)solid / total, dcov = (double)cov / total;
    BOOL faint = (dp90 < 0.45) || (dsolid < 0.5);
    // 二值化会大幅放大覆盖面积 → 说明这张图靠"大范围柔和渐变"定义外形（虚化/模糊），
    // 二值化会把柔边吃掉 → 原样返回，保留它自己的圆角与柔边。
    BOOL wideGradient = ((dcov - (double)core / total) > 0.25);
    if (!faint || wideGradient) {
        TBLogOnce([@"maskkeep|" stringByAppendingFormat:@"%.2f|%.2f|%d", dp90, dsolid, (int)wideGradient],
                  @"遮罩：原样使用（不当形状二值化）p90=%.2f 实心占比=%.2f 覆盖=%.2f 核心=%.2f → %@",
                  dp90, dsolid, dcov, (double)core / total,
                  (!faint ? @"真实形状/软边遮罩，保留它自己的圆角与柔边"
                          : @"有大幅柔和渐变（虚化/模糊遮罩），保留柔边"));
        CGContextRelease(ctx); free(buf);
        return mask;
    }
    TBLogOnce([@"maskbin|" stringByAppendingFormat:@"%.2f", dp90],
              @"遮罩：很淡的玻璃遮罩 → 二值化成形状 p90=%.2f 实心占比=%.2f 覆盖=%.2f",
              dp90, dsolid, dcov);
    for (size_t i = 0; i < total; i++) {
        unsigned char a = buf[i * 4 + 3], na = 0;
        if (a >= 18) na = 255;                            // ≥0.07 视为形状内部
        else if (a > 5) na = (unsigned char)((a - 5) * 255 / 13);   // 窄羽化
        buf[i * 4 + 0] = na; buf[i * 4 + 1] = na; buf[i * 4 + 2] = na;
        buf[i * 4 + 3] = na;
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx); free(buf);
    if (!out) return mask;
    UIImage *im = [UIImage imageWithCGImage:out scale:(mask.scale > 0.5 ? mask.scale : 3.0)
                                 orientation:mask.imageOrientation];
    CGImageRelease(out);
    return im ?: mask;
}

static UIImage *TBMaskWithThemeMask(UIImage *art, UIImage *mask) {
    if (!art || !mask) return art;
    mask = TBMaskShapeOnly(mask);                  // ★ 只取形状，避免把图标压淡
    CGSize pt = art.size;
    if (pt.width < 1 || pt.height < 1) return art;
    if (mask.size.width < 1 || mask.size.height < 1) return art;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = art.scale > 0.5 ? art.scale : 3.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [art drawInRect:CGRectMake(0, 0, pt.width, pt.height)];
        [mask drawInRect:CGRectMake(0, 0, pt.width, pt.height)   // 按素材尺寸缩放遮罩图
               blendMode:kCGBlendModeDestinationIn alpha:1.0];
    }];
}

/// 按给定半径裁圆角（SB roundedRectImageFromImage:withRadius:withCrop:YES 同款）
static UIImage *TBRoundedCornerImage(UIImage *img, CGFloat radius) {
    CGSize pt = img.size;
    if (pt.width < 1 || pt.height < 1) return img;
    if (radius < 0) radius = 0;
    CGFloat maxR = pt.width / 2.0;
    if (radius > maxR) radius = maxR;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = img.scale > 0.5 ? img.scale : 3.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt];
    return [rd imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, pt.width, pt.height)
                                                    cornerRadius:radius];
        [p addClip];
        [img drawInRect:CGRectMake(0, 0, pt.width, pt.height)];
    }];
}

/// 把「四角本来就透明的圆角素材」补成方角：用同行/同列最近的边缘像素颜色填四角。
/// 不补的话，素材自己的圆角永远盖过设置 —— 自定义圆角调小（更方）会完全看不出效果。
static NSMapTable *gSquareFillCache;
static UIImage *TBArtSquareFilled(UIImage *img) {
    if (!img || !img.CGImage) return img;
    // ★ 0.15.71 性能：补方角只是"用边缘颜色填四角"，不需要原分辨率。
    //   大图先降到 ~120px 再做逐像素填充（原来 180~540px 全分辨率跑两趟，
    //   换主题/改遮罩后回桌面要给上百个图标各做一次 → 明显掉帧）。
    {
        size_t w0 = CGImageGetWidth(img.CGImage);
        if (w0 > 120) {
            CGFloat ratio = 120.0 / (CGFloat)w0;
            CGSize small = CGSizeMake(round(img.size.width * ratio),
                                      round(img.size.height * ratio));
            UIGraphicsImageRendererFormat *f2 = [UIGraphicsImageRendererFormat defaultFormat];
            f2.scale = img.scale > 0.5 ? img.scale : 3.0;
            f2.opaque = NO;
            UIGraphicsImageRenderer *rd2 = [[UIGraphicsImageRenderer alloc] initWithSize:small format:f2];
            UIImage *sc = [rd2 imageWithActions:^(UIGraphicsImageRendererContext *c2) {
                [img drawInRect:CGRectMake(0, 0, small.width, small.height)];
            }];
            if (sc.CGImage) img = sc;
        }
    }
    const size_t W = CGImageGetWidth(img.CGImage), H = CGImageGetHeight(img.CGImage);
    if (W < 8 || H < 8 || W > 1400 || H > 1400) return img;
    if (!gSquareFillCache) gSquareFillCache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                                                   valueOptions:0];
    UIImage *hit = [gSquareFillCache objectForKey:img];
    if (hit) return hit;

    const size_t bpr = W * 4;
    unsigned char *buf = calloc(H * bpr, 1);
    if (!buf) return img;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, bpr, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return img; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), img.CGImage);

    // 四角都不透明 → 本来就是方角素材，不用补
    if (buf[3] > 24 && buf[(W - 1) * 4 + 3] > 24 &&
        buf[(H - 1) * bpr + 3] > 24 && buf[(H - 1) * bpr + (W - 1) * 4 + 3] > 24) {
        CGContextRelease(ctx); free(buf);
        [gSquareFillCache setObject:img forKey:img];
        return img;
    }

    int *xl = calloc(H, sizeof(int)), *xr = calloc(H, sizeof(int));
    int *yt = calloc(W, sizeof(int)), *yb = calloc(W, sizeof(int));
    if (!xl || !xr || !yt || !yb) { free(xl); free(xr); free(yt); free(yb); free(buf); CGContextRelease(ctx); return img; }
    for (size_t y = 0; y < H; y++) {
        xl[y] = -1; xr[y] = -1;
        for (size_t x = 0; x < W; x++) {
            if (buf[y * bpr + x * 4 + 3] > 24) { if (xl[y] < 0) xl[y] = (int)x; xr[y] = (int)x; }
        }
    }
    for (size_t x = 0; x < W; x++) {
        yt[x] = -1; yb[x] = -1;
        for (size_t y = 0; y < H; y++) {
            if (buf[y * bpr + x * 4 + 3] > 24) { if (yt[x] < 0) yt[x] = (int)y; yb[x] = (int)y; }
        }
    }
    for (size_t y = 0; y < H; y++) {
        if (xl[y] < 0) continue;
        for (size_t x = 0; x < W; x++) {
            unsigned char *d = &buf[y * bpr + x * 4];
            if (d[3] > 24) continue;
            const unsigned char *src = NULL;
            int hd = -1, vd = -1;
            if ((int)x < xl[y])      { hd = xl[y] - (int)x; src = &buf[y * bpr + (size_t)xl[y] * 4]; }
            else if ((int)x > xr[y]) { hd = (int)x - xr[y]; src = &buf[y * bpr + (size_t)xr[y] * 4]; }
            if (yt[x] >= 0 && (int)y < yt[x]) {
                int d2 = yt[x] - (int)y;
                if (hd < 0 || d2 < hd) { vd = d2; src = &buf[(size_t)yt[x] * bpr + x * 4]; }
            } else if (yb[x] >= 0 && (int)y > yb[x]) {
                int d2 = (int)y - yb[x];
                if (hd < 0 || d2 < hd) { vd = d2; src = &buf[(size_t)yb[x] * bpr + x * 4]; }
            }
            if (!src) continue;
            d[0] = src[0]; d[1] = src[1]; d[2] = src[2]; d[3] = 255;
        }
    }
    free(xl); free(xr); free(yt); free(yb);
    CGImageRef outRef = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    if (!outRef) return img;
    UIImage *out = [UIImage imageWithCGImage:outRef scale:(img.scale > 0.5 ? img.scale : 3.0)
                                 orientation:img.imageOrientation];
    CGImageRelease(outRef);
    if (out) [gSquareFillCache setObject:out forKey:img];
    return out ?: img;
}

/// 图标形状统一入口（图标与时钟表盘共用）：
///   ① 主题遮罩图（作者明确要的形状，这个模式下不做"已圆角就跳过"排查）
///   ② skipIfRounded：素材四角本来透明 → 直接返回，避免裁多
///   ③ MaskCornerRadiusOn：radius = (MaskCornerRadius / 60) × 宽度，上限 宽/2
///   ④ gSystemMaskTemplate：按系统遮罩形状裁（现状）
///   ⑤ 兜底 MIN(宽,高) × 0.2237（现状）
static UIImage *TBApplyIconShape(UIImage *img, BOOL skipIfRounded) {
    if (!img) return img;
    if (TBUseThemeIconMask()) {                       // ① 主题自带遮罩图
        UIImage *m = TBThemeMaskImage();
        if (m) return TBMaskWithThemeMask(img, m);
        // 主题里没有遮罩图 → 继续往下落到 ② / ③
    }
    CGSize pt = img.size;
    if (pt.width >= 1 && pt.height >= 1 && TBMaskCornerRadiusOn()) {  // ② 自定义圆角半径（用户显式选了就以它为准）
        CGFloat radius = (CGFloat)(TBMaskCornerRadius() / 60.0) * pt.width;
        UIImage *square = TBArtSquareFilled(img);      // 素材自带圆角 → 先补成方角，半径才看得出变化
        TBLogOnce([@"maskradius|" stringByAppendingFormat:@"%@", TBActiveTheme() ?: @""],
                  @"图标形状：自定义圆角 %.2f → radius %.2f（%.0fpt 宽）%@",
                  TBMaskCornerRadius(), radius, pt.width, (square == img ? @"" : @"（已补方角）"));
        return TBRoundedCornerImage(square, radius);
    }
    if (skipIfRounded && TBIconArtAlreadyRounded(img)) return img;    // ③ 已是圆角素材 → 不裁
    if (gSystemMaskTemplate) return TBMaskWithSystemShape(img);       // ④ 按系统形状裁（现状）
    if (pt.width < 16 || pt.height < 16) return img;                  // 现状：太小不动
    return TBRoundedCornerImage(img, MIN(pt.width, pt.height) * 0.2237);  // ⑤ 兜底（现状）
}

static UIImage *TBGlobalEffectImage(UIImage *src, NSString *bid);   // 前置：缓存写入端要用

static UIImage *TBIconRoundedImage(UIImage *img) {
    return TBApplyIconShape(img, YES);   // 图标：保留"已是圆角素材就跳过"保护
}

// ---- AnemoneEffects：玻璃叠加层 / 图标阴影 ----
//   AnemoneEffects/iPhoneOverlay@3x.png → @2x → 无后缀   叠在图标之上
//   AnemoneEffects/iPhoneShadow@3x.png  → @2x            垫在图标之下
// 只看这两个名字；icon_shortcut_mask 之类的专用遮罩不算，AnemoneEffects 也不当形状遮罩用。
// 结果按「主题名 + 名字」缓存，设置变更（TBReload）时清掉。
static UIImage *gFxImg[2];
static NSString *gFxKey[2];
static BOOL gFxChecked[2];
static UIImage *TBThemeFxImage(int slot, NSString *base) {
    if (TBSafeMode() || !TBEnabled()) return nil;
    // 素材包（独立素材）优先：CustomOverlayPath / CustomShadowPath
    id cp = TBPref(slot == 0 ? @"CustomOverlayPath" : @"CustomShadowPath");
    if ([cp isKindOfClass:[NSString class]] && [(NSString *)cp length]) {
        NSString *ck = [(slot == 0 ? @"ovl:" : @"shd:") stringByAppendingString:(NSString *)cp];
        if (gFxChecked[slot] && gFxKey[slot] && [gFxKey[slot] isEqualToString:ck]) return gFxImg[slot];
        gFxKey[slot] = ck; gFxChecked[slot] = YES;
        gFxImg[slot] = [[UIImage alloc] initWithContentsOfFile:(NSString *)cp];
        if (gFxImg[slot]) TBLogOnce(ck, @"特效：用独立素材 %@（%.0fx%.0f）", [(NSString *)cp lastPathComponent],
                                    gFxImg[slot].size.width, gFxImg[slot].size.height);
        return gFxImg[slot];
    }
    NSString *theme = TBActiveTheme();
    if (!theme.length) return nil;
    if (gFxChecked[slot] && gFxKey[slot] && [gFxKey[slot] isEqualToString:theme]) return gFxImg[slot];
    gFxKey[slot] = theme;
    gFxChecked[slot] = YES;
    gFxImg[slot] = nil;

    NSString *dir = TBThemeDir(theme);
    if (!dir.length) return nil;
    NSString *fx = TBResolveDirCI(dir, @"AnemoneEffects");
    if (!fx.length) return nil;
    NSArray *names = @[ [base stringByAppendingString:@"@3x.png"],
                        [base stringByAppendingString:@"@2x.png"],
                        [base stringByAppendingString:@".png"] ];
    for (NSString *n in names) {
        NSString *p = TBFindFileCI(fx, n);
        if (!p) continue;
        // 必须用 init：imageWithContentsOfFile: 已被本引擎 hook（递归会爆栈）
        UIImage *img = [[UIImage alloc] initWithContentsOfFile:p];
        if (!img) continue;
        gFxImg[slot] = img;
        TBLogOnce([@[@"overlay|", @"shadow|"][slot] stringByAppendingString:theme],
                  @"特效：用 %@（%.0fx%.0f pt）", n, img.size.width, img.size.height);
        return img;
    }
    return nil;
}
static UIImage *TBThemeOverlayImage(void) { return TBThemeFxImage(0, @"iPhoneOverlay"); }
static UIImage *TBThemeShadowImage(void)  { return TBThemeFxImage(1, @"iPhoneShadow"); }

/// 玻璃叠加层（iPhoneOverlay / 淡玻璃遮罩）强度：0 = 完全不画，1 = 原样叠加。
/// 0.15.48 默认 0.35 → 用户反馈「立体玻璃-遮罩B」「透明玻璃遮罩」都不明显了
/// （0.15.47 及以前是按 alpha 1.0 整张叠上去的）。0.15.49 默认回到 0.6，
/// 观感接近以前，同时保留 0~100% 可调（0 才是关闭）。
static double TBGlassOverlayStrength(void) {
    id v = TBPref(@"GlassOverlayStrength");
    double s = v ? [v doubleValue] : 0.6;
    if (!(s >= 0.0)) s = 0.0;
    if (s > 1.0) s = 1.0;
    return s;
}

/// 把 overlay 按图标的最终形状裁一刀：DestinationIn 取图标自身的 alpha。
/// 不裁的话，遮罩与玻璃层圆角不匹配时玻璃层会在边角溢出色块（"边角露出来"）。
/// iconRect = 图标在合成画布里的位置（有阴影时图标会缩小居中，这里要跟着走）。
static UIImage *TBMaskOverlayToIconAlpha(UIImage *overlay, UIImage *icon, CGRect iconRect) {
    if (!overlay || !icon) return overlay;
    CGSize pt = iconRect.size;
    if (pt.width < 1 || pt.height < 1) return overlay;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = icon.scale > 0.5 ? icon.scale : 3.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0, 0, pt.width, pt.height);
        [overlay drawInRect:rect];
        [icon drawInRect:rect blendMode:kCGBlendModeDestinationIn alpha:1.0];
    }];
}

/// 量出图里"有内容"的区域（单位坐标 0~1）。失败返回 NO。
/// 阴影素材自带很大边距（实测「立体玻璃-遮罩B」：画布 340×340，可见云团只占 48%×51%），
/// 不量的话把整张素材按图标 rect 画，云团只有图标宽度的 48%，全被图标盖住。
static BOOL TBImageContentBBox(UIImage *img, CGRect *out) {
    if (!img) return NO;
    const size_t W = 64, H = 64;
    unsigned char *buf = calloc(W * H * 4, 1);
    if (!buf) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NO; }
    UIGraphicsPushContext(ctx);
    [img drawInRect:CGRectMake(0, 0, W, H)];
    UIGraphicsPopContext();
    CGContextRelease(ctx);

    int minx = (int)W, maxx = -1, miny = (int)H, maxy = -1;
    for (int y = 0; y < (int)H; y++) {
        for (int x = 0; x < (int)W; x++) {
            if (buf[((size_t)y * W + x) * 4 + 3] < 8) continue;
            if (x < minx) minx = x;
            if (x > maxx) maxx = x;
            if (y < miny) miny = y;
            if (y > maxy) maxy = y;
        }
    }
    free(buf);
    if (maxx < 0 || maxy < 0) return NO;
    if (out) *out = CGRectMake((double)minx / W, (double)miny / H,
                               (double)(maxx - minx + 1) / W, (double)(maxy - miny + 1) / H);
    return YES;
}

// ---- 阴影 ----
// 0.15.48 把图标缩到 0.80 居中让阴影露出来 —— 用户不接受（"一开阴影图标就变小"）。
// 0.15.49 起：**图标尺寸完全不变**（kTBShadowIconScale = 1.00），阴影改走【视图层】
// （见 TBApplyIconLayerShadow：给图标视图的 layer 设 shadowColor/Opacity/Radius/Offset
//  + shadowPath 圆角矩形）。图内合成只保留很轻的一圈（云团 1.06 倍 + 整体下移），
// 保证纯图内通道（系统图标缓存里的那张图）也能看到阴影的边。
static const CGFloat kTBShadowIconScale   = 1.00;   // 图标不缩小（1.00 = 与画布同尺寸）
static const CGFloat kTBShadowCloudToIcon = 1.06;   // 阴影可见云团 = 图标的 1.06 倍 → 只在边缘露一圈
static const CGFloat kTBShadowOffsetYFrac = 0.035;  // 云团整体下移（阴影偏下更自然）

/// 阴影素材"可见区域"的 bbox 只量一次。
/// TBApplyIconEffects 每次出图都要用，而 TBImageContentBBox 会跑一遍 64×64 重绘 + 扫描；
/// 以前一次出图要算两遍（画一次、打日志一次），属于刷新/布局回调里的纯浪费。
static BOOL TBShadowArtBBox(UIImage *shadow, CGRect *out) {
    if (!shadow) return NO;
    static __weak UIImage *sImg = nil;
    static CGRect sBB = {{0, 0}, {0, 0}};
    static BOOL sHas = NO, sValid = NO;
    if (sValid && sImg == shadow) {
        if (out) *out = sBB;
        return sHas;
    }
    BOOL has = TBImageContentBBox(shadow, &sBB);
    sImg = shadow; sHas = has; sValid = YES;
    if (out) *out = sBB;
    return has;
}

/// 阴影素材在画布里的绘制 rect：把"可见云团"铺到 图标的 kTBShadowCloudToIcon 倍并居中（再整体下移）。
/// 量不出可见区域时退化成"整张素材放大到 2 倍画布居中"（按素材有一半是边距处理）。
static CGRect TBShadowArtRect(UIImage *shadow, CGRect canvas, CGRect iconRect) {
    CGSize art = shadow.size;
    if (art.width < 1 || art.height < 1) return canvas;
    CGSize cloud = CGSizeMake(iconRect.size.width * kTBShadowCloudToIcon,
                              iconRect.size.height * kTBShadowCloudToIcon);
    CGRect bb;
    if (!TBShadowArtBBox(shadow, &bb) || bb.size.width < 0.02 || bb.size.height < 0.02) {
        CGRect r = canvas;
        r.origin.x -= r.size.width * 0.5;
        r.origin.y -= r.size.height * 0.5;
        r.size.width *= 2.0; r.size.height *= 2.0;
        r.origin.y += canvas.size.height * kTBShadowOffsetYFrac;
        return r;
    }
    CGRect r;
    r.size.width  = cloud.width  / bb.size.width;
    r.size.height = cloud.height / bb.size.height;
    r.origin.x = canvas.size.width  / 2.0 - r.size.width  / 2.0;
    r.origin.y = canvas.size.height / 2.0 - r.size.height / 2.0
                 + canvas.size.height * kTBShadowOffsetYFrac;   // 阴影偏下
    return r;
}

/// 特效合成：阴影垫在图标下方 → 图标 → 叠加层盖在图标之上。
/// 画布尺寸保持 = 图标尺寸（不改尺寸 → 下游 TBFitCached / 系统缓存不会把阴影又缩回图标格）。
/// 0.15.49：**图标不缩小**（iconRect = 整块画布）；阴影只在图标边缘/底部露一圈，
/// 真正的投影交给视图层的 TBApplyIconLayerShadow。
static UIImage *TBApplyIconEffects(UIImage *img) {
    if (!img) return img;
    CGSize pt = img.size;
    if (pt.width < 1 || pt.height < 1) return img;
    UIImage *shadow  = TBUseThemeIconShadow()  ? TBThemeShadowImage()  : nil;
    UIImage *overlay = TBUseThemeIconOverlay() ? TBThemeOverlayImage() : nil;
    if (!overlay) overlay = TBThemeGlassFromFaintMask();   // 淡玻璃遮罩 → 在这里当玻璃层画
    double strength = TBGlassOverlayStrength();
    if (overlay && strength <= 0.001) overlay = nil;       // 0 = 不用玻璃层
    if (!overlay && !shadow) return img;      // 没开 / 主题里没素材 → 原样返回

    CGRect canvas = CGRectMake(0, 0, pt.width, pt.height);
    const CGFloat iconScale = kTBShadowIconScale;          // = 1.00，图标保持原尺寸
    CGRect iconRect = CGRectInset(canvas, pt.width * (1.0 - iconScale) / 2.0,
                                          pt.height * (1.0 - iconScale) / 2.0);
    // overlay 按最终形状裁那一刀只用在这里：DestinationIn 取的是【图标自己的 alpha】，
    // 图标是满尺寸的，所以裁完 overlay 仍是整块（不会被裁掉、也不会出边）。
    if (overlay) overlay = TBMaskOverlayToIconAlpha(overlay, img, iconRect);

    CGRect sr = CGRectZero;
    if (shadow) sr = TBShadowArtRect(shadow, canvas, iconRect);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = img.scale > 0.5 ? img.scale : 3.0;
    fmt.opaque = NO;
    UIImage *out = [[[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt]
        imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        if (shadow) [shadow drawInRect:sr blendMode:kCGBlendModeNormal alpha:strength];
        [img drawInRect:iconRect];
        if (overlay) [overlay drawInRect:iconRect blendMode:kCGBlendModeNormal alpha:strength];
    }];
    if (shadow) {
        TBLogOnce([@"shadowfx|" stringByAppendingFormat:@"%.0fx%.0f", pt.width, pt.height],
                  @"阴影：素材 %.0fx%.0f · 画布 %.0fx%.0f · K(图标占比)=%.2f（图标不缩小）· 云团=图标×%.2f "
                  @"→ 图内 rect %.0fx%.0f @(%.0f,%.0f) · 强度 %.2f · 投影走视图层",
                  shadow.size.width, shadow.size.height, pt.width, pt.height, iconScale,
                  kTBShadowCloudToIcon, sr.size.width, sr.size.height, sr.origin.x, sr.origin.y, strength);
    }
    if (overlay) {
        TBLogOnce([@"glassstrength|" stringByAppendingFormat:@"%.2f", strength],
                  @"玻璃层：强度 %.2f（0=不画）· 已按图标形状裁过（图标满尺寸，未被裁掉）· 源=%@", strength,
                  TBUseThemeIconOverlay() ? @"AnemoneEffects/iPhoneOverlay" : @"淡玻璃遮罩");
    }
    return out;
}

/// 图标最终出图：① 按形状裁（主题遮罩 / 自定义圆角 / 系统形状）② 再叠特效（阴影在下、叠加层在上）
static UIImage *TBIconFinalImage(UIImage *img) {
    return TBApplyIconEffects(TBIconRoundedImage(img));
}

#pragma mark - 阴影（视图层，0.15.49）

/// 特效相关偏好的 1 秒 TTL 缓存：layoutSubviews 里别每次都去问 cfprefsd / 读素材
static void TBShadowLayerParams(BOOL *enabledOut, double *strengthOut) {
    static BOOL sOn = NO;
    static double sStrength = 0;
    static NSTimeInterval sAt = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (sAt <= 0 || now - sAt > 1.0) {
        sAt = now;
        sStrength = TBGlassOverlayStrength();
        sOn = TBUseThemeIconShadow() && (TBThemeShadowImage() != nil) &&
              !TBSafeMode() && TBEnabled();
    }
    if (enabledOut) *enabledOut = sOn;
    if (strengthOut) *strengthOut = sStrength;
}

static char kTBLayerShadowKey;   // 记录已应用的阴影参数（layout 会被反复调用）

/// 阴影走【视图层】：给图标视图的 layer 设 shadowColor/Opacity/Radius/Offset + shadowPath。
///   · 图标尺寸完全不变（图内把图标缩到 0.80 的方案被用户否决）
///   · shadowPath 用圆角矩形 → UIKit 不用为了算阴影去栅格化整棵子树（滚动卡顿的主因）
///   · 强度仍然受 GlassOverlayStrength 控制（0 = 不画，同时把之前设过的清掉）
static void TBApplyIconLayerShadow(id iconView, UIView *imgView) {
    if (!iconView || ![iconView isKindOfClass:[UIView class]]) return;
    @try {
        UIView *v = (UIView *)iconView;
        CALayer *layer = v.layer;
        if (!layer) return;
        BOOL on = NO;
        double strength = 0;
        TBShadowLayerParams(&on, &strength);
        if (!on || strength <= 0.001) {
            if (layer.shadowOpacity > 0.0) {
                layer.shadowOpacity = 0.0;
                layer.shadowPath = NULL;
                objc_setAssociatedObject(v, &kTBLayerShadowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return;
        }
        CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"bounds"));
        CGFloat w = b.size.width, h = b.size.height;
        if (w < 4 || h < 4) return;
        CGFloat radius;
        if (TBMaskCornerRadiusOn()) radius = (CGFloat)(TBMaskCornerRadius() / 60.0) * w;
        else radius = MIN(w, h) * 0.2237;      // 和「形状兜底」同一口径（系统超椭圆近似）
        if (radius > MIN(w, h) * 0.5) radius = MIN(w, h) * 0.5;
        CGFloat opacity = (CGFloat)(strength * 0.45);     // 强度 0.6 → opacity 0.27
        CGFloat blur = MAX(3.0, MIN(w, h) * 0.18);
        CGFloat dy = h * 0.05;
        NSString *sig = [NSString stringWithFormat:@"%.1f|%.1f|%.2f|%.2f|%.1f", w, h, opacity, blur, dy];
        NSString *old = objc_getAssociatedObject(v, &kTBLayerShadowKey);
        if ([old isEqualToString:sig]) return;   // 参数没变 → 不动 layer（layout 每次都进来）
        objc_setAssociatedObject(v, &kTBLayerShadowKey, sig, OBJC_ASSOCIATION_COPY_NONATOMIC);

        CGRect r = CGRectMake(0, 0, w, h);
        if (imgView && imgView != v) {
            CGRect f = [imgView convertRect:imgView.bounds toView:v];
            if (f.size.width > 4 && f.size.height > 4) r = f;
        }
        if (layer.masksToBounds) {
            layer.masksToBounds = NO;   // 阴影必须画到 bounds 之外
            TBLogOnce(@"layershadow|unclip", @"阴影（视图层）：图标视图原本会裁剪，已关掉以让阴影露出来");
        }
        layer.shadowColor = [UIColor blackColor].CGColor;
        layer.shadowOpacity = opacity;
        layer.shadowRadius = blur;
        layer.shadowOffset = CGSizeMake(0, dy);
        layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius].CGPath;
        TBLogOnce([@"layershadow|" stringByAppendingFormat:@"%.0fx%.0f|%.2f", w, h, strength],
                  @"阴影（视图层）：图标 %.0fx%.0f 保持不变 · shadowPath %.0fx%.0f 圆角 %.1f · "
                  @"opacity %.2f（强度 %.2f）· blur %.1f · offset %.1f",
                  w, h, r.size.width, r.size.height, radius, opacity, strength, blur, dy);
    } @catch (NSException *e) { }
}

static UIImage *gSystemClockFace;   // 系统自己的时钟表盘（主题取消后还原用）

/// 无主题 / 主题没有表盘素材时，把系统原来的表盘还回去
static UIImage *TBSystemClockFace(void) {
    return gSystemClockFace;
}

// ---- 图标圆角：用【系统自己的遮罩形状】，不再自己画超椭圆 ----
// 我们是在 SBHIconImageCache 的读路径直接返回图的，这条路径系统认为是"已遮罩"的，
// 所以必须自己遮 —— 但形状要用系统那张（第一次从系统原实现里取到后缓存成模板）。
static UIImage *TBMaskWithSystemShape(UIImage *art) {
    if (!art || !gSystemMaskTemplate) return art;
    CGSize sz = gSystemMaskTemplate.size;
    if (sz.width < 4 || sz.height < 4) return art;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = gSystemMaskTemplate.scale > 0.5 ? gSystemMaskTemplate.scale : 3.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [art drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
        // DestinationIn：只保留模板不透明处的像素 = 系统的圆角/超椭圆形状
        [gSystemMaskTemplate drawInRect:CGRectMake(0, 0, sz.width, sz.height)
                              blendMode:kCGBlendModeDestinationIn alpha:1.0];
    }];
}

/// 把系统原实现返回的已遮罩图记成模板
static void TBLearnSystemMask(UIImage *sysMasked) {
    if (!sysMasked || !sysMasked.CGImage) return;
    if (gSystemMaskTemplate && CGSizeEqualToSize(gSystemMaskTemplate.size, sysMasked.size)) return;
    gSystemMaskTemplate = sysMasked;
    TBLogOnce(@"iconmask|learn", @"图标遮罩：已取到系统遮罩形状（%.0fx%.0f pt）",
              sysMasked.size.width, sysMasked.size.height);
}

/// 带缓存的"按尺寸适配"：同一 bid + 同一尺寸只渲染一次（原来每次调用都重画一张）
static UIImage *TBFitCached(UIImage *img, TBInfo info, NSString *bid) {
    if (!img) return nil;
    if (!bid.length) return TBFitImage(img, info);
    // 键里带主题名：换主题瞬间，同 bid 同尺寸的旧键不能命中旧主题的成品图
    // （bid 变体除外：TBImageForBundle 的图本来就该按 bid 查，不随主题键失效会重复渲染；
    //   这里统一带上主题最安全 —— 60x60 这类同尺寸键在换主题后必须重画。）
    NSString *k = [NSString stringWithFormat:@"%@|%@|%.0fx%.0f|%.1f", TBActiveTheme() ?: @"",
                   bid, info.size.width, info.size.height, info.scale];
    if (!gFitCache) { [gLock lock]; if (!gFitCache) gFitCache = [NSMutableDictionary dictionary]; [gLock unlock]; }
    UIImage *c = gFitCache[k];
    if (c) return c;
    UIImage *out = TBFitImage(img, info);
    if (out) gFitCache[k] = out;
    return out;
}

static UIImage *TBImageForBundle(NSString *bid) {
    if (!bid.length || !TBEnabled()) return nil;
    if (TBSafeMode()) return nil;   // 安全模式：只记日志，绝不改图
    // 时钟：表盘当普通图标图交给系统（IconBundles 优先，没有则用 Bundles 的表盘素材），
    // 指针/轴心由 imageSet 注入 —— 与 SnowBoard 一致。

    [gLock lock];
    TBLoadIndex();
    NSString *path = gIndex[bid];
    [gLock unlock];
    BOOL cameFromMaterial = NO;
    if (!path) {
        // 时钟/日历是动态图标，主题作者通常放在 Bundles/ 下的
        // ClockIcon*.png / CalendarIcon*.png，而不是 IconBundles/<包名>.png
        path = TBDynamicResourcePath(bid);
        if (path) cameFromMaterial = YES;
        if (!path) return nil;
        TBLogOnce([@"dynsrc|" stringByAppendingString:bid],
                  @"dynamic 图来自 Bundles: %@ → %@", bid, path.lastPathComponent);
    }

    BOOL isCalendar = [bid isEqualToString:@"com.apple.mobilecal"];
    NSString *cacheKey = bid;
    if (isCalendar) {
        // 日历按天缓存，跨天自动重画
        NSDateFormatter *dfd = [[NSDateFormatter alloc] init];
        dfd.dateFormat = @"yyyyMMdd";
        cacheKey = [bid stringByAppendingFormat:@"|%@", [dfd stringFromDate:[NSDate date]]];
    }
    UIImage *cached = [gImageCache objectForKey:cacheKey];
    if (cached) return cached;

    UIImage *img = [[UIImage alloc] initWithContentsOfFile:path];   // 不用被 hook 的类方法
    CGFloat inkPct = 0, opPct = 0;
    BOOL looksDrawn = TBImageDateAreaMetrics(img, &inkPct, &opPct);
    BOOL forceNoDate = NO;
    id ndv = TBPref(@"NoCalendarDate");
    if (ndv) forceNoDate = [ndv boolValue];
    BOOL calDynamic = cameFromMaterial || !looksDrawn;
    if (forceNoDate) calDynamic = NO;
    if (isCalendar && img) {
        TBLogOnce([@"caljudge|" stringByAppendingFormat:@"%@|%d", bid, (int)looksDrawn],
                  @"日历判定：墨 %.1f%% / 不透明 %.1f%% → %@%@",
                  inkPct, opPct,
                  (calDynamic ? @"自己写日期" : @"用主题图标原样"),
                  (forceNoDate ? @"（设置里强制不叠加）" : @""));
    }
    if (img && isCalendar) {
        if (!calDynamic) {
            // 主题图标自己已经画了日期/星期 → 直接用，不叠加（否则会重影）
            TBLogOnce(@"calc|static", @"日历：主题图标已自带日期，跳过叠加");
            UIImage *masked = TBIconFinalImage(img);        // 圆角遮罩 + 叠加层/阴影不能漏
            if (masked) img = masked;
            [gImageCache setObject:img forKey:cacheKey];
            return img;
        }
        UIImage *composed = TBCalendarCompositeImage(img);
        if (composed) {
            TBLogOnce(@"calc|ok", @"日历合成：底图 + 红星期 + 黑日期");
            UIImage *masked = TBIconFinalImage(composed);     // 合成后同样要裁圆角 + 叠特效
            if (masked) composed = masked;
            [gImageCache setObject:composed forKey:cacheKey];
            return composed;
        }
    }
    if (img) {
        // 日历/时钟带实时内容，不能进缓存，否则日期和指针会冻住
        BOOL dynamic = [bid isEqualToString:@"com.apple.mobilecal"] ||
                       [bid isEqualToString:@"com.apple.mobiletimer"];
        if (dynamic) {
            static int logged = 0;
            if (logged < 20) { logged++; TBLog(@"dynamic %@", bid); }
            img = TBDynamicIcon(img, bid);
        img = TBIconRoundedImage(img);
        }
        // 按系统遮罩形状裁一刀（= SnowBoard 的 roundedRectImage:withCrop:YES 那一步）
        // 最后一道：按形状裁 + 叠 AnemoneEffects（阴影在下、叠加层在上），一次性出最终图
        img = TBIconFinalImage(img);            // 交给系统前按形状裁 + 叠特效（SB 同款）
        if (!dynamic) [gImageCache setObject:img forKey:bid];
    }
    return img;
}

#pragma mark - 取 bundleID

/// 反 DNS 形式（至少含一个点）才算可用的 bundleID；UUID 之类一律视为不可用
static BOOL TBBIDLooksUsable(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 3) return NO;
    return [s rangeOfString:@"."].location != NSNotFound;
}

/// 把图标对象上所有可能带身份的字段摊平，便于定位「UUID 图标」到底是什么
static NSString *TBBIDDumpIcon(id icon) {
    NSMutableArray *pairs = [NSMutableArray array];
    NSArray *keys = @[@"leafIdentifier", @"applicationBundleID", @"applicationBundleIdentifier",
                      @"bundleIdentifier", @"uniqueIdentifier", @"iconIdentifier", @"displayName"];
    for (NSString *k in keys) {
        @try {
            if (![icon respondsToSelector:NSSelectorFromString(k)]) continue;
            id v = ((id (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(k));
            if ([v isKindOfClass:[NSString class]] && [v length]) {
                [pairs addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
            }
        } @catch (NSException *e) { }
    }
    @try {
        SEL appSel = NSSelectorFromString(@"application");
        if ([icon respondsToSelector:appSel]) {
            id app = ((id (*)(id, SEL))objc_msgSend)(icon, appSel);
            for (NSString *k in @[@"bundleIdentifier", @"applicationIdentifier"]) {
                if ([app respondsToSelector:NSSelectorFromString(k)]) {
                    id v = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(k));
                    if ([v isKindOfClass:[NSString class]] && [v length]) {
                        [pairs addObject:[NSString stringWithFormat:@"app.%@=%@", k, v]];
                    }
                }
            }
        }
    } @catch (NSException *e) { }
    return [pairs componentsJoinedByString:@" "];
}

static NSString *TBBIDFromIcon(id icon) {
    if (!icon) return nil;
    static NSArray *paths = nil;
    if (!paths) paths = @[@"applicationBundleID", @"bundleIdentifier",
                          @"applicationBundleIdentifier", @"leafIdentifier"];
    NSString *fallback = nil;
    for (NSString *k in paths) {
        @try {
            if (![icon respondsToSelector:NSSelectorFromString(k)]) continue;
            id v = [icon valueForKey:k];
            if (![v isKindOfClass:[NSString class]] || ![(NSString *)v length]) continue;
            if (TBBIDLooksUsable(v)) return v;
            if (!fallback) fallback = v;
        } @catch (NSException *e) {}
    }
    if (fallback.length) {
        NSString *cls = NSStringFromClass([icon class]);
        TBLogOnce([@"biddump|" stringByAppendingString:cls],
                  @"biddump cls=%@ %@", cls, TBBIDDumpIcon(icon));
    }
    return fallback;
}

#pragma mark - hook 工具

// ---- 通知中心 / 横幅 / 锁屏 图标（SystemBox 1.5-8 反编译定论）----
// 结论：NC 列表的图标视图是 `NCBadgedIconView`，真正的内容装载点是它的
//   `-_configureBadgedIconViewIfNecessary` / `-layoutSubviews`；`NCNotificationContent -icons`
//   在 17.2 上根本不被调用（0.15.37 实测 0 命中）。bundleID 取自
//   `_badgedIconDescription._bundleIdentifier`（KVC）。
static void (*o_ncBadgedLayout)(id, SEL);

static NSString *TBNCBIDFromBadgedView(id self) {
    @try {
        id d = nil;
        @try { d = [self valueForKey:@"badgedIconDescription"]; } @catch (NSException *e) {}
        @try { if (!d) d = [self valueForKey:@"_badgedIconDescription"]; } @catch (NSException *e) {}
        if (d) {
            @try {
                id bid = [d valueForKey:@"bundleIdentifier"];
                if ([bid isKindOfClass:[NSString class]] && [bid length]) return bid;
            } @catch (NSException *e) {}
        }
    } @catch (NSException *e) {}
    return nil;
}

static void (*o_ncBadgedConfigure)(id, SEL);
static void tb_ncBadgedApply(id self);
static void tb_ncBadgedLayout(id self, SEL _cmd) {
    if (o_ncBadgedLayout) o_ncBadgedLayout(self, _cmd);
    if (!TBApplyEnabled(@"ApplyNotification")) return;
    // 延后一拍再改图：绝不在当前布局/配置事务里动视图
    __weak UIView *wv = (UIView *)self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *v = wv;
        if (!v) return;
        tb_ncBadgedApply(v);
    });
}

static void tb_ncBadgedApply(id self) {
    @try {
        NSString *bid = TBNCBIDFromBadgedView(self);
        if (!bid.length) return;
        UIImage *img = TBImageForBundle(bid);
        if (!img) return;
        UIImage *out = TBApplyIconEffects(TBApplyIconShape(img, NO)) ?: img;
        id iconView = nil;
        @try { iconView = [self valueForKey:@"iconView"]; } @catch (NSException *e) {}
        @try { if (!iconView) iconView = [self valueForKey:@"_iconView"]; } @catch (NSException *e) {}
        if (![iconView isKindOfClass:[UIImageView class]]) return;
        UIImageView *iv = (UIImageView *)iconView;
        if (iv.image == out) return;
        iv.image = out;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        // 换图会丢系统形状 → 自己补圆角（iOS 图标圆角公式）
        CGFloat side = MIN(iv.bounds.size.width, iv.bounds.size.height);
        if (side > 1) {
            iv.layer.cornerRadius = side * 0.2237;
            iv.layer.cornerCurve = kCACornerCurveContinuous;
            iv.layer.masksToBounds = YES;
        }
        TBLogOnce([@"ncbadge|" stringByAppendingString:bid], @"NC 图标：%@ 已替换", bid);
    } @catch (NSException *e) {}
}

static IMP TBHook(Class cls, NSString *selName, IMP repl, const char *tag) {
    if (!cls) { TBLog(@"· %s: 类不存在", tag); return NULL; }
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(selName));
    if (!m) { TBLog(@"· %s: 方法不存在(%@)", tag, selName); return NULL; }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, repl);
    TBLog(@"✓ hook %@ -%@", NSStringFromClass(cls), selName);
    return orig;
}

static IMP TBHookClass(Class cls, NSString *selName, IMP repl, const char *tag) {
    if (!cls) { TBLog(@"· %s: 类不存在", tag); return NULL; }
    Method m = class_getClassMethod(cls, NSSelectorFromString(selName));
    if (!m) { TBLog(@"· %s: 类方法不存在(%@)", tag, selName); return NULL; }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, repl);
    TBLog(@"✓ hook %@ +%@", NSStringFromClass(cls), selName);
    return orig;
}

static void TBRemember(id cache) {
    if (!cache) return;
    [gLock lock];
    if (!gCaches) gCaches = [NSMutableSet set];
    [gCaches addObject:[NSValue valueWithPointer:(__bridge const void *)cache]];
    [gLock unlock];
}

#pragma mark - hook 实现

typedef id (*FnIcon)(id, SEL, id);
typedef id (*FnIconOpt)(id, SEL, id, unsigned long long);
typedef id (*FnImageForIcon)(id, SEL, id, id);
typedef id (*FnGen)(id, SEL, TBImageInfo);
typedef id (*FnGenSize)(id, SEL, CGSize, double, BOOL, id);
typedef id (*FnISGeneration)(id, SEL, id *);

static FnIcon o_imageForIcon, o_cachedForIcon, o_unmaskedForIcon;
static FnIconOpt o_imageForIconOpt, o_realForIconOpt, o_unmaskedForIconOpt;
static FnImageForIcon o_cacheImageForIcon;
static FnGen o_generateIconImageWithInfo, o_genericIconImage;
static FnGenSize o_iconImageOfSize;
static FnISGeneration o_isGeneration;
typedef id (*FnISGenerateImage)(id, SEL);
static FnISGenerateImage o_isGenerateImage;

static id tb_imageForIcon(id self, SEL _cmd, id icon) {
    // 直通：图像的"成品"由系统自己合成（素材由 SBIcon 那层给），我们不再在这里返回成品图。
    // 顺手从系统那张已遮罩图里学一次"系统遮罩形状"，供我们裁剪素材时使用。
    TBRemember(self);
    id r = o_imageForIcon ? o_imageForIcon(self, _cmd, icon) : nil;
    if (!gSystemMaskTemplate && [r isKindOfClass:[UIImage class]]) TBLearnSystemMask(r);
    return r;
}

static id tb_imageForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    return o_imageForIconOpt ? o_imageForIconOpt(self, _cmd, icon, opt) : nil;
}

static id tb_cachedForIcon(id self, SEL _cmd, id icon) {
    TBRemember(self);
    return o_cachedForIcon ? o_cachedForIcon(self, _cmd, icon) : nil;
}

static id tb_realForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    return o_realForIconOpt ? o_realForIconOpt(self, _cmd, icon, opt) : nil;
}

static id tb_unmaskedForIcon(id self, SEL _cmd, id icon) {
    TBRemember(self);
    return o_unmaskedForIcon ? o_unmaskedForIcon(self, _cmd, icon) : nil;
}

static id tb_unmaskedForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    return o_unmaskedForIconOpt ? o_unmaskedForIconOpt(self, _cmd, icon, opt) : nil;
}

/// 缓存落盘的那一刻换掉图 —— 这样所有后续消费者（含变体缓存）拿到的都是主题图
static id tb_cacheImageForIcon(id self, SEL _cmd, id image, id icon) {
    // 缓存写入端接管（这是唯一在本机实测有效的手段：系统写入缓存时把非主题图换成主题图）。
    // 系统在这台 iOS 17.2 上不会因为 purge/clear/update 就丢掉旧合成图，必须在这里拦截。
    TBRemember(self);
    @try {
        NSString *bid = TBBIDFromIcon(icon);
        if (bid.length && TBApplyIconForDesktop() && !TBSafeMode()) {
            UIImage *mine = TBFitCached(TBImageForBundle(bid), TBInfoOfCache(self), bid) ?: TBImageForBundle(bid);
            if (mine) {
                TBLogOnce([@"cachewrite|" stringByAppendingString:bid], @"cachewrite %@", bid);
                return o_cacheImageForIcon ? o_cacheImageForIcon(self, _cmd, mine, icon) : nil;
            }
            // 主题没覆盖 → 全局效果：把系统图加工后再落缓存
            UIImage *g = TBGlobalEffectImage(image, bid);
            if (g && g != image) {
                TBLogOnce([@"cachewriteG|" stringByAppendingString:bid], @"cachewrite(全局) %@", bid);
                return o_cacheImageForIcon ? o_cacheImageForIcon(self, _cmd, g, icon) : nil;
            }
        }
    } @catch (NSException *e) { }
    return o_cacheImageForIcon ? o_cacheImageForIcon(self, _cmd, image, icon) : nil;
}

/// 全局效果（默认开）：主题没覆盖的 App，拿系统自己的图标图，套上同一套
/// 形状（遮罩/自定义圆角）与边框/阴影 —— 这样整个桌面观感统一。
static BOOL TBGlobalEffectOn(void) {
    id v = TBPref(@"GlobalIconEffect");
    return v ? [v boolValue] : YES;
}
static NSMutableDictionary *gGlobalImgCache;
static NSString *gGlobalCacheTheme;
static UIImage *TBGlobalEffectImage(UIImage *src, NSString *bid) {
    if (!src || !bid.length) return src;
    if (!TBGlobalEffectOn() || TBSafeMode() || !TBEnabled()) return src;
    // 时钟/日历是动态合成图标，不套
    if ([bid isEqualToString:@"com.apple.mobiletimer"] ||
        [bid isEqualToString:@"com.apple.mobilecal"]) return src;
    BOOL anyFx = (TBUseThemeIconMask() || TBMaskCornerRadiusOn() ||
                  TBUseThemeIconOverlay() || TBUseThemeIconShadow());
    if (!anyFx) return src;
    if (src.size.width < 16 || src.size.height < 16) return src;
    NSString *theme = TBActiveTheme() ?: @"";
    // 缓存键带「主题 + 特效参数指纹」：参数没变就一直命中，不必每次刷新都重算所有图标
    // （0.15.48 的日志里 TBReload 一晚上跑了 256 次，每次 gGlobalImgCache = nil，
    //  于是几十个图标全部重新套形状+特效 → 主线程被拖死。现在只在参数真的变了才失效。）
    // ★ 指纹必须覆盖【所有会改变出图的输入】：
    //   - MaskCornerRadius 数值（滑块只改数值不改开关，旧指纹不含它 → 调圆角后全局效果的
    //     图标一直吃旧形状，要换主题/重启才变）
    //   - CustomMaskPath / 主题遮罩文件的修改时间（App 导入遮罩后 TBReload 会清 gMaskThemeImg，
    //     但旧指纹让这里直接命中缓存 → 「已覆盖主题图标的遮罩」永远不更新）
    NSString *maskPath = nil;
    {
        id cmp = TBPref(@"CustomMaskPath");
        if ([cmp isKindOfClass:[NSString class]]) maskPath = cmp;
    }
    NSString *maskSig = @"";
    NSString *maskFile = maskPath.length ? maskPath : nil;
    if (!maskFile) {
        NSString *theme = TBActiveTheme() ?: @"";
        if (theme.length) {
            NSString *dir = TBThemeDir(theme);
            NSString *ib = dir.length ? TBResolveDirCI(dir, @"IconBundles") : nil;
            maskFile = ib.length ? TBFindFileCI(ib, @"Icon.png") : nil;
        }
    }
    if (maskFile.length) {
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:maskFile error:NULL];
        NSDate *mt = at[NSFileModificationDate];
        maskSig = [NSString stringWithFormat:@"@%llu", mt ? (unsigned long long)[mt timeIntervalSince1970] : 0];
    }
    NSString *fp = [NSString stringWithFormat:@"%@|%d%d%d%d|%.2f|%.2f|%@%@",
                    theme,
                    TBUseThemeIconMask() ? 1 : 0, TBMaskCornerRadiusOn() ? 1 : 0,
                    TBUseThemeIconOverlay() ? 1 : 0, TBUseThemeIconShadow() ? 1 : 0,
                    TBGlassOverlayStrength(),
                    TBMaskCornerRadiusOn() ? TBMaskCornerRadius() : 0.0,
                    maskPath.length ? maskPath : @"-",
                    maskSig];
    if (!gGlobalImgCache || ![gGlobalCacheTheme isEqualToString:fp]) {
        gGlobalImgCache = [NSMutableDictionary dictionary];
        gGlobalCacheTheme = [fp copy];
    } else if (gGlobalImgCache.count > 4000) {
        [gGlobalImgCache removeAllObjects];      // 上限保护（图标尺寸变体会堆很多）
    }
    NSString *key = [NSString stringWithFormat:@"%@|%.0fx%.0f", bid, src.size.width, src.size.height];
    UIImage *hit = gGlobalImgCache[key];
    if (hit) return hit;
    UIImage *square = TBArtSquareFilled(src);          // 系统图自带圆角 → 先补方角，形状才听我们的
    UIImage *shaped = TBApplyIconShape(square, NO);
    UIImage *out = TBApplyIconEffects(shaped) ?: shaped;
    if (!out) return src;
    gGlobalImgCache[key] = out;
    TBLogOnce([@"globalfx|" stringByAppendingString:bid], @"全局效果：%@ 已套形状/特效", bid);
    return out;
}

typedef id (*FnInfoImage)(id, SEL, TBImageInfo);
static FnInfoImage o_iconImageWithInfo, o_unmaskedIconImageWithInfo;

/// SnowBoard 的通道：在 SBIcon 这层交出【原始素材】，遮罩/合成/缓存/刷新全交给系统
static id tb_iconImageWithInfo(id self, SEL _cmd, TBImageInfo info) {
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(self);
        UIImage *img = TBImageForBundle(bid);
        if (img) { gServe++; TBLogOnce([@"iconInfo|" stringByAppendingString:bid ?: @"?"], @"serve iconImageWithInfo %@", bid); return img; }
        UIImage *sys = o_iconImageWithInfo ? o_iconImageWithInfo(self, _cmd, info) : nil;
        UIImage *g = TBGlobalEffectImage(sys, bid);
        if (g && g != sys) { gServe++; return g; }
        return sys;
    }
    return o_iconImageWithInfo ? o_iconImageWithInfo(self, _cmd, info) : nil;
}

static id tb_unmaskedIconImageWithInfo(id self, SEL _cmd, TBImageInfo info) {
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(self);
        UIImage *img = TBImageForBundle(bid);
        if (img) { gServe++; TBLogOnce([@"iconInfoU|" stringByAppendingString:bid ?: @"?"], @"serve unmaskedIconImageWithInfo %@", bid); return img; }
        UIImage *sys = o_unmaskedIconImageWithInfo ? o_unmaskedIconImageWithInfo(self, _cmd, info) : nil;
        UIImage *g = TBGlobalEffectImage(sys, bid);
        if (g && g != sys) { gServe++; return g; }
        return sys;
    }
    return o_unmaskedIconImageWithInfo ? o_unmaskedIconImageWithInfo(self, _cmd, info) : nil;
}

static id tb_generateIconImageWithInfo(id self, SEL _cmd, TBImageInfo info) {
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(self);
        UIImage *img = TBImageForBundle(bid);
        if (img) { gServe++; TBLog(@"serve generateIconImageWithInfo %@", bid); return img; }
    }
    return o_generateIconImageWithInfo ? o_generateIconImageWithInfo(self, _cmd, info) : nil;
}

// ---- SBIconImageView.setImage:（SnowBoard 核心通道，快捷指令桌面）----
typedef void (*SetImgFn)(id, SEL, id);
static SetImgFn o_setImageOnIconView;

static void tb_setImageOnIconView(id self, SEL _cmd, id image) {
    if (TBEnabled() && !TBSafeMode()) {
        @try {
            // 阴影（视图层）：图标图像视图自己也挂一份，覆盖"走 setImage: 贴图"的图标
            if ([self isKindOfClass:[UIView class]]) TBApplyIconLayerShadow(self, nil);
            id icon = nil;
            if ([self respondsToSelector:NSSelectorFromString(@"icon")]) {
                icon = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"icon"));
            }
            NSString *bid = TBBIDFromIcon(icon);
            if (bid) {
                UIImage *img = TBImageForBundle(bid);
                if (img) {
                    // 只调用一次原实现，用主题图（不递归）
                    if (o_setImageOnIconView) o_setImageOnIconView(self, _cmd, img);
                    gServe++; TBLog(@"serve SBIconImageView.setImage %@", bid);
                    return;
                }
            }
        } @catch (NSException *e) { }
    }
    if (o_setImageOnIconView) o_setImageOnIconView(self, _cmd, image);
}

// ---- SBIconImageView.resetImageWithAppIcon:（SnowBoard 通道，拖拽放置重建）----
typedef void (*ResetImgFn)(id, SEL, id);
static ResetImgFn o_resetImageOnIconView;

static void tb_resetImageOnIconView(id self, SEL _cmd, id icon) {
    // 先让系统完成重置（保持层树完整、不递归）
    if (o_resetImageOnIconView) o_resetImageOnIconView(self, _cmd, icon);
    // 再用主题图覆盖，保证拖拽/状态重建后仍是主题
    if (TBEnabled() && !TBSafeMode()) {
        @try {
            NSString *bid = TBBIDFromIcon(icon);
            if (bid) {
                UIImage *img = TBImageForBundle(bid);
                if (img && o_setImageOnIconView) {
                    o_setImageOnIconView(self, NSSelectorFromString(@"setImage:"), img);
                    gServe++; TBLog(@"serve SBIconImageView.resetImageWithAppIcon %@", bid);
                }
            }
        } @catch (NSException *e) { }
    }
}

// ---- 自愈式校验：布局时只做指针比对，图不对才贴一次（收敛后不再触发）----
typedef void (*LayoutFn)(id, SEL);
static LayoutFn o_iconViewLayout;
static char kTBAppliedImageKey;
static int gHealDepth = 0;

/// 在子视图里找第一个能 setImage: 的 UIImageView（用于 App 资源库的 pod 视图）
static UIView *TBFindImageViewIn(UIView *root, NSInteger depth) {
    if (!root || depth > 4) return nil;
    if ([root isKindOfClass:NSClassFromString(@"UIImageView")] &&
        [root respondsToSelector:NSSelectorFromString(@"setImage:")]) return root;
    for (UIView *sub in root.subviews) {
        UIView *hit = TBFindImageViewIn(sub, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

/// 取某个图标视图里真正承载图片的视图：
/// 普通图标走 _iconImageView；资源库 pod / 自定义视图走 _customIconImageViewController
static id TBImageViewForIconView(id view) {
    if (!view) return nil;
    @try {
        SEL ivSel = NSSelectorFromString(@"_iconImageView");
        if ([view respondsToSelector:ivSel]) {
            id iv = ((id (*)(id, SEL))objc_msgSend)(view, ivSel);
            if (iv && [iv respondsToSelector:NSSelectorFromString(@"setImage:")]) return iv;
        }
    } @catch (NSException *e) { }
    @try {
        SEL vcSel = NSSelectorFromString(@"_customIconImageViewController");
        if ([view respondsToSelector:vcSel]) {
            id vc = ((id (*)(id, SEL))objc_msgSend)(view, vcSel);
            if (vc) {
                SEL imgSel = NSSelectorFromString(@"imageView");
                if ([vc respondsToSelector:imgSel]) {
                    id c = ((id (*)(id, SEL))objc_msgSend)(vc, imgSel);
                    if (c && [c respondsToSelector:NSSelectorFromString(@"setImage:")]) return c;
                }
                SEL vSel = NSSelectorFromString(@"view");
                if ([vc respondsToSelector:vSel]) {
                    UIView *vv = ((id (*)(id, SEL))objc_msgSend)(vc, vSel);
                    UIView *hit = TBFindImageViewIn(vv, 0);
                    if (hit) return hit;
                }
            }
        }
    } @catch (NSException *e) { }
    return nil;
}

static BOOL TBApplyThemeToIconView(id self) {
    if (!self) return NO;
    @try {
        id iv = TBImageViewForIconView(self);
        if (!iv || ![iv respondsToSelector:NSSelectorFromString(@"image")] ||
            ![iv respondsToSelector:NSSelectorFromString(@"setImage:")]) {
            TBLogOnce([@"skip-iv|" stringByAppendingString:NSStringFromClass([self class])],
                      @"skip-iv cls=%@", NSStringFromClass([self class]));
            return NO;
        }
        // 阴影（视图层）：不受"主题有没有这张图"影响 —— 全局效果的图标也要有阴影。
        // 图标尺寸不变；参数没变时这个调用是空操作（内部有去重）。
        TBApplyIconLayerShadow(self, (UIView *)iv);
        SEL iconSel = NSSelectorFromString(@"icon");
        id icon = [self respondsToSelector:iconSel] ?
            ((id (*)(id, SEL))objc_msgSend)(self, iconSel) : nil;
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *theme = TBImageForBundle(bid);
        if (!theme) {
            TBLogOnce([@"skip-theme|" stringByAppendingString:bid ?: @"(nil)"],
                      @"skip-theme cls=%@ bid=%@", NSStringFromClass([self class]), bid ?: @"(nil)");
            return NO;
        }
        CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"bounds"));
        UIImage *want = theme;
        if (b.size.width > 1 && b.size.height > 1 &&
            (fabs(theme.size.width - b.size.width) > 0.6 || fabs(theme.size.height - b.size.height) > 0.6)) {
            UIImage *cached = objc_getAssociatedObject(iv, &kTBAppliedImageKey);
            if (cached && fabs(cached.size.width - b.size.width) < 0.6 &&
                fabs(cached.size.height - b.size.height) < 0.6) {
                want = cached;
            } else {
                TBInfo fi; fi.size = b.size; fi.scale = 0; fi.ratio = 0;
                want = TBFitImage(theme, fi) ?: theme;
                objc_setAssociatedObject(iv, &kTBAppliedImageKey, want, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        UIImage *cur = ((id (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"image"));
        if (cur == want) return NO;   // 已经是我们的图，什么都不做
        ((void (*)(id, SEL, id))objc_msgSend)(iv, NSSelectorFromString(@"setImage:"), want);
        TBLogOnce([@"heal|" stringByAppendingString:bid ?: @"?"], @"heal %@", bid);
        return YES;
    } @catch (NSException *e) { }
    return NO;
}

static void TBPurgeIcons(NSValue *cacheValue, NSArray *icons);

/// 一次性探针：时钟视图的类链 / ivar / 相关方法 / 子视图树，用来确定表盘图存在哪
static void TBClockDumpNow(id v);
static NSInteger TBHealOneView(UIView *v, NSMutableArray *iconsOut) {
    if (!v) return 0;
    NSInteger fixed = 0;
    NSString *vcls = NSStringFromClass([v class]);
    // 时钟视图：换主题后要重画。顺序完全照 SnowBoard 的 refreshIconView:fully:：
    //   ① 图标自身清缓存（purgeCachedImages / reloadIconImage）
    //   ② 图片视图 clearCachedImages（无则 _clearCachedImages）
    //   ③ updateClockImages ④ updateImageAnimated:NO ⑤ _updateOverlayImage
    // 只在【这一个时钟视图】上做，对整棵视图树调用会崩。
    if ([vcls rangeOfString:@"Clock"].location != NSNotFound) {
        @try {
            TBLogOnce([@"clockrefresh|" stringByAppendingString:vcls], @"时钟视图重画 %@", vcls);
            NSMutableString *st = [NSMutableString string];
            SEL iconSel = NSSelectorFromString(@"icon");
            if ([v respondsToSelector:iconSel]) {
                id icon = ((id (*)(id, SEL))objc_msgSend)(v, iconSel);
                if (icon) {
                    if ([icon respondsToSelector:NSSelectorFromString(@"purgeCachedImages")]) {
                        ((void (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"purgeCachedImages"));
                        [st appendString:@"icon.purge "];
                    } else if ([icon respondsToSelector:NSSelectorFromString(@"reloadIconImage")]) {
                        ((void (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"reloadIconImage"));
                        [st appendString:@"icon.reload "];
                    } else {
                        [st appendString:@"icon.none "];
                    }
                }
            }
            if ([v respondsToSelector:NSSelectorFromString(@"clearCachedImages")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"clearCachedImages"));
                [st appendString:@"clear "];
            } else if ([v respondsToSelector:NSSelectorFromString(@"_clearCachedImages")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"_clearCachedImages"));
                [st appendString:@"_clear "];
            } else {
                [st appendString:@"clear.none "];
            }
            if ([v respondsToSelector:NSSelectorFromString(@"updateClockImages")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"updateClockImages"));
            }
            if ([v respondsToSelector:NSSelectorFromString(@"updateImageAnimated:")]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(v, NSSelectorFromString(@"updateImageAnimated:"), NO);
                [st appendString:@"updateImage "];
            }
            if ([v respondsToSelector:NSSelectorFromString(@"_updateOverlayImage")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"_updateOverlayImage"));
                [st appendString:@"overlay "];
            }
            // SnowBoard refreshIconView:fully:YES 的最后一步：把 icon 重新设一遍。
            // 这一下才会让系统重建时钟的组件（表盘才会跟着主题变）。
            {
                id ic = nil;
                if ([v respondsToSelector:NSSelectorFromString(@"icon")]) {
                    ic = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"icon"));
                }
                SEL a = NSSelectorFromString(@"_setIcon:animated:");
                SEL b = NSSelectorFromString(@"setIcon:animated:");
                if (ic && [v respondsToSelector:a]) {
                    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(v, a, ic, NO);
                    [st appendString:@"setIcon(priv) "];
                } else if (ic && [v respondsToSelector:b]) {
                    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(v, b, ic, NO);
                    [st appendString:@"setIcon "];
                } else {
                    [st appendString:@"setIcon.none "];
                }
            }
            // 只给时钟这一个视图硬贴一次表盘（其他图标不动）。
            // 系统缓存不会自己重算，这是本机唯一能让表盘立刻跟着主题变的手段。
            {
                UIImage *face = TBClockMaterialFace((UIView *)v);
                if (face && face.CGImage) {
                    ((UIView *)v).layer.contents = (__bridge id)face.CGImage;
                    @try { [v setValue:face forKey:@"mappedContentsImage"]; } @catch (NSException *e) { }
                    ((UIView *)v).layer.contentsGravity = kCAGravityResize;
                    [(UIView *)v setNeedsDisplay];
                    [st appendString:@"faceWrite "];
                }
            }
            // 方案 D：用系统自己的"图标图已更新"回调逼它重算合成图
            {
                id ic = nil;
                if ([v respondsToSelector:NSSelectorFromString(@"icon")]) {
                    ic = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"icon"));
                }
                id cache = nil;
                @try { cache = [v valueForKey:@"_iconImageCache"]; } @catch (NSException *e) { }
                if (ic && [v respondsToSelector:NSSelectorFromString(@"iconImageDidUpdate:")]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(v, NSSelectorFromString(@"iconImageDidUpdate:"), ic);
                    [st appendString:@"imgDidUpdate "];
                }
                if (ic && cache &&
                    [v respondsToSelector:NSSelectorFromString(@"iconImageCache:didUpdateImageForIcon:")]) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(
                        v, NSSelectorFromString(@"iconImageCache:didUpdateImageForIcon:"), cache, ic);
                    [st appendString:@"cacheDidUpdate "];
                }
            }
            // 最后三个候选（方法表里有、我们还没试过）
            if (!TBClockMaterialFace((UIView *)v)) {
                // 无素材/恢复默认：试着让系统把"已显示的图"清掉、自己重画
                if ([v respondsToSelector:NSSelectorFromString(@"setDisplayedImage:")]) {
                    @try {
                        ((void (*)(id, SEL, id))objc_msgSend)(v, NSSelectorFromString(@"setDisplayedImage:"), nil);
                        [st appendString:@"setDisplayedImage(nil) "];
                    } @catch (NSException *e) { }
                }
            }
            if ([v respondsToSelector:NSSelectorFromString(@"updateUnanimated")]) {
                @try {
                    ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"updateUnanimated"));
                    [st appendString:@"updateUnanimated "];
                } @catch (NSException *e) { }
            }
            TBLog(@"时钟刷新：%@", st);
        } @catch (NSException *e) { }
    }
    BOOL special = ([vcls rangeOfString:@"Folder"].location != NSNotFound) ||
                   ([vcls rangeOfString:@"Clock"].location != NSNotFound) ||
                   ([vcls rangeOfString:@"Library"].location != NSNotFound);
    if (!special &&
        ([v respondsToSelector:NSSelectorFromString(@"icon")] ||
         [v respondsToSelector:NSSelectorFromString(@"_iconImageView")])) {
        // 完全照 SnowBoard 的 refreshIconView:fully:，对【每个图标视图】跑一遍：
        //   [icon purgeCachedImages / reloadIconImage] → [imageView clearCachedImages /
        //   _clearCachedImages] → updateClockImages → updateImageAnimated:NO → _updateOverlayImage
        // （素材已由 SBIcon 层给出，这几步负责让系统把缓存里的旧图丢掉、重新合成）
        {
            @try {
                SEL iconSel = NSSelectorFromString(@"icon");
                id ic = [v respondsToSelector:iconSel]
                      ? ((id (*)(id, SEL))objc_msgSend)(v, iconSel) : nil;
                if (ic) {
                    if ([ic respondsToSelector:NSSelectorFromString(@"purgeCachedImages")]) {
                        ((void (*)(id, SEL))objc_msgSend)(ic, NSSelectorFromString(@"purgeCachedImages"));
                    } else if ([ic respondsToSelector:NSSelectorFromString(@"reloadIconImage")]) {
                        ((void (*)(id, SEL))objc_msgSend)(ic, NSSelectorFromString(@"reloadIconImage"));
                    }
                }
                id iv = nil;
                @try { iv = [v valueForKey:@"_iconImageView"]; } @catch (NSException *e) { }
                if (!iv) iv = v;
                if ([iv respondsToSelector:NSSelectorFromString(@"clearCachedImages")]) {
                    ((void (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"clearCachedImages"));
                } else if ([iv respondsToSelector:NSSelectorFromString(@"_clearCachedImages")]) {
                    ((void (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"_clearCachedImages"));
                }
                if ([iv respondsToSelector:NSSelectorFromString(@"updateClockImages")]) {
                    ((void (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"updateClockImages"));
                }
                if ([iv respondsToSelector:NSSelectorFromString(@"updateImageAnimated:")]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(iv, NSSelectorFromString(@"updateImageAnimated:"), NO);
                }
                if ([iv respondsToSelector:NSSelectorFromString(@"_updateOverlayImage")]) {
                    ((void (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"_updateOverlayImage"));
                }
                if ([v respondsToSelector:NSSelectorFromString(@"setIcon:animated:")]) {
                    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(v, NSSelectorFromString(@"setIcon:animated:"), ic, NO);
                }
                fixed++;
            } @catch (NSException *e) { }
        }
        if (iconsOut && iconsOut.count < 250) {
            @try {
                SEL iconSel = NSSelectorFromString(@"icon");
                if ([v respondsToSelector:iconSel]) {
                    id icon = ((id (*)(id, SEL))objc_msgSend)(v, iconSel);
                    if (icon && ![iconsOut containsObject:icon]) [iconsOut addObject:icon];
                }
            } @catch (NSException *e) { }
        }
    }
    for (UIView *sub in v.subviews) fixed += TBHealOneView(sub, iconsOut);
    return fixed;
}

/// 0.15.53：换主题后整棵窗口树【分批异步】遍历重贴。
/// 之前 TBHealAllIconViews 一口气在主线程跑完所有窗口（~118 个图标视图 × 每个七八步 msgSend
/// + 时钟特殊处理），应用主题回到桌面正好撞上这一大坨 → 掉帧卡顿。
/// 现在：收集（一次快照）→ 每批 36 个视图 dispatch_async，批间让出主线程；不改任何单视图逻辑。
static void TBHealAllIconViews(void) {
    if (gHealDepth > 0) return;
    gHealDepth++;
    TBLog(@"heal: 开始收集窗口树（分批异步重贴）");
    @try {
        // ① 一次性快照：把所有窗口里要处理的视图按序收平（此刻仍是一次遍历，但只做收集，
        //    不跑每个视图七八步的重贴 msgSend —— 纯收集在主线程是亚毫秒级）
        NSMutableArray *queue = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray array];
        for (UIView *w in [[UIApplication sharedApplication] windows]) [stack addObject:w];
        while (stack.count && queue.count < 600) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            [queue addObject:v];
            [stack addObjectsFromArray:[v.subviews copy]];
        }
        TBLog(@"heal: 收集 %lu 个视图待处理（每批 36）", (unsigned long)queue.count);
        if (queue.count == 0) { gHealDepth--; return; }

        // ② 分批异步重贴：每批 36 个视图一批批 dispatch_async，批间让出主线程
        __block NSInteger cursor = 0;          // 已处理到的下标（heal 返回值是修复数不是视图数，用游标推进）
        __block NSInteger fixed = 0;
        __block NSMutableArray *seen = [NSMutableArray array];
        __block NSInteger batch = 0;
        __block void (^drain)(void) = nil;   // 链式强引用在结尾 drain=nil 时断开（队列有限必会走完）
        drain = ^{
            if (cursor >= (NSInteger)queue.count) {
                TBLog(@"heal: 分批重贴完成 fixed=%ld seen=%lu（%ld 批）",
                      (long)fixed, (unsigned long)seen.count, (long)batch);
                gHealDepth--;
                drain = nil;
                return;
            }
            NSInteger start = cursor;
            NSInteger end = MIN(start + 36, (NSInteger)queue.count);
            for (NSInteger i = start; i < end; i++) {
                UIView *v = queue[i];
                if (!v.window && ![v isKindOfClass:[UIWindow class]]) continue;   // 已离屏
                fixed += TBHealOneView(v, seen);
            }
            cursor = end;
            batch++;
            if (batch <= 3 || batch % 5 == 0) {
                TBLog(@"heal: 批 %ld 完成（%ld/%lu）", (long)batch, (long)end, (unsigned long)queue.count);
            }
            dispatch_async(dispatch_get_main_queue(), drain);
        };
        dispatch_async(dispatch_get_main_queue(), drain);
    } @catch (NSException *e) {
        TBLog(@"heal: 异常 %@", e.reason);
        gHealDepth--;
    }
}

static __weak UIView *gLastClockView;   // 最近一次看到的时钟视图

static void tb_iconViewLayoutSubviews(id self, SEL _cmd) {
    if (o_iconViewLayout) o_iconViewLayout(self, _cmd);
    if (!TBApplyIconForDesktop() || TBSafeMode() || !TBEnabled()) return;
    TBApplyThemeToIconView(self);
}

// ---- 换图标后重贴（拖拽放置/资源库→桌面 时系统直接贴原始图，读端 hook 管不到）----
// 只在 SBIconView 更换 icon 时触发一次，不在 getter 热路径里，所以不会像
// 之前那样引起 SpringBoard 闪屏重启。
typedef void (*SetIconFn)(id, SEL, id, BOOL);
static SetIconFn o_setIconAnimated;

static void tb_setIconAnimated(id self, SEL _cmd, id icon, BOOL animated) {
    if (o_setIconAnimated) o_setIconAnimated(self, _cmd, icon, animated);
    if (!TBApplyIconForDesktop() || TBSafeMode() || !TBEnabled()) return;
    @try {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *theme = TBImageForBundle(bid);
        if (!theme) return;
        TBLogOnce([@"reapply|" stringByAppendingString:bid ?: @"?"], @"reapply %@", bid);
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                id iv = [self valueForKey:@"_iconImageView"];
                if (!iv || ![iv respondsToSelector:NSSelectorFromString(@"setImage:")]) return;
                SEL boundsSel = NSSelectorFromString(@"bounds");
                CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(iv, boundsSel);
                TBInfo fi;
                fi.size = (b.size.width > 1 && b.size.height > 1) ? b.size : CGSizeMake(60, 60);
                fi.scale = 0; fi.ratio = 0;
                UIImage *fit = TBFitImage(theme, fi);
                if (fit) {
                    ((void (*)(id, SEL, id))objc_msgSend)(iv, NSSelectorFromString(@"setImage:"), fit);
                }
            } @catch (NSException *e) { }
        });
    } @catch (NSException *e) { }
}

// ---- IconServices 生成阶段（拖拽/资源库重建后仍保持主题）----
// 这里先让系统生成原始 IFImage，再仅替换其位图。不要在 SBIconView
// getter 或 crossfade getter 中主动 setImage:，那些方法位于 SpringBoard
// 初始化热路径，容易递归并触发 SpringBoard 重启。
typedef id (*TBISGenerationFn)(id, SEL, id *);
typedef id (*TBIFObjectFn)(id, SEL);
typedef CGSize (*TBIFSizeFn)(id, SEL);
typedef double (*TBIFDoubleFn)(id, SEL);
typedef BOOL (*TBIFBoolFn)(id, SEL);
typedef id (*TBIFCacheInitFn)(id, SEL, CGImageRef, double, CGSize, BOOL, CGSize);
typedef id (*TBIFDataInitFn)(id, SEL, id, id, id);
typedef void (*TBIFSetLargestFn)(id, SEL, BOOL);

/// 主题里该 bundleID 的原图（用 ImageIO 读，不依赖 UIKit：iconservicesagent
/// 里 UIKit 可能没有加载，走 UIImage 会静默拿到 nil）
static CGImageRef TBCGImageForBundle(NSString *bid) {
    if (!bid.length || !TBEnabled() || TBSafeMode()) return NULL;
    [gLock lock];
    TBLoadIndex();
    NSString *path = gIndex[bid];
    [gLock unlock];
    if (!path.length) return NULL;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    return img;   // Create 规则：调用方负责释放
}

static BOOL TBIFReadGeometry(id image, CGSize *pixelSize, CGSize *minimumSize,
                             CGSize *iconSize, double *scale, BOOL *placeholder,
                             BOOL *largest) {
    if (!image) return NO;
    SEL pixelSel = NSSelectorFromString(@"pixelSize");
    SEL minSel = NSSelectorFromString(@"minimumSize");
    SEL iconSel = NSSelectorFromString(@"iconSize");
    SEL scaleSel = NSSelectorFromString(@"scale");
    SEL placeholderSel = NSSelectorFromString(@"placeholder");
    SEL largestSel = NSSelectorFromString(@"largest");
    if (![image respondsToSelector:pixelSel] || ![image respondsToSelector:minSel] ||
        ![image respondsToSelector:iconSel] || ![image respondsToSelector:scaleSel] ||
        ![image respondsToSelector:placeholderSel] || ![image respondsToSelector:largestSel]) return NO;
    TBIFSizeFn sizeFn = (TBIFSizeFn)objc_msgSend;
    TBIFDoubleFn doubleFn = (TBIFDoubleFn)objc_msgSend;
    TBIFBoolFn boolFn = (TBIFBoolFn)objc_msgSend;
    if (pixelSize) *pixelSize = sizeFn(image, pixelSel);
    if (minimumSize) *minimumSize = sizeFn(image, minSel);
    if (iconSize) *iconSize = sizeFn(image, iconSel);
    if (scale) *scale = doubleFn(image, scaleSel);
    if (placeholder) *placeholder = boolFn(image, placeholderSel);
    if (largest) *largest = boolFn(image, largestSel);
    return YES;
}

/// 用 CoreGraphics 把主题图重绘成系统要求的精确像素尺寸
static CGImageRef TBRasterFromCGImage(CGImageRef src, CGSize pixelSize) {
    if (!src) return NULL;
    size_t w = (size_t)pixelSize.width;
    size_t h = (size_t)pixelSize.height;
    if (w < 1 || h < 1 || w > 1200 || h > 1200) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return NULL;
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextClearRect(ctx, CGRectMake(0, 0, w, h));
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;   // Create 规则：调用方负责释放
}

/// 只接受系统图标生成器真正会产出、且尺寸自洽的几何参数
static BOOL TBISGeometrySupported(CGSize pixelSize, CGSize minimumSize, CGSize iconSize,
                                  double scale, BOOL placeholder) {
    if (placeholder) return NO;
    if (scale < 1 || scale > 3 || floor(scale) != scale) return NO;
    if (pixelSize.width < 1 || pixelSize.width > 1200) return NO;
    if (pixelSize.width != pixelSize.height || floor(pixelSize.width) != pixelSize.width) return NO;
    if (minimumSize.width <= 0 || minimumSize.width != minimumSize.height) return NO;
    if (iconSize.width < minimumSize.width || iconSize.width != iconSize.height) return NO;
    if (fabs(iconSize.width * scale - pixelSize.width) > 0.001) return NO;
    return YES;
}

static id TBCreateIFImageReplacement(id original, CGImageRef raster, CGSize minimumSize,
                                     CGSize iconSize, double scale, BOOL placeholder, BOOL largest) {
    if (!original || !raster) return nil;
    Class cacheClass = NSClassFromString(@"IFCacheImage");
    Class imageClass = NSClassFromString(@"IFImage");
    SEL cacheSel = NSSelectorFromString(@"initWithCGImage:scale:minimumSize:placeholder:iconSize:");
    SEL dataSel = NSSelectorFromString(@"initWithData:uuid:validationToken:");
    if (!cacheClass || !imageClass || ![cacheClass instancesRespondToSelector:cacheSel] ||
        ![imageClass instancesRespondToSelector:dataSel]) return nil;

    TBIFCacheInitFn cacheInit = (TBIFCacheInitFn)objc_msgSend;
    id cacheImage = cacheInit([cacheClass alloc], cacheSel, raster, scale, minimumSize, placeholder, iconSize);
    if (!cacheImage) return nil;
    SEL bitmapSel = NSSelectorFromString(@"bitmapData");
    if (![cacheImage respondsToSelector:bitmapSel]) return nil;
    id bitmapData = ((TBIFObjectFn)objc_msgSend)(cacheImage, bitmapSel);
    id uuid = [original valueForKey:@"uuid"];
    id validationToken = [original valueForKey:@"validationToken"];
    if (!bitmapData || !uuid) return nil;
    // 系统校验令牌固定 40 字节，长度不对说明 ABI 变了，直接放弃
    if (![validationToken respondsToSelector:@selector(length)] ||
        [(NSData *)validationToken length] != 40) return nil;

    TBIFDataInitFn dataInit = (TBIFDataInitFn)objc_msgSend;
    id replacement = dataInit([imageClass alloc], dataSel, bitmapData, uuid, validationToken);
    if (!replacement) return nil;
    SEL largestSel = NSSelectorFromString(@"setLargest:");
    if ([replacement respondsToSelector:largestSel]) {
        ((TBIFSetLargestFn)objc_msgSend)(replacement, largestSel, largest);
    }
    return replacement;
}

// 生成链统一替换入口。返回 original 表示未替换；reason 为失败原因码：
// 0 成功 / 1 无 bundleID / 2 几何不符 / 3 动态图标 / 4 非 bundle 图标 /
// 5 主题无图 / 6 重绘失败 / 7 像素尺寸不符 / 8 IFImage 重建失败 / 99 异常
static id TBReplaceGeneratedImage(id self, id original, int *reasonOut) {
    if (reasonOut) *reasonOut = 0;
    if (!original) return nil;
    @try {
        id icon = [self valueForKey:@"icon"];
        NSString *bid = [icon valueForKey:@"bundleIdentifier"];
        if (![bid isKindOfClass:[NSString class]] || bid.length == 0) {
            if (reasonOut) *reasonOut = 1;
            return original;
        }
        CGSize pixelSize = CGSizeZero, minimumSize = CGSizeZero, iconSize = CGSizeZero;
        double scale = 0;
        BOOL placeholder = NO, largest = NO;
        if (!TBIFReadGeometry(original, &pixelSize, &minimumSize, &iconSize, &scale, &placeholder, &largest) ||
            !TBISGeometrySupported(pixelSize, minimumSize, iconSize, scale, placeholder)) {
            if (reasonOut) *reasonOut = 2;
            return original;
        }
        // 日历/时钟每天要变，交给 SpringBoard 的专用钩子，这里保持原图
        if ([bid isEqualToString:@"com.apple.mobilecal"] ||
            [bid isEqualToString:@"com.apple.mobiletimer"]) {
            if (reasonOut) *reasonOut = 3;
            return original;
        }
        // 只处理系统自带的 bundle 图标（digest 为 NSUUID），其余类一律放行
        id digest = [original valueForKey:@"digest"];
        if (![digest isKindOfClass:[NSUUID class]]) {
            if (reasonOut) *reasonOut = 4;
            return original;
        }
        CGImageRef theme = TBCGImageForBundle(bid);
        if (!theme) {
            if (reasonOut) *reasonOut = 5;
            return original;
        }
        CGImageRef raster = TBRasterFromCGImage(theme, pixelSize);
        CGImageRelease(theme);
        if (!raster) {
            if (reasonOut) *reasonOut = 6;
            return original;
        }
        if (CGImageGetWidth(raster) != (size_t)pixelSize.width ||
            CGImageGetHeight(raster) != (size_t)pixelSize.height) {
            CGImageRelease(raster);
            if (reasonOut) *reasonOut = 7;
            return original;
        }
        id replacement = TBCreateIFImageReplacement(original, raster, minimumSize, iconSize,
                                                    scale, placeholder, largest);
        CGImageRelease(raster);
        if (!replacement) {
            if (reasonOut) *reasonOut = 8;
            return original;
        }
        return replacement;
    } @catch (NSException *e) {
        if (reasonOut) *reasonOut = 99;
        return original;
    }
}

static void TBLogGenerationResult(id request, id original, id result, int reason, const char *api) {
    static int logged = 0;
    if (logged >= 24) return;
    logged++;
    NSString *bid = nil;
    @try {
        bid = [[request valueForKey:@"icon"] valueForKey:@"bundleIdentifier"];
    } @catch (NSException *e) { }
    TBLog(@"gen %s ret=%d r=%d bid=%@", api, result != original, reason, bid ?: @"(nil)");
}

static id tb_isGeneration(id self, SEL _cmd, id *recordIdentifiers) {
    id original = o_isGeneration ? o_isGeneration(self, _cmd, recordIdentifiers) : nil;
    if (!original || !TBEnabled() || TBSafeMode()) return original;
    int reason = 0;
    id out = TBReplaceGeneratedImage(self, original, &reason);
    if (out != original) gServe++;
    TBLogGenerationResult(self, original, out, reason, "returningRecordIdentifiers");
    return out;
}

static id tb_isGenerateImage(id self, SEL _cmd) {
    id original = o_isGenerateImage ? o_isGenerateImage(self, _cmd) : nil;
    if (!original || !TBEnabled() || TBSafeMode()) return original;
    int reason = 0;
    id out = TBReplaceGeneratedImage(self, original, &reason);
    if (out != original) gServe++;
    TBLogGenerationResult(self, original, out, reason, "generateImage");
    return out;
}

// ---- IFImage（IconServices 图标服务，快捷指令/资源库共用）----
typedef id (*IFImgFn)(id, SEL, id);
typedef id (*IFSizeFn)(id, SEL, CGSize, double);
static IFImgFn o_ifImgDescriptor;
static IFSizeFn o_ifImgSize;

static id tb_ifImgDescriptor(id self, SEL _cmd, id descriptor) {
    if (!TBEnabled() || TBSafeMode()) {
        return o_ifImgDescriptor ? o_ifImgDescriptor(self, _cmd, descriptor) : nil;
    }
    @try {
        NSString *bid = TBBIDFromISIcon(self);
        if (bid.length) {
            UIImage *img = TBImageForBundle(bid);
            if (img) { gServe++; TBLog(@"serve IFImage.desc %@", bid); return img; }
        }
    } @catch (NSException *e) { }
    return o_ifImgDescriptor ? o_ifImgDescriptor(self, _cmd, descriptor) : nil;
}

static id tb_ifImgSize(id self, SEL _cmd, CGSize size, double scale) {
    if (!TBEnabled() || TBSafeMode()) {
        return o_ifImgSize ? o_ifImgSize(self, _cmd, size, scale) : nil;
    }
    @try {
        NSString *bid = TBBIDFromISIcon(self);
        if (bid.length) {
            UIImage *img = TBImageForBundle(bid);
            if (img) { gServe++; TBLog(@"serve IFImage.size %@", bid); return img; }
        }
    } @catch (NSException *e) { }
    return o_ifImgSize ? o_ifImgSize(self, _cmd, size, scale) : nil;
}

static id tb_iconImageOfSize(id self, SEL _cmd, CGSize size, double scale, BOOL gracefully, id drawing) {
    TBRemember(self);
    // 这里拿不到 icon，只做观测：确认这条链是否真的被走
    static int once = 0;
    if (once < 3) { once++; TBLog(@"观测 _iconImageOfSize:%.0fx%.0f scale=%.1f", size.width, size.height, scale); }
    return o_iconImageOfSize ? o_iconImageOfSize(self, _cmd, size, scale, gracefully, drawing) : nil;
}

typedef UIImage *(*UIActivityIconFn)(id, SEL, NSString *);
static UIActivityIconFn o_activityIcon;

/// ShareSheet.framework/UIActivity：分享面板里每个 App 的图标
static UIImage *tb_activityImageForBID(id self, SEL _cmd, NSString *bid) {
    if (!TBApplyEnabled(@"ApplyShare")) {
        // 分享面板：第三方 App 不走 UIActivity 通道
        // 已 hook SBHIconImageCache，通过桌面开关控制
        return o_activityIcon ? o_activityIcon(self, _cmd, bid) : nil;
    }
    if (gProbeCount < 20) { gProbeCount++; TBLog(@"probe UIActivity %@", bid); }
    UIImage *img = TBImageForBundle(bid);
    if (img) { gServe++; TBLog(@"serve UIActivity %@", bid); return img; }
    return o_activityIcon ? o_activityIcon(self, _cmd, bid) : nil;
}


#pragma mark - IconServices（设置页 / 资源库 / 通知中心那条链）

typedef CGImageRef (*ISIconCGFn)(id, SEL, id);
static ISIconCGFn o_isiconCG, o_isiconCG2;

static NSString *TBBIDFromISIcon(id icon) {
    if (!icon) return nil;
    for (NSString *k in @[@"bundleIdentifier", @"applicationBundleIdentifier"]) {
        @try {
            id v = [icon valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        } @catch (NSException *e) {}
    }
    @try {
        id ident = [icon valueForKey:@"_identity"];
        for (NSString *k in @[@"bundleIdentifier", @"applicationBundleIdentifier", @"resourceIdentifier"]) {
            id v = [ident valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        }
        id res = [ident valueForKey:@"resource"];
        id v2 = [res valueForKey:@"bundleIdentifier"];
        if ([v2 isKindOfClass:[NSString class]] && [v2 length]) return v2;
    } @catch (NSException *e) {}
    return nil;
}

static UIImage *TBImageFromISIcon(id icon, id descriptor) {
    NSString *bid = TBBIDFromISIcon(icon);
    if (!bid.length) return nil;
    UIImage *img = TBImageForBundle(bid);
    if (!img) return nil;

    CGSize pt = CGSizeMake(60, 60);
    CGFloat scale = 3.0;
    @try {
        NSValue *sv = [descriptor valueForKey:@"sanitizedSize"];
        if ([sv isKindOfClass:[NSValue class]]) pt = sv.CGSizeValue;
        NSNumber *sc = [descriptor valueForKey:@"sanitizedScale"];
        if ([sc isKindOfClass:[NSNumber class]]) scale = sc.doubleValue;
    } @catch (NSException *e) {}
    if (pt.width < 1) pt = CGSizeMake(60, 60);
    if (scale < 0.5) scale = 3.0;

    TBInfo info = { pt, (double)scale, 0 };
    return TBFitImage(img, info);
}

static CGImageRef tb_isicon_cg(id self, SEL _cmd, id descriptor) {
    static int loggedIcon0 = 0;
    if (loggedIcon0 < 20) { loggedIcon0++; TBLogOnce([@"ISIcon.cg1|" stringByAppendingString:(TBBIDFromISIcon(self) ?: @"(nil)")], @"api=ISIcon.cg1 bid=%@", TBBIDFromISIcon(self) ?: @"(nil)"); }
    if (!TBApplyEnabled(@"ApplySettings")) {
        return o_isiconCG ? o_isiconCG(self, _cmd, descriptor) : NULL;
    }
    @try {
        TBProbe(@"ISIcon CGImageForImageDescriptor %@", TBBIDFromISIcon(self));
        if (gProbeCount < 20) { gProbeCount++; TBLog(@"probe ISIcon %@", TBBIDFromISIcon(self)); }
        UIImage *img = TBImageFromISIcon(self, descriptor);
        if (img && img.CGImage) {
            gServe++;
            TBLog(@"serve ISIcon %@", TBBIDFromISIcon(self));
            return img.CGImage;
        }
    } @catch (NSException *e) {
        TBLog(@"ISIcon 异常: %@", e.reason);
    }
    return o_isiconCG ? o_isiconCG(self, _cmd, descriptor) : NULL;
}

static CGImageRef tb_isicon_cg2(id self, SEL _cmd, id descriptor) {
    static int loggedIcon1 = 0;
    if (loggedIcon1 < 20) { loggedIcon1++; TBLogOnce([@"ISIcon.cg2|" stringByAppendingString:(TBBIDFromISIcon(self) ?: @"(nil)")], @"api=ISIcon.cg2 bid=%@", TBBIDFromISIcon(self) ?: @"(nil)"); }
    if (!TBApplyEnabled(@"ApplySettings")) {
        return o_isiconCG2 ? o_isiconCG2(self, _cmd, descriptor) : NULL;
    }
    @try {
        UIImage *img = TBImageFromISIcon(self, descriptor);
        if (img && img.CGImage) {
            gServe++;
            TBLog(@"serve ISIcon(1) %@", TBBIDFromISIcon(self));
            return img.CGImage;
        }
    } @catch (NSException *e) {}
    return o_isiconCG2 ? o_isiconCG2(self, _cmd, descriptor) : NULL;
}


// 返回类型不确定（UIImage 或 CGImageRef），运行时按真实类型替换；只对日历/时钟生效
typedef id (*ISIconImgFn)(id, SEL, id);
static ISIconImgFn o_isiconImg, o_isiconImg2;

static BOOL TBIsDynamicBID(NSString *bid) {
    return [bid isEqualToString:@"com.apple.mobilecal"] || [bid isEqualToString:@"com.apple.mobiletimer"];
}

/// 动态图标（时钟/日历）在主题 Bundles/ 里找对应素材：
/// ClockIcon* / CalendarIcon*，优先 @3x > @2x > 1x
static NSString *TBDynamicResourcePath(NSString *bid) {
    if (!bid.length || !TBIsDynamicBID(bid)) return nil;
    NSString *prefix = [bid isEqualToString:@"com.apple.mobiletimer"] ? @"clockicon" : @"calendaricon";
    [gLock lock];
    TBLoadIndex();
    NSMutableDictionary *res = TBThemeBundleRes();   // 无主题 → 清空
    [gLock unlock];
    if (!res.count) return nil;

    (void)prefix;
    // 明确按名字优先级挑，支持多种后缀变体（_1024/_1200/@3x 等）
    NSArray<NSString *> *baseCandidates = [bid isEqualToString:@"com.apple.mobiletimer"]
        ? @[@"clockiconbackgroundsquare", @"clockiconbackground", @"clockicon"]
        : @[@"calendariconbackgroundsquare", @"calendariconbackground", @"calendaricon"];
    for (NSString *base in baseCandidates) {
        NSString *lowerBase = [base lowercaseString];
        NSString *best = nil;
        NSInteger bestLen = 0;
        for (NSString *key in res) {
            if (![key hasPrefix:lowerBase]) continue;
            if (![key hasSuffix:@".png"]) continue;
            // 命中即可，越短越准（clockiconbackgroundsquare.png 优先于 ..._1024.png）
            NSInteger len = (NSInteger)key.length;
            if (!best || len < bestLen) { best = res[key]; bestLen = len; }
        }
        if (best) return best;
    }
    return nil;
}

static id tb_isicon_image(id self, SEL _cmd, id descriptor) {
    static int loggedIcon2 = 0;
    if (loggedIcon2 < 20) { loggedIcon2++; TBLogOnce([@"ISIcon.img1|" stringByAppendingString:(TBBIDFromISIcon(self) ?: @"(nil)")], @"api=ISIcon.img1 bid=%@", TBBIDFromISIcon(self) ?: @"(nil)"); }
    id ret = o_isiconImg ? o_isiconImg(self, _cmd, descriptor) : nil;
    if (!TBApplyEnabled(@"ApplySettings")) return ret;

    NSString *bid = TBBIDFromISIcon(self);
    if (!TBIsDynamicBID(bid)) return ret;

    @try {
        UIImage *ours = TBImageFromISIcon(self, descriptor);
        if (!ours) return ret;
        if ([ret isKindOfClass:[UIImage class]]) {
            gServe++;
            TBLog(@"serve ISIcon.img %@", bid);
            return ours;
        }
        if (ret && CFGetTypeID((__bridge CFTypeRef)ret) == CGImageGetTypeID()) {
            gServe++;
            TBLog(@"serve ISIcon.cg %@", bid);
            return (__bridge id)ours.CGImage;
        }
    } @catch (NSException *e) {
        TBLog(@"ISIcon.image 异常: %@", e.reason);
    }
    return ret;
}

static id tb_isicon_image2(id self, SEL _cmd, id descriptor) {
    static int loggedIcon3 = 0;
    if (loggedIcon3 < 20) { loggedIcon3++; TBLogOnce([@"ISIcon.img2|" stringByAppendingString:(TBBIDFromISIcon(self) ?: @"(nil)")], @"api=ISIcon.img2 bid=%@", TBBIDFromISIcon(self) ?: @"(nil)"); }
    id ret = o_isiconImg2 ? o_isiconImg2(self, _cmd, descriptor) : nil;
    if (!TBApplyEnabled(@"ApplySettings")) return ret;

    NSString *bid = TBBIDFromISIcon(self);
    if (!TBIsDynamicBID(bid)) return ret;

    @try {
        UIImage *ours = TBImageFromISIcon(self, descriptor);
        if (!ours) return ret;
        if ([ret isKindOfClass:[UIImage class]]) {
            gServe++;
            TBLog(@"serve ISIcon.img2 %@", bid);
            return ours;
        }
        if (ret && CFGetTypeID((__bridge CFTypeRef)ret) == CGImageGetTypeID()) {
            gServe++;
            TBLog(@"serve ISIcon.cg2 %@", bid);
            return (__bridge id)ours.CGImage;
        }
    } @catch (NSException *e) {}
    return ret;
}

#pragma mark - SpringBoard 资源替换（时钟表盘/指针、文件夹底图）

typedef UIImage *(*ImgNameFn)(id, SEL, NSString *);
typedef UIImage *(*ImgNameBundleFn)(id, SEL, NSString *, NSBundle *);
typedef UIImage *(*ImgNameBundleTraitFn)(id, SEL, NSString *, NSBundle *, id);
static ImgNameFn o_imageNamed, o_imageWithFile;
static ImgNameBundleFn o_imageNamedInBundle;
static ImgNameBundleTraitFn o_imageNamedInBundleTrait;
typedef UIImage *(*AppIconFn)(id, SEL, id, int);
typedef UIImage *(*AppIconScaleFn)(id, SEL, id, int, double);
static AppIconFn o_appIcon;
static AppIconScaleFn o_appIconScale;

static BOOL TBIsThemedResourceName(NSString *name);
static NSString *TBBIDFromIcon(id icon);

/// 设置页图标 / 通知中心 共用 UIKit 应用图标入口
static BOOL TBUIKitIconEnabled(void) {
    return TBApplyEnabled(@"ApplySettings") || TBApplyEnabled(@"ApplyNotification");
}

/// UIKit 私有 format 参数里能识别的「请求尺寸」。只用于系统原实现没给图时的兜底，
/// 而且只会用来把主题图缩小，绝不会放大 —— 宁可小一点，也不能再出现"图标巨大"。
static CGFloat TBAppIconPointsForFormat(int format) {
    switch (format & 0xFF) {
        case 1:  return 29.0;    // 设置 / 通知中心这类列表用的小图标
        case 2:  return 40.0;    // 分享面板 / 搜索结果
        case 3:  return 60.0;    // 主屏图标尺寸
        default: return 0.0;     // 0 = 默认大图，不猜（交给系统原实现给尺寸）
    }
}

/// format → 请求尺寸（pt）缓存，避免每次调用都跑一遍系统原实现。
static NSMutableDictionary *gUIFmtSize;

/// 把主题图按「调用方请求的尺寸」重绘。
/// 之前直接把主题原图（180×180 / 1024×1024）返回，UIKit 只按自己的期望布局缩放、
/// 或者根本不缩放 → 别的 App 列表里图标巨大。这里解析请求尺寸并重绘：
///   ① 系统原实现返回图的尺寸（最可靠：那就是调用方要的尺寸）
///   ② :scale: 变体传进来的 scale
///   ③ format 兜底表（只搬小不搬大）
/// 三者都拿不到 → 返回 nil，调用方原样返回主题图（保持旧行为，不冒险）。
static UIImage *TBUIKitSizedThemeIcon(UIImage *theme, id self, SEL _cmd, id identifier,
                                      int format, double scale, BOOL hasScale) {
    if (!theme) return nil;
    CGSize want = CGSizeZero;
    CGFloat wantScale = hasScale ? scale : 0;

    // ① 先看缓存
    if (!gUIFmtSize) gUIFmtSize = [NSMutableDictionary dictionary];
    NSString *fkey = [NSString stringWithFormat:@"%d|%d", format, hasScale ? 1 : 0];
    NSValue *cv = gUIFmtSize[fkey];
    if (cv) {
        want = cv.CGSizeValue;
    } else {
        @try {
            UIImage *sys = hasScale
                ? (o_appIconScale ? o_appIconScale(self, _cmd, identifier, format, scale) : nil)
                : (o_appIcon      ? o_appIcon(self, _cmd, identifier, format)         : nil);
            if ([sys isKindOfClass:[UIImage class]] && sys.size.width >= 1 && sys.size.height >= 1) {
                want = sys.size;
                if (sys.scale > 0.5) wantScale = sys.scale;
                gUIFmtSize[fkey] = [NSValue valueWithCGSize:want];
            }
        } @catch (NSException *e) { }
    }

    // ③ format 兜底（拿不到系统图时）
    if (want.width < 1 || want.height < 1) {
        CGFloat side = TBAppIconPointsForFormat(format);
        if (side > 0) want = CGSizeMake(side, side);
    }
    if (want.width < 1 || want.height < 1) return nil;         // 真拿不到 → 交回原图
    if (wantScale < 0.5) wantScale = theme.scale > 0.5 ? theme.scale : 3.0;

    // 主题图本来就比请求尺寸小 → 不必重绘（也避免无意义的重绘）
    if (theme.size.width <= want.width + 0.6 && theme.size.height <= want.height + 0.6) return theme;

    TBInfo info = { want, wantScale, 0 };
    UIImage *out = TBFitCached(theme, info, ([identifier isKindOfClass:[NSString class]] ? identifier : nil));
    TBLogOnce([@"uikiticonsize|" stringByAppendingFormat:@"%d|%@", format, identifier ?: @"?"],
              @"UIKit 应用图标尺寸适配：fmt=%d scale=%.1f 请求 %.0fx%.0fpt ← 主题图 %.0fx%.0fpt → %@",
              format, wantScale, want.width, want.height,
              theme.size.width, theme.size.height, (out && out != theme ? @"已重绘" : @"保持原图"));
    return out ?: theme;
}

static UIImage *tb_appIconImageForBID(id self, SEL _cmd, id identifier, int format) {
    if (TBUIKitIconEnabled() && [identifier isKindOfClass:[NSString class]] && [identifier length]) {
        UIImage *img = TBImageForBundle(identifier);
        if (img) {
            gServe++;
            UIImage *sized = TBUIKitSizedThemeIcon(img, self, _cmd, identifier, format, 0, NO) ?: img;
            TBLogOnce([@"uikiticon|" stringByAppendingFormat:@"%@|%d", identifier, format],
                      @"serve 应用图标 %@ fmt=%d → %.0fx%.0fpt", identifier, format,
                      sized.size.width, sized.size.height);
            return sized;
        }
        // 0.15.53：主题【没覆盖】的 App 也走全局效果 —— 之前这条链只对主题覆盖的 App 出
        // 主题图，其余 App 原样返回系统图，于是 App 切换器多任务卡片里一部分 App 还是
        // 系统圆角矩形、和套了遮罩的混在一起。这里对系统原图先 TBArtSquareFilled →
        // TBApplyIconShape → TBApplyIconEffects（TBGlobalEffectImage 内部就是这个顺序），
        // 再按请求尺寸重绘；开关门控（GlobalIconEffect / 形状参数开关）都在函数里。
        UIImage *sys = o_appIcon ? o_appIcon(self, _cmd, identifier, format) : nil;
        UIImage *g = TBGlobalEffectImage(sys, identifier);
        if (g && g != sys) {
            gServe++;
            UIImage *sized = TBUIKitSizedThemeIcon(g, self, _cmd, identifier, format, 0, NO) ?: g;
            TBLogOnce([@"uikitfx|" stringByAppendingFormat:@"%@|%d", identifier, format],
                      @"切换器遮罩：%@（%.0f×%.0f）未覆盖主题，已套全局效果 fmt=%d",
                      identifier, sys.size.width, sys.size.height, format);
            return sized;
        }
        return sys;
    }
    return o_appIcon ? o_appIcon(self, _cmd, identifier, format) : nil;
}

static UIImage *tb_appIconImageForBIDScale(id self, SEL _cmd, id identifier, int format, double scale) {
    if (TBUIKitIconEnabled() && [identifier isKindOfClass:[NSString class]] && [identifier length]) {
        UIImage *img = TBImageForBundle(identifier);
        if (img) {
            gServe++;
            UIImage *sized = TBUIKitSizedThemeIcon(img, self, _cmd, identifier, format, scale, YES) ?: img;
            TBLogOnce([@"uikiticons|" stringByAppendingFormat:@"%@|%d", identifier, format],
                      @"serve 应用图标 %@ fmt=%d scale=%.1f → %.0fx%.0fpt", identifier, format, scale,
                      sized.size.width, sized.size.height);
            return sized;
        }
        // 0.15.53：:scale: 变体同样接全局效果（理由同上）
        UIImage *sys = o_appIconScale ? o_appIconScale(self, _cmd, identifier, format, scale) : nil;
        UIImage *g = TBGlobalEffectImage(sys, identifier);
        if (g && g != sys) {
            gServe++;
            UIImage *sized = TBUIKitSizedThemeIcon(g, self, _cmd, identifier, format, scale, YES) ?: g;
            TBLogOnce([@"uikitfxs|" stringByAppendingFormat:@"%@|%d", identifier, format],
                      @"切换器遮罩：%@（%.0f×%.0f）未覆盖主题，已套全局效果 fmt=%d scale=%.1f",
                      identifier, sys.size.width, sys.size.height, format, scale);
            return sized;
        }
    }
    return o_appIconScale ? o_appIconScale(self, _cmd, identifier, format, scale) : nil;
}

/// 主题资源请求诊断：时钟/日历相关名字只记一次，命中与否都记
static void TBLogResourceProbe(NSString *name, NSString *path) {
    if (!name.length) return;
    if (!([name hasPrefix:@"Clock"] || [name hasPrefix:@"Calendar"] || [name hasPrefix:@"Keypad"])) return;
    TBLogOnce([@"resprobe|" stringByAppendingString:name],
              @"resprobe %@ → %@", name, path ? path.lastPathComponent : @"(主题无此图)");
}

static UIImage *tb_imageNamed(id self, SEL _cmd, NSString *name) {
    if (!TBIsThemedResourceName(name)) {
        return o_imageNamed ? o_imageNamed(self, _cmd, name) : nil;
    }
    UIImage *sys0 = o_imageNamed ? o_imageNamed(self, _cmd, name) : nil;
    UIImage *img = TBMatchSystemGeometry(TBResourceImage(name), sys0);
    TBLogResourceProbe(name, img ? @"hit" : nil);
    if (img) {
        gServe++;
        if (name.length < 48) TBLogOnce([@"res2|" stringByAppendingString:name.lowercaseString],
                                        @"res2 imageNamed %@", name);
        TBLog(@"serve 资源 %@", name);
        return img;
    }
    return sys0;
}

/// +[UIImage imageNamed:inBundle:]、+[UIImage imageNamed:inBundle:compatibleWithTraitCollection:]
/// SpringBoard 的时钟视图有时走这两个变体，只挂 imageNamed: 拦不到
static UIImage *tb_imageNamedInBundle(id self, SEL _cmd, NSString *name, NSBundle *bundle) {
    if (!TBIsThemedResourceName(name)) {
        return o_imageNamedInBundle ? o_imageNamedInBundle(self, _cmd, name, bundle) : nil;
    }
    UIImage *sys = o_imageNamedInBundle ? o_imageNamedInBundle(self, _cmd, name, bundle) : nil;
    UIImage *img = TBMatchSystemGeometry(TBResourceImage(name), sys);
    TBLogResourceProbe(name, img ? @"hit(bundle)" : nil);
    if (img) {
        gServe++;
        if (name.length < 48) TBLogOnce([@"res2|" stringByAppendingString:name.lowercaseString],
                                        @"res2 inBundle %@", name);
        TBLog(@"serve 资源(bundle) %@", name);
        return img;
    }
    return sys;
}

static UIImage *tb_imageNamedInBundleTrait(id self, SEL _cmd, NSString *name, NSBundle *bundle, id trait) {
    if (!TBIsThemedResourceName(name)) {
        return o_imageNamedInBundleTrait ? o_imageNamedInBundleTrait(self, _cmd, name, bundle, trait) : nil;
    }
    UIImage *sys = o_imageNamedInBundleTrait ? o_imageNamedInBundleTrait(self, _cmd, name, bundle, trait) : nil;
    UIImage *img = TBMatchSystemGeometry(TBResourceImage(name), sys);
    TBLogResourceProbe(name, img ? @"hit(bundleTrait)" : nil);
    if (img) {
        gServe++;
        if (name.length < 48) TBLogOnce([@"res2|" stringByAppendingString:name.lowercaseString],
                                        @"res2 inBundleTrait %@", name);
        // 时钟表盘素材：这条路径（系统按名字取资源）也要「圆角 + 白底」，
        // 否则半透明玻璃会透出系统那块深色底盘 → 显示发黑（资源路径之前漏了这步）
        if ([name hasPrefix:@"ClockIconBackground"]) {
            img = TBClockRoundedFace(img);
            TBLogOnce([@"facefeed|res|" stringByAppendingString:(TBActiveTheme() ?: @"")],
                      @"表盘供图[资源路径] 主题=%@ %@", TBActiveTheme() ?: @"?", name);
        }
        TBLog(@"serve 资源(bundleTrait) %@", name);
        return img;
    }
    return sys;
}

/// 只有这些名字才值得查主题资源。imageWithContentsOfFile 是极热接口，
/// 这里不能加锁、不能访问文件系统（曾导致 SpringBoard 被拖死 → 整机重启）。
static BOOL TBIsThemedResourceName(NSString *name) {
    if (name.length < 6 || name.length > 48) return NO;
    unichar c0 = [name characterAtIndex:0];
    if (c0 != 'C' && c0 != 'A' && c0 != 'S' && c0 != 'K') return NO;
    // 指针/轴心素材绝不替换：它们的画布尺寸与表盘不是同一坐标系，
    // 交给系统会导致指针错位甚至跑到看不见的地方（只剩纯白表盘）。
    // 指针一律由系统自己画（黑时针 + 黑分针 + 橙秒针），与官方效果一致。
    if ([name rangeOfString:@"Hand"].location != NSNotFound) return NO;
    if ([name rangeOfString:@"Dot"].location != NSNotFound) return NO;
    // 分工（对齐 SnowBoard）：
    //  · 表盘（ClockIconBackground*）→ 资源重定向，替换系统表盘图
    //  · 指针/轴心（ClockIcon*Hand / *Dot）→ 不在这里，改由
    //    SBHClockHandsImageSet 注入（见 tb_makeImageSet）
    if ([name hasPrefix:@"ClockIconBackground"]) return YES;
    // 角标底板（SBBadgeBG@3x.png）：主题/素材包里有就替换（UseThemeBadge / CustomBadgePath）
    if ([name hasPrefix:@"SBBadgeBG"]) {
        id ub = TBPref(@"UseThemeBadge");
        if (ub && [ub boolValue]) return YES;
        id cb = TBPref(@"CustomBadgePath");
        if ([cb isKindOfClass:[NSString class]] && [(NSString *)cb length]) return YES;
        return NO;
    }
    static NSArray<NSString *> *prefixes = nil;
    if (!prefixes) prefixes = @[@"ANEM", @"CalendarIcon", @"Keypad"];
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p]) return YES;
    }
    return NO;
}

static BOOL TBIsThemedResourceName(NSString *name);

static UIImage *tb_imageWithFile(id self, SEL _cmd, NSString *path) {
    if (!TBIsThemedResourceName(path.lastPathComponent)) {
        return o_imageWithFile ? o_imageWithFile(self, _cmd, path) : nil;
    }
    UIImage *img = TBResourceImage(path);
    if (img) { gServe++; TBLog(@"serve 资源文件 %@", path.lastPathComponent); return img; }
    TBProbe(@"imageWithContentsOfFile 未命中 %@", path.lastPathComponent);
    return o_imageWithFile ? o_imageWithFile(self, _cmd, path) : nil;
}

#pragma mark - NSBundle 资源重定向（SpringBoard 自带的表盘/指针等）

typedef NSString *(*BundlePathFn)(id, SEL, NSString *, NSString *);
typedef NSString *(*BundlePathDirFn)(id, SEL, NSString *, NSString *, NSString *);
static BundlePathFn o_pathForRes;
static BundlePathDirFn o_pathForResDir;

static NSString *TBResourcePathNamed(NSString *name, NSString *ext) {
    if (!name.length || TBSafeMode() || !TBEnabled()) return nil;
    [gLock lock];
    TBLoadIndex();
    NSString *theme = TBActiveTheme();
    NSString *dir = theme.length ? TBThemeDir(theme) : nil;
    if (dir) TBLoadBundleResources(dir);
    NSMutableDictionary *res = gBundleRes;
    [gLock unlock];
    if (!res.count) return nil;

    NSString *key = ext.length ? [NSString stringWithFormat:@"%@.%@", name.lowercaseString, ext.lowercaseString]
                               : name.lowercaseString;
    NSString *hit = res[key] ?: res[name.lowercaseString];
    return hit;
}

static NSString *tb_pathForRes(id self, SEL _cmd, NSString *name, NSString *ext) {
    if (!TBIsThemedResourceName(name)) {
        return o_pathForRes ? o_pathForRes(self, _cmd, name, ext) : nil;
    }
    NSString *p = TBResourcePathNamed(name, ext);
    if (p) { TBLog(@"serve 资源路径 %@.%@", name, ext); return p; }
    return o_pathForRes ? o_pathForRes(self, _cmd, name, ext) : nil;
}

static NSString *tb_pathForResDir(id self, SEL _cmd, NSString *name, NSString *ext, NSString *subdir) {
    if (!TBIsThemedResourceName(name)) {
        return o_pathForResDir ? o_pathForResDir(self, _cmd, name, ext, subdir) : nil;
    }
    NSString *p = TBResourcePathNamed(name, ext);
    if (p) { TBLog(@"serve 资源路径(in) %@.%@", name, ext); return p; }
    return o_pathForResDir ? o_pathForResDir(self, _cmd, name, ext, subdir) : nil;
}

#pragma mark - 桌面时钟（SBHClockApplicationIconImageView 自己合成表盘+指针，绕过图片缓存）

typedef id (*ClockIconImageFn)(id, SEL, TBClockInfo, BOOL);
static ClockIconImageFn o_clockIconImage;

static id tb_clockIconImage(id self, SEL _cmd, TBClockInfo info, BOOL mask) {
    // 只替换底图，指针由系统自己画（SnowBoard 同款做法）：
    // 系统时钟视图会拿这张图当表盘，再把时/分/秒针叠上去，所以会跟着时间走。
    if (TBEnabled() && !TBSafeMode()) {
        UIImage *img = TBImageForBundle(@"com.apple.mobiletimer");
        if (img) {
            TBLogOnce(@"clockbase|hit", @"serve 时钟底图 %@", [img valueForKey:@"size"] ? @"(ok)" : @"(ok)");
            TBInfo fi; fi.size = CGSizeMake(info.w, info.h); fi.scale = info.scale; fi.ratio = 0;
            return TBFitImage(img, fi);
        }
    }
    return o_clockIconImage ? o_clockIconImage(self, _cmd, info, mask) : nil;
}

#pragma mark - 设置页图标（PSSpecifier，17.2 头文件确认）

// - (void)setupIconImageWithBundle:(id)bundle;
// - (void)setupIconImageWithPath:(id)path;
// 设置页每个 App 行的图标由这里生成，之前的 UIImage/ISIcon hook 都不会被调用。
typedef void (*SetupIconFn)(id, SEL, id);
static SetupIconFn o_setupIconBundle, o_setupIconPath;

static void tb_setupIconWithBundle(id self, SEL _cmd, id bundle) {
    if (o_setupIconBundle) o_setupIconBundle(self, _cmd, bundle);
    if (!TBEnabled() || TBSafeMode() || !TBUIKitIconEnabled()) return;
    @try {
        NSString *bid = nil;
        for (NSString *k in @[@"identifier", @"bundleIdentifier"]) {
            if ([self respondsToSelector:NSSelectorFromString(k)]) {
                id v = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(k));
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"."]) { bid = v; break; }
            }
        }
        if (!bid.length) return;
        UIImage *img = TBImageForBundle(bid);
        if (!img) { TBLog(@"miss(设置页) %@", bid); return; }
        SEL setIcon = NSSelectorFromString(@"setIconImage:");
        if ([self respondsToSelector:setIcon]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, setIcon, img);
            TBLog(@"serve(设置页) %@", bid);
        }
    } @catch (NSException *e) { }
}

// 时钟视图会从 imageSet 里取这三层指针叠加上去（17.2 头文件：
// + makeHoursHandLayerWithImageSet: / makeMinutesHandLayerWithImageSet: /
// + makeSecondsHandLayerWithImageSet:）。我们接管背景图后必须同时把这些层置空，
// 否则会出现"主题图自带一根秒针 + 系统又叠一根"的双指针。

#pragma mark - 时钟图像集注入（SnowBoard 同款：makeImageSetForMetrics:）

typedef id (*ClockImageSetFn)(id, SEL, void *);
static ClockImageSetFn o_makeImageSet, o_imageSet;

/// 一次性打印图像集的类名与所有可用成员（排查表盘是从哪里来的）
static void TBLogClockImageSetShape(id set) {
    static BOOL done = NO;
    if (done || !set) return;
    done = YES;
    NSMutableArray *found = [NSMutableArray array];
    NSArray *keys = @[@"hours", @"minutes", @"seconds", @"hourMinuteDot", @"secondDot",
                      @"blackDot", @"redDot", @"background", @"backgroundImage",
                      @"squareBackground", @"backgroundSquare", @"face"];
    for (NSString *k in keys) {
        SEL sel = NSSelectorFromString(k);
        if (![set respondsToSelector:sel]) continue;
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(set, sel);
            if ([v isKindOfClass:[UIImage class]]) {
                UIImage *im = v;
                [found addObject:[NSString stringWithFormat:@"%@=%.0fx%.0f", k, im.size.width, im.size.height]];
            } else {
                [found addObject:[NSString stringWithFormat:@"%@=%@", k, v ? NSStringFromClass([v class]) : @"nil"]];
            }
        } @catch (NSException *e) { }
    }
    TBLog(@"时钟图像集类=%@ 成员: %@", NSStringFromClass([set class]),
          [found componentsJoinedByString:@" "]);
}

static void TBApplyClockImagesToSet(id set) {
    if (!set || !TBEnabled() || TBSafeMode()) return;
    TBLogClockImageSetShape(set);
    // 主题素材 → 图像集成员（名字与 SnowBoard 反编译里一致）
    struct { NSString *key; NSString *res; } map[] = {
        {@"hours",         @"ClockIconHourHand"},
        {@"minutes",       @"ClockIconMinuteHand"},
        {@"seconds",       @"ClockIconSecondHand"},
        {@"hourMinuteDot", @"ClockIconBlackDot"},
        {@"secondDot",     @"ClockIconRedDot"},
    };
    NSInteger applied = 0, restored = 0;
    // 时钟素材准备结果缓存：同主题同成员只解码/抠白底/缩放一次。
    // 系统每次重建针集（约每 10 秒）都会走到这里，原来每次重跑一遍 → 持续耗电发热。
    static NSMutableDictionary *gPrepared = nil;
    static NSString *gPreparedTheme = nil;
    static dispatch_once_t oncePrep;
    dispatch_once(&oncePrep, ^{ gPrepared = [NSMutableDictionary dictionary]; });
    NSString *prepTheme = TBActiveTheme() ?: @"";
    if (![prepTheme isEqualToString:gPreparedTheme ?: @""]) {
        [gPrepared removeAllObjects];
        gPreparedTheme = [prepTheme copy];
    }

    static NSMutableDictionary *gOriginalMembers = nil;
    static dispatch_once_t onceMembers;
    static BOOL captured = NO;
    dispatch_once(&onceMembers, ^{ gOriginalMembers = [NSMutableDictionary dictionary]; });
    if (!captured) {
        // 只在这套针集【第一次被我们碰到、还没注入过】时记录系统原图 —— 这是唯一干净的一份。
        // （之前是"每项第一次见到就记"，结果把自己注入过的主题针也记成了系统原图 → 恢复时多一套针）
        captured = YES;
        for (unsigned i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
            SEL g = NSSelectorFromString(map[i].key);
            if (![set respondsToSelector:g]) continue;
            id v = ((id (*)(id, SEL))objc_msgSend)(set, g);
            if ([v isKindOfClass:[UIImage class]]) gOriginalMembers[map[i].key] = v;
        }
        TBLog(@"时钟图像集：已记录系统原图 %lu 项", (unsigned long)gOriginalMembers.count);
    }
    for (unsigned i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
        SEL setter0 = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
                                           [[map[i].key substringToIndex:1] uppercaseString],
                                           [map[i].key substringFromIndex:1]]);
        NSString *pkey = [prepTheme stringByAppendingFormat:@"|%@", map[i].key];
        {
            UIImage *prep = gPrepared[pkey];
            if ([prep isKindOfClass:[UIImage class]] && [set respondsToSelector:setter0]) {
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(set, setter0, prep);
                    applied++;
                } @catch (NSException *e) { }
                continue;
            }
        }
        UIImage *img = TBResourceImage(map[i].res);
        if (!img) {
            // 主题没这一项 → 还原系统原样（系统的针集是缓存复用的，不还原会残留上一个主题的针）
            UIImage *keep = gOriginalMembers[map[i].key];
            if (keep && [set respondsToSelector:setter0]) {
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(set, setter0, keep);
                    restored++;
                } @catch (NSException *e) { }
            }
            continue;
        }
        img = TBKeyOutCornerColor(img);   // 作者导出忘去白底时兜底

        // 关键：系统图像集里每根针都是按图标尺寸算好的，
        // 直接塞素材原图会大得离谱（248x547 那种画布）。这里取系统原本
        // 那一项的尺寸当目标，把主题素材缩放到同样大小（SnowBoard 同做法）。
        SEL getter = NSSelectorFromString(map[i].key);
        UIImage *orig = nil;
        if ([set respondsToSelector:getter]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(set, getter);
            if ([v isKindOfClass:[UIImage class]]) orig = v;
        }

        // 系统那一项的尺寸：只认第一次读到的"正常值"，之后读到坏值（0 或过小）一律忽略。
        // 否则一旦注入过坏尺寸的图，下次读到的就是它自己 → 越传越坏，系统拉伸铺满 → 针变粗。
        static NSMutableDictionary *gMemberSize = nil;
        static dispatch_once_t onceTok;
        dispatch_once(&onceTok, ^{ gMemberSize = [NSMutableDictionary dictionary]; });
        CGSize target = orig ? orig.size : CGSizeZero;
        NSValue *cachedSize = gMemberSize[map[i].key];
        if (target.width < 4 || target.height < 4) {
            if (cachedSize) {
                target = cachedSize.CGSizeValue;
                TBLogOnce([@"clocksizefb|" stringByAppendingFormat:@"%@|%@", map[i].key, TBActiveTheme() ?: @""],
                          @"时钟针 %@：系统那一项尺寸异常，改用首次记录的正常值 %.0fx%.0f pt",
                          map[i].key, target.width, target.height);
            }
        } else if (!cachedSize) {
            gMemberSize[map[i].key] = [NSValue valueWithCGSize:target];
        }
        TBLogOnce([@"clocksize|" stringByAppendingFormat:@"%@|%@", map[i].key, TBActiveTheme() ?: @""],
                  @"时钟素材尺寸 %@：主题原图 %.0fx%.0f pt scale=%.0f → 目标 %.0fx%.0f pt",
                  map[i].key, img.size.width, img.size.height, img.scale,
                  target.width, target.height);
        if (target.width < 1 || target.height < 1) continue;   // 系统没有这项就别乱塞

        // 与 SnowBoard 完全一致：只做一步 —— 把主题这张图缩放到「系统原本那根针」的尺寸。
        // 不做轴心换算、不改色、不动别的成员（主题没有的成员保持系统原样）。
        // 与 SnowBoard 同一步：把主题图缩放到系统那一项的尺寸。
        // 关键：点尺寸和 scale 都要和系统原本那张完全一致，否则像素尺寸变大，
        // 系统按像素铺开 → 指针看起来又粗又长。
        // SnowBoard 的规则：**只缩小，从不放大**。
        // 主题针比系统那项小就原样用（放大只会把细针糊成一坨粗块 —— 这就是"针变粗"的原因）；
        // 比系统大才按比例缩到能放进去。
        CGFloat oscale = orig.scale > 0.5 ? orig.scale : 1.0;
        CGSize tsz = img.size, osz = target;
        BOOL bigger = (tsz.width > osz.width + 0.01) || (tsz.height > osz.height + 0.01);
        if (bigger) {
            CGFloat k = MIN(osz.width / MAX(tsz.width, 0.01), osz.height / MAX(tsz.height, 0.01));
            target = CGSizeMake(tsz.width * k, tsz.height * k);
        } else {
            target = tsz;      // 主题针比系统那项小 → 目标就是它自己（这一步之前漏了，
                               // 结果还是按系统尺寸放大 → 细针糊成粗块）
        }
        if (bigger || fabs(img.scale - oscale) > 0.01) {
            UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
            fmt.scale = oscale;
            fmt.opaque = NO;
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
            img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [img drawInRect:CGRectMake(0, 0, target.width, target.height)];
            }];
            TBLogOnce([@"clockscale|" stringByAppendingFormat:@"%@|%@", map[i].key, TBActiveTheme() ?: @""],
                      @"时钟针 %@：主题 %.0fx%.0f → 注入 %.0fx%.0f pt（系统那一项 %.0fx%.0f，%@）",
                      map[i].key, tsz.width, tsz.height, img.size.width, img.size.height,
                      osz.width, osz.height, bigger ? @"按比例缩小" : @"原样用，不放大");
        }

        SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
                                          [[map[i].key substringToIndex:1] uppercaseString],
                                          [map[i].key substringFromIndex:1]]);
        if (![set respondsToSelector:setter]) continue;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(set, setter, img);
            applied++;
            gPrepared[pkey] = img;
        } @catch (NSException *e) { }
    }
    if (applied > 0 || restored > 0) {
        TBLogOnce([@"clockset|" stringByAppendingFormat:@"%@|%ld|%ld", prepTheme,
                   (long)applied, (long)restored],
                  @"时钟图像集：注入 %ld 项，还原系统 %ld 项", (long)applied, (long)restored);
    }
}

static id tb_makeImageSet(id self, SEL _cmd, void *metrics) {
    id set = o_makeImageSet ? o_makeImageSet(self, _cmd, metrics) : nil;
    TBApplyClockImagesToSet(set);   // 主题有的成员才替换，没有的保持系统的
    return set;
}

static id tb_imageSet(id self, SEL _cmd, void *metrics) {
    id set = o_imageSet ? o_imageSet(self, _cmd, metrics) : nil;
    TBApplyClockImagesToSet(set);
    return set;
}

#pragma mark - 安装

static BOOL gDoneImageHooks = NO;      // UIImage / NSBundle 那组
static BOOL gDoneISIcon = NO;
static BOOL gDoneActivity = NO;
static BOOL gDoneCache = NO;
// ---- 左滑删除：一次性把滑动容器的真实层级打进日志（灰底到底是什么）----
static NSString *TBColorDesc(UIColor *c) {
    if (!c) return @"nil";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([c getRed:&r green:&g blue:&b alpha:&a]) {
        return [NSString stringWithFormat:@"rgba(%.2f,%.2f,%.2f,%.2f)", r, g, b, a];
    }
    return NSStringFromClass([c class]);
}

static BOOL TBViewHasLabel(UIView *v, NSInteger depth) {
    if (depth > 3) return NO;
    for (UIView *sv in v.subviews) {
        if ([sv isKindOfClass:[UILabel class]]) return YES;
        if (TBViewHasLabel(sv, depth + 1)) return YES;
    }
    return NO;
}

static void TBSwipeTreeDesc(UIView *v, NSInteger depth, NSMutableString *out) {
    if (depth > 4) return;
    for (NSInteger i = 0; i < depth; i++) [out appendString:@"  "];
    NSString *ct = @"-";
    id c = v.layer.contents;
    if (c) {
        if (CFGetTypeID((__bridge CFTypeRef)c) == CGImageGetTypeID()) {
            ct = [NSString stringWithFormat:@"CGImage %.0fx%.0f",
                  CGImageGetWidth((__bridge CGImageRef)c), CGImageGetHeight((__bridge CGImageRef)c)];
        } else {
            ct = NSStringFromClass([(id)c class]);
        }
    }
    [out appendFormat:@"%@ f=%@ bg=%@ r=%.1f clips=%d a=%.2f hid=%d label=%d contents=%@\n",
        NSStringFromClass([v class]), NSStringFromCGRect(v.frame), TBColorDesc(v.backgroundColor),
        v.layer.cornerRadius, v.layer.masksToBounds, v.alpha, v.isHidden,
        TBViewHasLabel(v, 0), ct];
    for (UIView *sv in v.subviews) TBSwipeTreeDesc(sv, depth + 1, out);
}

static void tb_swipePullLayout(id self, SEL _cmd) {
    // 这里只做观测（一次性），不做任何修改
    static BOOL done = NO;
    if (!done && [self isKindOfClass:[UIView class]]) {
        done = YES;
        @try {
            UIView *pull = (UIView *)self;
            NSMutableString *o = [NSMutableString string];
            [o appendFormat:@"滑动容器 %@ f=%@ bg=%@ r=%.1f clips=%d\n",
                NSStringFromClass([pull class]), NSStringFromCGRect(pull.frame),
                TBColorDesc(pull.backgroundColor), pull.layer.cornerRadius,
                pull.layer.masksToBounds];
            NSInteger i = 0;
            for (UIView *p = pull.superview; p && i < 4; p = p.superview, i++) {
                [o appendFormat:@"  父%ld %@ f=%@ bg=%@\n", (long)i, NSStringFromClass([p class]),
                    NSStringFromCGRect(p.frame), TBColorDesc(p.backgroundColor)];
            }
            TBSwipeTreeDesc(pull, 0, o);
            TBLog(@"左滑层级:\n%@", o);
        } @catch (NSException *e) { }
    }
}

// ---- 静态图标模式：隐藏系统指针（图标自己画了指针，否则会重影）----
static void (*o_updateClockImages)(id, SEL);
// ---- 替换角标底板（SBBadgeBG）：系统取角标图不走 imageNamed:，只能从视图层换 ----
//
// 0.15.49 重写。用户实测症状：换主题之后角标「看起来像有两个 / 一直变不回来」，
// 检查发现旧角标会一直赖在图标上，注销（刷新桌面）之后才消失 —— 根因是**没有还原路径**。
// 这一版：
//   ① 【还原】：换主题 / 关角标开关 / 取消应用 / 设置变更（TBReload）时，把之前换上的
//      底板写回系统原图（下面 gBadgeRestores 还原表），日志打「角标：还原 N 处」。
//   ② 只在「真有素材（SBBadgeBG*）或 CustomBadgePath」时才替换；没有素材一律不动。
//   ③ 只换【底板那一层】：整棵角标子树里面积最大的那个 UIImageView（系统底板）；
//      有 UILabel 的层绝不碰 layer.contents —— 数字必须留着。
//   ④ 幂等：同一个角标一次布局只处理一次（还原表里查"还是不是我们换的图"），
//      绝不既改 image 又改 layer.contents（那会画两层 = "两个角标叠着"）。
//   ⑤ 日志必打「角标：命中 <完整路径>」/「角标：没找到素材」（换主题、开机各一次）。
static void (*o_badgeLayout)(id, SEL);
static NSMutableDictionary *gBadgeOrig;   // 类名 → 该类自己的原始 layoutSubviews IMP

/// 调「这个类自己的」原始 layoutSubviews（找不到该类的记录时才退回全局 o_badgeLayout）
static void TBBadgeCallOrig(id self, SEL _cmd) {
    void (*imp)(id, SEL) = NULL;
    [gLock lock];
    NSValue *v = gBadgeOrig[NSStringFromClass([self class])];
    [gLock unlock];
    if (v) imp = (void (*)(id, SEL))[v pointerValue];
    if (imp) imp(self, _cmd);
    else if (o_badgeLayout) o_badgeLayout(self, _cmd);
}

/// 主题角标图缓存：key = 文件路径，换主题整表作废。
/// ★ 必须缓存：幂等检查（plate.image == e.appliedImage）靠 UIImage 指针相等。
///   原来 ②③ 分支每次 layout 都 initWithContentsOfFile: 造新实例 ——
///   系统把底板图写回（image == 系统图）后我们再换一次时，还原表里会叠出
///   「origImage = 上一次的主题角标」的记录链；TBBadgeRestoreAll 按序还原，
///   最后一遍恰恰把【旧主题角标】写回底板 = 换主题后旧角标赖着不走。
///   同一文件返回同一实例后，记录链断掉，还原一定回到系统原图。
///   （只在主线程 layoutSubviews 里访问，不加锁。）
static NSMutableDictionary *gBadgeThemeImgCache;
static NSString *gBadgeThemeImgCacheTheme;
static UIImage *TBBadgeImageFromFileCached(NSString *path) {
    if (!path.length) return nil;
    NSString *theme = TBActiveTheme() ?: @"";
    if (!gBadgeThemeImgCache || ![gBadgeThemeImgCacheTheme isEqualToString:theme]) {
        gBadgeThemeImgCache = [NSMutableDictionary dictionary];
        gBadgeThemeImgCacheTheme = [theme copy];
    } else if (gBadgeThemeImgCache.count > 8) {
        [gBadgeThemeImgCache removeAllObjects];   // 上限保护（路径变体不会太多）
    }
    UIImage *hit = gBadgeThemeImgCache[path];
    if (hit) return hit;
    // 必须用 init：imageWithContentsOfFile: 已被本引擎 hook（递归会爆栈）
    UIImage *im = [[UIImage alloc] initWithContentsOfFile:path];
    if (im) gBadgeThemeImgCache[path] = im;
    return im;
}

/// 角标素材查找：返回图，并回填它到底来自哪个文件（日志要打完整路径）
static UIImage *TBThemeBadgeImageWithPath(NSString **outPath) {
    if (outPath) *outPath = nil;

    // ① 全局自定义素材 / 素材包（CustomBadgePath）—— 最高优先，按路径缓存
    id cb = TBPref(@"CustomBadgePath");
    if ([cb isKindOfClass:[NSString class]] && [(NSString *)cb length]) {
        static NSString *sCachedPath = nil;
        static UIImage *sCachedImg = nil;
        static BOOL sCachedDone = NO;
        NSString *cps = [(NSString *)cb copy];
        if (!sCachedDone || ![cps isEqualToString:sCachedPath ?: @""]) {
            sCachedPath = cps;
            sCachedDone = YES;
            // 必须用 init：imageWithContentsOfFile: 已被本引擎 hook（递归会爆栈）
            sCachedImg = [[UIImage alloc] initWithContentsOfFile:cps];
        }
        if (sCachedImg) {
            if (outPath) *outPath = cps;
            return sCachedImg;
        }
    }
    if (TBSafeMode()) return nil;

    NSString *theme = TBActiveTheme();
    if (!theme.length) return nil;

    // ② 主题 Bundles 递归表（大小写不敏感；Bundles/ 与 Bundles/com.apple.springboard/ 都覆盖）
    [gLock lock];
    NSMutableDictionary *res = TBThemeBundleRes();
    NSString *hit = nil;
    NSArray *keys = @[ @"sbbadgebg@3x.png", @"sbbadgebg@2x.png", @"sbbadgebg.png", @"sbbadgebg" ];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *p = res[keys[i]];
        if (p.length) { hit = [p copy]; break; }
    }
    [gLock unlock];
    if (hit.length) {
        UIImage *im = TBBadgeImageFromFileCached(hit);
        if (im) { if (outPath) *outPath = hit; return im; }
    }

    // ③ IconBundles / AnemoneEffects / 主题根目录（老主题常把角标丢在这些地方；素材包同名也算）
    NSString *dir = TBThemeDir(theme);
    if (dir.length) {
        NSArray *subs = @[ @"IconBundles", @"AnemoneEffects", @"" ];
        for (NSUInteger i = 0; i < subs.count; i++) {
            NSString *sub = subs[i];
            NSString *d = sub.length ? TBResolveDirCI(dir, sub) : dir;
            if (!d.length) continue;
            NSString *p = TBFindBestScaledPNG(d, @"SBBadgeBG");
            if (!p) continue;
            UIImage *im = TBBadgeImageFromFileCached(p);
            if (im) { if (outPath) *outPath = p; return im; }
        }
    }
    return nil;
}

/// 带日志的角标素材查找：同一主题（且"有没有素材"的结论没变）只打一次。
/// 必打「角标：命中 <完整路径>」或「角标：没找到素材」。
static UIImage *TBThemeBadgeImage(void) {
    static NSString *sLoggedTheme = nil;
    static BOOL sLoggedFound = NO;
    NSString *theme = TBActiveTheme() ?: @"";
    NSString *path = nil;
    UIImage *img = TBThemeBadgeImageWithPath(&path);
    BOOL found = (img != nil);
    BOOL same = (sLoggedTheme && [sLoggedTheme isEqualToString:theme] && sLoggedFound == found);
    if (!same) {
        sLoggedTheme = [theme copy];
        sLoggedFound = found;
        if (found) {
            TBLog(@"角标：命中 %@", path.length ? path : @"(自定义素材，路径为空)");
        } else {
            TBLog(@"角标：没找到素材（找过 CustomBadgePath、Bundles/SBBadgeBG@3x|@2x|.png、"
                  @"Bundles/com.apple.springboard/SBBadgeBG*、IconBundles/SBBadgeBG*、"
                  @"AnemoneEffects/SBBadgeBG* 和素材包同名文件，都大小写不敏感）"
                  @"→ 不改角标。要换请在抽屉里「导入角标图片」，或把 SBBadgeBG@3x.png 放进主题 Bundles/");
        }
    }
    return img;
}

#pragma mark - 角标还原表

/// 一条还原记录：我们换掉过哪一层、换之前是什么（视图一律弱引用，注销时不留野指针）
@interface TBBadgeRestore : NSObject
@property (nonatomic, weak) UIView *owner;         // 角标根视图（判断"还是不是我们换的图"）
@property (nonatomic, weak) UIImageView *plate;    // 被换的底板（nil = 走 layer.contents 通道）
@property (nonatomic, weak) UIView *contentsView;  // 直接写在 layer.contents 上的那一层
@property (nonatomic, strong) UIImage *origImage;
@property (nonatomic, assign) UIViewContentMode origMode;
@property (nonatomic, assign) BOOL origClips;
@property (nonatomic, strong) UIColor *origBG;
@property (nonatomic, assign) BOOL hadRedBG;
@property (nonatomic, strong) UIImage *appliedImage;
@property (nonatomic, strong) id origContents;
@end

@implementation TBBadgeRestore
@end

static NSMutableArray<TBBadgeRestore *> *gBadgeRestores;   // 全局还原表
static BOOL gBadgeApplied = NO;                            // 现在有没有我们换上去的角标

/// 这个角标上换过的地方，是不是"还是我们换的那张图"（是 → 本次布局不用再处理，幂等）
static BOOL TBBadgeAlreadyApplied(UIView *owner) {
    NSArray *list = gBadgeRestores;
    if (!list.count) return NO;
    for (NSUInteger i = 0; i < list.count; i++) {
        TBBadgeRestore *e = list[i];
        if (e.owner != owner) continue;
        if (e.contentsView) {
            if (e.contentsView.layer.contents) return YES;
        } else if (e.plate && e.plate.image == e.appliedImage) {
            return YES;
        }
    }
    return NO;
}

static void TBBadgeRemember(TBBadgeRestore *e) {
    if (!gBadgeRestores) gBadgeRestores = [NSMutableArray array];
    [gBadgeRestores addObject:e];
    gBadgeApplied = YES;
}

/// 还原我们换过的所有底板（换主题 / 关角标开关 / 取消应用 / 设置变更都走这里）。
/// 必须在主线程调用（会碰 UIKit 视图）。
static NSUInteger TBBadgeRestoreAll(NSString *why) {
    if (!gBadgeRestores.count) { gBadgeApplied = NO; return 0; }
    NSArray *list = [gBadgeRestores copy];
    [gBadgeRestores removeAllObjects];
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < list.count; i++) {
        TBBadgeRestore *e = list[i];
        @try {
            if (e.contentsView) {
                if (e.contentsView.layer.contents) { e.contentsView.layer.contents = e.origContents; n++; }
            } else if (e.plate) {
                e.plate.image = e.origImage;          // 写回系统原图
                e.plate.contentMode = e.origMode;
                e.plate.clipsToBounds = e.origClips;
                if (e.hadRedBG) e.plate.backgroundColor = e.origBG;
                n++;
            }
        } @catch (NSException *ex) { }
    }
    gBadgeApplied = NO;
    if (n) TBLog(@"角标：还原 %lu 处（%@）", (unsigned long)n, why ?: @"设置变更");
    return n;
}

#pragma mark - 角标底板识别 / 替换

/// 角标子树里找【系统底板】：面积最大的那个 UIImageView（最底层、面积最大的那一层）
static UIImageView *TBBadgeFindPlate(UIView *root) {
    UIImageView *best = nil;
    CGFloat bestA = 0;
    NSMutableArray *level = [NSMutableArray arrayWithObject:root];
    for (int d = 0; d <= 5 && level.count; d++) {
        NSMutableArray *next = [NSMutableArray array];
        for (NSUInteger i = 0; i < level.count; i++) {
            UIView *v = level[i];
            NSArray *kids = [[v subviews] copy];
            for (NSUInteger k = 0; k < kids.count; k++) {
                UIView *sv = kids[k];
                if (sv.hidden) continue;
                if ([sv isKindOfClass:[UIImageView class]]) {
                    CGRect b = sv.bounds;
                    CGFloat a = b.size.width * b.size.height;
                    if (a > bestA) { bestA = a; best = (UIImageView *)sv; }
                }
                [next addObject:sv];
            }
        }
        level = next;
    }
    return best;
}

/// 子树里有没有 UILabel —— 有就绝不能碰这一层的 layer.contents
/// （UILabel 的文字就是画在自己的 layer.contents 上的，换掉 = 数字消失）
static BOOL TBBadgeHasLabel(UIView *v, int depth) {
    if (depth > 5) return NO;
    if ([v isKindOfClass:[UILabel class]]) return YES;
    NSArray *kids = [[v subviews] copy];
    for (NSUInteger i = 0; i < kids.count; i++) {
        if (TBBadgeHasLabel(kids[i], depth + 1)) return YES;
    }
    return NO;
}

/// 只换【一层】底板；返回换了几层（0 或 1）。
/// 绝不既改 image 又改 layer.contents —— 那会画两层（"角标有两个"）。
static NSUInteger TBBadgeApply(UIView *root, UIImage *badge, BOOL verbose) {
    if (!root || !badge) return 0;

    // ① 优先：面积最大的 UIImageView = 系统底板
    UIImageView *plate = TBBadgeFindPlate(root);
    if (plate) {
        if (plate.image == badge) return 1;      // 已经是主题角标 → 幂等（不重复叠加、不重复记录）
        TBBadgeRestore *e = [[TBBadgeRestore alloc] init];
        e.owner = root;
        e.plate = plate;
        e.origImage = plate.image;
        e.origMode = plate.contentMode;
        e.origClips = plate.clipsToBounds;
        e.origBG = plate.backgroundColor;
        plate.image = badge;
        plate.contentMode = UIViewContentModeScaleToFill;
        plate.clipsToBounds = YES;
        // 底板自己画的红底 → 抹掉（只动底板，不碰数字和其它 view）
        UIColor *bg = e.origBG;
        CGFloat r = 0, g = 0, b = 0, a = 0;
        if (bg && [bg getRed:&r green:&g blue:&b alpha:&a] &&
            a > 0.2 && r > 0.45 && r > g * 1.6 && r > b * 1.6) {
            e.hadRedBG = YES;
            plate.backgroundColor = [UIColor clearColor];
        }
        e.appliedImage = badge;
        TBBadgeRemember(e);
        if (verbose) {
            TBLogOnce([@"badgeplate|" stringByAppendingFormat:@"%@|%@",
                       NSStringFromClass([plate class]), TBActiveTheme() ?: @""],
                      @"角标替换：底板 %@ frame=%@ 原图=%@ → 主题角标 %@（只换这一层，数字层没碰）",
                      NSStringFromClass([plate class]),
                      NSStringFromCGRect(CGRectIntegral(plate.frame)),
                      e.origImage ? NSStringFromCGSize(e.origImage.size) : @"(无)",
                      NSStringFromCGSize(badge.size));
        }
        return 1;
    }

    // ② 兜底：没有 UIImageView 底板 —— 只在「本层直接画了 CGImage，且子树里没有 UILabel」时换一次
    if (!TBBadgeHasLabel(root, 0) && root.layer.contents &&
        CFGetTypeID((__bridge CFTypeRef)root.layer.contents) == CGImageGetTypeID()) {
        TBBadgeRestore *e = [[TBBadgeRestore alloc] init];
        e.owner = root;
        e.contentsView = root;
        e.origContents = root.layer.contents;
        root.layer.contents = (__bridge id)badge.CGImage;
        e.appliedImage = badge;
        TBBadgeRemember(e);
        if (verbose) {
            TBLogOnce([@"badgecontents|" stringByAppendingFormat:@"%@|%@",
                       NSStringFromClass([root class]), TBActiveTheme() ?: @""],
                      @"角标替换：%@ 的 layer.contents 底板 → 主题角标（子树里没有 UILabel，数字不受影响）",
                      NSStringFromClass([root class]));
        }
        return 1;
    }
    return 0;
}

/// 还原之后：让屏幕上已有的角标重新布局一次 —— 新主题（有素材）立刻补上，
/// 没素材的主题就保持系统原样。只碰类名带 Badge 的视图，量很小。
static int TBBadgeRelayoutTree(UIView *v, int depth) {
    if (depth > 8) return 0;
    int n = 0;
    NSArray *kids = [[v subviews] copy];
    if ([NSStringFromClass([v class]) rangeOfString:@"Badge"
                                           options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [v setNeedsLayout];
        [v layoutIfNeeded];
        return 1;
    }
    for (NSUInteger i = 0; i < kids.count; i++) n += TBBadgeRelayoutTree(kids[i], depth + 1);
    return n;
}

static void TBBadgeRelayoutVisible(void) {
    @try {
        NSArray *wins = [[UIApplication sharedApplication] windows];
        for (NSUInteger i = 0; i < wins.count; i++) TBBadgeRelayoutTree(wins[i], 0);
    } @catch (NSException *e) { }
}

/// 子树里有没有「这个指针的视图」（0.12s 补刷用：找不到 = 已被复用/销毁，别再贴）
static BOOL TBBadgeTreeHasOwner(UIView *root, uintptr_t tag, int depth) {
    if (!root || depth > 8) return NO;
    if ((uintptr_t)root == tag) return YES;
    for (UIView *k in root.subviews) {
        if (TBBadgeTreeHasOwner(k, tag, depth + 1)) return YES;
    }
    return NO;
}

static void tb_badgeLayout(id self, SEL _cmd) {
    if (![self isKindOfClass:[UIView class]]) {
        TBBadgeCallOrig(self, _cmd);
        return;
    }
    // 父类/子类各挂了一次 hook 时，系统的 [super layoutSubviews] 会把我们拉回来：
    // 只放行最外层那一次，避免同一次布局把角标处理两遍（"两个角标叠着"来源之一）
    static int sDepth = 0;
    if (sDepth > 0) {
        TBBadgeCallOrig(self, _cmd);
        return;
    }
    sDepth++;
    UIView *selfView = (UIView *)self;
    @try {
        // 安全模式 / 总开关关闭：所有新路径（角标/阴影 layer/全局效果）都必须直通原实现。
        // 原来这里只查 UseThemeBadge —— 安全模式下只要开过角标就会继续换图，违背直通原则。
        if (TBSafeMode() || !TBEnabled()) {
            if (gBadgeApplied) TBBadgeRestoreAll(@"安全模式或总开关关闭");
            TBBadgeCallOrig(self, _cmd);
            sDepth--;
            return;
        }
        id ub = TBPref(@"UseThemeBadge");
        BOOL on = (ub && [ub boolValue]);
        id cb = TBPref(@"CustomBadgePath");
        BOOL hasCustom = ([cb isKindOfClass:[NSString class]] && [(NSString *)cb length] > 0);

        if (!on && !hasCustom) {
            // 关掉开关 / 取消应用 → 把之前换上的底板还原成系统原图（不还原就会"赖着不走"）
            if (gBadgeApplied) TBBadgeRestoreAll(@"角标开关已关闭");
            if (o_badgeLayout) o_badgeLayout(self, _cmd);
            sDepth--;
            return;
        }

        TBBadgeCallOrig(self, _cmd);   // 先让系统把底板和数字摆好

        UIImage *badge = TBThemeBadgeImage();
        if (!badge) { sDepth--; return; }               // 没素材一律不动

        if (TBBadgeAlreadyApplied(selfView)) { sDepth--; return; }   // 幂等

        NSUInteger hits = TBBadgeApply(selfView, badge, YES);
        if (hits > 0) {
            TBLogOnce([@"badgecount|" stringByAppendingFormat:@"%@|%@",
                       NSStringFromClass([self class]), TBActiveTheme() ?: @""],
                      @"角标替换：已换底板（%@，%lu 处）", NSStringFromClass([self class]),
                      (unsigned long)hits);
            // 系统有时在 layout 之后才把图写回去 → 稍后补一次（同样幂等，不会叠加）。
            // ★ 旧块捕获了「当时的 badge 图」：0.12s 内若换了主题并已还原（TBReload），
            //   会把【旧主题】的角标贴回去。补两道闸：
            //   ① owner 必须还在屏幕视图树上（不在 = 已销毁/进复用池）；
            //   ② 原有 gBadgeApplied / 幂等检查保留。
            __weak UIView *wv = selfView;
            uintptr_t ownerTag = (uintptr_t)selfView;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *v = wv;
                if (!v) return;
                if (!gBadgeApplied) return;                    // 已经被还原了，不要再贴回去
                if (TBBadgeAlreadyApplied(v)) return;          // 已经是我们换的图
                BOOL stillOnScreen = NO;
                @try {
                    NSArray *wins = [[UIApplication sharedApplication] windows];
                    for (UIView *w in wins) {
                        if (TBBadgeTreeHasOwner(w, ownerTag, 0)) { stillOnScreen = YES; break; }
                    }
                } @catch (NSException *e) { }
                if (!stillOnScreen) return;                    // 不在屏幕上：别把旧主题角标贴回复用池
                TBBadgeApply(v, badge, NO);
            });
        }
    } @catch (NSException *e) {
        TBLog(@"角标替换异常：%@", e.reason);
    }
    sDepth--;
}

static BOOL gDoneBadge = NO;
static BOOL gDoneNCBadge = NO;

static BOOL gDoneClock = NO;

// ---- 时钟表盘：SBHClockApplicationIconImageView 把整块表盘合成进自己的 contents，
//      没有子视图，所以「重画」不会让它重新取图。SnowBoard 的做法是 hook
//      SBLiveIconImageView -contentsImage / -squareContentsImage，直接返回主题表盘。
// ---- 指针颜色 / 秒针显隐：系统自己的接口（SnowBoard 用的就是这三个）----
typedef UIColor *(*HandColorFn)(id, SEL);
typedef BOOL (*HandBoolFn)(id, SEL);
static HandColorFn o_hmHandColor, o_secHandColor;
static HandBoolFn o_hidesSeconds;

static ContentsImgFn o_contentsImageLive, o_squareContentsImageLive;
static BOOL sInClockContents = NO;   // 防自调用（hook 装错层会无限递归）

static BOOL TBIsClockView(id v) {
    NSString *cls = NSStringFromClass([v class]);
    return [cls rangeOfString:@"Clock"].location != NSNotFound;
}

/// 按视图当前尺寸把主题表盘做成对应像素尺寸的图
/// 表盘必须带圆角遮罩：系统给出的图标是遮罩过的（超椭圆），我们直接写
/// layer.contents 的话，四角不透明就会露出方块（就是「时不时变成方的」）。
/// 形状规则与图标完全一致（① 主题遮罩图 → ② 自定义圆角 → ③ 系统形状 → 兜底）
static UIImage *TBClockRoundedFace(UIImage *img) {
    // 表盘不做"已圆角就跳过"排查：表盘素材经常自带透明圆角，跳过的话
    // 写进 layer.contents 就会露出透明角（这点和图标不同）
    return TBApplyIconShape(img, NO);
}

/// 时钟表盘：SnowBoard 的做法 —— 主题 Bundles 里有 ClockIconBackgroundSquare 就用它
/// （按图标圆角遮罩好），没有就返回 nil，让调用方走系统原实现。
/// 注意：不走 IconBundles 的静态图标；静态图标只在列表/快照里用，不参与实时时钟。
/// 表盘缓存：同一主题 + 同一尺寸只渲染一次（系统每分钟都会重建针集，
/// 每次都重渲染一张 192x192 的小图虽然开销很小，但没必要）
static UIImage *gFaceCacheImage;
static NSString *gFaceCacheKey;
static UIImage *TBClockMaterialFaceCached(UIView *v) {
    NSString *key = [NSString stringWithFormat:@"%@|%.0fx%.0f", TBActiveTheme() ?: @"",
                     v.bounds.size.width, v.bounds.size.height];
    if (gFaceCacheImage && [gFaceCacheKey isEqualToString:key]) return gFaceCacheImage;
    UIImage *face = TBClockMaterialFace(v);
    gFaceCacheImage = face;
    gFaceCacheKey = key;
    return face;
}

static UIImage *TBClockMaterialFace(UIView *v) {
    UIImage *face = TBResourceImage(@"ClockIconBackgroundSquare");
    if (!face) return nil;
    CGFloat sc = [UIScreen mainScreen].scale;
    if (sc < 0.5) sc = 3.0;
    TBInfo info;
    info.size = v.bounds.size;
    info.scale = sc;
    info.ratio = 0;
    if (info.size.width < 1 || info.size.height < 1) info.size = CGSizeMake(64, 64);
    return TBClockRoundedFace(TBFitImage(face, info));
}

static id tb_clockContentsImage(id self, SEL _cmd) {
    if (!sInClockContents && TBIsClockView(self)) {
        UIImage *face = TBClockMaterialFace((UIView *)self);
        if (face) {
            TBLogOnce(@"clockface|contents", @"时钟表盘：contentsImage 返回主题表盘 %.0fx%.0f",
                      face.size.width, face.size.height);
            return face;
        }
    }
    if (sInClockContents) return nil;                 // 逃出递归
    if (!o_contentsImageLive) return nil;
    sInClockContents = YES;
    id r = o_contentsImageLive(self, _cmd);
    sInClockContents = NO;
    return r;
}

static id tb_clockSquareContentsImage(id self, SEL _cmd) {
    if (!sInClockContents && TBIsClockView(self)) {
        UIImage *face = TBClockMaterialFace((UIView *)self);
        if (face) return face;
    }
    if (sInClockContents) return nil;
    if (!o_squareContentsImageLive) return nil;
    sInClockContents = YES;
    id r = o_squareContentsImageLive(self, _cmd);
    sInClockContents = NO;
    return r;
}

/// 找真正「自己声明」了这个方法的类（不能挂到只有继承实现的类上，否则原实现
/// 指针会指向我们自己的 hook → 自调用递归）
static Class TBClassDeclaring(Class cls, SEL sel) {
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        BOOL found = NO;
        for (unsigned int i = 0; i < n; i++) {
            if (method_getName(ms[i]) == sel) { found = YES; break; }
        }
        free(ms);
        if (found) return c;
    }
    return Nil;
}


/// 安装：优先挂 SBLiveIconImageView（时钟视图的父类，SnowBoard 也是挂这里），
/// 再兜底挂 SBIconImageView 的同名实现。
static void TBInstallClockContentsHooks(void) {
    Class live = NSClassFromString(@"SBLiveIconImageView");
    if (!live) live = NSClassFromString(@"SBIconImageView");
    if (!live) { TBLog(@"contentsImage：找不到图标图片视图类"); return; }
    // contentsImage / squareContentsImage 都是实例方法（用 TBHook，不是 TBHookClass）
    Class c1 = TBClassDeclaring(live, NSSelectorFromString(@"contentsImage"));
    if (c1) o_contentsImageLive = (ContentsImgFn)TBHook(c1, @"contentsImage",
                                                        (IMP)tb_clockContentsImage, "时钟contents");
    Class c2 = TBClassDeclaring(live, NSSelectorFromString(@"squareContentsImage"));
    if (c2) o_squareContentsImageLive = (ContentsImgFn)TBHook(c2, @"squareContentsImage",
                                                              (IMP)tb_clockSquareContentsImage, "时钟squareContents");
    // 指针：SnowBoard 同款 makeImageSetForMetrics: 注入（主题有的才替换）
    Class clock = NSClassFromString(@"SBHClockApplicationIconImageView");
    if (clock) {
        if (TBHasMethod(clock, @"makeImageSetForMetrics:")) {
            o_makeImageSet = (ClockImageSetFn)TBHookClass(clock, @"makeImageSetForMetrics:",
                                                          (IMP)tb_makeImageSet, "时钟图像集");
        }
        if (TBHasMethod(clock, @"imageSetForMetrics:")) {
            o_imageSet = (ClockImageSetFn)TBHookClass(clock, @"imageSetForMetrics:",
                                                      (IMP)tb_imageSet, "时钟图像集2");
        }
    }
}

static BOOL gDoneSpecifier = NO;
static BOOL gDoneGen = NO;
static BOOL gDoneISGeneration = NO;
static BOOL gDoneIconImageView = NO;
static BOOL gDoneSetIcon = NO;
static BOOL gDoneLayout = NO;
static BOOL gDoneIFImage = NO;

static void TBInstall(void) {
    // 检测 iOS 主版本
    int iosVer = TBGetIOSVersion();
    Class cache = NSClassFromString(@"SBHIconImageCache");
    Class icon  = NSClassFromString(@"SBIcon");
    Class isicon = NSClassFromString(@"ISIcon");
    Class activity = NSClassFromString(@"UIActivity");
    Class spec = NSClassFromString(@"PSSpecifier");
    Class clockView = NSClassFromString(@"SBHClockApplicationIconImageView");
    if (gIsPrimary) {
        TBLog(@"=== iOS 版本=%d 类状态: SBHIconImageCache=%@ SBIcon=%@ ISIcon=%@ UIActivity=%@ PSSpecifier=%@ ClockView=%@ ===",
              iosVer,
              cache ? @"有" : @"无",
              icon ? @"有" : @"无",
              isicon ? @"有" : @"无",
              activity ? @"有" : @"无",
              spec ? @"有" : @"无",
              clockView ? @"有" : @"无");
    }

    // UIImage / NSBundle 资源钩子（跨版本稳定）
    if (!gDoneImageHooks) {
        o_imageNamed = (ImgNameFn)TBHookClass([UIImage class], @"imageNamed:",
                                              (IMP)tb_imageNamed, "UIImage.imageNamed");
        o_imageWithFile = (ImgNameFn)TBHookClass([UIImage class], @"imageWithContentsOfFile:",
                                                 (IMP)tb_imageWithFile, "UIImage.imageWithContentsOfFile");
        o_imageNamedInBundle = (ImgNameBundleFn)TBHookClass([UIImage class], @"imageNamed:inBundle:",
                                                            (IMP)tb_imageNamedInBundle, "UIImage.imageNamed:inBundle");
        o_imageNamedInBundleTrait = (ImgNameBundleTraitFn)TBHookClass([UIImage class],
                                                            @"imageNamed:inBundle:compatibleWithTraitCollection:",
                                                            (IMP)tb_imageNamedInBundleTrait,
                                                            "UIImage.imageNamed:inBundle:trait");
        o_pathForRes = (BundlePathFn)TBHookClass([NSBundle class], @"pathForResource:ofType:",
                                                 (IMP)tb_pathForRes, "NSBundle.pathForResource");
        o_pathForResDir = (BundlePathDirFn)TBHookClass([NSBundle class], @"pathForResource:ofType:inDirectory:",
                                                       (IMP)tb_pathForResDir, "NSBundle.pathForResource:inDirectory");
        o_appIcon = (AppIconFn)TBHookClass([UIImage class], @"_applicationIconImageForBundleIdentifier:format:",
                                           (IMP)tb_appIconImageForBID, "应用图标");
        o_appIconScale = (AppIconScaleFn)TBHookClass([UIImage class], @"_applicationIconImageForBundleIdentifier:format:scale:",
                                                     (IMP)tb_appIconImageForBIDScale, "应用图标(scale)");
        gDoneImageHooks = YES;
    }

    // ISIcon（运行时检测）
    if (isicon && !gDoneISIcon) {
        gDoneISIcon = YES;
        if (TBHasMethod(isicon, @"CGImageForImageDescriptor:")) {
            o_isiconCG = (ISIconCGFn)TBHook(isicon, @"CGImageForImageDescriptor:", (IMP)tb_isicon_cg, "ISIcon 取图");
        }
        if (TBHasMethod(isicon, @"CGImageForDescriptor:")) {
            o_isiconCG2 = (ISIconCGFn)TBHook(isicon, @"CGImageForDescriptor:", (IMP)tb_isicon_cg2, "ISIcon 取图 2");
        }
        if (TBHasMethod(isicon, @"imageForImageDescriptor:")) {
            o_isiconImg = (ISIconImgFn)TBHook(isicon, @"imageForImageDescriptor:", (IMP)tb_isicon_image, "ISIcon 图像");
        }
        if (TBHasMethod(isicon, @"imageForDescriptor:")) {
            o_isiconImg2 = (ISIconImgFn)TBHook(isicon, @"imageForDescriptor:", (IMP)tb_isicon_image2, "ISIcon 图像 2");
        }
    }

    // 桌面时钟图标（运行时检测）
    if (clockView && !gDoneClock) {
        gDoneClock = YES;
        // 指针一律用系统自己的（黑时针 + 黑分针 + 橙秒针），不注入主题指针。
        // 表盘：hook contentsImage，始终返回当前主题的表盘（换主题后自然就是新表盘）
        TBInstallClockContentsHooks();
    }

        // ★★ 0.15.76：通知中心图标 hook 整段【停用】。
        //   用户实测：装上后收不到通知了 + SpringBoard 反复退出重启（自动注销）。
        //   结论：在这台 17.2 上改 NCBadgedIconView 的图会破坏通知链路，风险远大于收益。
        //   保留下面的代码仅作记录，不再执行（TBApplyEnabled(@"ApplyNotification") 也不生效）。
        if (NO && !gDoneNCBadge) {
            gDoneNCBadge = YES;
            for (NSString *cn in @[ @"NCBadgedIconView", @"NCNotificationShortLookView",
                                    @"NCNotificationLongLookView", @"NCExpandedPlatterView" ]) {
                Class c = NSClassFromString(cn);
                if (!c) continue;
                // ★ 0.15.76：不再 hook layoutSubviews（在布局事务里改 iconView.image/cornerRadius
                //   会触发再布局，是"SpringBoard 反复退出重启/自动注销"的真凶）。
                //   改为 didMoveToWindow（每个视图只来一次），且实际改图延后一个 runloop tick。
                for (NSString *sel in @[ @"didMoveToWindow", @"_configureBadgedIconViewIfNecessary" ]) {
                    if (!TBHasMethod(c, sel)) continue;
                    o_ncBadgedLayout = (void (*)(id, SEL))TBHook(c, sel,
                                                                 (IMP)tb_ncBadgedLayout, "NC 图标");
                }
            }
        }
    // 角标底板替换：从视图层换图（SBIconBadgeView / _SBIconBadgeView）。
    // ★ 0.15.51 拷问修复：这个块原来被嵌进了上面 clockView 的 if 里（0.15.49 少一个闭括号），
    //   桌面上没有时钟图标视图时整个角标 hook 都装不上（替换/还原全失效，表现即 0.15.49 的
    //   「角标赖着不走 / 变不回来」）。现在独立成块，clockView 有没有都装。
    if (!gDoneBadge) {
        gDoneBadge = YES;
        for (NSString *clsName in @[@"SBIconBadgeView", @"_SBIconBadgeView", @"SBHIconBadgeView"]) {
            Class bc = NSClassFromString(clsName);
            if (!bc) continue;
            if (TBHasMethod(bc, @"layoutSubviews")) {
                // 每个类存自己的 orig IMP（共用一个全局会让 A 类实例调进 B 类的原始实现）。
                // 注意：必须在 TBHook 之前取 method_getImplementation —— hook 后 Method 里的 imp
                // 就被改写成本实现的了。
                Method bm = class_getInstanceMethod(bc, @selector(layoutSubviews));
                IMP borig = bm ? method_getImplementation(bm) : NULL;
                o_badgeLayout = (void (*)(id, SEL))TBHook(bc, @"layoutSubviews",
                                                          (IMP)tb_badgeLayout, "角标视图");
                if (borig) {
                    if (!gBadgeOrig) gBadgeOrig = [NSMutableDictionary dictionary];
                    gBadgeOrig[clsName] = [NSValue valueWithPointer:borig];
                }
            }
        }
    }
        // ★★ 0.15.58 起彻底移除 UISwipeActionPullView -layoutSubviews 的 hook。
        //    真凶找到了：tb_swipePullLayout 替换了系统的 layoutSubviews 却**没有调用原实现**，
        //    滑动容器因此不做布局 → UIKit 校验「动作数 == 按钮数」永远不通过 →
        //    任何 App（不只 ThemeBoard，Filza 也一样）一左滑就抛
        //    NSInternalInconsistencyException: The swipe action count does not match ...
        //    之前所有在 App 侧的猜测（completionHandler / editingStyle / 模态弹窗）全是误判。
        //    这里永久不再安装该 hook（函数体保留，仅作记录）。
        // 不接管 iconImageWithImageInfo:includingMask:
        // 那一层返回的是「表盘+指针」的合成图，接管后系统画的指针会变形
        //（三根一样粗、橙秒针消失）。改由资源重定向提供 ClockIconBackgroundSquare，
        // 让系统自己合成底图与指针 —— 与 SnowBoard 一致。

    // PSSpecifier 设置页图标（iOS 17.2+ 使用此通道）
    if (spec && !gDoneSpecifier) {
        gDoneSpecifier = YES;
        if (TBHasMethod(spec, @"setupIconImageWithBundle:")) {
            o_setupIconBundle = (SetupIconFn)TBHook(spec, @"setupIconImageWithBundle:",
                                                    (IMP)tb_setupIconWithBundle, "PSSpecifier 设置页图标");
        }
    }

    // UIActivity 分享面板图标（运行时检测）
    if (activity && !gDoneActivity) {
        gDoneActivity = YES;
        if (TBHasMethod(activity, @"_activityImageForApplicationBundleIdentifier:")) {
            o_activityIcon = (UIActivityIconFn)TBHookClass(activity,
                @"_activityImageForApplicationBundleIdentifier:", (IMP)tb_activityImageForBID, "UIActivity 图标");
        }
    }

    // SBHIconImageCache 主通道（所有版本的核心缓存接口）
    if (cache && !gDoneCache) {
        gDoneCache = YES;
        // 跨版本最稳定的核心方法
        if (TBHasMethod(cache, @"imageForIcon:")) {
            o_imageForIcon = (FnIcon)TBHook(cache, @"imageForIcon:", (IMP)tb_imageForIcon, "imageForIcon");
        }
        if (TBHasMethod(cache, @"imageForIcon:options:")) {
            o_imageForIconOpt = (FnIconOpt)TBHook(cache, @"imageForIcon:options:", (IMP)tb_imageForIconOpt, "imageForIcon:options");
        }
        if (TBHasMethod(cache, @"cachedImageForIcon:")) {
            o_cachedForIcon = (FnIcon)TBHook(cache, @"cachedImageForIcon:", (IMP)tb_cachedForIcon, "cachedImageForIcon");
        }
        // iOS 17.2+ 特有
        if (iosVer >= 17 && TBHasMethod(cache, @"realImageForIcon:options:")) {
            o_realForIconOpt = (FnIconOpt)TBHook(cache, @"realImageForIcon:options:", (IMP)tb_realForIconOpt, "realImageForIcon:options");
        }
        if (iosVer >= 17 && TBHasMethod(cache, @"unmaskedImageForIcon:")) {
            o_unmaskedForIcon = (FnIcon)TBHook(cache, @"unmaskedImageForIcon:", (IMP)tb_unmaskedForIcon, "unmaskedImageForIcon");
        }
        if (iosVer >= 17 && TBHasMethod(cache, @"unmaskedImageForIcon:options:")) {
            o_unmaskedForIconOpt = (FnIconOpt)TBHook(cache, @"unmaskedImageForIcon:options:", (IMP)tb_unmaskedForIconOpt, "unmaskedImageForIcon:options");
        }
        // cacheImage:forIcon: 所有版本都存在
        if (TBHasMethod(cache, @"cacheImage:forIcon:")) {
            o_cacheImageForIcon = (FnImageForIcon)TBHook(cache, @"cacheImage:forIcon:", (IMP)tb_cacheImageForIcon, "cacheImage:forIcon");
        }
    }

    // SBIconImageView.setImage:（安全版，SnowBoard 通道）
    Class iconImageViewCls = NSClassFromString(@"SBIconImageView");
    if (iconImageViewCls && !gDoneIconImageView) {
        gDoneIconImageView = YES;
        if (TBHasMethod(iconImageViewCls, @"setImage:")) {
            o_setImageOnIconView = (SetImgFn)TBHook(iconImageViewCls, @"setImage:", (IMP)tb_setImageOnIconView, "SBIconImageView");
        }
        // SBIconImageView.resetImageWithAppIcon:（拖拽放置/状态重建通道）
        if (TBHasMethod(iconImageViewCls, @"resetImageWithAppIcon:")) {
            o_resetImageOnIconView = (ResetImgFn)TBHook(iconImageViewCls, @"resetImageWithAppIcon:", (IMP)tb_resetImageOnIconView, "SBIconImageView.reset");
        }
    }

    // SBIconView -layoutSubviews（自愈校验：图不对才贴，收敛后不再触发）
    Class iconViewCls2 = NSClassFromString(@"SBIconView");
    if (iconViewCls2 && !gDoneLayout && TBHasMethod(iconViewCls2, @"layoutSubviews")) {
        gDoneLayout = YES;
        o_iconViewLayout = (LayoutFn)TBHook(iconViewCls2, @"layoutSubviews",
                                            (IMP)tb_iconViewLayoutSubviews, "SBIconView.layout");
    }

    // SBIconView -_setIcon:animated:（若存在则用；17.2 上通常不存在）
    Class iconViewCls = NSClassFromString(@"SBIconView");
    if (iconViewCls && !gDoneSetIcon && TBHasMethod(iconViewCls, @"_setIcon:animated:")) {
        gDoneSetIcon = YES;
        o_setIconAnimated = (SetIconFn)TBHook(iconViewCls, @"_setIcon:animated:",
                                              (IMP)tb_setIconAnimated, "SBIconView._setIcon");
    }

    // 不安装 _iconImageView / crossfade getter hook：那属于图标初始化热路径。

    // iconservicesagent 的最终生成通道：资源库拖拽/桌面重建会重新经过这里。
    // 只在原实现返回后替换 IFImage，失败一律返回原图。
    Class generation = NSClassFromString(@"ISGenerationRequest");
    if (generation && !gDoneISGeneration) {
        gDoneISGeneration = YES;
        if (TBHasMethod(generation, @"generateImageReturningRecordIdentifiers:")) {
            o_isGeneration = (FnISGeneration)TBHook(generation,
                @"generateImageReturningRecordIdentifiers:",
                (IMP)tb_isGeneration, "ISGenerationRequest 图标生成");
        }
        if (TBHasMethod(generation, @"generateImage")) {
            o_isGenerateImage = (FnISGenerateImage)TBHook(generation,
                @"generateImage", (IMP)tb_isGenerateImage,
                "ISGenerationRequest generateImage");
        }
    }

    // IFImage（IconServices 通道）
    Class ifImage = NSClassFromString(@"IFImage");
    if (ifImage && !gDoneIFImage) {
        gDoneIFImage = YES;
        if (TBHasMethod(ifImage, @"imageForDescriptor:")) {
            o_ifImgDescriptor = (IFImgFn)TBHook(ifImage, @"imageForDescriptor:", (IMP)tb_ifImgDescriptor, "IFImage.desc");
        }
        if (TBHasMethod(ifImage, @"imageForSize:scale:")) {
            o_ifImgSize = (IFSizeFn)TBHook(ifImage, @"imageForSize:scale:", (IMP)tb_ifImgSize, "IFImage.size");
        }
    }

    // 一次性自检：确认关键 hook 都已就位（每个进程只打一行）
    static BOOL loggedState = NO;
    if (!loggedState) {
        loggedState = YES;
        TBLog(@"hookstate cache=%d gen=%d genImg=%d ifimg=%d sbiv=%d",
              o_imageForIcon != NULL, o_isGeneration != NULL,
              o_isGenerateImage != NULL, o_ifImgSize != NULL,
              o_setImageOnIconView != NULL);
    }

    // generateIconImageWithInfo: 仅在 iOS 17.x 上启用（唯一已验证版本）
    if (icon && !gDoneGen) {
        gDoneGen = YES;
        if (TBHasMethod(icon, @"generateIconImageWithInfo:")) {
            o_generateIconImageWithInfo = (FnGen)TBHook(icon, @"generateIconImageWithInfo:",
                                                        (IMP)tb_generateIconImageWithInfo, "generateIconImageWithInfo");
        }
        if (TBHasMethod(icon, @"iconImageWithInfo:")) {
            o_iconImageWithInfo = (FnInfoImage)TBHook(icon, @"iconImageWithInfo:",
                                                      (IMP)tb_iconImageWithInfo, "iconImageWithInfo");
        }
        if (TBHasMethod(icon, @"unmaskedIconImageWithInfo:")) {
            o_unmaskedIconImageWithInfo = (FnInfoImage)TBHook(icon, @"unmaskedIconImageWithInfo:",
                                                             (IMP)tb_unmaskedIconImageWithInfo, "unmaskedIconImageWithInfo");
        }
    }
}


/// 让 SpringBoard 自己重绘桌面图标（不注销）
/// 节流：noteIconStateChangedExternally 会让 SpringBoard 重排整个桌面，
/// 日志里它在 01:04~01:05 稳定 3~4 秒一次地打，主线程就是这么被拖死的。
/// 这里限制到最少 2 秒一次，被压掉的请求只记日志（合并成后面的那一次）。
static void TBRefreshSpringBoard(NSString *why) {
    static NSLock *sLock = nil;
    static NSTimeInterval sLast = 0;
    static NSUInteger sCalls = 0, sThrottled = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sLock = [[NSLock alloc] init]; });

    const NSTimeInterval kMinInterval = 2.0;
    static BOOL sFollow = NO;   // 是否已安排「节流收尾刷新」
    [sLock lock];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    sCalls++;
    if (sLast > 0 && now - sLast < kMinInterval) {
        NSTimeInterval since = now - sLast;
        sThrottled++;
        NSUInteger n = sCalls, t = sThrottled;
        BOOL needFollow = !sFollow;
        sFollow = YES;
        [sLock unlock];
        TBLog(@"刷新节流：距上次 SpringBoard 刷新仅 %.2fs（< %.1fs）→ 跳过第 %lu 次请求（已压掉 %lu 次，触发者=%@）",
              since, kMinInterval, (unsigned long)n, (unsigned long)t, why ?: @"?");
        // ★ 被压掉的请求不再直接丢弃（原注释写「合并成后面的那一次」但实际没有）：
        //   安排一次收尾刷新，保证最后一次设置变更也能落到桌面。
        if (needFollow) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMinInterval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [sLock lock];
                sFollow = NO;
                NSTimeInterval gap = [NSDate timeIntervalSinceReferenceDate] - sLast;
                [sLock unlock];
                if (gap >= kMinInterval - 0.05) TBRefreshSpringBoard(@"节流收尾");
            });
        }
        return;
    }
    sLast = now;
    NSUInteger n = sCalls;
    [sLock unlock];

    Class sc = NSClassFromString(@"SBIconController");
    if (sc) {
        @try {
            id ctrl = ((id (*)(id, SEL))objc_msgSend)(sc, NSSelectorFromString(@"sharedInstance"));
            SEL selMgr = NSSelectorFromString(@"iconManager");
            if (ctrl && [ctrl respondsToSelector:selMgr]) {
                id mgr = ((id (*)(id, SEL))objc_msgSend)(ctrl, selMgr);
                SEL selNote = NSSelectorFromString(@"noteIconStateChangedExternally");
                if (mgr && [mgr respondsToSelector:selNote]) {
                    ((void (*)(id, SEL))objc_msgSend)(mgr, selNote);
                    TBLog(@"已通知 SpringBoard 刷新图标（触发者=%@ 第 %lu 次）", why ?: @"?", (unsigned long)n);
                    return;
                }
            }
        } @catch (NSException *e) {
            TBLog(@"刷新失败: %@", e.reason);
        }
    }
    TBLog(@"· 没有找到 iconManager，图标要等下次重绘（触发者=%@ 第 %lu 次）", why ?: @"?", (unsigned long)n);
}

/// 取桌面上所有图标（用于按需清理缓存）
static NSArray *TBAllIcons(void) {
    @try {
        Class sc = NSClassFromString(@"SBIconController");
        if (!sc) return @[];
        id ctrl = ((id (*)(id, SEL))objc_msgSend)(sc, NSSelectorFromString(@"sharedInstance"));
        if (!ctrl) return @[];

        // 17.2 的 SBIconModel 不支持 leafIcons 的 KVC，改成按方法探测
        id model = nil;
        SEL modelSel = NSSelectorFromString(@"iconModel");
        if ([ctrl respondsToSelector:modelSel]) {
            model = ((id (*)(id, SEL))objc_msgSend)(ctrl, modelSel);
        }
        if (!model) {
            id mgr = [ctrl valueForKey:@"iconManager"];
            if ([mgr respondsToSelector:modelSel]) {
                model = ((id (*)(id, SEL))objc_msgSend)(mgr, modelSel);
            }
        }
        if (!model) return @[];

        NSArray *candidates = @[@"leafIcons", @"icons", @"allIcons", @"visibleIcons", @"leafIconsInIconList"];
        for (NSString *selName in candidates) {
            SEL sel = NSSelectorFromString(selName);
            if (![model respondsToSelector:sel]) continue;
            id arr = ((id (*)(id, SEL))objc_msgSend)(model, sel);
            if ([arr isKindOfClass:[NSArray class]] && [(NSArray *)arr count]) {
                TBLogOnce([@"iconslist|" stringByAppendingString:selName],
                          @"图标列表来源 %@ 共 %lu 个", selName, (unsigned long)[(NSArray *)arr count]);
                return arr;
            }
        }
        TBLogOnce(@"iconslist|none", @"图标列表：候选选择器全部为空");
    } @catch (NSException *e) {
        TBLog(@"取图标列表失败: %@", e.reason);
    }
    return @[];
}

/// 只清这些图标的缓存；icons 为空则退化为全清
static void TBPurgeIcons(NSValue *cacheValue, NSArray *icons) {
    id cache = (__bridge id)cacheValue.pointerValue;
    if (!cache) return;
    @try {
        if (icons.count) {
            SEL sel = NSSelectorFromString(@"purgeCachedImagesForIcons:");
            if ([cache respondsToSelector:sel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(cache, sel, icons);
            }
        } else {
            SEL all = NSSelectorFromString(@"purgeAllCachedImages");
            if ([cache respondsToSelector:all]) {
                ((void (*)(id, SEL))objc_msgSend)(cache, all);
            }
        }
    } @catch (NSException *e) {
        TBLog(@"清理异常: %@", e.reason);
    }
}

/// 只清「主题覆盖到的」那几十个图标的缓存，小批 + 间隔，避免把 SpringBoard 拖死。
static void TBPurgeThemedIcons(void) {
    if (TBSafeMode()) { TBLog(@"安全模式：跳过清缓存"); return; }
    id v = TBPref(@"PurgeCache");
    if (v && ![v boolValue]) { TBLog(@"已跳过清缓存（设置里关掉了）"); return; }

    [gLock lock];
    NSArray *caches = gCaches.allObjects;
    NSDictionary *index = gIndex;
    [gLock unlock];

    NSMutableSet *bids = [NSMutableSet set];
    for (NSString *bid in index) [bids addObject:bid];
    if (!bids.count || !caches.count) { TBLog(@"清缓存：没有可清的目标"); return; }

    // 取当前图标列表
    NSArray *icons = nil;
    @try {
        id ctrl = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"SBIconController"), NSSelectorFromString(@"sharedInstance"));
        id model = ((id (*)(id, SEL))objc_msgSend)(ctrl, NSSelectorFromString(@"iconModel"));
        icons = ((id (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"leafIcons"));
    } @catch (NSException *e) { icons = nil; }
    if (![icons isKindOfClass:[NSArray class]] || !icons.count) { TBLog(@"清缓存：拿不到图标列表"); return; }

    // 只挑主题覆盖到的
    NSMutableArray *targets = [NSMutableArray array];
    for (id icon in icons) {
        NSString *bid = TBBIDFromIcon(icon);
        if (bid && [bids containsObject:bid]) [targets addObject:icon];
    }
    if (!targets.count) { TBLog(@"清缓存：没有匹配到的图标"); return; }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger i = 0;
        while (i < targets.count) {
            NSUInteger n = MIN((NSUInteger)10, targets.count - i);
            NSArray *part = [targets subarrayWithRange:NSMakeRange(i, n)];
            for (NSValue *cv in caches) {
                id cache = cv.nonretainedObjectValue;
                @try {
                    SEL sel = NSSelectorFromString(@"purgeCachedImagesForIcons:");
                    if ([cache respondsToSelector:sel]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(cache, sel, part);
                    }
                } @catch (NSException *e) { }
            }
            i += n;
            usleep(250000);   // 每小批之间 250ms，让出主线程
        }
        TBLog(@"已小批清理 %lu 个图标缓存（每批 10 个）", (unsigned long)targets.count);
    });
}

/// （0.15.53：原来的 TBInvalidateIconViews 同步整表循环已并入 TBRunReload 的分批异步版，
///   这里不再保留独立函数 —— 通知逻辑只有这一处使用方。）

/// 正在执行的那次刷新序号（延迟任务用它判断自己是不是过期了）
static NSUInteger gReloadRunSeq = 0;

static void TBRunReload(NSUInteger mySeq, NSString *why);

/// ---------------------------------------------------------------------------
/// 刷新入口：**节流 + 去重 + 熔断**
///
/// 0.15.48 真机日志（shared-08E9891B_engine.log，8 分钟）实锤的卡死原因：
///   「设置变更：重建索引」出现 256 次、「已通知 SpringBoard 刷新图标」89 次，
///   后段稳定每 3~4 秒一次（01:04:23/24/26/28/31/35…）→ 主线程一直泡在
///   【重建索引 + 全量清缓存 + 窗口树遍历重贴 95 个图标视图 + noteIconStateChangedExternally】
///   里，最后 SpringBoard 被看门狗打死 / 用户看到卡死 + 回桌面。
///
/// 这里做三件事：
///   ① 合并：0.8s 冷却窗口内的重复请求合并成一次（延迟执行，不丢最后一次）
///   ② 熔断：10s 窗口内超过 8 次直接忽略 3s（风暴保护，防止连锁刷新自激）
///   ③ 每条都带「触发者 + 计数」，方便回看是谁在刷（Darwin 通知不带发送者 PID）
/// ---------------------------------------------------------------------------
static void TBReload(CFNotificationCenterRef c, void *o, CFNotificationName n,
                     const void *obj, CFDictionaryRef info) {
    static NSLock *sGate = nil;
    static NSUInteger sReq = 0, sWinCount = 0, sRunCount = 0, sSuppressed = 0;
    static NSTimeInterval sWinStart = 0, sLastRun = 0, sBreakerUntil = 0;
    static BOOL sScheduled = NO, sSaidNoPid = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sGate = [[NSLock alloc] init];
        sSaidNoPid = NO;
    });

    const NSTimeInterval kCooldown = 0.8;   // 冷却窗口
    const NSTimeInterval kWindow   = 10.0;  // 统计窗口
    const NSTimeInterval kBreaker  = 3.0;   // 熔断时长
    const NSUInteger   kWindowMax  = 8;     // 窗口内允许的最大执行次数

    NSString *why = @"Darwin通知";
    @try { if (n) why = [NSString stringWithFormat:@"Darwin通知 %@", (__bridge NSString *)n]; }
    @catch (NSException *e) { }

    [sGate lock];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    sReq++;
    if (sWinStart <= 0 || now - sWinStart > kWindow) { sWinStart = now; sWinCount = 0; sSuppressed = 0; }
    sWinCount++;

    if (now < sBreakerUntil) {
        sSuppressed++;
        NSTimeInterval left = sBreakerUntil - now;
        [sGate unlock];
        if (sSuppressed == 1 || sSuppressed % 50 == 0) {
            TBLog(@"刷新熔断中：忽略第 %lu 次请求（触发者=%@，还剩 %.1fs）", (unsigned long)sSuppressed, why, left);
        }
        return;
    }

    if (sWinCount > kWindowMax) {
        sBreakerUntil = now + kBreaker;
        sSuppressed = 0;
        NSUInteger win = sWinCount;
        [sGate unlock];
        TBLog(@"刷新风暴！%.0fs 内收到 %lu 次刷新请求（第 %lu 次触发者=%@）→ 熔断 %.1fs 内不再刷新"
              @"（日志里【本条】之前的『设置变更/阴影/全局效果』重复行就是刷新链在自激）",
              kWindow, (unsigned long)win, (unsigned long)sReq, why, kBreaker);
        return;
    }

    NSTimeInterval since = (sLastRun > 0) ? (now - sLastRun) : 1e9;
    if (sLastRun > 0 && since < kCooldown) {
        BOOL needSchedule = !sScheduled;
        sScheduled = YES;
        NSUInteger win = sWinCount;
        [sGate unlock];
        TBLog(@"刷新合并：距上次仅 %.2fs（< %.1fs 冷却，触发者=%@，本窗口第 %lu 次）→ 合并成一次",
              since, kCooldown, why, (unsigned long)win);
        if (needSchedule) {
            int64_t delayNs = (int64_t)((kCooldown - since) * (double)NSEC_PER_SEC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNs), dispatch_get_main_queue(), ^{
                [sGate lock];
                sScheduled = NO;
                sLastRun = [NSDate timeIntervalSinceReferenceDate];
                sRunCount++;
                NSUInteger seq = ++gReloadRunSeq;
                NSUInteger run = sRunCount;
                NSUInteger req = sReq;
                [sGate unlock];
                TBLog(@"设置变更（合并后执行）：累计请求 %lu 次 / 实际执行 %lu 次", (unsigned long)req, (unsigned long)run);
                TBRunReload(seq, @"合并延迟执行");
            });
        }
        return;
    }

    sLastRun = now;
    sRunCount++;
    NSUInteger seq = ++gReloadRunSeq;
    NSUInteger run = sRunCount, req = sReq;
    BOOL first = !sSaidNoPid;
    sSaidNoPid = YES;
    [sGate unlock];

    TBLog(@"刷新开始：触发者=%@（累计请求 %lu 次 / 实际执行 %lu 次）", why,
          (unsigned long)req, (unsigned long)run);
    if (first) {
        TBLog(@"说明：Darwin 通知不带发送者，看不到是谁 post 的；若这里持续刷屏，"
              @"说明有进程在反复 post com.ning.themeboard.changed（通常是 App 的滑块/开关在连点）");
    }
    TBRunReload(seq, why);
}

static void TBRunReload(NSUInteger mySeq, NSString *why) {
    [gLock lock];
    gIndex = nil;
    gBundleRes = nil;          // 强制重建资源表（含时钟/日历素材）
    gBundleResTheme = nil;
    // 遮罩图是按「主题名」缓存的：设置一变（例如 App 刚导入遮罩）就允许重扫，
    // 否则导入完必须换主题 / 重启才看得到新形状
    gMaskThemeChecked = NO;
    gMaskThemeKey = nil;
    gMaskThemeImg = nil;
    // 全局效果缓存【不再每次清空】：以前这里 gGlobalImgCache = nil，
    // 于是每次刷新（日志里 256 次）都要把所有图标重新套一遍形状+特效；
    // 现在缓存键里带「主题+特效参数指纹」，参数没变就直接命中。
    // 同理：叠加层 / 阴影素材也是按主题名缓存的
    for (int i = 0; i < 2; i++) { gFxChecked[i] = NO; gFxKey[i] = nil; gFxImg[i] = nil; }
    NSArray *caches = gCaches.allObjects;
    [gLock unlock];
    TBLog(@"设置变更：重建索引，清理 %lu 个缓存", (unsigned long)caches.count);

    // 注意：缓存写入端被我们接管后，换主题必须通知图标视图重取，
    // 这一步不能受「清缓存」开关控制（之前那版会被它一票否决 → 只能重启才刷新）
    BOOL allowPurge = YES;
    id pv = TBPref(@"PurgeCache");
    if (pv) allowPurge = [pv boolValue];
    if (!allowPurge) TBLog(@"清缓存开关关闭：跳过逐个清缓存，仍执行图标重取");

    [gImageCache removeAllObjects];
    {
        // gFitCache 是普通 NSMutableDictionary，读端（TBFitCached）只在写入时短暂拿 gLock。
        // 这里原来裸清：darwin 回调线程正在读/写时并发 removeAllObjects 会偶发崩溃。
        [gLock lock];
        [gFitCache removeAllObjects];
        [gLock unlock];
    }

    // 主线程：先（可选）分批清缓存，再通知图标视图重取，最后让 SpringBoard 重排
    dispatch_async(dispatch_get_main_queue(), ^{
        // 0.15.53：角标还原 + 屏上角标素材缓存失效【延后一个 tick】——
        // 它要逐个写回 plate.layer.contents，应用主题回桌面的第一帧别让它插队
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (mySeq != gReloadRunSeq) return;
            // 角标还原（0.15.49 根因修复）：换主题 / 关角标开关 / 取消应用 / 任何设置变更
            // 都要先把上次换上的底板写回【系统原图】—— 否则旧角标一直赖在图标上。
            if (gBadgeApplied) TBBadgeRestoreAll(@"设置变更（换主题/开关/取消应用）");
            // 角标素材图缓存按主题名失效：App 往同一主题里重导/覆盖 SBBadgeBG 素材后，
            // 旧主题名命中不了变化 —— 这里跟着 TBReload 一起清（主线程，与读端同队列）
            gBadgeThemeImgCache = nil;
            gBadgeThemeImgCacheTheme = nil;
        });

        NSArray *icons = TBAllIcons();
        NSArray *cacheList = caches;

        // 说明：换主题/还原系统时必须真的清掉图标缓存，否则系统会继续用旧图
        //（时钟底图赖着不走就是这个原因）。开关只用来限制「全量清」的规模，
        // 不再一票否决；这里始终按上限分批清。
        if (icons.count == 0) {
                // 拿不到图标列表时不做全量清缓存：一次性清掉上千张图会引发重绘尖峰，
                // 交给下面的窗口遍历按需清理（只碰屏幕上的几十个图标）。
                TBLog(@"拿不到图标列表：跳过全量清缓存，改由窗口遍历按需清理");
            } else {
                // ★ 0.15.69：分批清缓存改成【异步链】。原来 while+usleep(20ms) 仍在主线程
                //   同步占用（N 批 × 20ms），单独用遮罩/边框/阴影回桌面就是撞上这里。
                //   现在每批 dispatch_async，批间让出主线程；总时长不变，但不再卡帧。
                const NSUInteger chunk = 30;
                __block NSUInteger i = 0;
                __block NSInteger round = 0;
                __block void (^drainPurge)(void) = nil;
                drainPurge = ^{
                    if (i >= icons.count) {
                        TBLog(@"已分批清理 %lu 个图标的缓存（%ld 批，异步）",
                              (unsigned long)icons.count, (long)round);
                        drainPurge = nil;
                        return;
                    }
                    NSUInteger n = MIN(chunk, icons.count - i);
                    NSArray *part = [icons subarrayWithRange:NSMakeRange(i, n)];
                    for (NSValue *v in cacheList) { TBPurgeIcons(v, part); }
                    i += n;
                    round++;
                    dispatch_async(dispatch_get_main_queue(), drainPurge);
                };
                dispatch_async(dispatch_get_main_queue(), drainPurge);
        }

        // 0.15.53：通知图标视图重取改为【分批异步】。原来是同步循环 O(图标数 × 缓存数)，
        // 主题覆盖几百个图标时这一下能把主线程按住几百毫秒（应用主题回桌面卡顿主因之一）。
        // 每批 40 个图标 dispatch_async，批间让出主线程；总量超上限时仍走窗口遍历兜底。
        if (icons.count > 0 && icons.count <= 250) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [gLock lock];
                NSArray *cacheList2 = gCaches.allObjects;
                [gLock unlock];
                SEL upd = NSSelectorFromString(@"notifyObserversOfUpdateForIcon:");
                SEL updU = NSSelectorFromString(@"notifyObserversOfUnmaskedUpdateForIcon:");
                __block NSInteger sent = 0;
                const NSUInteger kChunk = 40;
                __block NSUInteger idx = 0;
                __block void (^drainNotify)(void) = nil;
                drainNotify = ^{
                    if (idx >= icons.count) {
                        TBLog(@"已通知图标视图重取 %ld 次（分批异步）", (long)sent);
                        drainNotify = nil;
                        return;
                    }
                    NSUInteger end = MIN(idx + kChunk, icons.count);
                    NSArray *part = [icons subarrayWithRange:NSMakeRange(idx, end - idx)];
                    for (NSValue *v in cacheList2) {
                        id cache = v.nonretainedObjectValue;
                        if (!cache) continue;
                        BOOL canUpd = [cache respondsToSelector:upd];
                        BOOL canUpdU = [cache respondsToSelector:updU];
                        if (!canUpd && !canUpdU) continue;
                        for (id icon in part) {
                            @try {
                                if (canUpd) ((void (*)(id, SEL, id))objc_msgSend)(cache, upd, icon);
                                if (canUpdU) ((void (*)(id, SEL, id))objc_msgSend)(cache, updU, icon);
                                sent++;
                            } @catch (NSException *e) { }
                        }
                    }
                    idx = end;
                    dispatch_async(dispatch_get_main_queue(), drainNotify);
                };
                dispatch_async(dispatch_get_main_queue(), drainNotify);
            });
        } else {
            TBLog(@"图标数 %lu 超过通知上限，跳过逐个通知，改用窗口遍历刷新", (unsigned long)icons.count);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (mySeq != gReloadRunSeq) return;   // 期间又刷了一次，交给最新那次处理
            TBHealAllIconViews();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (mySeq != gReloadRunSeq) return;   // 同上：过期的那次不要再补一刀
            TBRefreshSpringBoard(why);
        });
        // 还原之后把屏幕上的角标重新布局一次：新主题（有素材）立刻补上，
        // 没素材的主题就保持系统红底 —— 用户要的"换回没素材的主题，角标立刻变回来"
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (mySeq != gReloadRunSeq) return;
            TBBadgeRelayoutVisible();
        });
    });
}

/// App 请求重启桌面：让 SpringBoard 退出，系统会自动把它拉起来（等效 respring）
static void TBHandleRespring(CFNotificationCenterRef c, void *o, CFNotificationName n,
                             const void *obj, CFDictionaryRef info) {
    if (!gIsPrimary) return;
    TBLog(@"收到重启桌面请求 → 退出 SpringBoard");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
}

/// 最原始的存活标记：用 C 文件 API 直接写，绕开一切 Objective-C 机制。
/// 只要这个文件出现，就说明 dylib 被 dyld 加载并执行了构造器。
static void TBTouchMarker(const char *tag) {
    const char *paths[] = {
        "/var/mobile/Library/ThemeBoard/alive.txt",
        "/var/jb/var/mobile/Library/ThemeBoard/alive.txt",
        "/tmp/themeboard-alive.txt",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        FILE *f = fopen(paths[i], "a");
        if (!f) continue;
        time_t t = time(NULL);
        struct tm tmv;
        localtime_r(&t, &tmv);
        fprintf(f, "%02d:%02d:%02d pid=%d %s %s\n",
                tmv.tm_hour, tmv.tm_min, tmv.tm_sec, getpid(), tag,
                [[[NSProcessInfo processInfo] processName] UTF8String] ?: "?");
        fclose(f);
    }
}

__attribute__((constructor))
static void TBMain(void) {
    TBTouchMarker("constructor");   // 第一件事：证明自己被加载
    BOOL hasCache = NO;
    @try {
    hasCache = NSClassFromString(@"SBHIconImageCache") != nil;
    BOOL hasActivity = NSClassFromString(@"UIActivity") != nil;
    BOOL hasISIcon = NSClassFromString(@"ISIcon") != nil;
    // 注意：这里【不能】提前 return。构造器执行得极早，
    // SpringBoardHome 可能尚未加载，NSClassFromString 会返回 nil，
    // 一旦提前退出，引擎在 SpringBoard 里就永远装不上 hook。
    // 刷屏问题改由「只有 SpringBoard 写日志文件 + 串行队列」控制。

    // 用【进程名】判断，而不是 hasCache —— 构造器阶段 SBHIconImageCache 可能还没加载，
    // 用类判断会导致 SpringBoard 自己被当成"非主进程"，于是什么都不写。
    NSString *pname = [[NSProcessInfo processInfo] processName] ?: @"";
    gIsPrimary = [pname isEqualToString:@"SpringBoard"] ||
                 [pname rangeOfString:@"iconservicesagent"].location != NSNotFound;
    gLock = [[NSLock alloc] init];
    gImageCache = [[NSCache alloc] init];
    gImageCache.countLimit = 600;
    if (hasCache) {
        TBLog(@"=== ThemeBoardEngine 加载 pid=%d ===", getpid());
        TBLog(@"主题=%@ 开关=%@", TBActiveTheme() ?: @"(无)", TBEnabled() ? @"开" : @"关");
    }
    TBInstall();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TBHandleRespring,
                                    (__bridge CFStringRef)kRespring, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TBReload,
                                    (__bridge CFStringRef)kNotify, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    } @catch (NSException *e) {
        TBTouchMarker("crash");
    }

    // 心跳只在负责图标缓存的进程（SpringBoard）里跑，避免多进程反复改日志时间戳
    // 延迟重试：IconServices / ShareSheet 等框架是懒加载的，
    // 构造器执行时可能还没载入，导致对应 hook 一辈子装不上。
    for (int i = 1; i <= 10; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            TBInstall();
        });
    }

    if (!hasCache) return;
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        while (1) {
            sleep(60);
            if (gLogPath) {
                [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate date]}
                                                ofItemAtPath:gLogPath error:NULL];
            }
        }
    });
}
