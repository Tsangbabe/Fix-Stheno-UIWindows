/*
 * FixSthenoUIWindows.m
 *
 * SpringBoard-only verification candidate for the Stheno/SquidExtender
 * hosted-keyboard overlap on iOS 15.4.1.
 *
 * This candidate does not change UIKit keyboard geometry, window ordering,
 * clipping, key-window state, or hit testing.  It only attempts
 * the evidence-backed KeyboardArbiter host-PID transition when all runtime
 * identity and ABI gates pass.  Every external host transition is balanced.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif
void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *old);
#ifdef __cplusplus
}
#endif

static NSString * const SXDArbiterClassName =
    @"_UIKeyboardArbiter_ForSpringBoard";
static NSString * const SXDArbiterLaunchSelectorName =
    @"launchAdvisorWithOmniscientDelegate:";
static NSString * const SXDArbiterOwnerSelectorName = @"owner";
static NSString * const SXDArbiterHandlerSelectorName = @"handlerForPID:";
static NSString * const SXDArbiterHostSelectorName =
    @"setWindowHostingPID:active:";
static NSString * const SXDProcessIdentifierSelectorName =
    @"processIdentifier";

static NSString * const SXDSthenoWindowName = @"Stheno.SthenoWindow";
static NSString * const SXDKeyboardHostViewName = @"_UIKeyboardLayerHostView";
static NSString * const SXDContextHostViewName = @"_UIContextLayerHostView";
static NSString * const SXDExternalHostViewName =
    @"_UIExternalSceneLayerHostView";
static NSString * const SXDPanelWindowName = @"SGPanelWindow";
static NSString * const SXDLecardWindowSuffix = @"LecardWindow";

static NSString * const SXDLaunchAdvisorEncoding = @"@24@0:8@16";
static NSString * const SXDOwnerEncoding = @"@16@0:8";
static NSString * const SXDHandlerEncoding = @"@20@0:8i16";
static NSString * const SXDHostEncoding = @"v24@0:8i16B20";

static id SXDAdvisor = nil;
static id SXDActiveHandle = nil;
static int SXDActivePID = 0;
static BOOL SXDArbiterHookInstalled = NO;
static BOOL SXDTimerStarted = NO;

static id (*SXDOriginalLaunchAdvisor)(id, SEL, id) = NULL;

static BOOL SXDIsMainThread(void) {
    return [NSThread isMainThread];
}

static BOOL SXDIsSpringBoardProcess(void) {
    NSString *name = [NSProcessInfo processInfo].processName.lowercaseString;
    return [name containsString:@"springboard"];
}

static BOOL SXDEncodingMatches(Method method, NSString *expected) {
    if (!method || expected.length == 0) {
        return NO;
    }
    const char *encoding = method_getTypeEncoding(method);
    return encoding != NULL && [expected isEqualToString:@(encoding)];
}

static Method SXDInstanceMethod(id object, SEL selector, NSString *encoding) {
    if (!object || !selector) {
        return NULL;
    }
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || !SXDEncodingMatches(method, encoding)) {
        return NULL;
    }
    return method;
}

static BOOL SXDClassMethodEncoding(Class cls, SEL selector, NSString *encoding) {
    if (!cls || !selector || encoding.length == 0) {
        return NO;
    }
    Method method = class_getClassMethod(cls, selector);
    return SXDEncodingMatches(method, encoding);
}

static id SXDCallObject(id receiver, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static int SXDProcessIDFromObject(id object) {
    if (!object) {
        return 0;
    }

    SEL selectors[] = {
        sel_registerName("pid"),
        sel_registerName("processIdentifier"),
        sel_registerName("processID"),
    };
    const char *encodings[] = { "i16@0:8", "q16@0:8", "i16@0:8" };
    for (NSUInteger index = 0; index < sizeof(selectors) / sizeof(selectors[0]); index++) {
        Method method = class_getInstanceMethod(object_getClass(object), selectors[index]);
        if (!method || !SXDEncodingMatches(method, @(encodings[index]))) {
            continue;
        }
        @try {
            if (encodings[index][0] == 'q') {
                long long value = ((long long (*)(id, SEL))objc_msgSend)(
                    object, selectors[index]);
                if (value > 0 && value <= INT_MAX) {
                    return (int)value;
                }
            } else {
                int value = ((int (*)(id, SEL))objc_msgSend)(
                    object, selectors[index]);
                if (value > 0) {
                    return value;
                }
            }
        } @catch (__unused NSException *exception) {
            return 0;
        }
    }
    return 0;
}

static BOOL SXDWindowVisible(UIWindow *window) {
    return window != nil && !window.hidden && window.alpha > 0.01 &&
           window.bounds.size.width > 0.0 && window.bounds.size.height > 0.0;
}

static BOOL SXDIsForegroundScene(UIWindowScene *scene) {
    return scene != nil &&
           scene.activationState == UISceneActivationStateForegroundActive;
}

static BOOL SXDIsSthenoWindow(UIWindow *window) {
    if (!window) {
        return NO;
    }
    NSString *name = NSStringFromClass(window.class);
    return [name isEqualToString:SXDSthenoWindowName] ||
           [name hasSuffix:@"SthenoWindow"];
}

static BOOL SXDIsProxyWindow(UIWindow *window) {
    if (!window) {
        return NO;
    }
    NSString *name = NSStringFromClass(window.class);
    return [name isEqualToString:SXDPanelWindowName] ||
           [name hasSuffix:SXDLecardWindowSuffix];
}

static BOOL SXDIsKeyboardHostView(UIView *view) {
    if (!view) {
        return NO;
    }
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:SXDKeyboardHostViewName] ||
           [name isEqualToString:SXDContextHostViewName] ||
           [name isEqualToString:SXDExternalHostViewName];
}

static BOOL SXDViewTreeContainsVisibleKeyboardHost(UIView *view,
                                                    NSUInteger depth,
                                                    NSUInteger *visited) {
    if (!view || depth > 24 || !visited || *visited >= 768) {
        return NO;
    }
    *visited += 1;
    if (!view.hidden && view.alpha > 0.01 &&
        view.bounds.size.width > 0.0 && view.bounds.size.height > 0.0 &&
        SXDIsKeyboardHostView(view)) {
        return YES;
    }

    NSArray *children = nil;
    @try {
        children = [view.subviews copy];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    for (UIView *child in children) {
        if (SXDViewTreeContainsVisibleKeyboardHost(child, depth + 1, visited)) {
            return YES;
        }
    }
    return NO;
}

static NSArray *SXDWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (!application) {
        return @[];
    }

    NSMutableArray *result = [NSMutableArray arrayWithCapacity:32];
    void (^append)(UIWindow *) = ^(UIWindow *window) {
        if (!window || [result containsObject:window] || result.count >= 64) {
            return;
        }
        [result addObject:window];
    };

    @try {
        for (UIWindow *window in application.windows) {
            append(window);
        }
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in [(UIWindowScene *)scene windows]) {
                append(window);
            }
        }
    } @catch (__unused NSException *exception) {
        return [result copy];
    }
    return [result copy];
}

static UIWindow *SXDVisibleSthenoWindow(void) {
    for (UIWindow *window in SXDWindows()) {
        if (!SXDIsSthenoWindow(window) || !SXDWindowVisible(window) ||
            !SXDIsForegroundScene(window.windowScene)) {
            continue;
        }

        UIScreen *screen = window.screen ?: UIScreen.mainScreen;
        CGRect screenBounds = screen.bounds;
        CGFloat screenArea = fabs(screenBounds.size.width * screenBounds.size.height);
        CGFloat windowArea = fabs(window.bounds.size.width * window.bounds.size.height);
        if (screenArea > 0.0 && windowArea > 0.0 &&
            windowArea < screenArea * 0.95) {
            return window;
        }
    }
    return nil;
}

static BOOL SXDProxyMenuVisibleInScene(UIWindowScene *scene) {
    if (!scene) {
        return NO;
    }
    for (UIWindow *window in SXDWindows()) {
        if (!SXDIsProxyWindow(window) || !SXDWindowVisible(window) ||
            window.windowScene != scene) {
            continue;
        }
        NSUInteger visited = 0;
        if (SXDViewTreeContainsVisibleKeyboardHost(window, 0, &visited)) {
            return YES;
        }
    }
    return NO;
}

static int SXDRemotePIDForSthenoWindow(UIWindow *window) {
    if (!window || !SXDIsSthenoWindow(window)) {
        return 0;
    }

    SEL sceneSelector = sel_registerName("scene");
    Method sceneMethod = class_getInstanceMethod(object_getClass(window), sceneSelector);
    if (!SXDEncodingMatches(sceneMethod, SXDOwnerEncoding)) {
        return 0;
    }

    id scene = nil;
    @try {
        scene = SXDCallObject(window, sceneSelector);
    } @catch (__unused NSException *exception) {
        return 0;
    }
    if (!scene) {
        return 0;
    }

    SEL processSelector = sel_registerName("clientProcess");
    Method processMethod = class_getInstanceMethod(object_getClass(scene), processSelector);
    if (!SXDEncodingMatches(processMethod, SXDOwnerEncoding)) {
        return 0;
    }

    id process = nil;
    @try {
        process = SXDCallObject(scene, processSelector);
    } @catch (__unused NSException *exception) {
        return 0;
    }
    return SXDProcessIDFromObject(process);
}

static id SXDSpringBoardHandle(void) {
    id advisor = SXDAdvisor;
    if (!advisor || !SXDInstanceMethod(advisor,
                                       sel_registerName(SXDArbiterOwnerSelectorName.UTF8String),
                                       SXDOwnerEncoding)) {
        return nil;
    }

    id owner = nil;
    @try {
        owner = SXDCallObject(advisor,
                               sel_registerName(SXDArbiterOwnerSelectorName.UTF8String));
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (!owner) {
        return nil;
    }

    SEL handlerSelector = sel_registerName(SXDArbiterHandlerSelectorName.UTF8String);
    if (!SXDInstanceMethod(owner, handlerSelector, SXDHandlerEncoding)) {
        return nil;
    }

    id handle = nil;
    @try {
        handle = ((id (*)(id, SEL, int))objc_msgSend)(
            owner, handlerSelector, (int)getpid());
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (!handle) {
        return nil;
    }

    SEL identifierSelector =
        sel_registerName(SXDProcessIdentifierSelectorName.UTF8String);
    Method identifierMethod = class_getInstanceMethod(object_getClass(handle), identifierSelector);
    if (!SXDEncodingMatches(identifierMethod, @"i16@0:8") &&
        !SXDEncodingMatches(identifierMethod, @"q16@0:8")) {
        return nil;
    }
    if (SXDProcessIDFromObject(handle) != (int)getpid()) {
        return nil;
    }
    if (!SXDInstanceMethod(handle,
                           sel_registerName(SXDArbiterHostSelectorName.UTF8String),
                           SXDHostEncoding)) {
        return nil;
    }
    return handle;
}

static void SXDDeactivateHost(void) {
    id handle = SXDActiveHandle;
    int pid = SXDActivePID;
    if (!handle || pid <= 0) {
        SXDActiveHandle = nil;
        SXDActivePID = 0;
        return;
    }

    SXDActiveHandle = nil;
    SXDActivePID = 0;

    SEL selector = sel_registerName(SXDArbiterHostSelectorName.UTF8String);
    @try {
        ((void (*)(id, SEL, int, BOOL))objc_msgSend)(handle, selector, pid, NO);
    } @catch (__unused NSException *exception) {
        // Keep cleanup retryable if the balanced transition throws.
        SXDActiveHandle = handle;
        SXDActivePID = pid;
    }
}

static void SXDActivateHost(id handle, int pid) {
    if (!handle || pid <= 0 || pid == (int)getpid()) {
        return;
    }
    if (SXDActiveHandle == handle && SXDActivePID == pid) {
        return;
    }

    SXDDeactivateHost();
    SEL selector = sel_registerName(SXDArbiterHostSelectorName.UTF8String);
    @try {
        ((void (*)(id, SEL, int, BOOL))objc_msgSend)(handle, selector, pid, YES);
        SXDActiveHandle = handle;
        SXDActivePID = pid;
    } @catch (__unused NSException *exception) {
        SXDActiveHandle = nil;
        SXDActivePID = 0;
    }
}

static void SXDReconcile(void) {
    if (!SXDIsMainThread()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SXDReconcile();
        });
        return;
    }

    UIWindow *sthenoWindow = SXDVisibleSthenoWindow();
    UIWindowScene *scene = sthenoWindow.windowScene;
    if (!sthenoWindow || !scene || !SXDProxyMenuVisibleInScene(scene)) {
        SXDDeactivateHost();
        return;
    }

    int remotePID = SXDRemotePIDForSthenoWindow(sthenoWindow);
    if (remotePID <= 0 || remotePID == (int)getpid()) {
        SXDDeactivateHost();
        return;
    }

    id handle = SXDSpringBoardHandle();
    if (!handle) {
        SXDDeactivateHost();
        return;
    }
    SXDActivateHost(handle, remotePID);
}

static id SXDHookLaunchAdvisor(id self, SEL _cmd, id delegate) {
    id advisor = SXDOriginalLaunchAdvisor(self, _cmd, delegate);
    if (advisor) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SXDAdvisor = advisor;
            SXDReconcile();
        });
    }
    return advisor;
}

static BOOL SXDInstallArbiterHook(void) {
    if (SXDArbiterHookInstalled) {
        return YES;
    }

    Class arbiterClass = objc_getClass(SXDArbiterClassName.UTF8String);
    SEL selector = sel_registerName(SXDArbiterLaunchSelectorName.UTF8String);
    if (!arbiterClass ||
        !SXDClassMethodEncoding(arbiterClass, selector, SXDLaunchAdvisorEncoding)) {
        return NO;
    }

    MSHookMessageEx(object_getClass(arbiterClass),
                    selector,
                    (IMP)SXDHookLaunchAdvisor,
                    (IMP *)&SXDOriginalLaunchAdvisor);
    SXDArbiterHookInstalled = SXDOriginalLaunchAdvisor != NULL;
    return SXDArbiterHookInstalled;
}

static void SXDStartReconcileTimer(void) {
    if (SXDTimerStarted || !SXDIsMainThread()) {
        return;
    }
    SXDTimerStarted = YES;

    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!timer) {
        SXDTimerStarted = NO;
        return;
    }
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                              250 * NSEC_PER_MSEC,
                              50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        SXDReconcile();
    });
    dispatch_resume(timer);
}

static void SXDBootstrap(NSUInteger attempt) {
    if (!SXDIsMainThread()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SXDBootstrap(attempt);
        });
        return;
    }
    if (!SXDIsSpringBoardProcess()) {
        return;
    }

    BOOL installed = SXDInstallArbiterHook();
    if (installed) {
        SXDStartReconcileTimer();
        SXDReconcile();
        return;
    }

    if (attempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            SXDBootstrap(attempt + 1);
        });
    }
}

__attribute__((constructor))
static void SXDConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SXDBootstrap(0);
    });
}
