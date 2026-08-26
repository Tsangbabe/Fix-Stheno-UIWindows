/*
 * SthenoSquidExtenderDiagnostic.m
 *
 * Read-only runtime evidence collector for the Stheno floating-window /
 * SquidExtender keyboard-menu overlap.  This file deliberately contains no
 * UI repair: it never changes a frame, bounds, window level, Scene, layer,
 * clipping flag, key-window state, or touch result.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif
void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *old);
#ifdef __cplusplus
}
#endif

static NSString * const SXDSpringBoardPath =
    @"/var/mobile/Documents/SthenoSquidExtenderWindowDiagnostic-SpringBoard.plist";
static NSString * const SXDUIKitPath =
    @"/var/mobile/Documents/SthenoSquidExtenderWindowDiagnostic-UIKit.plist";
static NSString * const SXDUnknownPath =
    @"/var/mobile/Documents/SthenoSquidExtenderWindowDiagnostic-Unknown.plist";
static NSString * const SXDSthenoPreferencesPath =
    @"/var/mobile/Library/Preferences/com.nx.stheno.plist";

static const NSUInteger SXDMaxEvents = 96;
static const NSUInteger SXDMaxWindows = 48;
static const NSUInteger SXDMaxViewNodes = 512;
static const NSUInteger SXDMaxViewDepth = 20;
static const NSUInteger SXDMaxClassChain = 16;

static dispatch_queue_t SXDLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.tsangbaby.stheno-squid-diagnostic.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

typedef NS_ENUM(NSInteger, SXDProcessDomain) {
    SXDProcessDomainUnknown = 0,
    SXDProcessDomainSpringBoard = 1,
    SXDProcessDomainUIKit = 2,
};

static SXDProcessDomain SXDDomain = SXDProcessDomainUnknown;
static NSString *SXDOutputPath = nil;
static NSUInteger SXDSequence = 0;
static BOOL SXDSnapshotPending = NO;
static CFTimeInterval SXDLastSnapshotSchedule = 0;
static NSMapTable *SXDWindowSlots = nil;
static NSMapTable *SXDSceneSlots = nil;
static NSUInteger SXDNextWindowSlot = 1;
static NSUInteger SXDNextSceneSlot = 1;

static BOOL SXDIsMainThread(void) {
    return [NSThread isMainThread];
}

static NSString *SXDClassName(id object) {
    if (!object) {
        return @"<nil>";
    }
    return NSStringFromClass([object class]) ?: @"<unknown>";
}

static NSString *SXDProcessDomainName(void) {
    switch (SXDDomain) {
        case SXDProcessDomainSpringBoard:
            return @"SpringBoard";
        case SXDProcessDomainUIKit:
            return @"UIKit";
        default:
            return @"Unknown";
    }
}

static NSString *SXDPathForDomain(void) {
    if (SXDOutputPath.length > 0) {
        return SXDOutputPath;
    }
    switch (SXDDomain) {
        case SXDProcessDomainSpringBoard:
            return SXDSpringBoardPath;
        case SXDProcessDomainUIKit:
            return SXDUIKitPath;
        default:
            return SXDUnknownPath;
    }
}

static NSDictionary *SXDRectDictionary(CGRect rect) {
    if (CGRectIsNull(rect) || CGRectIsInfinite(rect)) {
        return @{};
    }
    return @{
        @"x" : @(rect.origin.x),
        @"y" : @(rect.origin.y),
        @"width" : @(rect.size.width),
        @"height" : @(rect.size.height),
    };
}

static NSArray *SXDClassChainForView(UIView *view) {
    NSMutableArray *chain = [NSMutableArray arrayWithCapacity:SXDMaxClassChain];
    UIView *current = view;
    while (current && chain.count < SXDMaxClassChain) {
        NSString *name = SXDClassName(current);
        if (name.length > 0) {
            [chain addObject:name];
        }
        current = current.superview;
    }
    return [chain copy];
}

static BOOL SXDIsSthenoWindow(UIWindow *window) {
    if (!window) {
        return NO;
    }
    NSString *name = SXDClassName(window);
    return [name hasSuffix:@"SthenoWindow"] ||
           [name isEqualToString:@"Stheno.SthenoWindow"];
}

static BOOL SXDIsKeyboardWindow(UIWindow *window) {
    if (!window) {
        return NO;
    }
    NSString *name = SXDClassName(window);
    return [name containsString:@"UIRemoteKeyboardWindow"];
}

static BOOL SXDClassLooksLikeSquidExtender(id object) {
    NSString *name = SXDClassName(object);
    return [name localizedCaseInsensitiveContainsString:@"squid"] ||
           [name localizedCaseInsensitiveContainsString:@"extender"];
}

static BOOL SXDWindowVisible(UIWindow *window) {
    return window && !window.hidden && window.alpha > 0.01 &&
           window.bounds.size.width > 0.0 && window.bounds.size.height > 0.0;
}

static BOOL SXDWindowLooksLikeCard(UIWindow *window) {
    if (!SXDIsSthenoWindow(window) || !SXDWindowVisible(window)) {
        return NO;
    }
    UIScreen *screen = window.screen ?: UIScreen.mainScreen;
    CGRect screenBounds = screen.bounds;
    CGFloat screenArea = fabs(screenBounds.size.width * screenBounds.size.height);
    CGFloat windowArea = fabs(window.bounds.size.width * window.bounds.size.height);
    if (screenArea <= 0.0) {
        return NO;
    }
    return windowArea > 0.0 && windowArea < screenArea * 0.95;
}

static NSUInteger SXDSlotForObject(NSMapTable * __strong *tableStorage,
                                   NSUInteger *nextSlotStorage,
                                   id object) {
    if (!object) {
        return 0;
    }
    if (!*tableStorage) {
        *tableStorage = [NSMapTable weakToStrongObjectsMapTable];
    }
    NSNumber *existing = [*tableStorage objectForKey:object];
    if (existing != nil) {
        return existing.unsignedIntegerValue;
    }
    NSUInteger slot = *nextSlotStorage;
    *nextSlotStorage = slot + 1;
    [*tableStorage setObject:@(slot) forKey:object];
    return slot;
}

static NSUInteger SXDWindowSlot(UIWindow *window) {
    return SXDSlotForObject(&SXDWindowSlots, &SXDNextWindowSlot, window);
}

static NSUInteger SXDSceneSlot(UIScene *scene) {
    return SXDSlotForObject(&SXDSceneSlots, &SXDNextSceneSlot, scene);
}

static void SXDWriteEvent(NSDictionary *event) {
    if (![event isKindOfClass:[NSDictionary class]] || event.count == 0) {
        return;
    }
    NSDictionary *snapshot = [event copy];
    dispatch_async(SXDLogQueue(), ^{
        @autoreleasepool {
            NSString *path = SXDPathForDomain();
            NSMutableDictionary *root =
                [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
            if (![root isKindOfClass:[NSMutableDictionary class]]) {
                root = [NSMutableDictionary dictionary];
            }

            NSMutableArray *events = [root[@"events"] mutableCopy];
            if (![events isKindOfClass:[NSMutableArray class]]) {
                events = [NSMutableArray array];
            }

            NSMutableDictionary *record = [snapshot mutableCopy];
            record[@"sequence"] = @(++SXDSequence);
            record[@"process_domain"] = SXDProcessDomainName();
            [events addObject:[record copy]];
            while (events.count > SXDMaxEvents) {
                [events removeObjectAtIndex:0];
            }

            root[@"format_version"] = @1;
            root[@"process_domain"] = SXDProcessDomainName();
            root[@"events"] = [events copy];
            [root writeToFile:path atomically:YES];
        }
    });
}

static void SXDResetOutputFile(void) {
    NSString *path = SXDPathForDomain();
    dispatch_sync(SXDLogQueue(), ^{
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    });
}

static void SXDRecord(NSString *phase, NSDictionary *fields) {
    if (phase.length == 0) {
        return;
    }
    NSMutableDictionary *event = [NSMutableDictionary dictionary];
    event[@"phase"] = phase;
    event[@"main_thread"] = @(SXDIsMainThread());
    if ([fields isKindOfClass:[NSDictionary class]]) {
        [event addEntriesFromDictionary:fields];
    }
    SXDWriteEvent(event);
}

static NSDictionary *SXDWindowState(UIWindow *window) {
    if (!window) {
        return @{};
    }
    UIWindowScene *scene = window.windowScene;
    CALayer *layer = window.layer;
    UIViewController *rootController = window.rootViewController;
    return @{
        @"window_slot" : @(SXDWindowSlot(window)),
        @"class" : SXDClassName(window),
        @"window_level" : @(window.windowLevel),
        @"is_key_window" : @(window.isKeyWindow),
        @"hidden" : @(window.hidden),
        @"alpha_nonzero" : @(window.alpha > 0.01),
        @"frame" : SXDRectDictionary(window.frame),
        @"bounds" : SXDRectDictionary(window.bounds),
        @"layer_z_position" : @(layer.zPosition),
        @"clips_to_bounds" : @(window.clipsToBounds),
        @"has_layer_mask" : @(layer.mask != nil),
        @"stheno_window" : @(SXDIsSthenoWindow(window)),
        @"card_mode_candidate" : @(SXDWindowLooksLikeCard(window)),
        @"keyboard_window" : @(SXDIsKeyboardWindow(window)),
        @"root_view_controller_class" : SXDClassName(rootController),
        @"scene_slot" : @(scene ? SXDSceneSlot(scene) : 0),
        @"scene_class" : SXDClassName(scene),
    };
}

static void SXDAppendViewNode(UIView *view,
                              NSUInteger windowSlot,
                              NSInteger parentIndex,
                              NSUInteger depth,
                              NSMutableArray *nodes) {
    if (!view || ![nodes isKindOfClass:[NSMutableArray class]] ||
        nodes.count >= SXDMaxViewNodes || depth > SXDMaxViewDepth) {
        return;
    }

    NSUInteger nodeIndex = nodes.count;
    CALayer *layer = view.layer;
    NSDictionary *node = @{
        @"node_index" : @(nodeIndex),
        @"window_slot" : @(windowSlot),
        @"parent_index" : @(parentIndex),
        @"depth" : @(depth),
        @"subview_index" : @(-1),
        @"class" : SXDClassName(view),
        @"squid_extender_like_class" : @(SXDClassLooksLikeSquidExtender(view)),
        @"frame" : SXDRectDictionary(view.frame),
        @"bounds" : SXDRectDictionary(view.bounds),
        @"layer_z_position" : @(layer.zPosition),
        @"clips_to_bounds" : @(view.clipsToBounds),
        @"has_layer_mask" : @(layer.mask != nil),
        @"hidden" : @(view.hidden),
        @"alpha_nonzero" : @(view.alpha > 0.01),
        @"user_interaction_enabled" : @(view.userInteractionEnabled),
    };
    [nodes addObject:node];

    NSArray *children = nil;
    @try {
        children = [view.subviews copy];
    } @catch (__unused NSException *exception) {
        return;
    }

    NSUInteger childIndex = 0;
    for (UIView *child in children) {
        if (nodes.count >= SXDMaxViewNodes) {
            break;
        }
        NSUInteger before = nodes.count;
        SXDAppendViewNode(child, windowSlot, (NSInteger)nodeIndex, depth + 1, nodes);
        if (nodes.count > before) {
            NSMutableDictionary *mutableNode = [nodes[before] mutableCopy];
            mutableNode[@"subview_index"] = @(childIndex);
            nodes[before] = [mutableNode copy];
        }
        childIndex += 1;
    }
}

static NSArray *SXDAllWindows(UIApplication *application) {
    NSMutableArray *windows = [NSMutableArray array];
    void (^appendWindow)(UIWindow *) = ^(UIWindow *window) {
        if (!window || [windows containsObject:window]) {
            return;
        }
        if (windows.count < SXDMaxWindows) {
            [windows addObject:window];
        }
    };

    @try {
        for (UIWindow *window in application.windows) {
            appendWindow(window);
        }
    } @catch (__unused NSException *exception) {
    }

    @try {
        NSSet *connectedScenes = application.connectedScenes;
        for (UIScene *scene in connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            for (UIWindow *window in [(UIWindowScene *)scene windows]) {
                appendWindow(window);
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return [windows copy];
}

static NSArray *SXDSceneStates(UIApplication *application) {
    NSMutableArray *scenes = [NSMutableArray array];
    @try {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            UISceneSession *session = windowScene.session;
            UIScreen *screen = windowScene.screen;
            [scenes addObject:@{
                @"scene_slot" : @(SXDSceneSlot(scene)),
                @"class" : SXDClassName(scene),
                @"activation_state" : @(scene.activationState),
                @"session_role" : session.role ?: @"<nil>",
                @"screen_bounds" : SXDRectDictionary(screen.bounds),
                @"window_count" : @([windowScene windows].count),
            }];
        }
    } @catch (__unused NSException *exception) {
    }
    return [scenes copy];
}

static NSDictionary *SXDClassPresence(void) {
    Class sthenoWindow = NSClassFromString(@"Stheno.SthenoWindow");
    Class keyboardWindow = NSClassFromString(@"UIRemoteKeyboardWindow");
    Class keyboardImpl = NSClassFromString(@"UIKeyboardImpl");
    Class keyboardLayerHost = NSClassFromString(@"_UIKeyboardLayerHostView");
    Class contextLayerHost = NSClassFromString(@"_UIContextLayerHostView");
    Class externalLayerHost = NSClassFromString(@"_UIExternalSceneLayerHostView");
    Class fbScene = NSClassFromString(@"FBScene");
    Class fbSceneLayerManager = NSClassFromString(@"FBSceneLayerManager");
    return @{
        @"Stheno.SthenoWindow" : @(sthenoWindow != Nil),
        @"UIRemoteKeyboardWindow" : @(keyboardWindow != Nil),
        @"UIKeyboardImpl" : @(keyboardImpl != Nil),
        @"_UIKeyboardLayerHostView" : @(keyboardLayerHost != Nil),
        @"_UIContextLayerHostView" : @(contextLayerHost != Nil),
        @"_UIExternalSceneLayerHostView" : @(externalLayerHost != Nil),
        @"FBScene" : @(fbScene != Nil),
        @"FBSceneLayerManager" : @(fbSceneLayerManager != Nil),
    };
}

static BOOL SXDHasVisibleSthenoCard(NSArray *windows) {
    for (UIWindow *window in windows) {
        if (SXDWindowLooksLikeCard(window)) {
            return YES;
        }
    }
    return NO;
}

static BOOL SXDHasVisibleKeyboard(NSArray *windows) {
    for (UIWindow *window in windows) {
        if (SXDIsKeyboardWindow(window) && SXDWindowVisible(window)) {
            return YES;
        }
    }
    return NO;
}

static void SXDRecordSnapshotOnMain(NSString *reason, BOOL force) {
    if (!SXDIsMainThread()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SXDRecordSnapshotOnMain(reason, force);
        });
        return;
    }

    UIApplication *application = [UIApplication sharedApplication];
    NSArray *windows = SXDAllWindows(application);
    BOOL hasCard = SXDHasVisibleSthenoCard(windows);
    BOOL hasKeyboard = SXDHasVisibleKeyboard(windows);
    if (!force) {
        if (SXDDomain == SXDProcessDomainSpringBoard && !hasCard) {
            return;
        }
        if (SXDDomain == SXDProcessDomainUIKit && !hasKeyboard) {
            return;
        }
    }

    NSMutableArray *windowStates = [NSMutableArray array];
    NSMutableArray *viewNodes = [NSMutableArray array];
    for (UIWindow *window in windows) {
        if (!window) {
            continue;
        }
        BOOL relevant = SXDDomain == SXDProcessDomainSpringBoard
            ? (SXDWindowVisible(window) || SXDIsSthenoWindow(window))
            : (SXDWindowVisible(window) || SXDIsKeyboardWindow(window) || window.isKeyWindow);
        if (!relevant) {
            continue;
        }
        [windowStates addObject:SXDWindowState(window)];
        if (viewNodes.count >= SXDMaxViewNodes) {
            continue;
        }
        @try {
            SXDAppendViewNode(window, SXDWindowSlot(window), -1, 0, viewNodes);
        } @catch (__unused NSException *exception) {
        }
    }

    SXDRecord(@"window_snapshot", @{
        @"snapshot_reason" : reason ?: @"unspecified",
        @"stheno_card_visible" : @(hasCard),
        @"keyboard_window_visible" : @(hasKeyboard),
        @"windows" : [windowStates copy],
        @"scenes" : SXDSceneStates(application),
        @"view_nodes" : [viewNodes copy],
        @"class_presence" : SXDClassPresence(),
    });
}

static void SXDScheduleSnapshot(NSString *reason) {
    if (!SXDIsMainThread()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SXDScheduleSnapshot(reason);
        });
        return;
    }
    if (SXDSnapshotPending) {
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (now - SXDLastSnapshotSchedule < 0.08) {
        return;
    }
    SXDLastSnapshotSchedule = now;
    SXDSnapshotPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SXDSnapshotPending = NO;
        SXDRecordSnapshotOnMain(reason, NO);
    });
}

static void SXDRecordWindowEvent(NSString *phase, UIWindow *window, NSDictionary *extra) {
    if (!SXDIsMainThread()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SXDRecordWindowEvent(phase, window, extra);
        });
        return;
    }
    if (!window) {
        return;
    }
    NSMutableDictionary *fields = [SXDWindowState(window) mutableCopy];
    if (![fields isKindOfClass:[NSMutableDictionary class]]) {
        fields = [NSMutableDictionary dictionary];
    }
    if ([extra isKindOfClass:[NSDictionary class]]) {
        [fields addEntriesFromDictionary:extra];
    }
    SXDRecord(phase, fields);
    if (SXDDomain == SXDProcessDomainSpringBoard &&
        (SXDIsKeyboardWindow(window) || SXDIsSthenoWindow(window))) {
        SXDRecordSnapshotOnMain(phase, YES);
    } else {
        SXDScheduleSnapshot(phase);
    }
}

static void SXDRecordTouchRoute(UIEvent *event) {
    if (!event || !SXDIsMainThread()) {
        return;
    }
    @try {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) {
                continue;
            }
            UIWindow *window = touch.window;
            UIView *view = touch.view;
            SXDRecord(@"touch_route", @{
                @"touch_window_slot" : @(SXDWindowSlot(window)),
                @"touch_window_class" : SXDClassName(window),
                @"touch_view_class" : SXDClassName(view),
                @"touch_view_class_chain" : SXDClassChainForView(view),
                @"touch_phase" : @(touch.phase),
            });
        }
    } @catch (__unused NSException *exception) {
        SXDRecord(@"touch_route_observation_exception", @{});
    }
    SXDScheduleSnapshot(@"touch_end");
}

static BOOL SXDUIKitSthenoPresenceHint(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath:SXDSthenoPreferencesPath];
}

static SXDProcessDomain SXDDetermineDomain(void) {
    NSString *processName = [NSProcessInfo processInfo].processName.lowercaseString ?: @"";
    if ([processName containsString:@"springboard"] ||
        NSClassFromString(@"Stheno.SthenoWindow") != Nil) {
        return SXDProcessDomainSpringBoard;
    }
    if (NSClassFromString(@"UIRemoteKeyboardWindow") != Nil &&
        NSClassFromString(@"UIKeyboardImpl") != Nil) {
        // The substrate filter already scopes this image to com.apple.UIKit.
        // Do not require Stheno's preference file: RootHide path mapping or
        // preference timing must not suppress the UIKit diagnostic itself.
        return SXDProcessDomainUIKit;
    }
    return SXDProcessDomainUnknown;
}

static id (*SXDOriginalInitWithWindowScene)(id, SEL, UIWindowScene *);
static void (*SXDOriginalSetWindowLevel)(id, SEL, CGFloat);
static void (*SXDOriginalSetWindowScene)(id, SEL, UIWindowScene *);
static void (*SXDOriginalKeyboardSetFrame)(id, SEL, CGRect);
static void (*SXDOriginalKeyboardSetBounds)(id, SEL, CGRect);
static id (*SXDOriginalRemoteKeyboardWindow)(id, SEL, UIScreen *, BOOL);
static void (*SXDOriginalSendEvent)(id, SEL, UIEvent *);

static id SXDHookInitWithWindowScene(id self, SEL _cmd, UIWindowScene *scene) {
    id window = SXDOriginalInitWithWindowScene(self, _cmd, scene);
    if (window && SXDIsSthenoWindow((UIWindow *)window)) {
        SXDRecordWindowEvent(@"window_init_with_scene", (UIWindow *)window, @{
            @"init_scene_class" : SXDClassName(scene),
        });
    }
    return window;
}

static void SXDHookSetWindowLevel(id self, SEL _cmd, CGFloat level) {
    SXDOriginalSetWindowLevel(self, _cmd, level);
    UIWindow *window = (UIWindow *)self;
    if (SXDIsSthenoWindow(window)) {
        SXDRecordWindowEvent(@"stheno_window_level_set", window, @{
            @"requested_window_level" : @(level),
        });
    }
}

static void SXDHookSetWindowScene(id self, SEL _cmd, UIWindowScene *scene) {
    SXDOriginalSetWindowScene(self, _cmd, scene);
    UIWindow *window = (UIWindow *)self;
    if (SXDIsSthenoWindow(window)) {
        SXDRecordWindowEvent(@"stheno_window_scene_set", window, @{
            @"requested_scene_class" : SXDClassName(scene),
        });
    }
}

static void SXDHookKeyboardSetFrame(id self, SEL _cmd, CGRect frame) {
    SXDOriginalKeyboardSetFrame(self, _cmd, frame);
    SXDRecordWindowEvent(@"remote_keyboard_window_frame_set", (UIWindow *)self, @{
        @"requested_frame" : SXDRectDictionary(frame),
    });
}

static void SXDHookKeyboardSetBounds(id self, SEL _cmd, CGRect bounds) {
    SXDOriginalKeyboardSetBounds(self, _cmd, bounds);
    SXDRecordWindowEvent(@"remote_keyboard_window_bounds_set", (UIWindow *)self, @{
        @"requested_bounds" : SXDRectDictionary(bounds),
    });
}

static id SXDHookRemoteKeyboardWindow(id self, SEL _cmd, UIScreen *screen, BOOL create) {
    id window = SXDOriginalRemoteKeyboardWindow(self, _cmd, screen, create);
    if (window) {
        SXDRecordWindowEvent(@"remote_keyboard_window_factory_return", (UIWindow *)window, @{
            @"factory_screen_class" : SXDClassName(screen),
            @"factory_create" : @(create),
        });
    }
    return window;
}

static void SXDHookSendEvent(id self, SEL _cmd, UIEvent *event) {
    SXDOriginalSendEvent(self, _cmd, event);
    if (!event || event.type != UIEventTypeTouches) {
        return;
    }
    BOOL hasFinishedTouch = NO;
    @try {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                hasFinishedTouch = YES;
                break;
            }
        }
    } @catch (__unused NSException *exception) {
        return;
    }
    if (hasFinishedTouch) {
        SXDRecordTouchRoute(event);
    }
}

static BOOL SXDInstallHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector || !replacement || !original ||
        class_getInstanceMethod(cls, selector) == NULL) {
        return NO;
    }
    MSHookMessageEx(cls, selector, replacement, original);
    return *original != NULL;
}

static BOOL SXDInstallCommonWindowHooks(void) {
    Class windowClass = objc_getClass("UIWindow");
    if (!windowClass) {
        return NO;
    }
    BOOL initInstalled = SXDInstallHook(windowClass,
                                        @selector(initWithWindowScene:),
                                        (IMP)SXDHookInitWithWindowScene,
                                        (IMP *)&SXDOriginalInitWithWindowScene);
    BOOL levelInstalled = SXDInstallHook(windowClass,
                                         @selector(setWindowLevel:),
                                         (IMP)SXDHookSetWindowLevel,
                                         (IMP *)&SXDOriginalSetWindowLevel);
    BOOL sceneInstalled = SXDInstallHook(windowClass,
                                         @selector(setWindowScene:),
                                         (IMP)SXDHookSetWindowScene,
                                         (IMP *)&SXDOriginalSetWindowScene);
    return initInstalled && levelInstalled && sceneInstalled;
}

static BOOL SXDInstallSpringBoardHooks(void) {
    Class application = objc_getClass("UIApplication");
    return SXDInstallHook(application,
                          @selector(sendEvent:),
                          (IMP)SXDHookSendEvent,
                          (IMP *)&SXDOriginalSendEvent);
}

static BOOL SXDInstallUIKitHooks(void) {
    Class keyboardImpl = objc_getClass("UIKeyboardImpl");
    Class keyboardWindow = objc_getClass("UIRemoteKeyboardWindow");
    Class application = objc_getClass("UIApplication");
    BOOL factoryInstalled = SXDInstallHook(keyboardImpl,
                                            @selector(remoteKeyboardWindowForScreen:create:),
                                            (IMP)SXDHookRemoteKeyboardWindow,
                                            (IMP *)&SXDOriginalRemoteKeyboardWindow);
    BOOL frameInstalled = SXDInstallHook(keyboardWindow,
                                         @selector(setFrame:),
                                         (IMP)SXDHookKeyboardSetFrame,
                                         (IMP *)&SXDOriginalKeyboardSetFrame);
    BOOL boundsInstalled = SXDInstallHook(keyboardWindow,
                                          @selector(setBounds:),
                                          (IMP)SXDHookKeyboardSetBounds,
                                          (IMP *)&SXDOriginalKeyboardSetBounds);
    BOOL eventInstalled = SXDInstallHook(application,
                                         @selector(sendEvent:),
                                         (IMP)SXDHookSendEvent,
                                         (IMP *)&SXDOriginalSendEvent);
    return factoryInstalled && frameInstalled && boundsInstalled && eventInstalled;
}

static void SXDInstallObservers(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSArray<NSNotificationName> *names = @[
        UIWindowDidBecomeVisibleNotification,
        UIWindowDidBecomeHiddenNotification,
        UIWindowDidBecomeKeyNotification,
        UIWindowDidResignKeyNotification,
        UIKeyboardWillShowNotification,
        UIKeyboardWillHideNotification,
    ];
    for (NSNotificationName name in names) {
        [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                         usingBlock:^(NSNotification *note) {
            UIWindow *window = [note.object isKindOfClass:[UIWindow class]]
                ? (UIWindow *)note.object : nil;
            SXDRecordWindowEvent(@"window_notification", window, @{
                @"notification_kind" : name ?: @"<nil>",
            });
            SXDScheduleSnapshot(name ?: @"notification");
        }];
    }
}

static void SXDInitializeOnMain(NSUInteger attempt) {
    if (!SXDIsMainThread()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SXDInitializeOnMain(attempt);
        });
        return;
    }

    SXDProcessDomain domain = SXDDetermineDomain();
    if (domain == SXDProcessDomainUnknown) {
        if (attempt < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                SXDInitializeOnMain(attempt + 1);
            });
        }
        return;
    }

    SXDDomain = domain;
    SXDOutputPath = [SXDPathForDomain() copy];
    SXDResetOutputFile();
    SXDInstallObservers();

    BOOL commonHooks = SXDInstallCommonWindowHooks();
    BOOL domainHooks = domain == SXDProcessDomainUIKit
        ? SXDInstallUIKitHooks()
        : SXDInstallSpringBoardHooks();
    SXDRecord(@"bootstrap", @{
        @"common_window_hooks_installed" : @(commonHooks),
        @"domain_hooks_installed" : @(domainHooks),
        @"stheno_preferences_present" : @(SXDUIKitSthenoPresenceHint()),
        @"class_presence" : SXDClassPresence(),
    });
    SXDRecordSnapshotOnMain(@"bootstrap", YES);
}

__attribute__((constructor))
static void SXDConstructor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        SXDInitializeOnMain(0);
    });
}
