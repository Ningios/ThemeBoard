#import "TBDocImport.h"

static NSString *TBTempClassName(void) {
    return @"NSTemporaryDirectory";
}

UIDocumentPickerViewController *TBNewImportPicker(NSArray *contentTypes,
                                                  NSArray<NSString *> *legacyTypes) {
    UIDocumentPickerViewController *p = nil;
    @try {
        if (@available(iOS 14.0, *)) {
            // 统一走 asCopy:YES：系统把选中的文件（或整个目录）先复制进 App 的临时区，
            // iCloud 文件由系统负责下载，拿到的是可读的本地副本。
            if (contentTypes.count) {
                p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes
                                                                               asCopy:YES];
            }
        } else {
            p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:(legacyTypes ?: @[@"public.item"])
                                                                       inMode:UIDocumentPickerModeImport];
        }
        // iOS14+ 但 contentTypes 传空时兜底成 public.item
        if (!p && legacyTypes.count) {
            p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:legacyTypes
                                                                       inMode:UIDocumentPickerModeImport];
        }
    } @catch (NSException *e) {
        NSLog(@"[ThemeBoard] picker 创建失败: %@", e.reason);
        p = nil;
    }
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
    if (error.localizedDescription.length) {
        [msg appendFormat:@"（%@）", error.localizedDescription];
    }
    return msg;
}

NSData *TBReadCoordinatedData(NSURL *url, NSError **error) {
    if (!url) {
        if (error) *error = TBMakeError(@"没有选择文件", nil);
        return nil;
    }
    __block NSData *data = nil;
    __block NSError *readErr = nil;
    NSError *coordErr = nil;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSFileCoordinator *coord = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    @try {
        // ReadingForUploading：让系统把 iCloud 上的文件真正下载到本机再交给 accessor。
        // 直接用 contentsOfFile: 拿到的是占位文件（读出来是空的/失败）。
        [coord coordinateReadingItemAtURL:url
                                  options:NSFileCoordinatorReadingForUploading
                                    error:&coordErr
                               byAccessor:^(NSURL *newURL) {
            NSError *e = nil;
            data = [NSData dataWithContentsOfURL:newURL options:0 error:&e];
            if (!data.length && e) readErr = e;
        }];
    } @catch (NSException *ex) {
        readErr = TBMakeError([NSString stringWithFormat:@"读取异常：%@", ex.reason ?: ex.name], nil);
    }
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (data.length) return data;
    if (error) {
        NSError *under = readErr ?: coordErr;
        *error = TBMakeError(TBImportFailureMessage(url, under, @"读不到这个文件"),
                             under);
    }
    return nil;
}

NSURL *TBCopyCoordinatedItemToTemp(NSURL *url, NSError **error) {
    if (!url) {
        if (error) *error = TBMakeError(@"没有选择文件", nil);
        return nil;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmpRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"tb-import-%@", [NSUUID UUID].UUIDString]];
    NSError *mkErr = nil;
    if (![fm createDirectoryAtPath:tmpRoot withIntermediateDirectories:YES attributes:nil error:&mkErr]) {
        if (error) *error = TBMakeError(@"建不了临时目录", mkErr);
        return nil;
    }
    NSString *name = url.lastPathComponent.length ? url.lastPathComponent : @"import";
    NSString *dstPath = [tmpRoot stringByAppendingPathComponent:name];
    NSURL *dstURL = [NSURL fileURLWithPath:dstPath];
    [fm removeItemAtURL:dstURL error:NULL];

    __block BOOL ok = NO;
    __block NSError *copyErr = nil;
    NSError *coordErr = nil;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSFileCoordinator *coord = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    @try {
        [coord coordinateReadingItemAtURL:url
                                  options:NSFileCoordinatorReadingForUploading
                                    error:&coordErr
                               byAccessor:^(NSURL *newURL) {
            NSError *e = nil;
            // 目标一定在 App 沙盒内（NSTemporaryDirectory()），目录会递归复制
            ok = [fm copyItemAtURL:newURL toURL:dstURL error:&e];
            if (!ok && !e) {
                // 有些 provider 给的是占位 URL：退一步用数据读取（只对文件有效）
                BOOL isDir = NO;
                if ([fm fileExistsAtPath:newURL.path isDirectory:&isDir] && !isDir) {
                    NSData *d = [NSData dataWithContentsOfURL:newURL options:0 error:&e];
                    if (d.length) ok = [d writeToURL:dstURL options:NSDataWritingAtomic error:&e];
                }
            }
            if (!ok) copyErr = e;
        }];
    } @catch (NSException *ex) {
        copyErr = TBMakeError([NSString stringWithFormat:@"复制异常：%@", ex.reason ?: ex.name], nil);
    }
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (ok) return dstURL;
    [fm removeItemAtPath:tmpRoot error:NULL];
    if (error) {
        NSError *under = copyErr ?: coordErr;
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