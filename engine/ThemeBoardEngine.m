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
    [gLock lock];
    TBLoadIndex();
    NSString *theme = TBActiveTheme();
    NSString *dir = theme.length ? TBThemeDir(theme) : nil;
    if (dir) TBLoadBundleResources(dir);
    NSMutableDictionary *res = gBundleRes;
    [gLock unlock];
    if (!res.count) return nil;

    NSString *key = name.lastPathComponent.lowercaseString;
    NSString *path = res[key];
    if (!path) {
        NSString *base = [key stringByDeletingPathExtension];
        if ([base hasSuffix:@"@2x"] || [base hasSuffix:@"@3x"])
            base = [base substringToIndex:base.length - 3];
        path = res[base];
    }
    // 必须用 init 方法：imageWithContentsOfFile: 已被本引擎 hook，
    // 在此调用会形成无限递归（栈溢出 → SpringBoard 崩溃循环）。
    if (!path) return nil;
    UIImage *img = [[UIImage alloc] initWithContentsOfFile:path];

    // 时钟底图：素材自带透明圆角会在四角透出壁纸，这里填成不透明
    NSString *lower = name.lowercaseString;
    if ([lower hasPrefix:@"clockiconbackground"] && img) {
        static NSMutableSet *done = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ done = [NSMutableSet set]; });
        if (![done containsObject:lower]) {
            [done addObject:lower];
            TBLogOnce(@"clockopaque", @"时钟底图不透明化（填掉透明圆角）");
        }
        img = TBMakeOpaqueOnBodyColor(img);
    }
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

/// 表盘素材中心区域是否已经有指针（个别主题直接把指针画进表盘素材里，
/// 再叠系统指针就重影）。做法：取全图亮度中位数当背景，看中心圆盘内
/// 与背景差异明显的像素占比。
static BOOL TBImageCenterHasInk(UIImage *img) {
    if (!img) return NO;
    const size_t W = 96, H = 96;
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

    // 亮度中位数 = 背景
    int hist[256] = {0};
    NSInteger np = 0;
    for (size_t i = 0; i < W * H; i++) {
        unsigned char *px = buf + i * 4;
        if (px[3] < 40) continue;
        int l = (int)(0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]);
        if (l > 255) l = 255;
        hist[l]++;
        np++;
    }
    int median = 0, acc = 0;
    for (int i = 0; i < 256; i++) { acc += hist[i]; if (acc * 2 >= np) { median = i; break; } }

    // 中心圆盘（半径 0.30）内偏离背景的像素
    CGFloat cx = W / 2.0, cy = H / 2.0, r = W * 0.30;
    NSInteger ink = 0, total = 0;
    for (size_t y = 0; y < H; y++) {
        for (size_t x = 0; x < W; x++) {
            CGFloat dx = x - cx, dy = y - cy;
            if (sqrt(dx * dx + dy * dy) > r) continue;
            unsigned char *px = buf + (y * W + x) * 4;
            if (px[3] < 40) continue;
            int l = (int)(0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]);
            total++;
            if (abs(l - median) > 60) ink++;
        }
    }
    free(buf);
    if (total < 50) return NO;
    return (ink * 100 / total) > 2;   // 中心盘里 2% 以上是"墨"= 画了指针
}

/// 主题只给了 IconBundles 静态图标（Bundles 里没有整套动态素材）→
/// 图标自己就画了日期/指针，我们不该再叠一层
static BOOL TBThemeHasClockMaterial(void) {
    return TBResourceImage(@"ClockIconBackgroundSquare") != nil;
}

static BOOL TBClockShouldHideHands(void) {
    if (!TBEnabled() || TBSafeMode()) return NO;
    NSString *theme = TBActiveTheme();
    if (!theme.length) return NO;                  // 没主题：系统表盘 + 系统指针
    // 用户手动指定优先（设置 → 隐藏时钟指针）
    id hv = TBPref(@"HideClockHands");
    if (hv) return [hv boolValue];

    // 按主题缓存一次结论（这个判断每分钟左右都会问到）
    static NSString *cachedTheme = nil;
    static BOOL cachedHide = NO;
    [gLock lock];
    BOOL same = [cachedTheme isEqualToString:theme];
    [gLock unlock];
    if (same) return cachedHide;

    BOOL hide = NO;
    if (!TBThemeHasClockMaterial()) {
        // 主题只有 IconBundles 静态图标 → 图标自己画了针，隐藏系统指针
        [gLock lock];
        TBLoadIndex();
        BOOL hasStatic = gIndex[@"com.apple.mobiletimer"] != nil;
        [gLock unlock];
        hide = hasStatic;
    } else {
        // 有表盘素材，但素材本身已经把指针画进去了 → 也隐藏，否则重影
        UIImage *face = TBResourceImage(@"ClockIconBackgroundSquare");
        hide = TBImageCenterHasInk(face);
    }
    [gLock lock];
    cachedTheme = [theme copy];
    cachedHide = hide;
    [gLock unlock];
    TBLogOnce([@"clockhands|" stringByAppendingString:theme],
              @"时钟指针判定：%@（中心有针/只有静态图标）",
              hide ? @"隐藏" : @"用系统指针");
    return hide;
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
static UIImage *TBIconRoundedImage(UIImage *img) {
    if (!img) return img;
    CGSize pt = img.size;
    if (pt.width < 16 || pt.height < 16) return img;
    CGFloat w = pt.width, h = pt.height;
    CGFloat a = w / 2.0, b = h / 2.0, cx = w / 2.0, cy = h / 2.0;
    const CGFloat n = 5.0;                 // 苹果图标轮廓 ≈ 超椭圆 n=5
    const NSInteger steps = 180;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = img.scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt];
    return [rd imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPath];
        for (NSInteger i = 0; i <= steps * 4; i++) {
            CGFloat t = (CGFloat)i / (CGFloat)(steps * 4) * 2.0 * M_PI;
            CGFloat ct = cos(t), st = sin(t);
            CGFloat x = cx + a * copysign(pow(fabs(ct), 2.0 / n), ct);
            CGFloat y = cy + b * copysign(pow(fabs(st), 2.0 / n), st);
            if (i == 0) [path moveToPoint:CGPointMake(x, y)];
            else [path addLineToPoint:CGPointMake(x, y)];
        }
        [path closePath];
        [path addClip];
        [img drawInRect:CGRectMake(0, 0, w, h)];
    }];
}

static UIImage *gSystemClockFace;   // 系统自己的时钟表盘（主题取消后还原用）

/// 无主题 / 主题没有表盘素材时，把系统原来的表盘还回去
static UIImage *TBSystemClockFace(void) {
    return gSystemClockFace;
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
            UIImage *masked = TBIconRoundedImage(img);      // 圆角遮罩不能漏
            if (masked) img = masked;
            [gImageCache setObject:img forKey:cacheKey];
            return img;
        }
        UIImage *composed = TBCalendarCompositeImage(img);
        if (composed) {
            TBLogOnce(@"calc|ok", @"日历合成：底图 + 红星期 + 黑日期");
            UIImage *masked = TBIconRoundedImage(composed);   // 合成后同样要裁圆角
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
        }
        img = TBIconRoundedImage(img);      // 方角素材统一裁成系统那种圆角
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
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLogOnce([@"imageForIcon|" stringByAppendingString:bid ?: @"?"], @"serve imageForIcon %@", bid); return img; }
        gMiss++;
        TBLogOnce([@"miss|" stringByAppendingString:bid ?: @"?"], @"miss %@", bid ?: @"(无bid)");
    }
    return o_imageForIcon ? o_imageForIcon(self, _cmd, icon) : nil;
}

static id tb_imageForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLogOnce([@"imageForIconOpt|" stringByAppendingString:bid ?: @"?"], @"serve imageForIcon:options: %@", bid); return img; }
    }
    return o_imageForIconOpt ? o_imageForIconOpt(self, _cmd, icon, opt) : nil;
}

static id tb_cachedForIcon(id self, SEL _cmd, id icon) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLogOnce([@"cachedImageForIcon|" stringByAppendingString:bid ?: @"?"], @"serve cachedImageForIcon %@", bid); return img; }
    }
    return o_cachedForIcon ? o_cachedForIcon(self, _cmd, icon) : nil;
}

static id tb_realForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLogOnce([@"realImageForIcon|" stringByAppendingString:bid ?: @"?"], @"serve realImageForIcon %@", bid); return img; }
    }
    return o_realForIconOpt ? o_realForIconOpt(self, _cmd, icon, opt) : nil;
}

static id tb_unmaskedForIcon(id self, SEL _cmd, id icon) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLogOnce([@"unmaskedImageForIcon|" stringByAppendingString:bid ?: @"?"], @"serve unmaskedImageForIcon %@", bid); return img; }
    }
    return o_unmaskedForIcon ? o_unmaskedForIcon(self, _cmd, icon) : nil;
}

static id tb_unmaskedForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLogOnce([@"unmaskedImageForIconOpt|" stringByAppendingString:bid ?: @"?"], @"serve unmaskedImageForIcon:options %@", bid); return img; }
    }
    return o_unmaskedForIconOpt ? o_unmaskedForIconOpt(self, _cmd, icon, opt) : nil;
}

/// 缓存落盘的那一刻换掉图 —— 这样所有后续消费者（含变体缓存）拿到的都是主题图
static id tb_cacheImageForIcon(id self, SEL _cmd, id image, id icon) {
    TBRemember(self);
    NSString *bid = TBBIDFromIcon(icon);
    // 缓存写入端接管：拖拽/重建时系统会把「非主题」图写进缓存，这里拦下来换成主题图
    if (bid.length && TBApplyIconForDesktop() && !TBSafeMode()) {
        @try {
            UIImage *mine = TBImageForBundle(bid);
            if (mine && image != mine) {
                UIImage *fit = TBFitImage(mine, TBInfoOfCache(self));
                if (fit) {
                    TBLogOnce([@"cachewrite|" stringByAppendingString:bid], @"cachewrite %@", bid);
                    return o_cacheImageForIcon ? o_cacheImageForIcon(self, _cmd, fit, icon) : nil;
                }
            }
        } @catch (NSException *e) { }
    }
    return o_cacheImageForIcon ? o_cacheImageForIcon(self, _cmd, image, icon) : nil;
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
static UIImage *TBClockFaceForView(UIView *v);   // 定义在后面（时钟段）

static NSString *TBViewTreeDesc(UIView *v, NSInteger depth) {
    NSMutableString *s = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) [s appendString:@"  "];
    [s appendFormat:@"%@ f=%@", NSStringFromClass([v class]), NSStringFromCGRect(v.frame)];
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImage *im = ((UIImageView *)v).image;
        [s appendFormat:@" img=%@", im ? [NSString stringWithFormat:@"%.0fx%.0f", im.size.width, im.size.height] : @"nil"];
    }
    if (v.layer.contents) [s appendString:@" [contents]"];
    if (v.isHidden) [s appendString:@" hidden"];
    [s appendString:@"\n"];
    if (depth < 6) for (UIView *sv in v.subviews) [s appendString:TBViewTreeDesc(sv, depth + 1)];
    return s;
}

/// 一次性探针：时钟视图的类链 / ivar / 相关方法 / 子视图树，用来确定表盘图存在哪
static void TBClockDumpNow(id v);
static void TBClockDumpOnce(id v) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    // 延后一点：等这次布局跑完，视图树里才有真正的表盘节点
    __weak id wv = v;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id v = wv; if (!v) return;
        TBClockDumpNow(v);
    });
}

static void TBClockDumpNow(id v) {
    @try {
        NSMutableString *chain = [NSMutableString string];
        for (Class c = [v class]; c && c != [NSObject class]; c = class_getSuperclass(c))
            [chain appendFormat:@"%@ ", NSStringFromClass(c)];
        TBLog(@"时钟类链: %@", chain);

        NSMutableString *ivs = [NSMutableString string];
        for (Class c = [v class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
            unsigned int n = 0; Ivar *list = class_copyIvarList(c, &n);
            for (unsigned int i = 0; i < n; i++) { const char *nm = ivar_getName(list[i]); if (nm) [ivs appendFormat:@"%s ", nm]; }
            free(list);
        }
        TBLog(@"时钟 ivar: %@", ivs);

        NSMutableString *ms = [NSMutableString string];
        for (Class c = [v class]; c && c != [NSObject class]; c = class_getSuperclass(c)) {
            unsigned int n = 0; Method *list = class_copyMethodList(c, &n);
            for (unsigned int i = 0; i < n; i++) {
                NSString *sn = NSStringFromSelector(method_getName(list[i]));
                if ([sn rangeOfString:@"mage"].location != NSNotFound ||
                    [sn rangeOfString:@"lock"].location != NSNotFound ||
                    [sn rangeOfString:@"ackground"].location != NSNotFound ||
                    [sn rangeOfString:@"pdate"].location != NSNotFound ||
                    [sn rangeOfString:@"efresh"].location != NSNotFound)
                    [ms appendFormat:@"%@ ", sn];
            }
            free(list);
        }
        TBLog(@"时钟方法: %@", ms);
        TBLog(@"时钟视图树:\n%@", TBViewTreeDesc((UIView *)v, 0));
        @try {
            UIView *uv = (UIView *)v;
            NSMutableString *ls = [NSMutableString string];
            [ls appendFormat:@"自身 layer contents=%@\n",
                uv.layer.contents ? @"有" : @"无"];
            for (CALayer *l in uv.layer.sublayers) {
                CGSize cs = CGSizeZero;
                id c = l.contents;
                if (c && CFGetTypeID((__bridge CFTypeRef)c) == CGImageGetTypeID()) {
                    cs = CGSizeMake(CGImageGetWidth((__bridge CGImageRef)c),
                                    CGImageGetHeight((__bridge CGImageRef)c));
                }
                [ls appendFormat:@"  子层 %@ f=%@ contents=%.0fx%.0f\n",
                    NSStringFromClass([l class]), NSStringFromCGRect(l.frame), cs.width, cs.height];
            }
            TBLog(@"时钟图层:\n%@", ls);
        } @catch (NSException *e) { }
    } @catch (NSException *e) { TBLog(@"时钟探针异常: %@", e.reason); }
}

static NSInteger TBHealViewTree(UIView *v, NSInteger depth, NSMutableArray *iconsOut) {
    if (!v || depth > 12) return 0;
    NSInteger fixed = 0;
    NSString *vcls = NSStringFromClass([v class]);
    // 时钟视图：换主题后必须重画，否则表盘会一直停在上一个主题
    if ([vcls rangeOfString:@"Clock"].location != NSNotFound) {
        @try {
            TBLogOnce([@"clockrefresh|" stringByAppendingString:vcls], @"时钟视图重画 %@", vcls);
            TBClockDumpOnce(v);
            [v setNeedsLayout];
            [v setNeedsDisplay];
            if ([v respondsToSelector:NSSelectorFromString(@"updateClockImages")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"updateClockImages"));
            }
            // SnowBoard 同款刷新顺序：clearCachedImages → updateClockImages →
            // updateImageAnimated: 。只对【这一个时钟视图】调用（对整棵视图树调用会崩）。
            if ([v respondsToSelector:NSSelectorFromString(@"clearCachedImages")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"clearCachedImages"));
            } else if ([v respondsToSelector:NSSelectorFromString(@"_clearCachedImages")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"_clearCachedImages"));
            }
            if ([v respondsToSelector:NSSelectorFromString(@"updateClockImages")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"updateClockImages"));
            }
            if ([v respondsToSelector:NSSelectorFromString(@"updateImageAnimated:")]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(v, NSSelectorFromString(@"updateImageAnimated:"), NO);
            }
            // 不指望系统重取：直接把当前主题的表盘写进这个视图（它就是表盘本身，
            // 没有子视图；指针是它自己的子图层/自己画的）。
            // 指针开关：不依赖 updateClockImages 的 hook，这里直接按判定设置
            {
                BOOL hide = TBClockShouldHideHands();
                NSInteger n = 0;
                for (CALayer *l in ((UIView *)v).layer.sublayers) { l.hidden = hide; n++; }
                TBLogOnce([@"clockhandsapply|" stringByAppendingFormat:@"%@|%d", TBActiveTheme() ?: @"", (int)hide],
                          @"时钟：指针 %@（%ld 个子层）", hide ? @"已隐藏" : @"显示", (long)n);
            }
            UIImage *cface = TBClockFaceForView((UIView *)v);
            if (cface && cface.CGImage) {
                @try {
                    ((UIView *)v).layer.contents = (__bridge id)cface.CGImage;
                    [v setValue:cface forKey:@"mappedContentsImage"];
                    TBLog(@"时钟表盘：直接写入 layer.contents %.0fx%.0f",
                          cface.size.width, cface.size.height);
                } @catch (NSException *e) {
                    TBLog(@"时钟表盘：写入失败 %@", e.reason);
                }
            }
        } @catch (NSException *e) { }
    }
    BOOL special = ([vcls rangeOfString:@"Folder"].location != NSNotFound) ||
                   ([vcls rangeOfString:@"Clock"].location != NSNotFound) ||
                   ([vcls rangeOfString:@"Library"].location != NSNotFound);
    if (!special &&
        ([v respondsToSelector:NSSelectorFromString(@"icon")] ||
         [v respondsToSelector:NSSelectorFromString(@"_iconImageView")])) {
        if (TBApplyThemeToIconView(v)) fixed++;
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
    for (UIView *sub in v.subviews) fixed += TBHealViewTree(sub, depth + 1, iconsOut);
    return fixed;
}

/// 换主题后遍历窗口层级强制重贴（不依赖图标视图是否登记为缓存观察者）
static void TBHealAllIconViews(void) {
    if (gHealDepth > 0) return;
    gHealDepth++;
    TBLog(@"heal: 开始遍历窗口树");
    @try {
        NSInteger fixed = 0;
        NSMutableArray *seen = [NSMutableArray array];
        for (UIView *w in [[UIApplication sharedApplication] windows]) {
            fixed += TBHealViewTree(w, 0, seen);
            if (fixed > 400) break;   // 上限保护
        }
        TBLog(@"heal: 遍历完成 fixed=%ld seen=%lu", (long)fixed, (unsigned long)seen.count);
        if (fixed > 0) TBLog(@"换主题后重贴 %ld 个图标视图（%lu 个图标）", (long)fixed, (unsigned long)seen.count);

        // 只清「屏幕上真正碰到」的这些图标，避免 purgeAllCachedImages 一次清掉
        // 上千张图、紧接着全量重绘造成尖峰（曾被系统看门狗杀掉）。
        // 注意：这里【不要】清缓存。对屏幕上正在显示的图标调
        // purgeCachedImagesForIcons: 会把 SpringBoard 搞崩（14:33 那次注销的元凶），
        // 而且实测 fixed 恒为 0，本来就没有效果。
        (void)seen;
    } @catch (NSException *e) { }
    TBLog(@"heal: 结束");
    gHealDepth--;
}

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
    NSString *theme = TBActiveTheme();
    NSString *dir = theme.length ? TBThemeDir(theme) : nil;
    if (dir) TBLoadBundleResources(dir);
    NSMutableDictionary *res = gBundleRes;
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

static UIImage *tb_appIconImageForBID(id self, SEL _cmd, id identifier, int format) {
    if (TBUIKitIconEnabled() && [identifier isKindOfClass:[NSString class]] && [identifier length]) {
        UIImage *img = TBImageForBundle(identifier);
        if (img) { gServe++; TBLog(@"serve 应用图标 %@ fmt=%d", identifier, format); return img; }
    }
    return o_appIcon ? o_appIcon(self, _cmd, identifier, format) : nil;
}

static UIImage *tb_appIconImageForBIDScale(id self, SEL _cmd, id identifier, int format, double scale) {
    if (TBUIKitIconEnabled() && [identifier isKindOfClass:[NSString class]] && [identifier length]) {
        UIImage *img = TBImageForBundle(identifier);
        if (img) { gServe++; TBLog(@"serve 应用图标 %@ fmt=%d scale=%.0f", identifier, format, scale); return img; }
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
        if ([name hasPrefix:@"ClockIconBackground"] && sys0) gSystemClockFace = sys0;
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
        if ([name hasPrefix:@"ClockIconBackground"] && sys) gSystemClockFace = sys;
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
        TBLog(@"serve 资源(bundleTrait) %@", name);
        if ([name hasPrefix:@"ClockIconBackground"] && sys) gSystemClockFace = sys;
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

typedef struct { double w, h, scale, ratio; } TBClockInfo;      // SBIconImageInfo 的等价布局
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
    NSInteger applied = 0;
    for (unsigned i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
        UIImage *img = TBResourceImage(map[i].res);
        if (!img) continue;
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

        // 一次性把「系统原本那根针」导出成文件，便于分析其画布/轴心约定
        static BOOL dumped = NO;
        if (!dumped && orig) {
            dumped = YES;
            NSString *dir = @"/var/mobile/Library/ThemeBoard/clockdump";
            [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                      withIntermediateDirectories:YES attributes:nil error:NULL];
            for (NSString *k in @[@"hours", @"minutes", @"seconds", @"hourMinuteDot", @"secondDot"]) {
                SEL g = NSSelectorFromString(k);
                if (![set respondsToSelector:g]) continue;
                id v = ((id (*)(id, SEL))objc_msgSend)(set, g);
                if (![v isKindOfClass:[UIImage class]]) continue;
                NSData *png = UIImagePNGRepresentation((UIImage *)v);
                if (!png) continue;
                NSString *fp = [dir stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"sys-%@.png", k]];
                [png writeToFile:fp atomically:YES];
            }
            TBLog(@"已导出系统指针图到 %@", dir);
        }
        CGSize target = orig ? orig.size : CGSizeZero;
        if (target.width < 1 || target.height < 1) continue;   // 系统没有这项就别乱塞

        if (fabs(img.size.width - target.width) > 1.0 || fabs(img.size.height - target.height) > 1.0) {
            // 关键：scale 必须跟「系统原本那根针」一致，否则点尺寸对了但像素尺寸仍然巨大，
            // 图层按像素铺开 → 指针巨大（上一版就是这个坑）。
            UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
            fmt.scale = orig.scale > 0 ? orig.scale : 3.0;
            fmt.opaque = NO;
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
            img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [img drawInRect:CGRectMake(0, 0, target.width, target.height)];
            }];
            TBLogOnce([@"clockscale|" stringByAppendingString:map[i].key],
                      @"时钟素材缩放 %@：系统 %.0fx%.0f pt scale=%.1f → 注入 %.0fx%.0f pt scale=%.1f",
                      map[i].key, target.width, target.height, orig.scale,
                      img.size.width, img.size.height, img.scale);
        }

        SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
                                          [[map[i].key substringToIndex:1] uppercaseString],
                                          [map[i].key substringFromIndex:1]]);
        if (![set respondsToSelector:setter]) continue;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(set, setter, img);
            applied++;
        } @catch (NSException *e) { }
    }
    if (applied > 0) {
        TBLogOnce(@"clockset", @"时钟图像集注入 %ld 项（指针/轴心来自主题素材）", (long)applied);
    }
}

static id tb_makeImageSet(id self, SEL _cmd, void *metrics) {
    id set = o_makeImageSet ? o_makeImageSet(self, _cmd, metrics) : nil;
    TBApplyClockImagesToSet(set);
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
static void tb_updateClockImages(id self, SEL _cmd) {
    if (o_updateClockImages) o_updateClockImages(self, _cmd);
    if (![self isKindOfClass:[UIView class]]) return;
    BOOL hide = TBClockShouldHideHands();
    for (CALayer *l in ((UIView *)self).layer.sublayers) l.hidden = hide;
    if (hide) TBLogOnce(@"clockhands|hidden", @"时钟：主题只给了静态图标 → 隐藏系统指针");
}

static BOOL gDoneClock = NO;

// ---- 时钟表盘：SBHClockApplicationIconImageView 把整块表盘合成进自己的 contents，
//      没有子视图，所以「重画」不会让它重新取图。SnowBoard 的做法是 hook
//      SBLiveIconImageView -contentsImage / -squareContentsImage，直接返回主题表盘。
typedef id (*ContentsImgFn)(id, SEL);
static ContentsImgFn o_contentsImageLive, o_squareContentsImageLive;
static BOOL sInClockContents = NO;   // 防自调用（hook 装错层会无限递归）

static BOOL TBIsClockView(id v) {
    NSString *cls = NSStringFromClass([v class]);
    return [cls rangeOfString:@"Clock"].location != NSNotFound;
}

/// 按视图当前尺寸把主题表盘做成对应像素尺寸的图
/// 表盘必须带圆角遮罩：系统给出的图标是遮罩过的（超椭圆），我们直接写
/// layer.contents 的话，四角不透明就会露出方块（就是「时不时变成方的」）。
static UIImage *TBClockRoundedFace(UIImage *img) {
    if (!img) return img;
    CGSize pt = img.size;
    if (pt.width < 1 || pt.height < 1) return img;
    CGFloat r = MIN(pt.width, pt.height) * 0.2237;   // iOS 图标圆角 ≈ 22.37%
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = img.scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt];
    return [rd imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, pt.width, pt.height)
                                                    cornerRadius:r];
        [p addClip];
        [img drawInRect:CGRectMake(0, 0, pt.width, pt.height)];
    }];
}

static UIImage *TBClockFaceForView(UIView *v) {
    // 1) 主题 Bundles/ 下的表盘素材（ClockIconBackgroundSquare）
    UIImage *face = TBResourceImage(@"ClockIconBackgroundSquare");
    // 2) 主题没有 Bundles 目录 → 用主题 IconBundles 里的时钟图标当表盘
    if (!face) face = TBImageForBundle(@"com.apple.mobiletimer");
    // 3) 没主题 / 主题没有时钟素材 → 还原系统自己的表盘
    if (!face) face = TBSystemClockFace();
    if (!face) return nil;
    CGFloat sc = [UIScreen mainScreen].scale;
    if (sc < 0.5) sc = 3.0;
    TBInfo info; info.size = v.bounds.size; info.scale = sc; info.ratio = 0;
    if (info.size.width < 1 || info.size.height < 1) { info.size = CGSizeMake(60, 60); }
    return TBClockRoundedFace(TBFitImage(face, info));
}

static id tb_clockContentsImage(id self, SEL _cmd) {
    if (!sInClockContents && TBIsClockView(self)) {
        UIImage *face = TBClockFaceForView((UIView *)self);
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
        UIImage *face = TBClockFaceForView((UIView *)self);
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

typedef void (*SetIconImageFn)(id, SEL, id, unsigned long long, unsigned long long, long long);
static SetIconImageFn o_setIconImage;

static void tb_clockSetImage(id self, SEL _cmd, id image,
                             unsigned long long edges, unsigned long long outside, long long style) {
    if (TBIsClockView(self)) {
        UIImage *face = TBClockFaceForView((UIView *)self);
        if (face) image = face;   // 系统每次贴图都换成当前主题的表盘（含圆角遮罩）
    }
    if (o_setIconImage) o_setIconImage(self, _cmd, image, edges, outside, style);
}

/// 安装：优先挂 SBLiveIconImageView（时钟视图的父类，SnowBoard 也是挂这里），
/// 再兜底挂 SBIconImageView 的同名实现。
static void TBInstallClockContentsHooks(void) {
    Class live = NSClassFromString(@"SBLiveIconImageView");
    if (!live) live = NSClassFromString(@"SBIconImageView");
    if (!live) { TBLog(@"contentsImage：找不到图标图片视图类"); return; }
    // 注意：contentsImage / squareContentsImage 都是【实例方法】，必须用 TBHook
    // （TBHookClass 挂的是类方法，用错了会静默失败：日志「类方法不存在」）
    Class c1 = TBClassDeclaring(live, NSSelectorFromString(@"contentsImage"));
    if (c1) o_contentsImageLive = (ContentsImgFn)TBHook(c1, @"contentsImage",
                                                        (IMP)tb_clockContentsImage, "时钟contents");
    Class c3 = TBClassDeclaring(live, NSSelectorFromString(@"_setImage:onEdges:outside:style:"));
    if (c3) o_setIconImage = (SetIconImageFn)TBHook(c3, @"_setImage:onEdges:outside:style:",
                                                    (IMP)tb_clockSetImage, "时钟贴图");
    Class c2 = TBClassDeclaring(live, NSSelectorFromString(@"squareContentsImage"));
    if (c2) o_squareContentsImageLive = (ContentsImgFn)TBHook(c2, @"squareContentsImage",
                                                              (IMP)tb_clockSquareContentsImage, "时钟squareContents");
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
        // 指针：主题只给静态图标时隐藏系统指针
        {
            Class cv = NSClassFromString(@"SBHClockApplicationIconImageView");
            if (!cv) cv = NSClassFromString(@"SBLiveIconImageView");
            SEL usel = NSSelectorFromString(@"updateClockImages");
            Class owner = nil;
            for (Class c = cv; c && c != [NSObject class]; c = class_getSuperclass(c)) {
                unsigned int n = 0;
                Method *ms = class_copyMethodList(c, &n);
                BOOL found = NO;
                for (unsigned int i = 0; i < n; i++) if (method_getName(ms[i]) == usel) { found = YES; break; }
                free(ms);
                if (found) { owner = c; break; }
            }
            if (owner) o_updateClockImages = (void (*)(id, SEL))TBHook(owner, @"updateClockImages",
                                                                      (IMP)tb_updateClockImages, "时钟指针开关");
        }
        // 左滑删除：装一次观测，把滑动容器的层级结构打进日志
        {
            Class pull = NSClassFromString(@"UISwipeActionPullView");
            if (pull) TBHook(pull, @"layoutSubviews", (IMP)tb_swipePullLayout, "左滑层级观测");
        }
        // 不接管 iconImageWithImageInfo:includingMask:
        // 那一层返回的是「表盘+指针」的合成图，接管后系统画的指针会变形
        //（三根一样粗、橙秒针消失）。改由资源重定向提供 ClockIconBackgroundSquare，
        // 让系统自己合成底图与指针 —— 与 SnowBoard 一致。
    }

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
    }
}


/// 让 SpringBoard 自己重绘桌面图标（不注销）
static void TBRefreshSpringBoard(void) {
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
                    TBLog(@"已通知 SpringBoard 刷新图标");
                    return;
                }
            }
        } @catch (NSException *e) {
            TBLog(@"刷新失败: %@", e.reason);
        }
    }
    TBLog(@"· 没有找到 iconManager，图标要等下次重绘");
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

/// 让所有注册过的图标缓存通知观察者（图标视图）重新取图 —— 换主题后即时生效的关键
static NSInteger TBInvalidateIconViews(NSArray *icons) {
    if (!icons.count) return 0;
    [gLock lock];
    NSArray *cacheList = gCaches.allObjects;
    [gLock unlock];
    SEL upd = NSSelectorFromString(@"notifyObserversOfUpdateForIcon:");
    SEL updU = NSSelectorFromString(@"notifyObserversOfUnmaskedUpdateForIcon:");
    NSInteger sent = 0;
    for (NSValue *v in cacheList) {
        id cache = v.nonretainedObjectValue;
        if (!cache) continue;
        BOOL canUpd = [cache respondsToSelector:upd];
        BOOL canUpdU = [cache respondsToSelector:updU];
        if (!canUpd && !canUpdU) continue;
        for (id icon in icons) {
            @try {
                if (canUpd) ((void (*)(id, SEL, id))objc_msgSend)(cache, upd, icon);
                if (canUpdU) ((void (*)(id, SEL, id))objc_msgSend)(cache, updU, icon);
                sent++;
            } @catch (NSException *e) { }
        }
    }
    return sent;
}

static void TBReload(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef info) {
    static NSUInteger sReloadSeq = 0;
    const NSUInteger mySeq = ++sReloadSeq;
    [gLock lock];
    gIndex = nil;
    gBundleRes = nil;          // 强制重建资源表（含时钟/日历素材）
    gBundleResTheme = nil;
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

    // 主线程：先（可选）分批清缓存，再通知图标视图重取，最后让 SpringBoard 重排
    dispatch_async(dispatch_get_main_queue(), ^{
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
                const NSUInteger chunk = 30;
                NSUInteger i = 0;
                NSInteger round = 0;
                while (i < icons.count) {
                    NSUInteger n = MIN(chunk, icons.count - i);
                    NSArray *part = [icons subarrayWithRange:NSMakeRange(i, n)];
                    for (NSValue *v in cacheList) { TBPurgeIcons(v, part); }
                    i += n;
                    round++;
                    usleep(20000);   // 每批之间让出 20ms，避免主线程长时间被占用
                }
                TBLog(@"已分批清理 %lu 个图标的缓存（%ld 批）", (unsigned long)icons.count, (long)round);
        }

        // 通知是 O(图标数 × 缓存数)，主题可能覆盖上千个图标；
        // 超过上限就跳过，靠下面的窗口遍历（只碰屏幕上的几十个视图）刷新，
        // 避免主线程被几千次调用堵死触发 watchdog。
        if (icons.count > 0 && icons.count <= 250) {
            NSInteger sent = TBInvalidateIconViews(icons);
            TBLog(@"已通知图标视图重取 %ld 次", (long)sent);
        } else {
            TBLog(@"图标数 %lu 超过通知上限，跳过逐个通知，改用窗口遍历刷新", (unsigned long)icons.count);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (mySeq != sReloadSeq) return;   // 期间又切了主题，交给最新那次处理
            TBHealAllIconViews();
        });
        // 再补一次：时钟视图有时要等布局完成后才会重新取表盘
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (mySeq != sReloadSeq) return;
            TBHealAllIconViews();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            TBRefreshSpringBoard();
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
