#import "SHLoginViewController.h"
#import "SHChallengeFlow.h"
#import "SHInstagram.h"
#import "SHSettings.h"
#import "SHAppDelegate.h"
#import "SHTheme.h"
#import "SHUtils.h"
#import "SHCommon.h"

#define SH_ALERT_2FA 100

@interface SHLoginViewController () <UITextFieldDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UITextField *usernameField;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UIButton *loginButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic, strong) SHLoginStep *step;   // the code Instagram asked for, while its alert is up
@end

@implementation SHLoginViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    SHTheme *theme = [SHTheme shared];
    self.view.backgroundColor = [theme linenColor];

    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_scrollView];

    CGFloat w = MIN(self.view.bounds.size.width - 60, 320);
    CGFloat x = (self.view.bounds.size.width - w) / 2;
    CGFloat y = SHIsPad() ? 110 : 60;

    // the name in script lettering, pressed into the linen
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(x - 20, y, w + 40, 70)];
    title.text = @"Gramify";
    title.font = [theme logoFontOfSize:56];
    title.textColor = [theme textColor];
    title.backgroundColor = [UIColor clearColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [theme embossLabel:title];
    [_scrollView addSubview:title];
    y += 76;

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 22)];
    subtitle.text = L(@"Sign in with your Instagram account");
    subtitle.font = [UIFont boldSystemFontOfSize:14];
    subtitle.textColor = [theme secondaryTextColor];
    subtitle.backgroundColor = [UIColor clearColor];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [theme embossLabel:subtitle];
    [_scrollView addSubview:subtitle];
    y += 38;

    // both fields in one rounded group, an etched line between them (a grouped table of iOS 6)
    UIImageView *group = [[UIImageView alloc] initWithImage:[theme cardBackgroundImage]];
    group.frame = CGRectMake(x, y, w, 88);
    group.userInteractionEnabled = YES;
    group.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    [_scrollView addSubview:group];
    UIView *etchDark = [[UIView alloc] initWithFrame:CGRectMake(1, 43, w - 2, 1)];
    etchDark.backgroundColor = [UIColor colorWithWhite:0 alpha:theme.isDark ? 0.6 : 0.15];
    [group addSubview:etchDark];
    UIView *etchLight = [[UIView alloc] initWithFrame:CGRectMake(1, 44, w - 2, 1)];
    etchLight.backgroundColor = [UIColor colorWithWhite:1 alpha:theme.isDark ? 0.07 : 0.9];
    [group addSubview:etchLight];

    _usernameField = [self fieldWithFrame:CGRectMake(12, 2, w - 24, 40) placeholder:L(@"Username")];
    _usernameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _usernameField.autocorrectionType = UITextAutocorrectionTypeNo;
    _usernameField.returnKeyType = UIReturnKeyNext;
    [group addSubview:_usernameField];

    _passwordField = [self fieldWithFrame:CGRectMake(12, 46, w - 24, 40) placeholder:L(@"Password")];
    _passwordField.secureTextEntry = YES;
    _passwordField.returnKeyType = UIReturnKeyGo;
    [group addSubview:_passwordField];
    y += 88 + 18;

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

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[theme spinnerStyle]];
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
    SHTheme *theme = [SHTheme shared];
    UITextField *f = [[UITextField alloc] initWithFrame:frame];
    f.placeholder = placeholder;
    f.borderStyle = UITextBorderStyleNone;   // (the rounded group around both is the field's frame)
    f.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    f.font = [UIFont systemFontOfSize:16];
    f.textColor = [theme inputTextColor];
    f.keyboardAppearance = theme.isDark ? UIKeyboardAppearanceAlert : UIKeyboardAppearanceDefault;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.delegate = self;
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
    _task = [SHInstagram loginWithUsername:user password:pass completion:^(SHLoginStep *step, NSError *error) {
        [self setLoading:NO];
        if (step) { [self askForCode:step problem:nil]; return; }
        [self finishSignIn:error];
    }];
}

// After the password (or the code): the app with the session, the security check, or why not. Never the app
// without a session (it used to open with every screen saying "Your session expired").
- (void)finishSignIn:(NSError *)error
{
    if (error) {
        if (error.code == SHErrorChallenge) { [self startChallenge:error]; return; }
        [SHUtils alertWithTitle:L(@"Log In") message:error.localizedDescription];
        return;
    }
    if (![SHSettings isLoggedIn]) {
        [SHUtils alertWithTitle:L(@"Log In") message:L(@"Couldn't sign in. Please try again.")];
        return;
    }
    SHLog(@"Logged in as %@", [SHSettings username]);
    [[SHAppDelegate shared] showFeed];
}

// The code Instagram asked for: from the authenticator app, a text message, or the one that confirms a new device.
// `problem`: why the last code did not do (one alert says both; iOS 6 would stack two the wrong way round).
- (void)askForCode:(SHLoginStep *)step problem:(NSString *)problem
{
    self.step = step;
    NSString *title = step.kind == SHLoginStepNewDevice ? L(@"Verify it's you") : L(@"Two-Factor Authentication");
    NSString *message;
    if (step.kind == SHLoginStepNewDevice)
        message = L(@"Instagram sent a code to confirm this sign-in, by e-mail or text message. Enter it here.");
    else if (step.kind == SHLoginStepTwoFactor && [step.method isEqualToString:@"sms"])
        message = L(@"Enter the code Instagram sent you by text message.");
    else if (step.kind == SHLoginStepTwoFactor)
        message = L(@"Enter the code from your authenticator app.");
    else
        message = L(@"Enter the code from your authenticator app or SMS.");
    if (problem.length) message = [NSString stringWithFormat:@"%@\n\n%@", problem, message];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:self
                                          cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Verify"), nil];
    alert.tag = SH_ALERT_2FA;
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *tf = [alert textFieldAtIndex:0];
    tf.keyboardType = UIKeyboardTypeNumberPad;
    tf.placeholder = L(@"Code");
    [alert show];
}

#pragma mark - Challenge (checkpoint) flow

- (void)startChallenge:(NSError *)challengeError
{
    [self setLoading:YES];
    [SHChallengeFlow startInView:self.view completion:^(BOOL passed, NSError *error) {
        [self setLoading:NO];
        if (passed) {
            SHLog(@"Challenge passed, signed in");
            if ([SHSettings isLoggedIn]) [[SHAppDelegate shared] showFeed];
            else [SHUtils alertWithTitle:L(@"Verify it's you") message:L(@"Verified. Please log in again.")];
            return;
        }
        // Even when the steps could not be walked, say what is going on rather than nothing.
        if (error) [SHUtils alertWithTitle:L(@"Verify it's you") message:error.localizedDescription ?: challengeError.localizedDescription];
    }];
}

#pragma mark - 2FA UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView.tag != SH_ALERT_2FA) return;
    SHLoginStep *step = self.step;
    if (buttonIndex == alertView.cancelButtonIndex || !step) { self.step = nil; return; }
    NSString *code = [[alertView textFieldAtIndex:0] text];
    if (!code.length) { [self askForCode:step problem:nil]; return; }
    [self setLoading:YES];
    [_task cancel];
    _task = [SHInstagram finishLoginStep:step code:code completion:^(NSError *error) {
        [self setLoading:NO];
        if (error.code == SHErrorAPI || (error.code >= 400 && error.code < 500)) {
            // a code that did not do: the step stays usable, the code once more (a typo, or a code that came late)
            [self askForCode:step problem:error.localizedDescription];
            return;
        }
        self.step = nil;
        [self finishSignIn:error];
    }];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orient
{
    return SHIsPad() || orient == UIInterfaceOrientationPortrait;
}

@end
