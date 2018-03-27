//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSScreenLockUI.h"
#import "Signal-Swift.h"
#import <SignalMessaging/SignalMessaging-Swift.h>
#import <SignalMessaging/UIView+OWS.h>

NS_ASSUME_NONNULL_BEGIN

@interface OWSScreenLockUI ()

@property (nonatomic) UIWindow *screenBlockingWindow;
@property (nonatomic) UIViewController *screenBlockingViewController;

// Unlike UIApplication.applicationState, this state is
// updated conservatively, e.g. the flag is cleared during
// "will enter background."
@property (nonatomic) BOOL appIsInactive;
@property (nonatomic) BOOL appIsInBackground;

@property (nonatomic) BOOL isShowingScreenLockUI;
@property (nonatomic) BOOL didLastUnlockAttemptFail;

// We want to remain in "screen lock" mode while "local auth"
// UI is dismissing.
@property (nonatomic) BOOL shouldClearAuthUIWhenActive;

@property (nonatomic, nullable) NSTimer *screenLockUITimer;

@property (nonatomic, nullable) NSDate *appEnteredBackgroundDate;
@property (nonatomic, nullable) NSDate *appEnteredForegroundDate;
@property (nonatomic, nullable) NSDate *lastUnlockAttemptDate;
@property (nonatomic, nullable) NSDate *lastUnlockSuccessDate;

@end

#pragma mark -

@implementation OWSScreenLockUI

+ (instancetype)sharedManager
{
    static OWSScreenLockUI *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initDefault];
    });
    return instance;
}

- (instancetype)initDefault
{
    self = [super init];

    if (!self) {
        return self;
    }

    [self observeNotifications];

    OWSSingletonAssert();

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)observeNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:OWSApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:OWSApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:OWSApplicationWillEnterForegroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:OWSApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(registrationStateDidChange)
                                                 name:RegistrationStateDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenLockDidChange:)
                                                 name:OWSScreenLock.ScreenLockDidChange
                                               object:nil];
}

- (void)setupWithRootWindow:(UIWindow *)rootWindow
{
    OWSAssertIsOnMainThread();
    OWSAssert(rootWindow);

    [self prepareScreenProtectionWithRootWindow:rootWindow];

    [AppReadiness runNowOrWhenAppIsReady:^{
        [self ensureScreenProtection];
    }];
}

#pragma mark - Methods

- (void)setAppIsInactive:(BOOL)appIsInactive
{
    _appIsInactive = appIsInactive;

    [self ensureScreenProtection];
}

- (void)setAppIsInBackground:(BOOL)appIsInBackground
{
    if (appIsInBackground) {
        if (!_appIsInBackground) {
            // Record the time when app entered background.
            self.appEnteredBackgroundDate = [NSDate new];

            self.didLastUnlockAttemptFail = NO;
        }
    }

    _appIsInBackground = appIsInBackground;

    [self ensureScreenProtection];
}

- (void)ensureScreenProtection
{
    OWSAssertIsOnMainThread();

    if (!AppReadiness.isAppReady) {
        [AppReadiness runNowOrWhenAppIsReady:^{
            [self ensureScreenProtection];
        }];
        return;
    }

    BOOL shouldHaveScreenLock = self.shouldHaveScreenLock;
    BOOL shouldHaveScreenProtection = self.shouldHaveScreenProtection;

    BOOL shouldShowBlockWindow = shouldHaveScreenProtection || shouldHaveScreenLock;
    DDLogVerbose(@"%@, shouldHaveScreenProtection: %d, shouldHaveScreenLock: %d, shouldShowBlockWindow: %d",
        self.logTag,
        shouldHaveScreenProtection,
        shouldHaveScreenLock,
        shouldShowBlockWindow);
    if (self.screenBlockingWindow.hidden != !shouldShowBlockWindow) {
        DDLogInfo(@"%@, %@.", self.logTag, shouldShowBlockWindow ? @"showing block window" : @"hiding block window");
    }
    [self updateScreenBlockingWindow:shouldShowBlockWindow shouldHaveScreenLock:shouldHaveScreenLock];

    [self.screenLockUITimer invalidate];
    self.screenLockUITimer = nil;

    if (shouldHaveScreenLock && !self.didLastUnlockAttemptFail) {
        [self tryToPresentScreenLockUI];
    }
}

- (void)tryToPresentScreenLockUI
{
    OWSAssertIsOnMainThread();

    [self.screenLockUITimer invalidate];
    self.screenLockUITimer = nil;

    // If we no longer want to present the screen lock UI, abort.
    if (!self.shouldHaveScreenLock) {
        return;
    }
    if (self.didLastUnlockAttemptFail) {
        return;
    }
    if (self.isShowingScreenLockUI) {
        return;
    }

    DDLogInfo(@"%@, try to unlock screen lock", self.logTag);

    self.isShowingScreenLockUI = YES;
    self.lastUnlockAttemptDate = [NSDate new];

    [OWSScreenLock.sharedManager tryToUnlockScreenLockWithSuccess:^{
        DDLogInfo(@"%@ unlock screen lock succeeded.", self.logTag);
        self.isShowingScreenLockUI = NO;
        self.lastUnlockSuccessDate = [NSDate new];
        [self ensureScreenProtection];
    }
        failure:^(NSError *error) {
            DDLogInfo(@"%@ unlock screen lock failed.", self.logTag);

            [self clearAuthUIWhenActive];

            self.didLastUnlockAttemptFail = YES;

            [self showScreenLockFailureAlertWithMessage:error.localizedDescription];
        }
        cancel:^{
            DDLogInfo(@"%@ unlock screen lock cancelled.", self.logTag);

            [self clearAuthUIWhenActive];

            self.didLastUnlockAttemptFail = YES;

            // Re-show the unlock UI.
            [self ensureScreenProtection];
        }];
}

- (BOOL)shouldHaveScreenProtection
{
    // Show 'Screen Protection' if:
    //
    // * App is inactive and...
    // * 'Screen Protection' is enabled.
    if (!self.appIsInactive) {
        return NO;
    } else if (!Environment.preferences.screenSecurityIsEnabled) {
        return NO;
    } else {
        return YES;
    }
}

- (BOOL)hasUnlockedScreenLock
{
    if (!self.lastUnlockSuccessDate) {
        return NO;
    } else if (!self.appEnteredBackgroundDate) {
        return YES;
    } else {
        return [self.lastUnlockSuccessDate isAfterDate:self.appEnteredBackgroundDate];
    }
}

- (BOOL)shouldHaveScreenLock
{
    if (![TSAccountManager isRegistered]) {
        // Don't show 'Screen Lock' if user is not registered.
        DDLogVerbose(@"%@ shouldHaveScreenLock NO 1.", self.logTag);
        return NO;
    } else if (!OWSScreenLock.sharedManager.isScreenLockEnabled) {
        // Don't show 'Screen Lock' if 'Screen Lock' isn't enabled.
        DDLogVerbose(@"%@ shouldHaveScreenLock NO 2.", self.logTag);
        return NO;
    } else if (self.hasUnlockedScreenLock) {
        // Don't show 'Screen Lock' if 'Screen Lock' has been unlocked.
        DDLogVerbose(@"%@ shouldHaveScreenLock NO 3.", self.logTag);
        return NO;
    } else if (self.appIsInBackground) {
        // Don't show 'Screen Lock' if app is in background.
        DDLogVerbose(@"%@ shouldHaveScreenLock NO 4.", self.logTag);
        return NO;
    } else if (self.isShowingScreenLockUI) {
        // Maintain blocking window in 'screen lock' mode while we're
        // showing the 'Unlock Screen Lock' UI.
        DDLogVerbose(@"%@ shouldHaveScreenLock YES 0.", self.logTag);
        return YES;
    } else if (self.appIsInactive) {
        // Don't show 'Screen Lock' if app is inactive.
        DDLogVerbose(@"%@ shouldHaveScreenLock NO 5.", self.logTag);
        return NO;
    } else if (!self.appEnteredBackgroundDate) {
        // Show 'Screen Lock' if app has just launched.
        DDLogVerbose(@"%@ shouldHaveScreenLock YES 1.", self.logTag);
        return YES;
    } else {
        OWSAssert(self.appEnteredBackgroundDate);

        NSTimeInterval screenLockInterval = fabs([self.appEnteredBackgroundDate timeIntervalSinceNow]);
        NSTimeInterval screenLockTimeout = OWSScreenLock.sharedManager.screenLockTimeout;
        OWSAssert(screenLockInterval >= 0);
        OWSAssert(screenLockTimeout >= 0);
        if (screenLockInterval < screenLockTimeout) {
            // Don't show 'Screen Lock' if 'Screen Lock' timeout hasn't elapsed.
            DDLogVerbose(@"%@ shouldHaveScreenLock NO 6.", self.logTag);
            return NO;
        } else {
            // Otherwise, show 'Screen Lock'.
            DDLogVerbose(@"%@ shouldHaveScreenLock YES 2.", self.logTag);
            return YES;
        }
    }
}

- (void)showScreenLockFailureAlertWithMessage:(NSString *)message
{
    OWSAssertIsOnMainThread();

    [OWSAlerts showAlertWithTitle:NSLocalizedString(@"SCREEN_LOCK_UNLOCK_FAILED",
                                      @"Title for alert indicating that screen lock could not be unlocked.")
                          message:message
                      buttonTitle:nil
                     buttonAction:^(UIAlertAction *action) {
                         // After the alert, re-show the unlock UI.
                         [self ensureScreenProtection];
                     }];
}

// 'Screen Blocking' window obscures the app screen:
//
// * In the app switcher.
// * During 'Screen Lock' unlock process.
- (void)prepareScreenProtectionWithRootWindow:(UIWindow *)rootWindow
{
    OWSAssertIsOnMainThread();
    OWSAssert(rootWindow);

    UIWindow *window = [[UIWindow alloc] initWithFrame:rootWindow.bounds];
    window.hidden = YES;
    window.opaque = YES;
    window.windowLevel = CGFLOAT_MAX;
    window.backgroundColor = UIColor.ows_materialBlueColor;

    UIViewController *viewController = [UIViewController new];
    viewController.view.backgroundColor = UIColor.ows_materialBlueColor;

    window.rootViewController = viewController;

    self.screenBlockingWindow = window;
    self.screenBlockingViewController = viewController;

    [self updateScreenBlockingWindow:YES shouldHaveScreenLock:NO];
}

- (void)updateScreenBlockingWindow:(BOOL)shouldShowBlockWindow shouldHaveScreenLock:(BOOL)shouldHaveScreenLock
{
    OWSAssertIsOnMainThread();

    self.screenBlockingWindow.hidden = !shouldShowBlockWindow;

    UIView *rootView = self.screenBlockingViewController.view;
    for (UIView *subview in rootView.subviews) {
        [subview removeFromSuperview];
    }

    UIView *edgesView = [UIView containerView];
    [rootView addSubview:edgesView];
    [edgesView autoHCenterInSuperview];
    [edgesView autoPinEdgeToSuperviewEdge:ALEdgeTop];
    [edgesView autoPinEdgeToSuperviewEdge:ALEdgeBottom];

    UIView *containerView = [UIView containerView];
    [edgesView addSubview:containerView];
    [containerView autoVCenterInSuperview];
    [containerView autoPinWidthToSuperviewWithMargin:20.f];

    UIImage *image = [UIImage imageNamed:@"logoSignal"];
    UIImageView *imageView = [UIImageView new];
    imageView.image = image;
    [containerView addSubview:imageView];
    [imageView autoPinTopToSuperview];
    [imageView autoHCenterInSuperview];

    const CGSize screenSize = UIScreen.mainScreen.bounds.size;
    const CGFloat shortScreenDimension = MIN(screenSize.width, screenSize.height);
    const CGFloat imageSize = round(shortScreenDimension / 3.f);
    [imageView autoSetDimension:ALDimensionWidth toSize:imageSize];
    [imageView autoSetDimension:ALDimensionHeight toSize:imageSize];

    BOOL shouldShowUnlockButton = (!self.appIsInactive && !self.appIsInBackground && self.didLastUnlockAttemptFail);

    DDLogVerbose(@"%@ updateScreenBlockingWindow. shouldShowBlockWindow: %d, shouldHaveScreenLock: %d, "
                 @"shouldShowUnlockButton: %d.",
        self.logTag,
        shouldShowBlockWindow,
        shouldHaveScreenLock,
        shouldShowUnlockButton);

    if (shouldHaveScreenLock) {
        const CGFloat kButtonHeight = 40.f;
        OWSFlatButton *button =
            [OWSFlatButton buttonWithTitle:NSLocalizedString(@"SCREEN_LOCK_UNLOCK_SIGNAL",
                                               @"Label for button on lock screen that lets users unlock Signal.")
                                      font:[OWSFlatButton fontForHeight:kButtonHeight]
                                titleColor:[UIColor ows_materialBlueColor]
                           backgroundColor:[UIColor whiteColor]
                                    target:self
                                  selector:@selector(showUnlockUI)];
        [containerView addSubview:button];
        [button autoSetDimension:ALDimensionHeight toSize:kButtonHeight];
        const CGFloat kVSpacing = 80.f;
        [button autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:imageView withOffset:kVSpacing];
        // For symmetry, use equal padding below so that "unlock" button is visually centered
        // (under the local auth UI alert) and the Signal logo is moved upwards, not blocked by
        // the local auth UI alert.
        const CGFloat kBottomPadding = imageSize + kVSpacing;
        [button autoPinBottomToSuperviewWithMargin:kBottomPadding];
        [button autoPinLeadingAndTrailingToSuperview];

        button.hidden = !shouldShowUnlockButton;
    } else {
        [imageView autoPinBottomToSuperview];
    }

    [rootView layoutIfNeeded];
}

- (void)showUnlockUI
{
    OWSAssertIsOnMainThread();

    DDLogInfo(@"showUnlockUI");

    self.didLastUnlockAttemptFail = NO;

    [self ensureScreenProtection];
}

#pragma mark - Events

- (void)screenLockDidChange:(NSNotification *)notification
{
    [self ensureScreenProtection];
}

- (void)registrationStateDidChange
{
    OWSAssertIsOnMainThread();

    DDLogInfo(@"registrationStateDidChange");

    [self ensureScreenProtection];
}

- (void)clearAuthUIWhenActive
{
    if (self.appIsInactive) {
        self.shouldClearAuthUIWhenActive = YES;
    } else {
        self.isShowingScreenLockUI = NO;
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    self.appIsInactive = NO;

    if (self.shouldClearAuthUIWhenActive) {
        self.shouldClearAuthUIWhenActive = NO;
        self.isShowingScreenLockUI = NO;
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    self.appIsInactive = YES;
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    // Clear the "delay Screen Lock UI" state; we don't want any
    // delays when presenting the "unlock screen lock UI" after
    // returning from background.
    [self.screenLockUITimer invalidate];
    self.screenLockUITimer = nil;
    self.lastUnlockAttemptDate = nil;
    self.lastUnlockSuccessDate = nil;

    self.appIsInBackground = NO;
    self.appEnteredForegroundDate = [NSDate new];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    self.appIsInBackground = YES;
}

@end

NS_ASSUME_NONNULL_END
