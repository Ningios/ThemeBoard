#import "TBDocImport.h"
#if __has_include(<UniformTypeIdentifiers/UniformTypeIdentifiers.h>)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#define TB_HAS_UTTYPE 1
#endif

/// 打印类型数组里的 identifier（UTType → 它的 identifier，其余原样 description）
static NSString *TBPickerTypeNames(NSArray *types) {
    if (!types.count) return @"(空)";
    NSMutableArray<NSString *> *n = [NSMutableArray array];
    for (id t in types) {
#ifdef TB_HAS_UTTYPE
        if ([t isKindOfClass:[UTType class]]) {
            NSString *i = [(UTType *)t identifier];
            [n addObject:i.length ? i : @"?"];
            continue;
        }
#endif
        [n addObject:[t description] ?: @"?"];
    }
    return [n componentsJoinedByString:@","];
}

/// iCloud 占位文件（未下载）在本地就是个 ".xxx.icloud" 小文件
static BOOL TBIsICloudPlaceholder(NSURL *url) {
    NSString *leaf = url.lastPathComponent.lowercaseString ?: @"";
    return [leaf hasSuffix:@".icloud"];
}

static NSString *TBErrText(NSError *e) {
    if (!e) return @"(无)";
    return [NSString stringWithFormat:@"%@(%ld) %@", e.domain, (long)e.code,
            e.localizedDescription ?: @""];
}

UIDocumentPickerViewController *TBNewImportPicker(NSArray *contentTypes,
                                                  NSArray<NSString *> *legacyTypes) {
    // ★ 0.15.59：照 MarkFont-Ning（同账号、能正常从 iCloud 云盘导入）的做法：
    //   · iOS14+：initForOpeningContentTypes:asCopy:NO，**只用具体类型**
    //     （UTTypeZIP / UTTypeFolder / 图片），绝不带 UTTypeItem —— 带 Item 时系统
    //     会把 iCloud 上不匹配的条目置灰或走 provider 的“导入”语义，进而被当成取消。
    //   · 老系统：initWithDocumentTypes:inMode:UIDocumentPickerModeImport，同样只给具体 UTI。
    //   asCopy:NO = open in place，拿到的就是原文件 URL（配 security scope 读取），
    //   不会触发系统“复制进 Inbox”那一步（那一步在 rootless 下会报 257 无权限）。
    UIDocumentPickerViewController *p = nil;
    NSString *mode = @"(未创建)";
#ifdef TB_HAS_UTTYPE
    if (@available(iOS 14.0, *)) {
        NSMutableArray *types = [NSMutableArray array];
        for (id t in contentTypes) {
            if ([t isKindOfClass:[UTType class]]) [types addObject:t];
        }
        if (!types.count) types = [@[ UTTypeZIP ] mutableCopy];
        @try {
            p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
            mode = @"initForOpeningContentTypes:asCopy:NO";
        } @catch (NSException *e) {
            TBLog2(@"[导入][picker] ❌ iOS14 分支创建异常：%@ — %@", e.name, e.reason);
            p = nil;
        }
    }
#endif
    if (!p) {
        @try {
            p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:(legacyTypes ?: @[@"public.zip-archive"])
                                                                       inMode:UIDocumentPickerModeImport];
            mode = @"initWithDocumentTypes:UIDocumentPickerModeImport(legacy)";
        } @catch (NSException *e) {
            TBLog2(@"[导入][picker] ❌ 创建异常：%@ — %@", e.name, e.reason);
            NSLog(@"[ThemeBoard] picker 创建失败: %@", e.reason);
            p = nil;
        }
    }
    TBLog2(@"[导入][picker] 模式=%@ contentTypes(iOS14 不用)=[%@] legacyTypes=[%@] → %@",
           mode, TBPickerTypeNames(contentTypes),
           legacyTypes.count ? [legacyTypes componentsJoinedByString:@","] : @"(空)",
           p ? @"创建成功" : @"创建失败(返回 nil)");
    return p;
}

BOOL TBURLIsICloud(NSURL *url) {
    if (!url) return NO;
    NSString *p = url.path;
    if (!p.length) p = url.absoluteString;
    if (!p.length) return NO;
    if ([p rangeOfString:@"Mobile Documents"].location != NSNotFound) return YES;
    if ([p rangeOfString:@"com~apple~CloudDocs"].location != NSNotFound) return YES;
    if ([p rangeOfString:@"/.fileprovider/"].location != NSNotFound) return YES;
    // 占位文件：iCloud 未下载时是 ".xxx.icloud"
    if ([[p lastPathComponent] hasSuffix:@".icloud"]) return YES;
    return NO;
}

static NSError *TBMakeError(NSString *desc, NSError *underlying) {
    NSMutableDictionary *ui = [NSMutableDictionary dictionary];
    ui[NSLocalizedDescriptionKey] = desc ?: @"导入失败";
    if (underlying) {
        ui[NSUnderlyingErrorKey] = underlying;
        ui[NSLocalizedFailureReasonErrorKey] = underlying.localizedDescription ?: @"";
    }
    return [NSError errorWithDomain:@"ThemeBoard.Import" code:1 userInfo:ui];
}

#pragma mark - iCloud 兜底（0.15.63）

/// 触发 iCloud 下载并在有界时间内等它落地。
/// 只用于「coordinator 拿不到本地文件」时的兜底，不弹任何文案、不做任何前置拒绝，
/// 成败一律交给后续真正的复制/读取去判定。
static BOOL TBWaitForICloudDownload(NSURL *url, NSTimeInterval timeout) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:url.path]) return YES;
    NSError *e = nil;
    BOOL started = NO;
    @try {
        started = [fm startDownloadingUbiquitousItemAtURL:url error:&e];
    } @catch (NSException *ex) {
        TBLog2(@"[导入][下载] startDownloadingUbiquitousItem 抛异常：%@ — %@", ex.name, ex.reason);
    }
    TBLog2(@"[导入][下载] startDownloadingUbiquitousItem=%d err=%@", started, TBErrText(e));
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSInteger spins = 0;
    while ([deadline timeIntervalSinceNow] > 0.0) {
        if ([fm fileExistsAtPath:url.path]) {
            TBLog2(@"[导入][下载] ✅ 已落地（等了 %.2fs）",
                   timeout - [deadline timeIntervalSinceNow]);
            return YES;
        }
        // 轮询期间跑一下 runloop，让 provider / 下载任务有机会推进
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        spins++;
    }
    BOOL there = [fm fileExistsAtPath:url.path];
    TBLog2(@"[导入][下载] ⏱ 等待 %.1fs 结束（轮询 %ld 次）本地存在=%d",
           timeout, (long)spins, there);
    return there;
}

static NSInteger TBRawCopyDirectory(NSURL *src, NSURL *dst, NSError **firstErr);

/// 绕过 NSFileCoordinator，按字节把源读出来写到目标（文件/目录都支持）。
/// 部分 rootless 环境里 coordinator 会报 257 / EPERM，这条兜底能绕过去。
static BOOL TBRawCopyItem(NSURL *src, NSURL *dst, NSError **err) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:src.path isDirectory:&isDir]) {
        if (err) *err = [NSError errorWithDomain:@"ThemeBoard.Import" code:11 userInfo:@{
            NSLocalizedDescriptionKey: @"源文件不在本机（等下载之后再读）",
            NSFilePathErrorKey: src.path ?: @""}];
        return NO;
    }
    if (isDir) return TBRawCopyDirectory(src, dst, err) >= 0;

    NSError *e = nil;
    NSData *d = [NSData dataWithContentsOfURL:src options:0 error:&e];
    if (!d.length) {
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:src.path];
        if (fh) { d = [fh readDataToEndOfFile]; [fh closeFile]; }
        TBLog2(@"[导入][直读] dataWithContentsOfURL(%@) → NSFileHandle 读到 %lu 字节",
               TBErrText(e), (unsigned long)d.length);
    }
    if (!d.length) {
        if (err) *err = e ?: [NSError errorWithDomain:@"ThemeBoard.Import" code:12 userInfo:@{
            NSLocalizedDescriptionKey: @"直读源文件只拿到 0 字节"}];
        return NO;
    }
    NSError *wErr = nil;
    if (![d writeToURL:dst options:NSDataWritingAtomic error:&wErr]) {
        if (err) *err = wErr;
        return NO;
    }
    [fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:dst.path error:NULL];
    TBLog2(@"[导入][直读] ✅ %lu 字节 → %@", (unsigned long)d.length, dst.lastPathComponent ?: @"?");
    return YES;
}

static NSInteger TBRawCopyDirectory(NSURL *src, NSURL *dst, NSError **firstErr) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *e = nil;
    if (![fm createDirectoryAtURL:dst withIntermediateDirectories:YES attributes:nil error:&e]) {
        if (firstErr) *firstErr = e;
        return -1;
    }
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:src.path error:&e];
    if (!items) {
        TBLog2(@"[导入][直读] 列目录失败 %@：%@", src.path ?: @"?", TBErrText(e));
        if (firstErr) *firstErr = e;
        return -1;
    }
    NSInteger okCount = 0;
    for (NSString *name in items) {
        NSURL *s = [src URLByAppendingPathComponent:name];
        NSURL *d = [dst URLByAppendingPathComponent:name];
        NSError *subErr = nil;
        if (TBRawCopyItem(s, d, &subErr)) okCount++;
        else {
            TBLog2(@"[导入][直读] 跳过 %@：%@", name, TBErrText(subErr));
            if (firstErr && !*firstErr) *firstErr = subErr;
        }
    }
    TBLog2(@"[导入][直读] 目录 %@：复制成功 %ld / 共 %lu 项",
           src.lastPathComponent ?: @"?", (long)okCount, (unsigned long)items.count);
    return okCount;
}

NSString *TBImportFailureMessage(NSURL *url, NSError *error, NSString *fallback) {
    // 0.15.63：只报真实错误（domain + code + 描述），不再自己编「请先去下载」这类前置文案
    NSMutableString *msg = [NSMutableString string];
    [msg appendString:fallback.length ? fallback : @"读取失败。"];
    if (error.localizedDescription.length) {
        [msg appendFormat:@"\n\n%@", error.localizedDescription];
    }
    if (error.domain.length) {
        [msg appendFormat:@"\n错误码：%@ %ld", error.domain, (long)error.code];
    }
    NSError *under = error.userInfo[NSUnderlyingErrorKey];
    if (under.localizedDescription.length) {
        [msg appendFormat:@"\n底层原因：%@（%@ %ld）", under.localizedDescription,
             under.domain, (long)under.code];
    }
    if (url.lastPathComponent.length) {
        [msg appendFormat:@"\n文件：%@", url.lastPathComponent];
    }
    return msg;
}

NSData *TBReadCoordinatedData(NSURL *url, NSError **error) {
    if (!url) {
        TBLog2(@"[导入][读] ❌ 没有选择文件（url=nil）");
        if (error) *error = TBMakeError(@"没有选择文件", nil);
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL placeholder = TBIsICloudPlaceholder(url);
    TBLog2(@"[导入][读] 开始 url=%@ iCloud=%d 占位(.icloud)=%d 本地存在=%d",
           url.absoluteString ?: @"(nil)", TBURLIsICloud(url), placeholder,
           [fm fileExistsAtPath:url.path]);

    __block NSData *data = nil;
    __block NSError *readErr = nil;
    NSError *coordErr = nil;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    TBLog2(@"[导入][读] startAccessingSecurityScopedResource=%d", scoped);
    NSFileCoordinator *coord = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    @try {
        // MarkFont 的可工作选项：ReadingWithoutChanges（= 0）
        [coord coordinateReadingItemAtURL:url
                                  options:NSFileCoordinatorReadingWithoutChanges
                                    error:&coordErr
                               byAccessor:^(NSURL *newURL) {
            BOOL there = [fm fileExistsAtPath:newURL.path];
            TBLog2(@"[导入][读] accessor url=%@ 本地存在=%d", newURL.path ?: @"(nil)", there);
            // ★ 0.15.63：这里不再因为「文件不在本机」就报错返回（iCloud 未下载时就是如此），
            //   交给下面的直读 / 等下载 兜底。
            if (!there) return;
            NSError *e = nil;
            data = [NSData dataWithContentsOfURL:newURL options:0 error:&e];
            TBLog2(@"[导入][读] 读出 %lu 字节 %@", (unsigned long)data.length, TBErrText(e));
            if (!data.length && e) readErr = e;
        }];
    } @catch (NSException *ex) {
        TBLog2(@"[导入][读] ❌ 协调读取异常：%@ — %@", ex.name, ex.reason);
        readErr = TBMakeError([NSString stringWithFormat:@"读取异常：%@", ex.reason ?: ex.name], nil);
    }

    // 兜底 1：绕过 coordinator 直接读原始 URL（rootless 下经常能成）
    if (!data.length) {
        NSError *e = nil;
        data = [NSData dataWithContentsOfURL:url options:0 error:&e];
        if (data.length) {
            TBLog2(@"[导入][读] 兜底直读 ✅ %lu 字节", (unsigned long)data.length);
        } else {
            TBLog2(@"[导入][读] 兜底直读失败：%@", TBErrText(e));
            if (!readErr) readErr = e;
        }
    }
    // 兜底 2：iCloud 未下载 → 触发下载 + 有界等待 → 再读一次
    if (!data.length && ![fm fileExistsAtPath:url.path]) {
        if (TBWaitForICloudDownload(url, 2.5)) {
            NSError *e = nil;
            data = [NSData dataWithContentsOfURL:url options:0 error:&e];
            TBLog2(@"[导入][读] 等下载后直读 %lu 字节 %@",
                   (unsigned long)data.length, TBErrText(e));
            if (!data.length && !readErr) readErr = e;
        }
    }
    // 兜底 3：NSFileHandle 原始读
    if (!data.length && [fm fileExistsAtPath:url.path]) {
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:url.path];
        if (fh) { data = [fh readDataToEndOfFile]; [fh closeFile]; }
        TBLog2(@"[导入][读] NSFileHandle 兜底 %lu 字节", (unsigned long)data.length);
    }
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (data.length) {
        TBLog2(@"[导入][读] ✅ 成功 %lu 字节 ← %@", (unsigned long)data.length, url.lastPathComponent);
        return data;
    }
    NSError *under = readErr ?: coordErr;
    TBLog2(@"[导入][读] ❌ 失败 %@ → coordinator=%@ 读取=%@ 占位=%d",
           url.lastPathComponent ?: @"?", TBErrText(coordErr), TBErrText(readErr), placeholder);
    if (error) {
        *error = TBMakeError(TBImportFailureMessage(url, under, @"读不到这个文件"), under);
    }
    return nil;
}

NSURL *TBCopyCoordinatedItemToTemp(NSURL *url, NSError **error) {
    if (!url) {
        TBLog2(@"[导入][复制] ❌ 没有选择文件（url=nil）");
        if (error) *error = TBMakeError(@"没有选择文件", nil);
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL placeholder = TBIsICloudPlaceholder(url);
    NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"tb-import-%@", [NSUUID UUID].UUIDString]];
    NSError *mkErr = nil;
    if (![fm createDirectoryAtPath:tmpRoot withIntermediateDirectories:YES attributes:nil error:&mkErr]) {
        TBLog2(@"[导入][复制] ❌ 建不了临时目录 %@：%@", tmpRoot, TBErrText(mkErr));
        if (error) *error = TBMakeError(@"建不了临时目录", mkErr);
        return nil;
    }
    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"import";
    if (placeholder) {
        // ".xxx.zip.icloud" → "xxx.zip"
        if ([name hasPrefix:@"."]) name = [name substringFromIndex:1];
        if ([name.lowercaseString hasSuffix:@".icloud"]) {
            name = [name substringToIndex:name.length - @".icloud".length];
        }
        if (!name.length) name = @"import";
    }
    NSString *dstPath = [tmpRoot stringByAppendingPathComponent:name];
    NSURL *dstURL = [NSURL fileURLWithPath:dstPath];
    [fm removeItemAtURL:dstURL error:NULL];
    TBLog2(@"[导入][复制] 开始 url=%@ iCloud=%d 占位=%@ → 临时 %@",
           url.absoluteString ?: @"(nil)", TBURLIsICloud(url),
           placeholder ? @"是" : @"否", dstPath);

    __block BOOL ok = NO;
    __block NSError *copyErr = nil;
    __block NSURL *srcUsed = nil;          // 真正复制成功的源（用于字节校验）
    NSError *coordErr = nil;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    TBLog2(@"[导入][复制] startAccessingSecurityScopedResource=%d", scoped);
    NSFileCoordinator *coord = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    @try {
        [coord coordinateReadingItemAtURL:url
                                  options:NSFileCoordinatorReadingWithoutChanges
                                    error:&coordErr
                               byAccessor:^(NSURL *newURL) {
            BOOL isDirNow = NO;
            BOOL there = [fm fileExistsAtPath:newURL.path isDirectory:&isDirNow];
            TBLog2(@"[导入][复制] accessor url=%@ 存在=%d 目录=%d",
                   newURL.path ?: @"(nil)", there, isDirNow);
            // ★ 0.15.63：核心修复 —— 这里【不再】因为「副本不在本机」就报
            //   「文件还在 iCloud 云端没有下载到本机…」并 return。MarkFont 之所以能导
            //   iCloud 文件，就是因为它不做这个前置拒绝，交给系统在复制时下载。
            if (!there) {
                TBLog2(@"[导入][复制] accessor 没给到本地文件 → 交给直读/等下载兜底");
                return;
            }
            NSError *e = nil;
            srcUsed = newURL;
            [fm removeItemAtURL:dstURL error:NULL];   // 清掉上一次失败留下的半成品
            ok = [fm copyItemAtURL:newURL toURL:dstURL error:&e];
            TBLog2(@"[导入][复制] copyItemAtURL=%d 失败原因=%@", ok, TBErrText(e));
            if (!ok && !isDirNow) {
                // 有些 provider 给的是占位 URL：退一步按字节读
                NSData *d = [NSData dataWithContentsOfURL:newURL options:0 error:&e];
                TBLog2(@"[导入][复制] 退一步直读 %lu 字节", (unsigned long)d.length);
                if (d.length) ok = [d writeToURL:dstURL options:NSDataWritingAtomic error:&e];
            }
            if (!ok) copyErr = e;
        }];
    } @catch (NSException *ex) {
        TBLog2(@"[导入][复制] ❌ 协调复制异常：%@ — %@", ex.name, ex.reason);
        copyErr = TBMakeError([NSString stringWithFormat:@"复制异常：%@", ex.reason ?: ex.name], nil);
    }

    // 兜底 1：coordinator 没给出可用源 / 复制失败 → 直接用原始 URL 复制
    if (!ok && [fm fileExistsAtPath:url.path]) {
        NSError *e = nil;
        [fm removeItemAtURL:dstURL error:NULL];
        ok = [fm copyItemAtURL:url toURL:dstURL error:&e];
        TBLog2(@"[导入][复制] 兜底1 原始 URL 复制=%d 失败原因=%@", ok, TBErrText(e));
        if (ok) srcUsed = url;
        else if (!copyErr) copyErr = e;
    }
    // 兜底 2：原始 URL 不在本机（iCloud 未下载）→ 触发下载 + 有界等待 → 再复制
    if (!ok && ![fm fileExistsAtPath:url.path]) {
        if (TBWaitForICloudDownload(url, 3.0)) {
            NSError *e = nil;
            [fm removeItemAtURL:dstURL error:NULL];
            ok = [fm copyItemAtURL:url toURL:dstURL error:&e];
            TBLog2(@"[导入][复制] 兜底2 下载后复制=%d 失败原因=%@", ok, TBErrText(e));
            if (ok) srcUsed = url;
            else if (!copyErr) copyErr = e;
        }
    }
    // 兜底 3：完全绕过 coordinator，按字节读原始 URL 再写临时文件（rootless 257/EPERM 的解）
    if (!ok) {
        NSError *e = nil;
        ok = TBRawCopyItem(url, dstURL, &e);
        TBLog2(@"[导入][复制] 兜底3 直读=%d 原因=%@", ok, TBErrText(e));
        if (ok) srcUsed = url;
        else if (!copyErr) copyErr = e;
    }
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (ok) {
        // 复制后收紧权限 + 字节校验（目录跳过校验）
        BOOL dstIsDir = NO;
        BOOL dstThere = [fm fileExistsAtPath:dstPath isDirectory:&dstIsDir];
        if (!dstThere) {
            ok = NO;
            copyErr = [NSError errorWithDomain:@"ThemeBoard.Import" code:13 userInfo:@{
                NSLocalizedDescriptionKey: @"复制完成后临时副本不存在"}];
        } else if (!dstIsDir) {
            [fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:dstPath error:NULL];
            NSDictionary *at = [fm attributesOfItemAtPath:dstPath error:NULL];
            NSDictionary *srcAt = srcUsed ? [fm attributesOfItemAtPath:srcUsed.path error:NULL] : nil;
            unsigned long long srcSize = [srcAt fileSize];
            unsigned long long dstSize = [at fileSize];
            TBLog2(@"[导入][复制] 字节校验 源=%llu 副本=%llu", srcSize, dstSize);
            // 源大小取不到（provider 不给属性）时只打日志，不误判失败
            if (srcSize > 0 && srcSize != dstSize) {
                ok = NO;
                copyErr = [NSError errorWithDomain:@"ThemeBoard.Import" code:9 userInfo:@{
                    NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"复制后大小不一致（源 %llu / 副本 %llu）",
                         srcSize, dstSize]}];
                TBLog2(@"[导入][复制] ❌ 大小不一致：%@", TBErrText(copyErr));
            }
        }
        if (ok) {
            TBLog2(@"[导入][复制] ✅ 成功 → %@（目录=%d）", dstPath, dstIsDir);
            return dstURL;
        }
    }

    [fm removeItemAtPath:tmpRoot error:NULL];
    NSError *under = copyErr ?: coordErr;
    TBLog2(@"[导入][复制] ❌ 失败 %@ → coordinator=%@ 复制=%@ 占位=%d",
           url.lastPathComponent ?: @"?", TBErrText(coordErr), TBErrText(copyErr), placeholder);
    TBLog2(@"[导入][复制] 失败详情 domain=%@ code=%ld desc=%@ userInfo=%@",
           under.domain ?: @"-", (long)under.code, under.localizedDescription ?: @"-",
           under.userInfo ?: @{});
    if (error) {
        *error = TBMakeError(TBImportFailureMessage(url, under, @"复制到 App 临时目录失败"), under);
    }
    return nil;
}

void TBRemoveTempCopy(NSURL *tempURL) {
    if (!tempURL) return;
    // 只清理我们自己造的 tb-import-* 目录，避免误删
    NSString *parent = tempURL.URLByDeletingLastPathComponent.path;
    NSString *tmp = [NSTemporaryDirectory() stringByStandardizingPath];
    if (!parent.length) return;
    if (![parent hasPrefix:tmp]) return;
    if (![[parent lastPathComponent] hasPrefix:@"tb-import-"]) return;
    [[NSFileManager defaultManager] removeItemAtPath:parent error:NULL];
}
UIViewController *TBTopPresentingViewController(UIViewController *from) {
    UIViewController *vc = from;
    NSInteger guard = 0;
    while (vc.presentedViewController && guard++ < 16) {
        UIViewController *next = vc.presentedViewController;
        // 正在被 dismiss 的中间态不要跟进去（会拿到一个马上要消失的 VC）
        if (next.isBeingDismissed) break;
        vc = next;
    }
    // 兜底：如果这条链上没有任何 VC 真的挂在窗口里（例如从被移出层级的抽屉里 present），
    // 改用窗口的 rootViewController —— 那才是唯一保证能正常弹 picker 且回调能回来的对象。
    if (!vc.view.window) {
        UIWindow *w = from.view.window;
        if (!w) {
            for (UIWindow *cand in [UIApplication sharedApplication].windows) {
                if (cand.isKeyWindow) { w = cand; break; }
            }
        }
        UIViewController *root = w.rootViewController;
        if (root && root != vc) {
            UIViewController *top = root;
            NSInteger g2 = 0;
            while (top.presentedViewController && g2++ < 16 &&
                   !top.presentedViewController.isBeingDismissed) {
                top = top.presentedViewController;
            }
            return top;
        }
    }
    return vc ?: from;
}
