#import "TBImageUtil.h"

/// 统一的位图上下文：RGBA8（预乘），尺寸限制在 1024 以内（遮罩不需要大图）
static CGContextRef TBCreateBitmap(CGImageRef cg, size_t *outW, size_t *outH, uint8_t **outBuf) {
    if (!cg) return NULL;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 1 || h < 1) return NULL;

    const size_t kMax = 1024;
    if (w > kMax || h > kMax) {
        CGFloat s = MIN((CGFloat)kMax / (CGFloat)w, (CGFloat)kMax / (CGFloat)h);
        w = MAX((size_t)1, (size_t)lround((double)w * s));
        h = MAX((size_t)1, (size_t)lround((double)h * s));
    }

    size_t bytes = w * h * 4;
    uint8_t *buf = (uint8_t *)calloc(bytes, 1);
    if (!buf) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NULL; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), cg);
    *outW = w; *outH = h; *outBuf = buf;
    return ctx;
}

NSData *TBMaskPNGDataFromImage(UIImage *src) {
    if (!src) return nil;
    size_t w = 0, h = 0;
    uint8_t *buf = NULL;
    CGContextRef ctx = TBCreateBitmap(src.CGImage, &w, &h, &buf);
    if (!ctx) return nil;

    size_t bytes = w * h * 4;
    BOOL anyTransparent = NO;
    for (size_t i = 0; i < bytes; i += 4) {
        if (buf[i + 3] < 250) { anyTransparent = YES; break; }
    }
    if (!anyTransparent) {
        // 完全没有透明像素 → 用亮度当 alpha（黑底白形状的图也能直接当遮罩）
        for (size_t i = 0; i < bytes; i += 4) {
            double lum = 0.299 * buf[i] + 0.587 * buf[i + 1] + 0.114 * buf[i + 2];
            NSInteger a = (NSInteger)lround(lum);
            if (a < 0) a = 0;
            if (a > 255) a = 255;
            buf[i + 3] = (uint8_t)a;
        }
    }

    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!out) { free(buf); return nil; }
    UIImage *img = [UIImage imageWithCGImage:out];
    CGImageRelease(out);
    free(buf);
    return UIImagePNGRepresentation(img);
}

NSData *TBPlainPNGDataFromImage(UIImage *src) {
    if (!src) return nil;
    size_t w = 0, h = 0;
    uint8_t *buf = NULL;
    CGContextRef ctx = TBCreateBitmap(src.CGImage, &w, &h, &buf);
    if (!ctx) return UIImagePNGRepresentation(src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    if (!out) return UIImagePNGRepresentation(src);
    UIImage *img = [UIImage imageWithCGImage:out];
    CGImageRelease(out);
    return UIImagePNGRepresentation(img);
}
