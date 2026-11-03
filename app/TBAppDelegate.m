#import "TBAppDelegate.h"
#import "TBRootController.h"
#import "TBGlass.h"
#import "TBPrefs.h"


#pragma mark - 崩溃日志（App 侧，落盘到 /var/mobile/Library/ThemeBoard/app-crash.log）

static NSString *TBCrashLogPath(void) {
    NSString *dir = @"/var/mobile/Library/ThemeBoard";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"app-crash.log"];
}

void TBAppLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [NSDate date], msg ?: @""];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:TBCrashLogPath()];
    if (!fh) {
        [line writeToFile:TBCrashLogPath() atomically:YES
                 encoding:NSUTF8StringEncoding error:NULL];
    } else {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (NSException *e) { }
        [fh closeFile];
    }
}

static void TBUncaughtExceptionHandler(NSException *e) {
    TBAppLog(@"=== 未捕获异常 %@: %@\n%@", e.name, e.reason,
             [e.callStackSymbols componentsJoinedByString:@"\n"]);
}

static void TBSignalHandler(int sig) {
    NSString *s = [NSString stringWithFormat:@"=== 信号崩溃 signal=%d", sig];
    TBAppLog(@"%@", s);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void TBCrashLogInstall(void) {
    NSSetUncaughtExceptionHandler(&TBUncaughtExceptionHandler);
    int sigs[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
    for (unsigned i = 0; i < sizeof(sigs)/sizeof(sigs[0]); i++) signal(sigs[i], TBSignalHandler);
    TBAppLog(@"--- App 启动 v%@ ---",
             [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?");
}

@implementation TBAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    TBCrashLogInstall();
    TBInstallGlassSearchBars();   // 所有搜索框统一毛玻璃外观（详情页/主题页/设置页）
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor colorWithRed:0.870 green:0.858 blue:0.843 alpha:1];
    self.window.rootViewController = [[TBRootController alloc] init];
    [self.window makeKeyAndVisible];

    // 背景铺在 window 上，导航栏/标签栏都透明，磨砂才不会被内容滚动带跑
    TBAttachWindowFrost(self.window);

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyAppearance)
                                                 name:@"TBAppearanceChanged"
                                               object:nil];
    [self applyAppearance];
    return YES;
}

- (void)applyAppearance {
    BOOL follow = [TBPrefs boolForKey:@"FollowSystem" defaultValue:YES];
    self.window.overrideUserInterfaceStyle = follow ? UIUserInterfaceStyleUnspecified
                                                    : UIUserInterfaceStyleLight;
}

@end
