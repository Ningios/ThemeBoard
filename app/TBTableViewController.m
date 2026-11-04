#import "TBTableViewController.h"
#import "TBGlass.h"

@interface TBTableViewController ()
@property (nonatomic, assign) UITableViewStyle style;
@property (nonatomic, strong) UIView *bgView;
@end

@implementation TBTableViewController

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _style = style;
    }
    return self;
}

- (instancetype)init {
    return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // 1) 背景：独立兄弟视图，铺满整页，永远在最底层
    self.bgView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.bgView.userInteractionEnabled = NO;
    [self.view addSubview:self.bgView];
    TBApplyPageBackground(self.bgView);

    // 2) 表格：子视图，透明，压在背景之上
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:self.style];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

/// 玻璃卡要按页面 16pt 对齐时，可能在 cell 左右各外扩几 pt；cell 默认会裁剪，
/// 这里统一放开（卡片本身仍在 cell 的上下 2pt 内缩，不会压到相邻行）。
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    cell.clipsToBounds = NO;
    cell.contentView.clipsToBounds = NO;
    cell.backgroundView.clipsToBounds = NO;
}

- (UIRefreshControl *)refreshControl {
    return self.tableView.refreshControl;
}

- (void)setRefreshControl:(UIRefreshControl *)refreshControl {
    self.tableView.refreshControl = refreshControl;
}

#pragma mark - 默认数据源（子类会覆盖）

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 0; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

@end
