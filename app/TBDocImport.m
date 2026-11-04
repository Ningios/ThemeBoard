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
    // ★ 0.15.57：按用户要求统一走 legacy Import 模式
    //   IPC = initWithDocumentTypes:inMode:UIDocumentPickerModeImport
    //   系统会把选中的文件/整个目录复制进 App 的 Inbox，返回普通 file:// URL，
    //   不需要 security scope —— 在越狱 / 根less 环境里这条最稳。
    //   （iOS14+ 的 initForOpeningContentTypes:asCopy:YES 在部分 iCloud provider 上会被
    //     当成 documentPickerWasCancelled；如果真机上 legacy 又出现 cancel，把下面这一行
    //     换成 asCopy 分支即可：contentTypes 只放 @[UTTypeZIP, UTTypeFolder]，不要带 UTTypeItem。）
    UIDocumentPickerViewController *p = nil;
    NSString *mode = @"(未创建)";
    @try {
        p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:(legacyTypes ?: @[@"public.item"])
                                                                   inMode:UIDocumentPickerModeImport];
        mode = @"initWithDocumentTypes:UIDocumentPickerModeImport(legacy)";
    } @catch (NSException *e) {
        TBLog2(@"[导入][picker] ❌ 创建异常：%@ — %@", e.name, e.reason);
        NSLog(@"[ThemeBoard] picker 创建失败: %@", e.reason);
        p = nil;
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
        // ReadingForUploading：让系统把 iCloud 上的文件真正下载到本机再交给 accessor。
        // 直接用 contentsOfFile: 拿到的是占位文件（读出来是空的/失败）。
        [coord coordinateReadingItemAtURL:url
                                  options:NSFileCoordinatorReadingForUploading
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
                                  options:NSFileCoordinatorReadingForUploading
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
                TBLog2(@"[导入][复制] ✅ 成功 字节数=%lu 目录=%d",
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
