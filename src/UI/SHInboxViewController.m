#import "SHInboxViewController.h"
#import "SHThreadViewController.h"
#import "SHProfileViewController.h"
#import "SHInstagram.h"
#import "SHDirectMonitor.h"
#import "SHPoller.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

static NSString * const SHThreadCellId = @"ThreadCell";

@interface SHThreadRowCell : UITableViewCell
@property (nonatomic, strong) SHImageView *avatar;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *previewLabel;
@property (nonatomic, strong) UIImageView *unreadDot;
@property (nonatomic, copy) void (^onAvatarTap)(void);   // tapping the picture opens that person's profile
@end

@implementation SHThreadRowCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        SHTheme *theme = [SHTheme shared];
        _avatar = [[SHImageView alloc] initWithFrame:CGRectMake(12, 11, 50, 50)];
        [theme styleAvatar:_avatar radius:5];
        _avatar.maxPixels = 128;
        _avatar.userInteractionEnabled = YES;
        [_avatar addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(avatarTapped)]];
        [self.contentView addSubview:_avatar];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont boldSystemFontOfSize:15];
        _titleLabel.textColor = [theme textColor];
        _titleLabel.highlightedTextColor = [UIColor whiteColor];
        _titleLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_titleLabel];
        [self.contentView addSubview:_titleLabel];
        _previewLabel = [[UILabel alloc] init];
        _previewLabel.font = [UIFont systemFontOfSize:13];
        _previewLabel.textColor = [theme secondaryTextColor];
        _previewLabel.highlightedTextColor = [UIColor whiteColor];
        _previewLabel.backgroundColor = [UIColor clearColor];
        [theme embossLabel:_previewLabel];
        [self.contentView addSubview:_previewLabel];
        _unreadDot = [[UIImageView alloc] initWithImage:[theme unreadDotImage]];
        _unreadDot.hidden = YES;
        [self.contentView addSubview:_unreadDot];
        self.accessoryView = [[UIImageView alloc] initWithImage:[theme disclosureChevronImage]];
    }
    return self;
}
- (void)avatarTapped { if (_onAvatarTap) _onAvatarTap(); }

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width, x = 74;
    _titleLabel.frame = CGRectMake(x, 15, w - x - 30, 21);
    _previewLabel.frame = CGRectMake(x, 38, w - x - 30, 18);
    _unreadDot.frame = CGRectMake(w - 20, 30, 12, 12);
}
@end

@interface SHInboxViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *threads;
@property (nonatomic, copy) NSString *cursor;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL fresh;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic) BOOL pending;   // the message requests instead of the inbox
@property (nonatomic, strong) SHPoller *poller;      // new messages while the list is on screen
@property (nonatomic) BOOL loadedMore;               // pages further down are in
@property (nonatomic, copy) NSString *signature;     // what the rows showed last (to redraw only on a change)
@end

@implementation SHInboxViewController

- (instancetype)initWithPendingRequests
{
    if ((self = [super init])) _pending = YES;
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    SHTheme *theme = [SHTheme shared];
    // (the tab keeps its own item: a pushed list of requests takes the title, the tab's root only the bar's)
    if (_pending) self.title = L(@"Message requests");
    else self.title = L(@"Direct");
    self.view.backgroundColor = [theme linenColor];
    _threads = [NSMutableArray array];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 72;
    [theme applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 30, 0)];
    _statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.font = [UIFont boldSystemFontOfSize:15];
    _statusLabel.textColor = [theme secondaryTextColor];
    _statusLabel.backgroundColor = [UIColor clearColor];
    [theme embossLabel:_statusLabel];
    _statusLabel.hidden = YES;
    [self.view addSubview:_statusLabel];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[theme spinnerStyle]];
    _spinner.center = CGPointMake(self.view.bounds.size.width / 2, 80);
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    // the conversations of last time at once; the network freshens them when the tab shows
    if (!_pending) {
        [SHInstagram cachedDirectInboxWithCompletion:^(NSArray *threads, NSString *cursor, NSError *error) {
            if (self->_fresh || !threads.count) return;
            [self->_threads setArray:threads];
            [self->_spinner stopAnimating];
            [self->_tableView reloadData];
        }];
        // and while the list is on screen, again now and then (new chats, new messages, what was read)
        __weak SHInboxViewController *weakSelf = self;
        _poller = [[SHPoller alloc] initWithMinInterval:15 maxInterval:60 block:^(void (^done)(BOOL changed)) {
            SHInboxViewController *s = weakSelf;
            if (!s || s->_loading) { done(NO); return; }
            NSString *before = s->_signature;
            [s load:NO then:^{ done(![(before ?: @"") isEqualToString:(weakSelf.signature ?: @"")]); }];
        }];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [_poller start];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_poller stop];
}

// The rows as they would look: ids, previews, times, unread.
- (NSString *)signatureOfThreads
{
    NSMutableString *s = [NSMutableString string];
    SHDirectMonitor *monitor = [SHDirectMonitor shared];
    for (SHDirectThread *t in _threads)
        [s appendFormat:@"%@|%@|%.0f|%d;", t.threadId, t.lastText ?: @"", [t.lastActivity timeIntervalSince1970], [monitor threadIsUnread:t]];
    [s appendFormat:@"requests=%ld", (long)(_pending ? 0 : [SHInstagram pendingMessageRequestCount])];
    return s;
}

// "Message requests (n)" over the conversations while some wait (the count comes with the inbox).
- (void)updateRequestsRow
{
    NSInteger count = _pending ? 0 : [SHInstagram pendingMessageRequestCount];
    if (count <= 0) { _tableView.tableHeaderView = nil; return; }
    SHTheme *theme = [SHTheme shared];
    CGFloat w = _tableView.bounds.size.width;
    UIImageView *row = [[UIImageView alloc] initWithImage:[theme cellBackgroundImage]];
    row.frame = CGRectMake(0, 0, w, 50);
    row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    row.userInteractionEnabled = YES;
    row.accessibilityLabel = L(@"Message requests");
    [row addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openRequests)]];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, w - 50, 50)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.text = [NSString stringWithFormat:@"%@ (%ld)", L(@"Message requests"), (long)count];
    label.font = [UIFont boldSystemFontOfSize:15];
    label.textColor = [theme linkColor];
    label.backgroundColor = [UIColor clearColor];
    [theme embossLabel:label];
    [row addSubview:label];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[theme disclosureChevronImage]];
    chevron.frame = CGRectMake(w - 24, floorf((50 - chevron.image.size.height) / 2), chevron.image.size.width, chevron.image.size.height);
    chevron.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:chevron];
    _tableView.tableHeaderView = row;
}

- (void)openRequests
{
    [self.navigationController pushViewController:[[SHInboxViewController alloc] initWithPendingRequests] animated:YES];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self load:NO];   // refresh each time the tab is shown
    [_poller noteFresh];
}

- (void)dealloc
{
    [_poller stop];
    [_task cancel];
}

- (void)load:(BOOL)more { [self load:more then:nil]; }

- (void)load:(BOOL)more then:(void (^)(void))then
{
    if (_loading || (more && !_cursor.length)) { if (then) then(); return; }
    _loading = YES;
    if (_threads.count == 0) [_spinner startAnimating];
    [_task cancel];
    __weak SHInboxViewController *weakSelf = self;
    SHThreadsCompletion done = ^(NSArray *threads, NSString *cursor, NSError *error) {
        SHInboxViewController *s = weakSelf;
        if (!s) { if (then) then(); return; }
        s->_loading = NO;
        [s->_spinner stopAnimating];
        if (error) {
            if (s->_threads.count == 0) { s->_statusLabel.text = error.localizedDescription; s->_statusLabel.hidden = NO; }
            if (then) then();
            return;
        }
        NSMutableSet *ids = [NSMutableSet set];
        for (SHDirectThread *t in threads) if (t.threadId.length) [ids addObject:t.threadId];
        if (!more) {
            // the first page anew; once pages further down are in, those stay under it (less what moved up)
            NSMutableArray *rest = [NSMutableArray array];
            if (s->_loadedMore) for (SHDirectThread *t in s->_threads) if (![ids containsObject:t.threadId]) [rest addObject:t];
            [s->_threads setArray:threads];
            [s->_threads addObjectsFromArray:rest];
            s->_fresh = YES;
        } else {
            NSMutableSet *have = [NSMutableSet set];
            for (SHDirectThread *t in s->_threads) if (t.threadId.length) [have addObject:t.threadId];
            for (SHDirectThread *t in threads) if (![have containsObject:t.threadId]) [s->_threads addObject:t];
            s->_loadedMore = YES;
        }
        s->_cursor = s->_pending ? nil : cursor;
        s->_statusLabel.hidden = s->_threads.count > 0;
        if (s->_threads.count == 0) {
            s->_statusLabel.text = s->_pending ? L(@"No requests.") : L(@"No messages yet.");
            s->_statusLabel.hidden = NO;
        }
        NSString *signature = [s signatureOfThreads];
        if (![signature isEqualToString:(s->_signature ?: @"")]) {   // (a poll that found nothing new redraws nothing)
            s->_signature = signature;
            [s updateRequestsRow];
            [s->_tableView reloadData];
        }
        if (then) then();
    };
    if (_pending) _task = [SHInstagram pendingDirectInboxWithCompletion:done];
    else _task = [SHInstagram directInboxWithCursor:more ? _cursor : nil completion:done];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)_threads.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    SHThreadRowCell *cell = [tableView dequeueReusableCellWithIdentifier:SHThreadCellId];
    if (!cell) cell = [[SHThreadRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:SHThreadCellId];
    [[SHTheme shared] styleCell:cell];
    SHDirectThread *t = _threads[(NSUInteger)indexPath.row];
    SHUser *first = [t.users firstObject];
    [cell.avatar setImageURL:first.profilePicURL placeholder:[[SHTheme shared] avatarPlaceholderWithSize:50]];
    __weak SHInboxViewController *weakSelf = self;
    cell.onAvatarTap = ^{
        if (!first.username.length && !first.pk.length) return;
        SHProfileViewController *vc = [[SHProfileViewController alloc] initWithUsername:first.username pk:first.pk];
        [weakSelf.navigationController pushViewController:vc animated:YES];
    };
    cell.titleLabel.text = [SHUtils displayText:t.title];
    cell.previewLabel.text = [SHUtils displayText:t.lastText ?: @""];
    BOOL unread = [[SHDirectMonitor shared] threadIsUnread:t];   // (also off at once for a chat just read here)
    cell.unreadDot.hidden = !unread;
    cell.previewLabel.textColor = unread ? [[SHTheme shared] textColor] : [[SHTheme shared] secondaryTextColor];
    [cell setNeedsLayout];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ((NSUInteger)indexPath.row + 3 >= _threads.count && _cursor.length && !_loading) [self load:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    SHDirectThread *t = _threads[(NSUInteger)indexPath.row];
    SHThreadViewController *vc = [[SHThreadViewController alloc] initWithThread:t];
    if (_pending) {
        // a request: read it first, then Accept or Delete in place of the bar
        vc.pendingRequest = YES;
        __weak SHInboxViewController *weakSelf = self;
        vc.onRequestAnswered = ^(BOOL accepted) { [weakSelf load:NO]; };
    }
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
