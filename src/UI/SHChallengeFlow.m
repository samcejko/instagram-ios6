#import "SHChallengeFlow.h"
#import "SHInstagram.h"
#import "SHUtils.h"
#import "SHCommon.h"

#define SH_ALERT_CODE   300
#define SH_ALERT_REVIEW 301

static SHChallengeFlow *g_flow = nil;   // the running flow keeps itself alive while its alerts are up

static NSError *SHCannotFinishHere(void)
{
    return SHMakeError(SHErrorAPI, L(@"Instagram still asks for a check it can't do here. Confirm it in the Instagram app or on instagram.com, then try again."));
}

// A value of the step's data, or nil when Instagram left it empty ("None" in some replies).
static NSString *SHStepValue(NSString *key)
{
    NSString *v = SHStr([[SHInstagram challengeStepData] objectForKey:key]);
    return (v.length && ![v isEqualToString:@"None"] && ![v isEqualToString:@"null"]) ? v : nil;
}

@interface SHChallengeFlow () <UIAlertViewDelegate, UIActionSheetDelegate>
@property (nonatomic, weak) UIView *view;
@property (nonatomic, copy) void (^completion)(BOOL passed, NSError *error);
@property (nonatomic, strong) SHHTTPTask *task;
@property (nonatomic) NSInteger hops;                   // steps taken, so a checkpoint that never closes cannot loop
@property (nonatomic) BOOL acknowledged;                // the blind "choice 0" was tried once
@property (nonatomic, strong) NSArray *methodChoices;   // the choice value behind each button of the method sheet
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

// Instagram names the step. Unknown ones (a notice of some kind) take a plain "choice 0" acknowledgement, which
// closes most of them; what that does not close, and what this app cannot answer honestly (a new password, a
// selfie, a birthday), has to be finished in the official app or on instagram.com.
- (void)handleStep:(NSString *)step
{
    SHLog(@"Challenge step: %@ (data: %@)", step.length ? step : @"(none)",
          [[[SHInstagram challengeStepData] allKeys] componentsJoinedByString:@","] ?: @"-");
    if (++_hops > 6) { [self finish:NO error:SHCannotFinishHere()]; return; }
    if ([step isEqualToString:@"close"]) { [self finish:YES error:nil]; return; }
    if ([step isEqualToString:@"select_verify_method"] || [step isEqualToString:@"select_contact_point_recovery"]) { [self askVerifyMethod]; return; }
    if ([step hasPrefix:@"verify_"] || [step isEqualToString:@"submit_code"]) { [self promptForCode]; return; }
    if ([step isEqualToString:@"delta_login_review"] || [step isEqualToString:@"login_review"]) { [self askReview:L(@"Was this you?")]; return; }
    if ([step isEqualToString:@"scraping_warning"]) {
        [self askReview:L(@"Instagram noticed unusual activity on this account. Confirm that it was you to continue.")];
        return;
    }
    if ([@[ @"change_password", @"selfie_captcha", @"add_birthday", @"captcha" ] containsObject:step]) { [self finish:NO error:SHCannotFinishHere()]; return; }
    if (!_acknowledged) { _acknowledged = YES; [self postChoice:0]; return; }
    [self finish:NO error:SHCannotFinishHere()];
}

- (void)postChoice:(NSInteger)choice
{
    [_task cancel];
    _task = [SHInstagram challengeSelectMethod:choice completion:^(NSString *stepName, BOOL needsMethodChoice, NSError *error) {
        if (error) { [self finish:NO error:error]; return; }
        [self handleStep:stepName];
    }];
}

// Offers what the account has, with the masked address Instagram shows ("s****@g****.com", "+420 *** *** *12").
- (void)askVerifyMethod
{
    NSString *email = SHStepValue(@"email"), *phone = SHStepValue(@"phone_number");
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:L(@"Where should we send the code?")
        delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    NSMutableArray *choices = [NSMutableArray array];
    if (email.length || !phone.length) {
        [sheet addButtonWithTitle:email.length ? [NSString stringWithFormat:@"%@ (%@)", L(@"Email"), email] : L(@"Email")];
        [choices addObject:@1];
    }
    if (phone.length || !email.length) {
        [sheet addButtonWithTitle:phone.length ? [NSString stringWithFormat:@"%@ (%@)", L(@"Text message"), phone] : L(@"Text message")];
        [choices addObject:@0];
    }
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Cancel")];
    _methodChoices = choices;
    UIView *v = self.view ?: [UIApplication sharedApplication].keyWindow;
    [sheet showInView:v];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == actionSheet.cancelButtonIndex || buttonIndex < 0 || (NSUInteger)buttonIndex >= _methodChoices.count) {
        [self finish:NO error:nil];
        return;
    }
    [self postChoice:[[_methodChoices objectAtIndex:(NSUInteger)buttonIndex] integerValue]];   // 1 = e-mail, 0 = SMS
}

- (void)askReview:(NSString *)message
{
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Verify it's you") message:message
                                                   delegate:self cancelButtonTitle:L(@"Cancel") otherButtonTitles:L(@"It was me"), nil];
    alert.tag = SH_ALERT_REVIEW;
    [alert show];
}

- (void)promptForCode
{
    NSString *contact = SHStepValue(@"contact_point");
    NSString *message = contact.length ? [NSString stringWithFormat:L(@"Enter the code Instagram sent to %@."), contact]
                                       : L(@"Enter the code Instagram sent to your email or phone.");
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:L(@"Verify it's you") message:message
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
