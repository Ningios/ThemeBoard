#import "TBSettingsController.h"
#import "TBPrefs.h"
#import "TBThemeScanner.h"
#import "TBGlass.h"
#import "TBTableViewController.h"
#import "TBEngineInstaller.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "TBDocImport.h"

@interface TBSettingsController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *model;
@end

@implementation TBSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";

    self.tableView.rowHeight = 56;

    self.model = @[
        @[ @{@"t": @"引擎状态", @"act": @"engineInfo"},
           @{@"t": @"重启桌面（让引擎生效）", @"act": @"respring"} ],
        @[ @{@"t": @"启用引擎", @"k": TBKeyEnabled, @"v": @YES, @"d": @"关闭后完全恢复系统原样"} ],
        @[ @{@"t": @"用主题遮罩图", @"k": @"UseThemeIconMask", @"v": @NO,
             @"d": @"主题里放 IconMask.png 就用它当图标形状"},
           @{@"t": @"自定义图标圆角", @"k": @"MaskCornerRadiusOn", @"v": @NO,
             @"d": @"开启后按 CustomCornerRadius 算法（默认 13.42）裁圆角"},
           @{@"t": @"图标圆角半径", @"k": @"MaskCornerRadius", @"v": @13.42, @"num": @YES,
             @"d": @"CustomCornerRadius，60 ≈ 满圆角，默认 13.42"} ],
        @[ @{@"t": @"程序坞", @"k": TBKeyApplyDock, @"v": @YES},
           @{@"t": @"文件夹预览", @"k": TBKeyApplyFolder, @"v": @YES},
           @{@"t": @"App 切换器", @"k": TBKeyApplySwitcher, @"v": @YES},
           @{@"t": @"设置页图标", @"k": TBKeyApplySettings, @"v": @YES},
           @{@"t": @"通知中心", @"k": TBKeyApplyNotification, @"v": @YES},
           @{@"t": @"分享面板", @"k": TBKeyApplyShare, @"v": @YES} ],
        @[ @{@"t": @"在文件管理器中打开主题目录", @"act": @"open"} ],
        @[ @{@"t": @"日历不叠加日期", @"k": @"NoCalendarDate", @"v": @NO,
             @"d": @"主题日历图标已经画了日期时打开，直接用主题图标"} ],
        @[ @{@"t": @"跟随系统深色模式", @"k": @"FollowSystem", @"v": @YES, @"d": @"关掉则固定浅色"} ],
        @[ @{@"t": @"写日志", @"k": TBKeyLogEnabled, @"v": @YES},
           @{@"t": @"安全模式（只记录，不换图）", @"k": @"SafeMode", @"v": @NO},
           @{@"t": @"应用后清图标缓存", @"k": @"PurgeCache", @"v": @YES} ],
    ];

    // 每行配一个 SF Symbol
    NSDictionary *icons = @{
        @"引擎状态": @"waveform.path.ecg", @"重启桌面（让引擎生效）": @"arrow.clockwise.circle", @"安装 / 更新引擎": @"arrow.down.circle",
        @"重启桌面": @"arrow.clockwise.circle",
        @"启用引擎": @"power", @"程序坞": @"dock.rectangle", @"文件夹预览": @"folder",
        @"用主题遮罩图": @"square.dashed", @"自定义图标圆角": @"circle.dashed", @"图标圆角半径": @"ruler",
        @"App 切换器": @"rectangle.stack", @"设置页图标": @"gearshape", @"分享面板": @"square.and.arrow.up",
        @"通知中心": @"bell.badge",
        @"导入主题…": @"square.and.arrow.down", @"在文件管理器中打开主题目录": @"folder.badge.gearshape",
        @"重新扫描主题": @"arrow.triangle.2.circlepath", @"清除当前主题": @"trash",
        @"日历不叠加日期": @"calendar.badge.minus",
        @"跟随系统深色模式": @"circle.lefthalf.filled", @"写日志": @"doc.text", @"安全模式（只记录，不换图）": @"exclamationmark.shield",
        @"应用后清图标缓存": @"arrow.clockwise",
    };
    NSMutableArray *patched = [NSMutableArray array];
    for (NSArray *sec in self.model) {
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *row in sec) {
            NSMutableDictionary *m = [row mutableCopy];
            NSString *ic = icons[row[@"t"]];
            if (ic) m[@"icon"] = ic;
            [rows addObject:m];
        }
        [patched addObject:rows];
    }
    self.model = patched;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.model.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"引擎组件";
        case 1: return @"开关";
        case 2: return @"图标形状";
        case 3: return @"生效范围";
        case 4: return @"主题";
        case 5: return @"外观";
        default: return @"诊断";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        NSString *st = [TBEngineInstaller runtimeState];
        if ([st isEqualToString:@"运行中"]) return @"引擎正在运行。换主题、改开关都不需要重启桌面。";
        if ([st isEqualToString:@"已安装·未运行"]) return @"引擎已安装但当前没在跑，重启一次桌面即可生效。";
        return @"没有检测到引擎。RootHide 下 App 无法写入注入目录，请在 Sileo 安装「ThemeBoard 引擎」，装完重启一次桌面。";
    }
    if (section == 1) return @"关闭后完全恢复系统原样。";
    if (section == 2) return @"优先级：主题遮罩图 → 自定义圆角 → 系统形状。两个开关都关着 = 保持现在这样。";
    if (section == 3) return @"程序坞 / 文件夹预览 / App 切换器共用系统图标缓存，任一开启即生效；设置页图标 / 通知中心 / 分享面板可单独关闭。";
    if (section == 4) {
        NSMutableString *s = [NSMutableString stringWithString:@"主题目录：\n"];
        for (NSDictionary *d in [TBThemeScanner rootDiagnostics]) {
            NSString *flag = [d[@"exists"] boolValue]
                ? ([d[@"writable"] boolValue] ? @"✓可写" : @"✓只读")
                : @"✗不存在";
            [s appendFormat:@"%@ %@ (%@ 项)\n", flag, d[@"path"], d[@"count"]];
        }
        return s;
    }
    if (section == 5) return nil;
    if (section == 6) return nil;
    if (section == 7) return @"打开：应用主题后分批清理图标缓存，桌面立即刷新。关闭：资源库立即生效，桌面要等系统自然刷新或重启桌面。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.model[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.model[indexPath.section][indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.backgroundView = TBGlassCellBG(12);
    cell.selectedBackgroundView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = row[@"t"];
    if (row[@"icon"]) {
        cell.imageView.image = [UIImage systemImageNamed:row[@"icon"]];
        cell.imageView.tintColor = [UIColor secondaryLabelColor];
    }

    if (row[@"num"]) {
        // 数值行（MaskCornerRadius）：右侧可编辑的输入框，失焦/点"完成"时写回偏好
        if (row[@"d"]) cell.detailTextLabel.text = row[@"d"];
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 88, 32)];
        tf.textAlignment = NSTextAlignmentRight;
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
        tf.text = [NSString stringWithFormat:@"%.2f",
                   [TBPrefs doubleForKey:row[@"k"] defaultValue:[row[@"v"] doubleValue]]];
        tf.tag = indexPath.section * 100 + indexPath.row;
        [tf addTarget:self action:@selector(numberChanged:) forControlEvents:UIControlEventEditingDidEnd];
        UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
        bar.items = @[ [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                     target:nil action:nil],
                       [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                     target:tf action:@selector(resignFirstResponder)] ];
        tf.inputAccessoryView = bar;
        cell.accessoryView = tf;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (row[@"k"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [TBPrefs boolForKey:row[@"k"] defaultValue:[row[@"v"] boolValue]];
        sw.tag = indexPath.section * 100 + indexPath.row;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (row[@"d"]) cell.detailTextLabel.text = row[@"d"];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if ([row[@"act"] isEqualToString:@"engineInfo"]) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            NSString *st = [TBEngineInstaller runtimeState];
            cell.detailTextLabel.text = st;
            if ([st isEqualToString:@"运行中"]) {
                cell.detailTextLabel.textColor = [UIColor systemGreenColor];
            } else if ([st isEqualToString:@"已安装·未运行"]) {
                cell.detailTextLabel.textColor = [UIColor systemOrangeColor];
            } else {
                cell.detailTextLabel.textColor = [UIColor systemRedColor];
            }
        }
        if ([row[@"act"] isEqualToString:@"respring"]) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.detailTextLabel.text = @"只在装完引擎后用一次";
        }
        if ([row[@"act"] isEqualToString:@"clear"]) {
            cell.textLabel.textColor = [UIColor systemRedColor];
        }
        if ([row[@"act"] isEqualToString:@"open"] && [TBThemeScanner themeRoots].count) {
            cell.detailTextLabel.text = [TBThemeScanner themeRoots].firstObject;
            cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        }
    }
    return cell;
}

- (void)switchChanged:(UISwitch *)sw {
    NSInteger section = sw.tag / 100, row = sw.tag % 100;
    NSDictionary *item = self.model[section][row];
    [TBPrefs setBool:sw.on forKey:item[@"k"]];
    [TBPrefs notifyChanged];
    if ([item[@"k"] isEqualToString:@"FollowSystem"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TBAppearanceChanged" object:nil];
    }
}

/// 数值行编辑结束：写回偏好（非法输入回默认值）
- (void)numberChanged:(UITextField *)tf {
    NSInteger section = tf.tag / 100, row = tf.tag % 100;
    if (section < 0 || section >= (NSInteger)self.model.count) return;
    if (row < 0 || row >= (NSInteger)self.model[section].count) return;
    NSDictionary *item = self.model[section][row];
    NSString *k = item[@"k"];
    if (!k.length) return;
    double v = tf.text.doubleValue;
    if (tf.text.length == 0 || v < 0 || v != v || v > 10000) v = [item[@"v"] doubleValue];
    [TBPrefs setDouble:v forKey:k];
    [TBPrefs notifyChanged];
    tf.text = [NSString stringWithFormat:@"%.2f", v];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.model[indexPath.section][indexPath.row];
    NSString *act = row[@"act"];
    if (!act) return;

    if ([act isEqualToString:@"import"]) {
        // 与主题列表页同一个选择器：iOS14+ = initForOpeningContentTypes:asCopy:YES
        UIDocumentPickerViewController *picker =
            TBNewImportPicker(@[ UTTypeFolder, UTTypeZIP ], @[ @"public.folder", @"public.zip-archive" ]);
        if (!picker) { [self alert:@"打不开" msg:@"系统没有可用的文件夹选择器"]; return; }
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } else if ([act isEqualToString:@"respring"]) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"重启桌面？"
            message:@"屏幕会黑一下然后回到桌面，正在运行的应用会被关闭。装完新引擎后用一次即可。"
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 (__bridge CFStringRef)@"com.ning.themeboard.respring",
                                                 NULL, NULL, true);
        }]];
        [self presentViewController:ac animated:YES completion:nil];
    } else if ([act isEqualToString:@"open"]) {
        [self openThemeFolder];
    } else if ([act isEqualToString:@"rescan"]) {
        NSArray *themes = [TBThemeScanner scanThemes];
        [self alert:@"扫描完成" msg:[NSString stringWithFormat:@"找到 %lu 个主题", (unsigned long)themes.count]];
    } else if ([act isEqualToString:@"installEngine"]) {
        [self installEngineTapped];
    } else if ([act isEqualToString:@"helperTest"]) {
        NSString *r = [TBEngineInstaller runHelperTest];
        [self alert:@"助手自检" msg:r];
    } else if ([act isEqualToString:@"respring"]) {
        [self confirmRespring];
    } else if ([act isEqualToString:@"clear"]) {
        [TBPrefs setString:nil forKey:TBKeyActiveTheme];
        [TBPrefs notifyChanged];
        [self alert:@"已清除" msg:@"当前不再使用任何主题"];
    }
}

- (void)installEngineTapped {
    NSError *err = nil;
    if ([TBEngineInstaller dynamicLibrariesDir] == nil) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"这台设备要用引擎包安装"
            message:@"RootHide 把注入目录对 App 隐藏了，App 无法直接写入。\n在 Sileo 里装「ThemeBoard 引擎」即可，装完重启一次桌面，以后不用再管。"
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"复制包名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = @"com.ning.themeboard.engine";
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"去 Sileo" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (![TBEngineInstaller openSileoForEngine]) {
                [self alert:@"打不开 Sileo" msg:@"请手动在 Sileo 搜索 ThemeBoard 引擎"];
            }
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    if ([TBEngineInstaller installEngine:&err]) {
        [self.tableView reloadData];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"引擎已写入"
            message:@"需要重启一次桌面才会加载。现在就重启吗？\n（只会重启 SpringBoard，不影响其他东西）"
            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"立即重启" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self doRespring];
        }]];
        [self presentViewController:ac animated:YES completion:nil];
    } else {
        [self alert:@"安装失败" msg:err.localizedDescription ?: @"未知错误"];
    }
}

- (void)confirmRespring {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"重启桌面？"
        message:@"屏幕会黑一下，随后回到桌面，正在运行的 App 会被关闭"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self doRespring];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)doRespring {
    if (![TBEngineInstaller respring]) {
        [self alert:@"重启失败" msg:@"找不到 sbreload / killall，请手动重启桌面"];
    }
}

- (void)openThemeFolder {
    NSString *path = [TBThemeScanner writableThemeRoot];
    if (!path) { [self alert:@"打不开" msg:@"没有可写的主题目录"]; return; }
    NSArray *urls = @[[NSString stringWithFormat:@"filza://view%@", path],
                      [NSString stringWithFormat:@"shareddocuments://%@", path],
                      [NSString stringWithFormat:@"filza://%@", path]];
    __block BOOL opened = NO;
    for (NSString *s in urls) {
        NSURL *u = [NSURL URLWithString:s];
        if (!u) continue;
        if ([[UIApplication sharedApplication] canOpenURL:u]) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            opened = YES;
            break;
        }
    }
    if (!opened) {
        [UIPasteboard generalPasteboard].string = path;
        [self alert:@"已复制路径" msg:path];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSError *err = nil;
    NSString *dst = [TBThemeScanner importFromAnyURL:url error:&err];   // 内部走文件协调器
    if (dst) [self alert:@"导入完成" msg:dst];
    else [self alert:@"导入失败" msg:(err.localizedDescription
                                  ?: TBImportFailureMessage(url, nil, @"未知错误"))];
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
