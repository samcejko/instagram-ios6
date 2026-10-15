#import "SHChallengeFlow.h"
#import "SHInstagram.h"
#import "SHUtils.h"
#import "SHCommon.h"

#define SH_ALERT_CODE   300
#define SH_ALERT_REVIEW 301

static SHChallengeFlow *g_flow = nil;   // the running flow keeps itself alive while its alerts are up

@interface SHChallengeFlow () <UIAlertViewDelegate, UIActionSheetDelegate>
@property (nonatomic, weak) UIView *view;
@property (nonatomic, copy) void (^completion)(BOOL passed, NSError *error);
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic) NSInteger hops;        // steps taken, so a checkpoint that never closes cannot loop
@property (nonatomic) BOOL acknowledged;     // the blind "choice 0" was tried once
@end

@implementation SHChallengeFlow

+ (BOOL)isRunning { return g_flow != nil; }

+ (void)startInView:(UIView *)view completion:(void (^)(BOOL passed, NSError *error))completion
{
    if (g_flow) { if (completion) completion(NO, nil); return; }
    SHChallengeFlow *flow = [[SHChallengeFlow alloc] init];
    flow.view = view;
    flow.completion = completion;
    g_flow = flow;
    [flow fetchStep];
}

- (void)finish:(BOOL)passed error:(NSError *)error
{
    void (^completion)(BOOL, NSError *) = self.completion;
    self.completion = nil;
    [_task cancel];
    if (g_flow == self) g_flow = nil;
    if (completion) completion(passed, error);
}

- (void)fetchStep
{
    [_task cancel];
    _task = [SHInstagram challengeFetchWithCompletion:^(NSString *stepName, BOOL needsMethodChoice, NSError *error) {
        if (error) { [self finish:NO error:error]; return; }
        [self handleStep:stepName];
    }];
}

// Instagram names the step; unknown ones (an unusual-activity notice, a "review" page) take a plain "choice 0"
// acknowledgement, which closes most of them. What that does not close must be finished on instagram.com.
- (void)handleStep:(NSString *)step
{
    SHLog(@"Challenge step: %@", step.length ? step : @"(none)");
    if (++_hops > 6) { [self finish:NO error:SHMakeError(SHErrorAPI, L(@"Instagram still asks for a check it can't do here. Confirm it in the Instagram app or on instagram.com, then try again."))]; return; }
    if ([step isEqualToString:@"close"]) { [self finish:YES error:nil]; return; }
    if ([step isEqualToString:@"select_verify_method"]) { [self askVerifyMethod]; return; }
    if ([step hasPrefix:@"verify_"] || [step isEqualToString:@"submit_code"]) { [self promptForCode]; return; }
    if ([step isEqualToString:@"delta_login_review"] || [step isEqualToString:@"login_review"]) { [self askLoginReview]; return; }
    if (!_acknowledged) { _acknowledged = YES; [self postChoice:0]; return; }
    [self finish:NO error:SHMakeError(SHErrorAPI, L(@"Instagram still asks for a check it can't do here. Confirm it in the Instagram app or on instagram.com, then try again."))];
}

- (void)postChoice:(NSInteger)choice
{
    [_task cancel];
    _task = [SHInstagram challengeSelectMethod:choice completion:^(NSString *stepName, BOOL needsMethodChoice, NSError *error) {
        if (error) { [self finish:NO error:error]; return; }
        [self handleStep:stepName];
    }];
}

- (void)askVerifyMethod
{
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:L(@"Where should we send the code?")
        delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    [sheet addButtonWithTitle:L(@"Email")];
    [sheet addButtonWithTitle:L(@"Text message")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    UIView *v = self.view ?: [UIApplication sharedApplication].keyWindow;
    [sheet showInView:v];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == actionSheet.cancelButtonIndex) { [self finish:NO error:nil]; return; }
    [self postChoice:buttonIndex == 0 ? 1 : 0];   // 1 = e-mail, 0 = SMS
}

- (void)askLoginReview
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Verify it's you") message:L(@"Was this you?")
                                                   delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"It was me"), nil];
    alert.tag = SH_ALERT_REVIEW;
    [alert show];
}

- (void)promptForCode
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Verify it's you")
        message:L(@"Enter the code Instagram sent to your email or phone.")
        delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"Verify"), nil];
    alert.tag = SH_ALERT_CODE;
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    UITextField *tf = [alert textFieldAtIndex:0];
    tf.keyboardType = UIKeyboardTypeNumberPad;
    tf.placeholder = L(@"Code");
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == alertView.cancelButtonIndex) { [self finish:NO error:nil]; return; }
    if (alertView.tag == SH_ALERT_REVIEW) { [self postChoice:0]; return; }
    NSString *code = [[alertView textFieldAtIndex:0] text];
    if (!code.length) { [self promptForCode]; return; }
    [_task cancel];
    _task = [SHInstagram challengeSubmitCode:code completion:^(SHUser *user, NSError *error) {
        if (error) {
            [SHUtils alertWithTitle:L(@"Verify it's you") message:error.localizedDescription];
            [self promptForCode];
            return;
        }
        SHLog(@"Challenge passed");
        [self finish:YES error:nil];
    }];
}

@end
