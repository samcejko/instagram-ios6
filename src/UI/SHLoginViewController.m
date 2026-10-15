#import "SHLoginViewController.h"
#import "SHInstagram.h"
#import "SHSettings.h"
#import "SHAppDelegate.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

#define SH_ALERT_2FA 100
#define SH_ALERT_CHALLENGE 200

@interface SHLoginViewController () <UITextFieldDelegate, UIAlertViewDelegate, UIActionSheetDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField *usernameField;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UIButton *loginButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic, copy) NSString *twoFactorId;
@end

@implementation SHLoginViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [[SHTheme shared] backgroundColor];

    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_scrollView];

    CGFloat w = MIN(self.view.bounds.size.width - 60, 320);
    CGFloat x = (self.view.bounds.size.width - w) / 2;
    CGFloat y = SHIsPad() ? 120 : 80;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 40)];
    title.text = @"Gramify";
    title.font = [UIFont boldSystemFontOfSize:28];
    title.textColor = [[SHTheme shared] textColor];
    title.backgroundColor = [UIColor clearColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [_scrollView addSubview:title];
    y += 50;

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 22)];
    subtitle.text = L(@"Sign in with your Instagram account");
    subtitle.font = [UIFont systemFontOfSize:14];
    subtitle.textColor = [[SHTheme shared] secondaryTextColor];
    subtitle.backgroundColor = [UIColor clearColor];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [_scrollView addSubview:subtitle];
    y += 40;

    _usernameField = [self fieldWithFrame:CGRectMake(x, y, w, 38) placeholder:L(@"Username")];
    _usernameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _usernameField.autocorrectionType = UITextAutocorrectionTypeNo;
    _usernameField.returnKeyType = UIReturnKeyNext;
    [_scrollView addSubview:_usernameField];
    y += 48;

    _passwordField = [self fieldWithFrame:CGRectMake(x, y, w, 38) placeholder:L(@"Password")];
    _passwordField.secureTextEntry = YES;
    _passwordField.returnKeyType = UIReturnKeyGo;
    [_scrollView addSubview:_passwordField];
    y += 58;

    _loginButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _loginButton.frame = CGRectMake(x, y, w, 42);
    _loginButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [_loginButton setTitle:L(@"Log In") forState:UIControlStateNormal];
    [_loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _loginButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    // the glossy iOS 6 capsule button from the theme instead of a flat fill
    [_loginButton setBackgroundImage:[[SHTheme shared] accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
    [_loginButton setBackgroundImage:[[SHTheme shared] accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
    [_loginButton setBackgroundImage:[[SHTheme shared] accentButtonImageHighlighted:NO disabled:YES] forState:UIControlStateDisabled];
    [[SHTheme shared] embossButton:_loginButton];
    [_loginButton addTarget:self action:@selector(loginTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:_loginButton];
    y += 52;

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    _spinner.center = CGPointMake(x + w / 2, y + 10);
    _spinner.hidesWhenStopped = YES;
    _spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [_scrollView addSubview:_spinner];
    y += 30;

    _scrollView.contentSize = CGSizeMake(self.view.bounds.size.width, y + 40);

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (UITextField *)fieldWithFrame:(CGRect)frame placeholder:(NSString *)placeholder
{
    UITextField *f = [[UITextField alloc] initWithFrame:frame];
    f.placeholder = placeholder;
    f.borderStyle = UITextBorderStyleRoundedRect;
    f.font = [UIFont systemFontOfSize:15];
    f.delegate = self;
    f.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    return f;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_task cancel];
}

#pragma mark - Keyboard

- (void)keyboardWillShow:(NSNotification *)note
{
    CGRect kbFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    _scrollView.contentInset = UIEdgeInsetsMake(0, 0, kbFrame.size.height, 0);
}

- (void)keyboardWillHide:(NSNotification *)note
{
    _scrollView.contentInset = UIEdgeInsetsZero;
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    if (textField == _usernameField) { [_passwordField becomeFirstResponder]; return YES; }
    if (textField == _passwordField) { [self loginTapped]; return YES; }
    return YES;
}

#pragma mark - Login

- (void)setLoading:(BOOL)loading
{
    _loginButton.enabled = !loading;
    _loginButton.alpha = loading ? 0.5 : 1.0;
    loading ? [_spinner startAnimating] : [_spinner stopAnimating];
}

- (void)loginTapped
{
    NSString *user = [_usernameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *pass = _passwordField.text ?: @"";
    if (!user.length || !pass.length) {
        [SHUtils alertWithTitle:L(@"Log In") message:L(@"Enter your username and password.")];
        return;
    }
    [self.view endEditing:YES];
    [self setLoading:YES];
    [_task cancel];
    _task = [SHInstagram loginWithUsername:user password:pass completion:^(SHUser *loggedIn, NSString *twoFactorId, NSError *error) {
        [self setLoading:NO];
        if (twoFactorId.length) {
            self.twoFactorId = twoFactorId;
            [SHSettings setUsername:user];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Two-Factor Authentication")
                                                            message:L(@"Enter the code from your authenticator app or SMS.")
                                                           delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Verify"), nil];
            alert.tag = SH_ALERT_2FA;
            alert.alertViewStyle = UIAlertViewStylePlainTextInput;
            UITextField *tf = [alert textFieldAtIndex:0];
            tf.keyboardType = UIKeyboardTypeNumberPad;
            tf.placeholder = L(@"Code");
            [alert show];
            return;
        }
        if (error) {
            if (error.code == SHErrorChallenge) { [self startChallenge:error]; return; }
            [SHUtils alertWithTitle:L(@"Log In") message:error.localizedDescription];
            return;
        }
        SHLog(@"Logged in as %@", loggedIn.username);
        [[SHAppDelegate shared] showFeed];
    }];
}

#pragma mark - Challenge (checkpoint) flow

- (void)startChallenge:(NSError *)challengeError
{
    [self setLoading:YES];
    [_task cancel];
    _task = [SHInstagram challengeFetchWithCompletion:^(NSString *stepName, BOOL needsMethodChoice, NSError *error) {
        [self setLoading:NO];
        if (error) {
            // Even if fetching the step failed, tell the user what is going on rather than nothing.
            [SHUtils alertWithTitle:L(@"Verify it's you") message:challengeError.localizedDescription];
            return;
        }
        if (needsMethodChoice) [self askVerifyMethod];
        else [self promptForCode];
    }];
}

- (void)askVerifyMethod
{
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:L(@"Where should we send the code?")
        delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    [sheet addButtonWithTitle:L(@"Email")];
    [sheet addButtonWithTitle:L(@"Text message")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    NSInteger choice = buttonIndex == 0 ? 1 : 0;   // 1 = email, 0 = SMS
    [self setLoading:YES];
    [_task cancel];
    _task = [SHInstagram challengeSelectMethod:choice completion:^(NSString *stepName, BOOL needsMethodChoice, NSError *error) {
        [self setLoading:NO];
        if (error) { [SHUtils alertWithTitle:L(@"Verify it's you") message:error.localizedDescription]; return; }
        [self promptForCode];
    }];
}

- (void)promptForCode
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Verify it's you")
        message:L(@"Enter the code Instagram sent to your email or phone.")
        delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Verify"), nil];
    alert.tag = SH_ALERT_CHALLENGE;
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *tf = [alert textFieldAtIndex:0];
    tf.keyboardType = UIKeyboardTypeNumberPad;
    tf.placeholder = L(@"Code");
    [alert show];
}

#pragma mark - 2FA UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) return;
    NSString *code = [[alertView textFieldAtIndex:0] text];
    if (!code.length) return;
    [self setLoading:YES];
    [_task cancel];
    if (alertView.tag == SH_ALERT_CHALLENGE) {
        _task = [SHInstagram challengeSubmitCode:code completion:^(SHUser *user, NSError *error) {
            [self setLoading:NO];
            if (error) { [SHUtils alertWithTitle:L(@"Verify it's you") message:error.localizedDescription]; [self promptForCode]; return; }
            SHLog(@"Challenge passed, signed in");
            [[SHAppDelegate shared] showFeed];
        }];
        return;
    }
    _task = [SHInstagram twoFactorLoginWithIdentifier:_twoFactorId code:code completion:^(SHUser *user, NSError *error) {
        [self setLoading:NO];
        if (error) { [SHUtils alertWithTitle:L(@"Two-Factor Authentication") message:error.localizedDescription]; return; }
        SHLog(@"2FA ok, logged in as %@", user.username);
        [[SHAppDelegate shared] showFeed];
    }];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
