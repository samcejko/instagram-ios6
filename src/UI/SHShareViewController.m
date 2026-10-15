#import "SHShareViewController.h"
#import "SHInstagram.h"
#import "SHModels.h"
#import "SHImageLoader.h"
#import "SHExternalOpen.h"
#import "SHLinkRouter.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHModern.h"
#import "SHCommon.h"
#import <QuartzCore/QuartzCore.h>

// Someone to send to: a chat (thread) or a person found by the search.
@interface SHShareRecipient : NSObject
@property (nonatomic, copy) NSString *threadId;
@property (nonatomic, copy) NSString *userPk;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *pictureURL;
@property (nonatomic, readonly) NSString *key;
@end

@implementation SHShareRecipient
- (NSString *)key { return self.threadId.length ? [@"t:" stringByAppendingString:self.threadId] : [@"u:" stringByAppendingString:self.userPk ?: @""]; }
@end

@interface SHShareViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UITextFieldDelegate>
@property (nonatomic, strong) SHPost *post;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITextField *messageField;
@property (nonatomic, strong) NSArray *recent;            // SHShareRecipient from the inbox
@property (nonatomic, strong) NSArray *results;           // a search's, nil when not searching
@property (nonatomic, strong) NSMutableDictionary *threadByUser;   // pk -> the one-to-one chat with them
@property (nonatomic, strong) NSMutableDictionary *selected;       // key -> recipient
@property (nonatomic, strong) NSMutableArray *order;               // in the order they were ticked
@property (nonatomic, strong) SHHTTPTask *inboxTask;
@property (nonatomic, strong) SHHTTPTask *searchTask;
@property (nonatomic, strong) UIPopoverController *popover;        // iOS 6 iPad: the system share sheet
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic) BOOL sending;
@property (nonatomic) BOOL inboxDone;
@end

@implementation SHShareViewController

+ (void)presentForPost:(SHPost *)post
{
    if (!post.pk.length) return;
    [SHLinkRouter presentInNavigation:[[SHShareViewController alloc] initWithPost:post]];
}

// The code in a post's link is its numeric id in base 64 (A-Z a-z 0-9 - _), when the post did not bring it.
static NSString *SHShortcodeFromPk(NSString *pk)
{
    static NSString * const alphabet = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    NSString *digits = [[pk componentsSeparatedByString:@"_"] firstObject];
    unsigned long long n = strtoull([digits UTF8String] ?: "0", NULL, 10);
    if (!n) return nil;
    NSMutableString *code = [NSMutableString string];
    while (n > 0) {
        [code insertString:[alphabet substringWithRange:NSMakeRange((NSUInteger)(n % 64), 1)] atIndex:0];
        n /= 64;
    }
    return code;
}

+ (NSURL *)webURLForPost:(SHPost *)post
{
    NSString *code = post.code.length ? post.code : SHShortcodeFromPk(post.pk);
    if (!code.length) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.instagram.com/p/%@/", code]];
}

+ (void)flashMessage:(NSString *)text
{
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window || !text.length) return;
    UIFont *font = [UIFont boldSystemFontOfSize:17];
    CGFloat w = MAX(140, [text sizeWithFont:font].width + 40), h = 64;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(floorf((window.bounds.size.width - w) / 2), floorf((window.bounds.size.height - h) / 2), w, h)];
    box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    box.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    box.layer.cornerRadius = 10;
    box.userInteractionEnabled = NO;
    UILabel *label = [[UILabel alloc] initWithFrame:box.bounds];
    label.text = text;
    label.font = font;
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.backgroundColor = [UIColor clearColor];
    label.shadowColor = [UIColor blackColor];
    label.shadowOffset = CGSizeMake(0, -1);
    [box addSubview:label];
    [window addSubview:box];
    // (the fade starts later rather than with a delay: a delayed animation would set the box's alpha to 0 at once,
    // and the debug snapshot, which draws the layers' model values, would never show the notice)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ box.alpha = 0; } completion:^(BOOL finished) { [box removeFromSuperview]; }];
    });
}

- (instancetype)initWithPost:(SHPost *)post
{
    if ((self = [super init])) {
        _post = post;
        _recent = @[];
        _selected = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
        _threadByUser = [NSMutableDictionary dictionary];
    }
    return self;
}

- (UIButton *)glossyButton:(NSString *)title action:(SEL)action
{
    SHTheme *theme = [SHTheme shared];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [b setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[theme textColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [theme embossButton:b];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    SHTheme *theme = [SHTheme shared];
    self.title = L(@"Send to");
    self.view.backgroundColor = [theme linenColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                          target:self action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Send") style:UIBarButtonItemStyleDone
                                                                             target:self action:@selector(sendTapped)];
    self.navigationItem.rightBarButtonItem.enabled = NO;

    CGFloat w = self.view.bounds.size.width;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 44 + 50 + 46)];
    header.backgroundColor = [UIColor clearColor];
    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
    _searchBar.placeholder = L(@"Search users...");
    _searchBar.delegate = self;
    _searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [theme applyToSearchBar:_searchBar];
    [header addSubview:_searchBar];

    _messageField = [[UITextField alloc] initWithFrame:CGRectMake(10, 44 + 9, w - 20, 32)];
    _messageField.borderStyle = UITextBorderStyleNone;
    _messageField.background = [theme textFieldBackgroundImage];
    _messageField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 32)];
    _messageField.leftViewMode = UITextFieldViewModeAlways;
    _messageField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _messageField.placeholder = L(@"Write a message...");
    _messageField.font = [UIFont systemFontOfSize:15];
    _messageField.textColor = [theme inputTextColor];
    _messageField.returnKeyType = UIReturnKeyDone;
    _messageField.delegate = self;
    _messageField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:_messageField];

    CGFloat bw = floorf((w - 30) / 2);
    UIButton *copy = [self glossyButton:L(@"Copy Link") action:@selector(copyTapped)];
    copy.frame = CGRectMake(10, 44 + 50, bw, 34);
    copy.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleWidth;
    [header addSubview:copy];
    UIButton *more = [self glossyButton:L(@"Share via...") action:@selector(moreTapped:)];
    more.frame = CGRectMake(20 + bw, 44 + 50, w - 30 - bw, 34);
    more.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleWidth;
    [header addSubview:more];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.tableHeaderView = header;
    [theme applyToTableView:_tableView];
    [self.view addSubview:_tableView];

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, header.frame.size.height + 30, w - 40, 40)];
    _emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.font = [UIFont boldSystemFontOfSize:15];
    _emptyLabel.textColor = [theme secondaryTextColor];
    _emptyLabel.backgroundColor = [UIColor clearColor];
    [theme embossLabel:_emptyLabel];
    _emptyLabel.hidden = YES;
    [self.view addSubview:_emptyLabel];

    // the chats kept from the last time at once, then the inbox as it is now (one request)
    [SHInstagram cachedDirectInboxWithCompletion:^(NSArray *threads, NSString *cursor, NSError *error) {
        if (!self->_recent.count && threads.count) [self showThreads:threads];
    }];
    _inboxTask = [SHInstagram directInboxWithCursor:nil completion:^(NSArray *threads, NSString *cursor, NSError *error) {
        self->_inboxDone = YES;
        if (threads) [self showThreads:threads];
        [self updateEmpty];
    }];
}

- (void)dealloc
{
    [_inboxTask cancel];
    [_searchTask cancel];
    [self closePopover];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self closePopover];
}

// The system's share sheet goes with this screen: a popover released while still on screen stops the app.
- (void)closePopover
{
    if (!_popover) return;
    if ([_popover.contentViewController isKindOfClass:[UIActivityViewController class]])
        [(UIActivityViewController *)_popover.contentViewController setCompletionHandler:nil];
    [_popover dismissPopoverAnimated:NO];
    _popover = nil;
}

- (void)showThreads:(NSArray *)threads
{
    NSMutableArray *list = [NSMutableArray array];
    for (SHDirectThread *t in threads) {
        if (!t.threadId.length) continue;
        SHShareRecipient *r = [[SHShareRecipient alloc] init];
        r.threadId = t.threadId;
        r.title = [SHUtils displayText:t.title];
        SHUser *first = [t.users firstObject];
        r.pictureURL = first.profilePicURL;
        if (t.users.count == 1) {
            r.subtitle = [SHUtils displayText:first.fullName];
            if (first.pk.length) _threadByUser[first.pk] = t.threadId;
        } else {
            r.subtitle = L(@"Group");
        }
        [list addObject:r];
    }
    _recent = list;
    [_tableView reloadData];
    [self updateEmpty];
}

- (NSArray *)rows { return _results ?: _recent; }

- (void)updateEmpty
{
    BOOL loading = !_results && !_recent.count && !_inboxDone;
    _emptyLabel.text = _results ? L(@"No users found.") : L(@"No chats yet.");
    _emptyLabel.hidden = [self rows].count > 0 || loading;
}

#pragma mark - Search

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
    NSString *q = [searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return;
    [_searchTask cancel];
    _searchTask = [SHInstagram searchUsers:q completion:^(NSArray *users, NSError *error) {
        if (error) { [SHUtils alertWithTitle:L(@"Search") message:error.localizedDescription]; return; }
        NSMutableArray *list = [NSMutableArray array];
        for (SHUser *u in users) {
            if (!u.pk.length) continue;
            SHShareRecipient *r = [[SHShareRecipient alloc] init];
            r.threadId = self->_threadByUser[u.pk];   // the chat with them when there is one
            r.userPk = u.pk;
            r.title = u.username;
            r.subtitle = [SHUtils displayText:u.fullName];
            r.pictureURL = u.profilePicURL;
            [list addObject:r];
        }
        self->_results = list;
        [self->_tableView reloadData];
        [self updateEmpty];
    }];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    if (searchText.length) return;
    [_searchTask cancel];
    _results = nil;   // back to the recent chats
    [_tableView reloadData];
    [self updateEmpty];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return NO; }

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return (NSInteger)[self rows].count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (![self rows].count) return nil;
    return _results ? L(@"Results") : L(@"Recent");
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return 56; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"R"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"R"];
        [[SHTheme shared] styleAvatar:cell.imageView radius:5];
    }
    [[SHTheme shared] styleCell:cell];
    SHShareRecipient *r = [self rows][(NSUInteger)indexPath.row];
    cell.textLabel.text = r.title;
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.detailTextLabel.text = r.subtitle;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.textColor = [[SHTheme shared] secondaryTextColor];
    cell.accessoryView = _selected[r.key] ? [[UIImageView alloc] initWithImage:[[SHTheme shared] checkmarkImage]] : nil;
    cell.imageView.image = [[SHTheme shared] avatarPlaceholderWithSize:40];
    NSString *url = r.pictureURL;
    if (url.length) {
        [[SHImageLoader shared] loadImage:url maxPixels:80 completion:^(UIImage *image) {
            NSIndexPath *now = [tableView indexPathForCell:cell];
            NSArray *rows = [self rows];
            if (!image || !now || (NSUInteger)now.row >= rows.count || ![[rows[(NSUInteger)now.row] pictureURL] isEqualToString:url]) return;
            CGFloat scale = image.size.width > 0 ? image.size.width * image.scale / 40.0f : 1;   // shown 40 points wide
            cell.imageView.image = [UIImage imageWithCGImage:image.CGImage scale:scale orientation:UIImageOrientationUp];
            [cell setNeedsLayout];
        }];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_sending) return;
    SHShareRecipient *r = [self rows][(NSUInteger)indexPath.row];
    if (_selected[r.key]) {
        [_selected removeObjectForKey:r.key];
        for (SHShareRecipient *o in [_order copy]) if ([o.key isEqualToString:r.key]) [_order removeObject:o];
    } else {
        _selected[r.key] = r;
        [_order addObject:r];
    }
    [tableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
    self.navigationItem.rightBarButtonItem.enabled = _order.count > 0;
    self.navigationItem.rightBarButtonItem.title = _order.count > 1 ? [NSString stringWithFormat:@"%@ (%lu)", L(@"Send"), (unsigned long)_order.count] : L(@"Send");
}

#pragma mark - Sending

- (void)cancelTapped
{
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)sendTapped
{
    if (_sending || !_order.count) return;
    [self.view endEditing:YES];
    _sending = YES;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [spinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
    NSString *message = [_messageField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self sendTo:0 message:message failures:0 lastError:nil];
}

// One person after the other, a moment apart (as a person ticks and sends): the post, then the message if any.
- (void)sendTo:(NSUInteger)i message:(NSString *)message failures:(NSUInteger)failures lastError:(NSError *)lastError
{
    if (i >= _order.count) { [self finishedWithFailures:failures error:lastError]; return; }
    SHShareRecipient *r = _order[i];
    void (^next)(BOOL, NSError *) = ^(BOOL ok, NSError *error) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self sendTo:i + 1 message:message failures:failures + (ok ? 0 : 1) lastError:ok ? lastError : error];
        });
    };
    [SHInstagram sharePost:_post toThread:r.threadId orUser:r.userPk completion:^(BOOL ok, NSString *threadId, NSError *error) {
        if (!ok || !message.length) { next(ok, error); return; }
        [SHInstagram sendDirectText:message toThread:threadId orUser:threadId.length ? nil : r.userPk
                         completion:^(BOOL ok2, NSString *thread2, NSError *error2) { next(ok2, error2); }];
    }];
}

- (void)finishedWithFailures:(NSUInteger)failures error:(NSError *)error
{
    _sending = NO;
    if (!failures) {
        [self dismissViewControllerAnimated:YES completion:^{ [SHShareViewController flashMessage:L(@"Sent")]; }];
        return;
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Send") style:UIBarButtonItemStyleDone
                                                                             target:self action:@selector(sendTapped)];
    [SHUtils alertWithTitle:L(@"Send to") message:error.localizedDescription ?: L(@"The post didn't send.")];
}

#pragma mark - Outside the app

- (void)copyTapped
{
    NSURL *url = [SHShareViewController webURLForPost:_post];
    if (!url) return;
    [UIPasteboard generalPasteboard].string = url.absoluteString;
    [SHShareViewController flashMessage:L(@"Link copied")];
}

- (void)moreTapped:(UIButton *)button
{
    NSURL *url = [SHShareViewController webURLForPost:_post];
    if (!url) return;
    if (SHModernIOS()) { [SHExternalOpen presentShareSheetForURL:url from:self anchor:button]; return; }
    // iOS 6: the system's own sheet (Mail, Messages, Twitter, Facebook, Copy); in a popover on the iPad
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[ url ] applicationActivities:nil];
    if (SHIsPad()) {
        _popover = [[UIPopoverController alloc] initWithContentViewController:activity];
        __weak SHShareViewController *weakSelf = self;
        activity.completionHandler = ^(NSString *activityType, BOOL completed) {
            [weakSelf.popover dismissPopoverAnimated:YES];
            weakSelf.popover = nil;
        };
        [_popover presentPopoverFromRect:button.bounds inView:button permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
        return;
    }
    [self presentViewController:activity animated:YES completion:nil];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
