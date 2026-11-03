#import <UIKit/UIKit.h>

/// 把任意图片重绘成 PNG，给「遮罩」用：
///   ① 有透明通道 → 原样保留（SnowBoard 遮罩的标准形态）
///   ② 完全没有透明像素（JPG、无 alpha 的 PNG）→ 用亮度当 alpha：白留、黑裁，
///      这样"黑底白形状"的图也能直接当遮罩用
NSData *TBMaskPNGDataFromImage(UIImage *src);

/// 简单重编码成 PNG（保留原样，不做亮度转换），给边框 / 阴影素材用
NSData *TBPlainPNGDataFromImage(UIImage *src);
