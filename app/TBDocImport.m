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

NSString *TBImportFailureMessage(NSURL *url, NSError *error, NSString *fallback) {
    NSMutableString *msg = [NSMutableString string];
    if (TBURLIsICloud(url)) {
        [msg appendString:@"iCloud 文件下载失败，请先在「文件」App 里把这个文件/文件夹下载到本机"
                        @"（长按 → 下载），再重新导入。\n\n"];
    } else {
        [msg appendString:fallback.length ? fallback : @"读取失败。\n\n"];
    }
    if (TBIsICloudPlaceholder(url)) {
        [msg appendString:@"（这是一个 iCloud 占位文件 .icloud，本机还没有实际内容。）\n"];
    }
    if (error.localizedDescription.length) {
        [msg appendFormat:@"（%@）", error.localizedDescription];
    }
    if (error.domain.length) {
        [msg appendFormat:@"\n错误码：%@ %ld", error.domain, (long)error.code];
    }
    NSError *under = error.userInfo[NSUnderlyingErrorKey];
    if (under.localizedDescription.length) {
        [msg appendFormat:@"\n底层原因：%@（%@ %ld）", under.localizedDescription,
             under.domain, (long)under.code];
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
    BOOL cloud = TBURLIsICloud(url);
    BOOL placeholder = TBIsICloudPlaceholder(url);
    BOOL exists = [fm fileExistsAtPath:url.path];
    TBLog2(@"[导入][读] 开始 url=%@ iCloud=%d 占位(.icloud)=%d 本地存在=%d",
           url.absoluteString ?: @"(nil)", cloud, placeholder, exists);
    if (placeholder) {
        TBLog2(@"[导入][读] ⚠️ 这是 iCloud 未下载的占位文件，需要系统先下载（NSFileCoordinator）");
    }

    __block NSData *data = nil;
    __block NSError *readErr = nil;
    NSError *coordErr = nil;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    TBLog2(@"[导入][读] startAccessingSecurityScopedResource=%d", scoped);
    NSFileCoordinator *coord = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    @try {
        // ★ 0.15.59：改成 ReadingWithoutChanges（= 0）。MarkFont-Ning 用这个选项能在
        //   同一台机器、同样的 ldid 签名、没有任何 iCloud entitlement 的情况下从 iCloud
        //   云盘读文件；ReadingForUploading 会要求 provider 走“上传”语义，rootless 下
        //   没有对应权限 → 正是 257 / EPERM 的来源。
        [coord coordinateReadingItemAtURL:url
                                  options:NSFileCoordinatorReadingWithoutChanges
                                    error:&coordErr
                               byAccessor:^(NSURL *newURL) {
            TBLog2(@"[导入][读] accessor url=%@ 本地存在=%d",
                   newURL.path ?: @"(nil)", [fm fileExistsAtPath:newURL.path]);
            // 0.15.53：ReadingForUploading 后系统给的应是本地临时副本；若还是没有，
            // 说明文件仍在云端没下载下来 —— 直接给用户明确指引，不要傻读。
            if (![fm fileExistsAtPath:newURL.path]) {
                TBLog2(@"[导入][读] ❌ accessor 给的副本不存在 → 文件还在云端未下载");
                readErr = TBMakeError(@"文件还在 iCloud 云端没有下载到本机，"
                                      @"请先在「文件」App 里长按它 → 下载，再回来重新导入", nil);
                return;
            }
            NSError *e = nil;
            data = [NSData dataWithContentsOfURL:newURL options:0 error:&e];
            TBLog2(@"[导入][读] 读出 %lu 字节 %@",
                   (unsigned long)data.length, e.localizedDescription ?: @"");
            if (!data.length && e) readErr = e;
        }];
    } @catch (NSException *ex) {
        TBLog2(@"[导入][读] ❌ 协调读取异常：%@ — %@", ex.name, ex.reason);
        readErr = TBMakeError([NSString stringWithFormat:@"读取异常：%@", ex.reason ?: ex.name], nil);
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
    BOOL cloud = TBURLIsICloud(url);
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
    NSString *dstPath = [tmpRoot stringByAppendingPathComponent:name];
    NSURL *dstURL = [NSURL fileURLWithPath:dstPath];
    [fm removeItemAtURL:dstURL error:NULL];
    TBLog2(@"[导入][复制] 开始 url=%@ iCloud=%d 占位=%@ → 临时 %@",
           url.absoluteString ?: @"(nil)", cloud, placeholder ? @"是" : @"否", dstPath);

    __block BOOL ok = NO;
    __block NSError *copyErr = nil;
    NSError *coordErr = nil;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    TBLog2(@"[导入][复制] startAccessingSecurityScopedResource=%d", scoped);
    NSFileCoordinator *coord = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    @try {
        [coord coordinateReadingItemAtURL:url
                                  options:NSFileCoordinatorReadingWithoutChanges
                                    error:&coordErr
                               byAccessor:^(NSURL *newURL) {
            NSError *e = nil;
            BOOL isDirNow = NO;
            BOOL there = [fm fileExistsAtPath:newURL.path isDirectory:&isDirNow];
            TBLog2(@"[导入][复制] accessor url=%@ 存在=%d 目录=%d", newURL.path ?: @"(nil)", there, isDirNow);
            // 0.15.53：asCopy/ReadingForUploading 之后系统给的已经是本地临时副本，
            // 上面 TBURLIsICloud/占位判断只做【日志】，不再做 iCloud 特判或二次下载 ——
            // 对系统给的副本再走 iCloud 分支是画蛇添足，还可能把好端端的副本读成空。
            if (!there) {
                TBLog2(@"[导入][复制] ❌ accessor 给的副本不存在 → 文件还在云端未下载");
                copyErr = TBMakeError(@"文件还在 iCloud 云端没有下载到本机，"
                                      @"请先在「文件」App 里长按它 → 下载，再回来重新导入", nil);
                return;
            }
            // 目标一定在 App 沙盒内（NSTemporaryDirectory()），目录会递归复制
            ok = [fm copyItemAtURL:newURL toURL:dstURL error:&e];
            TBLog2(@"[导入][复制] copyItemAtURL=%d 失败原因=%@", ok, e.localizedDescription ?: @"-");
            if (!ok && !e) {
                // 有些 provider 给的是占位 URL：退一步用数据读取（只对文件有效）
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:newURL.path isDirectory:&isDir] && !isDir) {
                    NSData *d = [NSData dataWithContentsOfURL:newURL options:0 error:&e];
                    TBLog2(@"[导入][复制] 兜底直读 %lu 字节", (unsigned long)d.length);
                    if (d.length) ok = [d writeToURL:dstURL options:NSDataWritingAtomic error:&e];
                }
            }
            if (!ok) copyErr = e;
            if (ok) {
                NSDictionary *at = [fm attributesOfItemAtPath:dstPath error:NULL];
                if (!isDirNow) {
                    // 照 MarkFont：复制后把权限收紧到 0600，并校验字节数与源一致
                    [fm setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:dstPath error:NULL];
                    NSDictionary *srcAt = [fm attributesOfItemAtPath:newURL.path error:NULL];
                    unsigned long long srcSize = [srcAt fileSize];
                    unsigned long long dstSize = [at fileSize];
                    TBLog2(@"[导入][复制] 字节校验 源=%llu 副本=%llu", srcSize, dstSize);
                    if (srcSize != dstSize) {
                        ok = NO;
                        copyErr = [NSError errorWithDomain:@"ThemeBoard.Import" code:9 userInfo:@{
                            NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:@"复制后大小不一致（源 %llu / 副本 %llu）",
                                 srcSize, dstSize]}];
                        TBLog2(@"[导入][复制] ❌ 大小不一致，判定失败：%@", TBErrText(copyErr));
                    }
                }
                if (ok) TBLog2(@"[导入][复制] ✅ 成功 字节数=%lu 目录=%d 权限=0600",
                               (unsigned long)[at fileSize], isDirNow);
            }
        }];
    } @catch (NSException *ex) {
        TBLog2(@"[导入][复制] ❌ 协调复制异常：%@ — %@", ex.name, ex.reason);
        copyErr = TBMakeError([NSString stringWithFormat:@"复制异常：%@", ex.reason ?: ex.name], nil);
    }
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (ok) {
        TBLog2(@"[导入][复制] ✅ 成功 → %@", dstPath);
        return dstURL;
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
