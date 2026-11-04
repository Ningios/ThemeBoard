#import "TBPanelController.h"
#import "TBThemeDetailController.h"
#import "TBAppInfo.h"
#import "TBThemeScanner.h"
#import "TBPrefs.h"
#import "TBMissingController.h"
#import "TBGlass.h"
#import "TBToast.h"

#pragma mark - 遮罩偏好键（与引擎 / 抽屉完全一致）

static NSString *const kTBKeyUseThemeIconMask   = @"UseThemeIconMask";
static NSString *const kTBKeyMaskCornerRadiusOn = @"MaskCornerRadiusOn";
static NSString *const kTBKeyMaskCornerRadius   = @"MaskCornerRadius";
static NSString *const kTBKeyUseThemeIconOverlay = @"UseThemeIconOverlay";
static NSString *const kTBKeyUseThemeIconShadow  = @"UseThemeIconShadow";
static const double  kTBDefaultMaskCornerRadius = 13.42;

static const CGFloat kTBCardRadius   = 20.0;   // 与 TBGlassCard(20) / 列表卡片一致
static const CGFloat kTBCardGap      = 12.0;   // 卡片间距
static const CGFloat kTBSideInset    = 16.0;   // 左右内缩

#pragma mark - 方形卡片 cell（双列网格的通用卡片）

@interface TBSquareCardCell : UICollectionViewCell
@property (nonatomic, assign) BOOL compact;          // 四功能小卡
@property (nonatomic, strong) NSArray *compactCons;
@property (nonatomic, strong) NSArray *gridCons;
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *captionLabel;
@end

@implementation TBSquareCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _card = TBGlassCard(kTBCardRadius);
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_card];
        [NSLayoutConstraint activateConstraints:@[
            [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_card addSubview:_titleLabel];

        _icon = [[UIImageView alloc] init];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.clipsToBounds = NO;
        [_card addSubview:_icon];

        _captionLabel = [[UILabel alloc] init];
        _captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _captionLabel.font = [UIFont systemFontOfSize:11];
        _captionLabel.textColor = [UIColor secondaryLabelColor];
        _captionLabel.textAlignment = NSTextAlignmentCenter;
        _captionLabel.numberOfLines = 3;
        _captionLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_card addSubview:_captionLabel];

        NSLayoutConstraint *titleL = [_titleLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:8];
        NSLayoutConstraint *titleR = [_titleLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-8];
        NSLayoutConstraint *capL = [_captionLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:8];
        NSLayoutConstraint *capR = [_captionLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-8];
        NSLayoutConstraint *iconX = [_icon.centerXAnchor constraintEqualToAnchor:_card.centerXAnchor];

        // 图标卡：卡片只比图标大一点点（上标题 / 中图标 / 下名字，紧凑竖排）
        _gridCons = @[
            [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:6],
            iconX,
            [_icon.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],
            [_icon.widthAnchor constraintEqualToAnchor:_card.widthAnchor multiplier:0.80],
            [_icon.heightAnchor constraintEqualToAnchor:_icon.widthAnchor],
            [_captionLabel.topAnchor constraintEqualToAnchor:_icon.bottomAnchor constant:4],
            [_captionLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_card.bottomAnchor constant:-6],
        ];
        // 功能卡：更小一档的小方卡（概览 / 应用主题 / 取消应用 / 导出），图标 20pt
        _compactCons = @[
            [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:10],
            iconX,
            [_icon.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
            [_icon.widthAnchor constraintEqualToConstant:20],
            [_icon.heightAnchor constraintEqualToConstant:20],
            [_captionLabel.topAnchor constraintEqualToAnchor:_icon.bottomAnchor constant:4],
            [_captionLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_card.bottomAnchor constant:-8],
        ];
        [NSLayoutConstraint activateConstraints:@[titleL, titleR, capL, capR]];
        [NSLayoutConstraint activateConstraints:_gridCons];
    }
    return self;
}

- (void)setCompact:(BOOL)compact {
    if (_compact == compact) return;
    _compact = compact;
    [NSLayoutConstraint deactivateConstraints:(compact ? _gridCons : _compactCons)];
    [NSLayoutConstraint activateConstraints:(compact ? _compactCons : _gridCons)];
    _titleLabel.font = [UIFont systemFontOfSize:(compact ? 12.5 : 13) weight:UIFontWeightSemibold];
    _captionLabel.font = [UIFont systemFontOfSize:(compact ? 10 : 11)];
    _captionLabel.numberOfLines = compact ? 3 : 2;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.card.alpha = highlighted ? 0.7 : 1.0;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.card.alpha = 1.0;
    self.icon.image = nil;
    self.titleLabel.text = nil;
    self.captionLabel.text = nil;
}

@end

#pragma mark - 预览合并卡（遮罩预览 + 前几个图标，一张卡内 2×3 并排）

static const CGFloat kTBPreviewPad  = 14.0;
static const CGFloat kTBPreviewGap  = 12.0;
static const CGFloat kTBPreviewImgH = 76.0;
static const CGFloat kTBPreviewCapH = 26.0;

/// 合并预览卡的高度（宽度 = 卡宽）。卡内是 3 列 × 2 行，第 0 格是遮罩预览。
static CGFloat TBPreviewCardHeight(CGFloat width) {
    CGFloat innerW = width - kTBPreviewPad * 2.0;
    CGFloat slotW = (innerW - kTBPreviewGap * 2.0) / 3.0;
    CGFloat imgH = MIN(kTBPreviewImgH, MAX(40.0, slotW));
    return kTBPreviewPad * 2.0 + (imgH + 4.0 + kTBPreviewCapH) * 2.0 + kTBPreviewGap;
}

@interface TBPreviewCardCell : UICollectionViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *slots;
@property (nonatomic, strong) NSMutableArray<UILabel *> *caps;
@end

@implementation TBPreviewCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _card = TBGlassCard(kTBCardRadius);       // 一张卡装下全部预览
        _card.clipsToBounds = YES;
        [self.contentView addSubview:_card];

        _slots = [NSMutableArray array];
        _caps = [NSMutableArray array];
        for (NSInteger i = 0; i < 6; i++) {
            UIImageView *iv = [[UIImageView alloc] init];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.clipsToBounds = NO;
            iv.hidden = YES;
            [_card addSubview:iv];
            [_slots addObject:iv];

            UILabel *cl = [[UILabel alloc] init];
            cl.font = [UIFont systemFontOfSize:9.5];
            cl.textColor = [UIColor secondaryLabelColor];
            cl.textAlignment = NSTextAlignmentCenter;
            cl.numberOfLines = 2;
            cl.lineBreakMode = NSLineBreakByTruncatingTail;
            cl.hidden = YES;
            [_card addSubview:cl];
            [_caps addObject:cl];
        }
    }
    return self;
}

/// 第 0 格 = 遮罩预览（配说明），后面依次是主题里的前几个图标
- (void)setPreviewImages:(NSArray *)images captions:(NSArray<NSString *> *)captions {
    for (NSInteger i = 0; i < (NSInteger)self.slots.count; i++) {
        UIImageView *iv = self.slots[i];
        UILabel *cap = self.caps[i];
        id o = (i < (NSInteger)images.count) ? images[i] : nil;
        UIImage *im = [o isKindOfClass:[UIImage class]] ? o : nil;
        NSString *tx = (i < (NSInteger)captions.count) ? captions[i] : nil;
        if (!tx.length) tx = nil;
        iv.image = im;
        cap.text = tx;
        iv.hidden = (im == nil);
        cap.hidden = (tx == nil);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    self.card.frame = b;
    CGFloat innerW = b.size.width - kTBPreviewPad * 2.0;
    CGFloat slotW = (innerW - kTBPreviewGap * 2.0) / 3.0;
    CGFloat imgH = MIN(kTBPreviewImgH, MAX(40.0, slotW));
    for (NSInteger i = 0; i < (NSInteger)self.slots.count; i++) {
        NSInteger row = i / 3, col = i % 3;
        CGFloat x = kTBPreviewPad + col * (slotW + kTBPreviewGap);
        CGFloat y = kTBPreviewPad + row * (imgH + 4.0 + kTBPreviewCapH + kTBPreviewGap);
        self.slots[i].frame = CGRectMake(x, y, slotW, imgH);
        self.caps[i].frame = CGRectMake(x - 2, y + imgH + 4.0, slotW + 4, kTBPreviewCapH);
    }
}

@end

#pragma mark - 分区标题

@interface TBSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation TBSectionHeaderView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        [self addSubview:_titleLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
            [_titleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
        ]];
    }
    return self;
}
@end

#pragma mark - 详情页

@interface TBThemeDetailController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
                                       UISearchResultsUpdating>
@property (nonatomic, strong) TBTheme *theme;
@property (nonatomic, strong) NSArray<NSString *> *allBids;
@property (nonatomic, strong) NSArray<NSString *> *bids;        // 搜索过滤后
@property (nonatomic, strong) NSArray<NSString *> *previewBids; // 预览方卡用的前几个
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) UIView *bgView;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, assign) NSUInteger covered;
@property (nonatomic, assign) NSUInteger installed;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, strong) UIImage *maskPreviewImage;   // 遮罩预览（已按当前形状裁好）
@property (nonatomic, copy) NSString *maskPreviewCaption;
- (void)tb_dismissSearch;

- (void)tb_prefsChanged;   // 偏好变更通知 → 刷新遮罩预览
@end

/// 偏好一变（形状三模式 / 叠加层 / 阴影 / 导入遮罩）就让遮罩预览立即重算
static void TBDetailPrefsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                                 const void *object, CFDictionaryRef userInfo) {
    TBThemeDetailController *vc = (__bridge TBThemeDetailController *)observer;
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc tb_prefsChanged];
    });
}


@implementation TBThemeDetailController

- (instancetype)initWithTheme:(TBTheme *)theme {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _theme = theme;
    }
    return self;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.theme.name;

    [self.theme loadIndex];
    self.allBids = [self.theme bundleIdentifiers];
    self.bids = self.allBids;

    // 预览方卡：取前 5 个真的有图的图标
    NSMutableArray<NSString *> *pv = [NSMutableArray array];
    for (NSString *bid in self.allBids) {
        if ([self.theme imageForBundleID:bid]) {
            [pv addObject:bid];
            if (pv.count >= 5) break;
        }
    }
    self.previewBids = pv;

    [self computeCoverage];
    [self tb_buildUI];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜应用名或 bundleID";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;

    // 0.15.53：与列表页同款的三条搜索退出路径（0.15.50 删了系统「取消」按钮）。
    // ① 点网格任意处收起；cancelsTouchesInView=NO，不影响 cell 点按
    UITapGestureRecognizer *dismissTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tb_dismissSearch)];
    dismissTap.cancelsTouchesInView = NO;
    [self.collectionView addGestureRecognizer:dismissTap];
    // ③ 键盘收起（下拉隐藏键盘 / 系统收起）→ 同步退出搜索态
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tb_dismissSearch)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    [self refreshMaskPreview];
    [self refreshApplyState];

    // 偏好变更（形状 / 叠加层 / 阴影）：预览卡片立即刷新
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)(self), TBDetailPrefsChanged,
                                    (__bridge CFStringRef)TBNotifyChanged, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)(self),
                                       (__bridge CFStringRef)TBNotifyChanged, NULL);
}

/// 遮罩/特效参数变了 → 重算预览并只重载「预览」分区
- (void)tb_prefsChanged {
    [self refreshMaskPreview];
    if (self.collectionView.numberOfSections > 1) {
        [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:1]];
    }
}

/// 背景 + 双列方形卡片网格
- (void)tb_buildUI {
    self.view.backgroundColor = [UIColor clearColor];

    self.bgView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.bgView.userInteractionEnabled = NO;
    [self.view addSubview:self.bgView];
    TBApplyPageBackground(self.bgView);

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = kTBCardGap;
    layout.minimumLineSpacing = kTBCardGap;
    layout.sectionInset = UIEdgeInsetsMake(8, kTBSideInset, 28, kTBSideInset);

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    [self.collectionView registerClass:[TBSquareCardCell class]
            forCellWithReuseIdentifier:@"card"];
    [self.collectionView registerClass:[TBPreviewCardCell class]
            forCellWithReuseIdentifier:@"preview"];
    [self.collectionView registerClass:[TBSectionHeaderView class]
            forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
                   withReuseIdentifier:@"header"];
    [self.view addSubview:self.collectionView];

    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshMaskPreview];      // 遮罩形状参数可能在别处改过
    [self refreshApplyState];
    [self.collectionView reloadData];
}

- (void)computeCoverage {
    NSArray<NSDictionary *> *apps = [TBAppInfo installedApps];
    self.installed = apps.count;
    NSUInteger hit = 0;
    for (NSDictionary *a in apps) {
        if ([self.theme hasIconForBundleID:a[@"bid"]]) hit++;
    }
    self.covered = hit;
}

/// 应用状态 + 右上角「缺 N」入口（原有功能入口全部保留）
- (void)refreshApplyState {
    self.active = [[TBPrefs stringForKey:TBKeyActiveTheme] isEqualToString:self.theme.name];
    NSUInteger miss = self.installed > self.covered ? self.installed - self.covered : 0;
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:(miss ? [NSString stringWithFormat:@"缺 %lu", (unsigned long)miss] : @"全覆盖")
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(missingTapped)],
    ];
    if (self.collectionView.numberOfSections > 0) {
        [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:0]];
    }
}

#pragma mark - 遮罩预览

/// 示例图标：优先用主题里第一张真图；没有就画一张占位方图（保证预览永远有东西看）
- (UIImage *)tb_sampleIcon {
    for (NSString *bid in self.allBids) {
        UIImage *img = [self.theme imageForBundleID:bid];
        if (img) return img;
    }
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(180, 180)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor systemBlueColor] setFill];
        UIRectFill(CGRectMake(0, 0, 180, 180));
        [[UIColor whiteColor] setFill];
        UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(55, 55, 70, 70)];
        [p fill];
    }];
}

/// 按当前生效的形状 + AnemoneEffects（叠加层 / 阴影）裁出示例图标：
///   UseThemeIconMask  → 用主题的遮罩图（找不到就顺延，和引擎一致）
///   MaskCornerRadiusOn → 圆角 = (MaskCornerRadius / 60) × 边长
///   否则               → 系统形状 22.37%
///   UseThemeIconShadow → 阴影垫在图标下方
///   UseThemeIconOverlay→ 叠加层盖在图标之上
/// 任一参数变了，viewWillAppear / 通知回调都会重算这张预览
- (void)refreshMaskPreview {
    BOOL useThemeMask = [TBPrefs boolForKey:kTBKeyUseThemeIconMask defaultValue:NO];
    BOOL cornerOn = [TBPrefs boolForKey:kTBKeyMaskCornerRadiusOn defaultValue:NO];
    double r = [TBPrefs doubleForKey:kTBKeyMaskCornerRadius defaultValue:kTBDefaultMaskCornerRadius];
    if (!(r > 0.0)) r = kTBDefaultMaskCornerRadius;

    UIImage *art = [self tb_sampleIcon];
    UIImage *mask = nil;
    if (useThemeMask) {
        NSString *p = [self.theme iconMaskPath];
        if (p.length) mask = [UIImage imageWithContentsOfFile:p];
    }
    // AnemoneEffects：主题里真的有素材才算"生效"
    UIImage *shadow = nil, *overlay = nil;
    NSString *shadowPath = [self.theme anemoneEffectPath:@"iPhoneShadow"];
    NSString *overlayPath = [self.theme anemoneEffectPath:@"iPhoneOverlay"];
    if ([TBPrefs boolForKey:kTBKeyUseThemeIconShadow defaultValue:NO] && shadowPath.length)
        shadow = [UIImage imageWithContentsOfFile:shadowPath];
    if ([TBPrefs boolForKey:kTBKeyUseThemeIconOverlay defaultValue:NO] && overlayPath.length)
        overlay = [UIImage imageWithContentsOfFile:overlayPath];

    const CGFloat side = 200.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    UIImage *out = [rd imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, side, side);
        if (shadow) [shadow drawInRect:rect];                 // ① 阴影垫在下面

        CGContextSaveGState(c);
        if (mask) {                                           // ② 形状：主题遮罩图
            [art drawInRect:rect];
            [mask drawInRect:rect blendMode:kCGBlendModeDestinationIn alpha:1.0];
        } else if (cornerOn) {                                //    形状：自定义圆角
            CGFloat radius = (CGFloat)(r / 60.0) * side;
            CGFloat maxR = side / 2.0;
            if (radius > maxR) radius = maxR;
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
            [p addClip];
            [art drawInRect:rect];
        } else {                                              //    形状：系统形状
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:rect
                                                         cornerRadius:side * 0.2237];
            [p addClip];
            [art drawInRect:rect];
        }
        CGContextRestoreGState(c);

        if (overlay) [overlay drawInRect:rect];                // ③ 叠加层盖在上面
    }];
    self.maskPreviewImage = out;

    NSMutableString *cap = [NSMutableString string];
    if (useThemeMask && mask) {
        [cap appendString:@"主题遮罩图"];
    } else if (cornerOn) {
        [cap appendFormat:@"自定义圆角\n半径 %.2f", r];
    } else if (useThemeMask) {
        [cap appendString:@"主题里没有遮罩图\n→ 系统形状"];
    } else {
        [cap appendString:@"系统形状\n（22.37%）"];
    }
    if (overlay || shadow) {
        [cap appendString:@"\n"];
        if (overlay) [cap appendString:@"＋叠加层 "];
        if (shadow) [cap appendString:@"＋阴影"];
    }
    self.maskPreviewCaption = cap;
}

#pragma mark - 操作卡片

- (void)applyTapped {
    [TBPrefs setString:self.theme.name forKey:TBKeyActiveTheme];
    [TBPrefs setBool:YES forKey:TBKeyEnabled];
    [TBPrefs notifyChanged];
    [self refreshApplyState];
    [TBToast showAppliedIn:self];   // 玻璃胶囊提示，替换原来的系统弹窗
}

- (void)cancelApplyTapped {
    NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
    if (![active isEqualToString:self.theme.name]) return;
    TBPresentConfirm(self, @"取消应用？", @"桌面图标会恢复系统原样，主题文件夹不会被删除",
                     @"取消", @"取消应用", YES, ^(BOOL ok) {
        if (!ok) return;
        [TBPrefs setString:nil forKey:TBKeyActiveTheme];
        [TBPrefs notifyChanged];
        [self refreshApplyState];
        [TBToast showCancelledIn:self];
    });
}

- (void)exportTapped {
    NSArray<NSDictionary *> *apps = [TBAppInfo installedApps];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *root = [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"Exports/%@", self.theme.name]];
    NSString *iconsDir = [root stringByAppendingPathComponent:@"IconBundles"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:root error:nil];
    [fm createDirectoryAtPath:iconsDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSUInteger copied = 0;
    for (NSDictionary *a in apps) {
        NSString *bid = a[@"bid"];
        NSString *src = [self.theme imagePathForBundleID:bid];
        if (src.length == 0) {
            [missing addObject:[NSString stringWithFormat:@"%@\t%@", bid, a[@"name"] ?: @""]];
            continue;
        }
        NSString *dst = [iconsDir stringByAppendingPathComponent:src.lastPathComponent];
        [fm removeItemAtPath:dst error:nil];
        if ([fm copyItemAtPath:src toPath:dst error:nil]) copied++;
    }
    NSString *missingPath = [root stringByAppendingPathComponent:@"缺失清单.txt"];
    [[missing componentsJoinedByString:@"\n"] writeToFile:missingPath atomically:YES
                                                  encoding:NSUTF8StringEncoding error:nil];

    NSString *msg = [NSString stringWithFormat:@"已导出 %lu 个图标，缺失 %lu 个（清单在同目录）\n\n%@",
                     (unsigned long)copied, (unsigned long)missing.count, root];
    TBPresentAlert(self, @"导出完成", msg);
}

- (void)missingTapped {
    [self.navigationController pushViewController:[[TBMissingController alloc] initWithTheme:self.theme] animated:YES];
}

#pragma mark - 搜索

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    if (q.length == 0) {
        self.bids = self.allBids;
    } else {
        NSString *q2 = [q lowercaseString];
        self.bids = [self.allBids filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *bid, NSDictionary *b) {
            if ([[bid lowercaseString] rangeOfString:q2].location != NSNotFound) return YES;
            NSString *tail = [[bid componentsSeparatedByString:@"."] lastObject];
            if ([[tail lowercaseString] rangeOfString:q2].location != NSNotFound) return YES;
            NSString *name = [TBAppInfo displayNameForBundleID:bid];
            return name && [[name lowercaseString] rangeOfString:q2].location != NSNotFound;
        }]];
    }
    [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:2]];
}

/// 收起搜索（0.15.53：搜索栏删了系统「取消」按钮后的退出路径）
- (void)tb_dismissSearch {
    if (self.search && self.search.active) {
        self.search.active = NO;   // searchBar 会跟着失焦收起
        self.bids = self.allBids;
        if (self.collectionView.numberOfSections > 2) {
            [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:2]];
        }
    }
}

/// ② 开始拖动网格 → 收起搜索（用户往下滑是明确的「退出搜索」意图）
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self tb_dismissSearch];
}

/// ② 兜底：大位移滚动（只在用户真实拖动/惯性时触发；搜索激活动画也会改 contentOffset，别误收）
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!self.search.active) return;
    BOOL userScrolling = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating;
    if (userScrolling && fabs(scrollView.contentOffset.y) > 10.0) [self tb_dismissSearch];
}

#pragma mark - 网格（双列方形卡片）

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv { return 3; }

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s {
    if (s == 0) return 4;                       // 概览 / 应用 / 取消应用 / 导出
    if (s == 1) return 1;                       // 合并成一张预览卡
    return self.bids.count;
}

- (CGFloat)collectionView:(UICollectionView *)cv
layout:(UICollectionViewLayout *)layout
heightForHeaderInSection:(NSInteger)s {
    return s == 0 ? 0.0 : 30.0;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)cv
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)ip {
    if (![kind isEqualToString:UICollectionElementKindSectionHeader]) return nil;
    TBSectionHeaderView *h = [cv dequeueReusableSupplementaryViewOfKind:kind
                                                    withReuseIdentifier:@"header"
                                                           forIndexPath:ip];
    h.titleLabel.text = (ip.section == 1)
        ? @"预览"
        : [NSString stringWithFormat:@"全部图标（%lu）", (unsigned long)self.bids.count];
    return h;
}

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)ip {
    CGFloat W = cv.bounds.size.width;
    if (W < 1) W = [UIScreen mainScreen].bounds.size.width;
    if (ip.section == 0) {                      // 四个功能卡：再小一档（78 高）
        CGFloat two = floor((W - kTBSideInset * 2 - kTBCardGap) / 2.0);
        if (two < 120) two = 120;
        return CGSizeMake(two, 78);
    }
    if (ip.section == 1) {                      // 预览：一张卡（卡内 2×3）
        CGFloat w = W - kTBSideInset * 2;
        if (w < 160) w = 160;
        return CGSizeMake(w, TBPreviewCardHeight(w));
    }
    // 全部图标：四列，图标 = 卡宽 × 0.80，高度 = 图标 + 名字（2 行小字）
    CGFloat col = floor((W - kTBSideInset * 2 - kTBCardGap * 3) / 4.0);
    if (col < 56) col = 56;
    CGFloat iconH = floor(col * 0.80);
    return CGSizeMake(col, iconH + 52.0);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)ip {
    // 预览分区：一张卡里并排显示「遮罩预览 + 前几个图标」
    if (ip.section == 1) {
        TBPreviewCardCell *pc = [cv dequeueReusableCellWithReuseIdentifier:@"preview" forIndexPath:ip];
        NSMutableArray *imgs = [NSMutableArray array];
        NSMutableArray *caps = [NSMutableArray array];
        [imgs addObject:self.maskPreviewImage ?: [NSNull null]];
        [caps addObject:(self.maskPreviewCaption.length ? self.maskPreviewCaption : @"遮罩预览")];
        for (NSString *bid in self.previewBids) {
            UIImage *im = [self.theme imageForBundleID:bid];
            [imgs addObject:im ?: [NSNull null]];
            NSString *dn = [TBAppInfo displayNameForBundleID:bid];
            [caps addObject:(dn.length ? dn : [[bid componentsSeparatedByString:@"."] lastObject])];
        }
        [pc setPreviewImages:imgs captions:caps];
        return pc;
    }

    TBSquareCardCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"card" forIndexPath:ip];
    cell.icon.tintColor = [UIColor secondaryLabelColor];
    cell.compact = (ip.section == 0);
    cell.captionLabel.hidden = NO;
    if (ip.section == 0) {
        NSString *sym = nil;
        switch (ip.item) {
            case 0: sym = @"square.grid.2x2"; break;
            case 1: sym = self.active ? @"checkmark.circle.fill" : @"checkmark.circle"; break;
            case 2: sym = @"arrow.uturn.backward.circle"; break;
            default: sym = @"square.and.arrow.up"; break;
        }
        UIImageSymbolConfiguration *sc =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIFontWeightRegular];
        cell.icon.image = [[UIImage systemImageNamed:sym withConfiguration:sc]
                           imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        cell.icon.contentMode = UIViewContentModeCenter;
        if (ip.item == 0) {
            cell.titleLabel.text = @"概览";
            cell.captionLabel.text = [NSString stringWithFormat:@"%lu 个图标\n覆盖 %lu/%lu · %lu 文件",
                                      (unsigned long)self.allBids.count, (unsigned long)self.covered,
                                      (unsigned long)self.installed, (unsigned long)self.theme.fileCount];
        } else if (ip.item == 1) {
            cell.titleLabel.text = self.active ? @"已应用" : @"应用主题";
            cell.captionLabel.text = self.active ? @"当前正在使用" : @"点一下立即换图";
        } else if (ip.item == 2) {
            cell.titleLabel.text = @"取消应用";
            cell.captionLabel.text = self.active ? @"恢复系统图标\n（不删主题）" : @"当前未应用";
        } else {
            cell.titleLabel.text = @"导出";
            cell.captionLabel.text = @"导出已覆盖图标\n到“文件”App";
        }
        cell.icon.alpha = (ip.item == 1 && self.active) ? 0.6 : 1.0;
        cell.titleLabel.textColor = ([UIColor labelColor]);
        return cell;
    }

    // 全部图标（四列方形卡：图标 = 卡宽 × 0.80，名字小字 2 行截断）
    NSString *bid = self.bids[ip.item];
    cell.icon.contentMode = UIViewContentModeScaleAspectFit;
    cell.icon.alpha = 1.0;
    cell.icon.image = [self.theme imageForBundleID:bid];
    cell.titleLabel.textColor = [UIColor labelColor];
    cell.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    cell.titleLabel.numberOfLines = 2;
    cell.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    NSString *dn = [TBAppInfo displayNameForBundleID:bid];
    cell.titleLabel.text = dn.length ? dn : [[bid componentsSeparatedByString:@"."] lastObject];
    cell.captionLabel.hidden = YES;          // 四列空间紧，只留名字（2 行截断）
    cell.captionLabel.text = nil;
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [cv deselectItemAtIndexPath:ip animated:YES];
    if (ip.section == 1) return;             // 预览卡只做展示
    if (ip.section == 0) {
        if (ip.item == 0) {                  // 概览卡：点一下刷新统计
            [self computeCoverage];
            [self refreshApplyState];
            return;
        }
        if (ip.item == 1) { [self applyTapped]; return; }
        if (ip.item == 2) { [self cancelApplyTapped]; return; }
        [self exportTapped];
        return;
    }
    // 图标卡：保留原来的「复制文件名」入口
    NSString *bid = self.bids[ip.item];
    TBPresentAlert(self, [TBAppInfo displayNameForBundleID:bid] ?: bid, [NSString stringWithFormat:@"%@.png", bid]);
}

@end
