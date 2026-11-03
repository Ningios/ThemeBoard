#import "TBTheme.h"

@interface TBTheme ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *index;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *cache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *rank;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation TBTheme

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _name = [[path lastPathComponent] copy];
        if ([_name hasSuffix:@".theme"]) _name = [_name substringToIndex:_name.length - 6];
        _iconBundlesPath = [[path stringByAppendingPathComponent:@"IconBundles"] copy];
        _hasBundles = [[NSFileManager defaultManager] fileExistsAtPath:
                       [path stringByAppendingPathComponent:@"Bundles"]];
        _index = [NSMutableDictionary dictionary];
        _cache = [NSMutableDictionary dictionary];
        _rank  = [NSMutableDictionary dictionary];
    }
    return self;
}

// 文件名 → bundleID（剥离 @2x/@3x/-large/~ipad 等后缀）
static NSString *TBBundleIDFromFilename(NSString *file) {
    NSString *s = [file stringByDeletingPathExtension];
    if ([s hasSuffix:@"@2x"] || [s hasSuffix:@"@3x"]) s = [s substringToIndex:s.length - 3];
    for (NSString *suffix in @[@"-large", @"-small", @"-76", @"-60", @"-40"]) {
        if ([s hasSuffix:suffix]) s = [s substringToIndex:s.length - suffix.length];
    }
    NSRange tilde = [s rangeOfString:@"~"];
    if (tilde.location != NSNotFound) s = [s substringToIndex:tilde.location];
    return s;
}

static NSInteger TBScaleRank(NSString *file) {
    if ([file hasSuffix:@"@3x.png"]) return 30;
    if ([file hasSuffix:@"-large.png"]) return 28;
    if ([file hasSuffix:@"@2x.png"]) return 20;
    return 10;
}

- (void)loadIndex {
    if (self.loaded) return;
    self.loaded = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:self.iconBundlesPath error:NULL];
    if (!files) return;

    self.fileCount = files.count;
    for (NSString *file in files) {
        if ([file hasPrefix:@"."]) continue;
        if (![[file pathExtension].lowercaseString isEqualToString:@"png"]) continue;
        NSString *bid = TBBundleIDFromFilename(file);
        if (bid.length == 0) continue;

        NSInteger rank = TBScaleRank(file);
        NSNumber *old = self.rank[bid];
        if (old && old.integerValue >= rank) continue;

        self.index[bid] = [self.iconBundlesPath stringByAppendingPathComponent:file];
        self.rank[bid] = @(rank);
    }
    self.iconCount = self.index.count;
}

- (NSArray<NSString *> *)bundleIdentifiers {
    [self loadIndex];
    return [self.index.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

- (NSString *)imagePathForBundleID:(NSString *)bid {
    [self loadIndex];
    return bid ? self.index[bid] : nil;
}

- (UIImage *)imageForBundleID:(NSString *)bid {
    if (!bid) return nil;
    UIImage *img = self.cache[bid];
    if (img) return img;

    NSString *p = [self imagePathForBundleID:bid];
    if (!p) return nil;
    img = [UIImage imageWithContentsOfFile:p];
    if (img) self.cache[bid] = img;
    return img;
}

- (BOOL)hasIconForBundleID:(NSString *)bid {
    return bid && [self imagePathForBundleID:bid] != nil;
}

#pragma mark - 主题自带遮罩图

/// 逐段大小写不敏感地解析相对目录
static NSString *TBResolveSubdirCI(NSString *base, NSString *rel) {
    if (!base.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *cur = base;
    for (NSString *comp in [rel componentsSeparatedByString:@"/"]) {
        if (!comp.length) continue;
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:cur isDirectory:&isDir] || !isDir) return nil;
        NSString *next = nil;
        for (NSString *item in [fm contentsOfDirectoryAtPath:cur error:NULL]) {
            NSString *full = [cur stringByAppendingPathComponent:item];
            BOOL d = NO;
            if ([fm fileExistsAtPath:full isDirectory:&d] && d &&
                [item caseInsensitiveCompare:comp] == NSOrderedSame) { next = full; break; }
        }
        if (!next) return nil;
        cur = next;
    }
    return cur;
}

/// 目录里按名字找文件（大小写不敏感）
static NSString *TBFindFileCIInDir(NSString *dir, NSString *name) {
    if (!dir.length || !name.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([item caseInsensitiveCompare:name] != NSOrderedSame) continue;
        NSString *p = [dir stringByAppendingPathComponent:item];
        BOOL d = NO;
        if ([fm fileExistsAtPath:p isDirectory:&d] && !d) return p;
    }
    return nil;
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

- (NSString *)iconMaskPath {
    if (!self.path.length) return nil;

    // ① IconBundles/Icon.png（含小写 icon.png）
    NSString *ib = TBResolveSubdirCI(self.path, @"IconBundles");
    if (ib.length) {
        NSString *p = TBFindFileCIInDir(ib, @"Icon.png");
        if (p) return p;
    }
    // ② 主题根目录 icon.png
    NSString *p2 = TBFindFileCIInDir(self.path, @"Icon.png");
    if (p2) return p2;
    // ③ 经典 AppIconMask
    NSString *fw = TBResolveSubdirCI(self.path, @"Bundles/com.apple.mobileicons.framework");
    if (fw.length) {
        NSString *p3 = TBFindBestScaledPNG(fw, @"AppIconMask");
        if (p3) return p3;
    }
    // ④ 旧写法兜底
    NSArray *cands = @[ @[@"", @"IconMask.png"],
                        @[@"", @"IconMask@3x.png"],
                        @[@"", @"IconMask@2x.png"],
                        @[@"IconBundles", @"IconMask.png"],
                        @[@"Bundles/com.apple.springboard", @"IconMask.png"] ];
    for (NSArray *c in cands) {
        NSString *sub = c[0], *name = c[1];
        NSString *d = sub.length ? TBResolveSubdirCI(self.path, sub) : self.path;
        if (!d.length) continue;
        NSString *p = TBFindFileCIInDir(d, name);
        if (p) return p;
    }
    return nil;
}

- (NSString *)anemoneEffectPath:(NSString *)base {
    if (!self.path.length || !base.length) return nil;
    NSString *fx = TBResolveSubdirCI(self.path, @"AnemoneEffects");
    if (!fx.length) return nil;
    NSArray *names = @[ [base stringByAppendingString:@"@3x.png"],
                        [base stringByAppendingString:@"@2x.png"],
                        [base stringByAppendingString:@".png"] ];
    for (NSString *n in names) {
        NSString *p = TBFindFileCIInDir(fx, n);
        if (p) return p;
    }
    return nil;
}

- (UIImage *)coverImageWithSize:(CGFloat)size {
    [self loadIndex];
    NSArray<NSString *> *bids = [self bundleIdentifiers];
    if (bids.count == 0) return nil;

    NSArray *prefer = @[@"com.apple.mobilesafari", @"com.tencent.xin", @"com.apple.MobileSMS",
                        @"com.apple.Preferences", @"com.ss.iphone.ugc.Aweme", @"com.taobao.taobao4iphone"];
    NSMutableArray *pick = [NSMutableArray array];
    for (NSString *p in prefer) {
        if ([bids containsObject:p] && pick.count < 4) [pick addObject:p];
    }
    for (NSString *b in bids) {
        if (pick.count >= 4) break;
        if (![pick containsObject:b]) [pick addObject:b];
    }

    CGFloat cell = size / 2.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        for (NSUInteger i = 0; i < pick.count && i < 4; i++) {
            UIImage *img = [self imageForBundleID:pick[i]];
            if (!img) continue;
            CGFloat x = (i % 2) * cell, y = (i / 2) * cell;
            [img drawInRect:CGRectMake(x, y, cell, cell)];
        }
    }];
}

@end
