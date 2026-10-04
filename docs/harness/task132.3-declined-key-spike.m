// TASK-132.3 follow-up spike: a key sent straight to a hidden in-window web view (D) that its page
// declines is handed by WebKit to [NSApp sendEvent:] again (WebViewImpl::doneWithKeyEvent). Where does
// it land when the window is the app's key window and another web view (A) is first responder?
// And does a local event monitor see (and can it swallow) that re-sent event?
// Never activates the app; argv[1]=1 makes the window the (inactive) app's key window.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
static void P(NSString *fmt, ...) { va_list a; va_start(a, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a); printf("%s\n", s.UTF8String); fflush(stdout); }
static BOOL spin(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done()) { if ([end timeIntervalSinceNow] < 0) return NO; NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.02] inMode:NSDefaultRunLoopMode dequeue:YES]; if (e) [NSApp sendEvent:e]; [NSApp updateWindows]; }
    return YES;
}
static void pause_(NSTimeInterval t) { spin(t, ^BOOL{ return NO; }); }
static id js(WKWebView *wv, NSString *body) {
    __block id out = nil; __block BOOL fin = NO;
    [wv callAsyncJavaScript:body arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id r, NSError *e) { out = e ? [NSString stringWithFormat:@"JSERROR: %@", e.localizedDescription] : r; fin = YES; }];
    if (!spin(8, ^BOOL{ return fin; })) return @"EVAL TIMEOUT";
    return out;
}
static NSString *page(NSString *bg) {
    return [NSString stringWithFormat:@"<!doctype html><body style='margin:0;background:%@'>"
        "<input id=i spellcheck=false autocorrect=off autocomplete=off autocapitalize=off style='position:absolute;left:20px;top:100px;width:200px;height:30px'>"
        "<script>window.log=[];for(const t of ['keydown','keypress','input','keyup'])document.addEventListener(t,e=>log.push(t+'/'+(e.isTrusted?'T':'u')+'/'+(e.target.id||e.target.nodeName)+(e.key?'/'+e.key:'')),true);</script>", bg];
}
@interface MenuTarget : NSObject @property NSInteger fired; @end
@implementation MenuTarget
- (void)menuAction:(id)sender { self.fired++; }
@end
@interface SpyWindow : NSWindow @property (weak) NSView *vetoed; @property NSInteger vetoCount; @property NSMutableArray *sent; @end
@implementation SpyWindow
- (BOOL)makeFirstResponder:(NSResponder *)r { if (r && r == self.vetoed) { self.vetoCount++; return NO; } return [super makeFirstResponder:r]; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)sendEvent:(NSEvent *)e { if (e.type == NSEventTypeKeyDown || e.type == NSEventTypeKeyUp) [self.sent addObject:[NSString stringWithFormat:@"%@:%@", e.type == NSEventTypeKeyDown ? @"down" : @"up", e.characters]]; [super sendEvent:e]; }
@end
static NSEvent *key(NSEventType type, NSString *chars, unsigned short code, NSEventModifierFlags flags, NSWindow *w) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
}
int main(int argc, const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    BOOL makeKey = argc > 1 && atoi(argv[1]);
    SpyWindow *w = [[SpyWindow alloc] initWithContentRect:NSMakeRect(60, 60, 800, 600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    w.sent = [NSMutableArray array];
    WKWebView *(^make)(void) = ^WKWebView *{ return [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:[WKWebViewConfiguration new]]; };
    WKWebView *A = make(), *D = make();
    D.hidden = YES; [w.contentView addSubview:D]; [w.contentView addSubview:A];
    [w orderBack:nil];
    [A loadHTMLString:page(@"#00c") baseURL:[NSURL URLWithString:@"https://a.example/"]];
    [D loadHTMLString:page(@"#cc0") baseURL:[NSURL URLWithString:@"https://d.example/"]];
    spin(15, ^BOOL{ return !A.isLoading && !D.isLoading; }); pause_(1.0);
    [w makeFirstResponder:A]; w.vetoed = D;
    js(A, @"document.getElementById('i').focus(); return 1");
    if (makeKey) [w makeKeyWindow];
    P(@"window key=%d appKeyWindow=%d appActive=%d firstResponder is A=%d", w.isKeyWindow, NSApp.keyWindow == w, NSApp.isActive, w.firstResponder == A);

    // 1. A key D's page declines (nothing focused there).
    NSEvent *down = key(NSEventTypeKeyDown, @"j", 38, 0, w);
    [D keyDown:down]; [D keyUp:key(NSEventTypeKeyUp, @"j", 38, 0, w)]; pause_(1.0);
    P(@"1. declined 'j' sent to D | D log: %@ | A log: '%@' A value='%@' | window sendEvent saw: %@", js(D, @"return log.splice(0).join(' ')"), js(A, @"return log.splice(0).join(' ')"), js(A, @"return document.getElementById('i').value"), [w.sent componentsJoinedByString:@","]);
    [w.sent removeAllObjects];

    // 2. Same, with a local monitor that swallows key events it was told about.
    NSHashTable *driven = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    __block NSInteger monitorSaw = 0, monitorSwallowed = 0;
    id monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
        monitorSaw++;
        if ([driven containsObject:e]) { monitorSwallowed++; return nil; }
        return e;
    }];
    NSEvent *down2 = key(NSEventTypeKeyDown, @"k", 40, 0, w);
    [driven addObject:down2];
    [D keyDown:down2]; [D keyUp:key(NSEventTypeKeyUp, @"k", 40, 0, w)]; pause_(1.0);
    P(@"2. declined 'k' with monitor | monitor saw=%ld swallowed=%ld | D log: %@ | A log: '%@' A value='%@' | window sendEvent saw: %@", (long)monitorSaw, (long)monitorSwallowed, js(D, @"return log.splice(0).join(' ')"), js(A, @"return log.splice(0).join(' ')"), js(A, @"return document.getElementById('i').value"), [w.sent componentsJoinedByString:@","]);
    [w.sent removeAllObjects];

    // 3. A key D's page handles (typed into its focused input): is anything re-sent?
    js(D, @"document.getElementById('i').focus(); return 1");
    NSEvent *down3 = key(NSEventTypeKeyDown, @"z", 6, 0, w);
    [driven addObject:down3]; monitorSaw = 0; monitorSwallowed = 0;
    [D keyDown:down3]; [D keyUp:key(NSEventTypeKeyUp, @"z", 6, 0, w)]; pause_(1.0);
    P(@"3. handled 'z' | monitor saw=%ld swallowed=%ld | D value='%@' | A log: '%@' | window sendEvent saw: %@", (long)monitorSaw, (long)monitorSwallowed, js(D, @"return document.getElementById('i').value"), js(A, @"return log.splice(0).join(' ')"), [w.sent componentsJoinedByString:@","]);
    // 4. Cmd+J with a main-menu item bound to it: does the re-sent, declined key fire the menu item?
    MenuTarget *target = [MenuTarget new];
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Main"]; NSMenuItem *top = [[NSMenuItem alloc] initWithTitle:@"T" action:nil keyEquivalent:@""]; NSMenu *sub = [[NSMenu alloc] initWithTitle:@"T"];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"J" action:@selector(menuAction:) keyEquivalent:@"j"]; item.target = target; [sub addItem:item]; top.submenu = sub; [mainMenu addItem:top]; NSApp.mainMenu = mainMenu;
    js(D, @"document.activeElement.blur(); return 1");
    NSEvent *down4 = key(NSEventTypeKeyDown, @"j", 38, NSEventModifierFlagCommand, w);
    [driven addObject:down4]; monitorSaw = 0; monitorSwallowed = 0;
    [D keyDown:down4]; [D keyUp:key(NSEventTypeKeyUp, @"j", 38, NSEventModifierFlagCommand, w)]; pause_(1.0);
    P(@"4. declined Cmd+J WITH monitor | monitor saw=%ld swallowed=%ld | menu fired=%ld | D log: %@ | A log: '%@'", (long)monitorSaw, (long)monitorSwallowed, (long)target.fired, js(D, @"return log.splice(0).join(' ')"), js(A, @"return log.splice(0).join(' ')"));
    [NSEvent removeMonitor:monitor];
    NSEvent *down5 = key(NSEventTypeKeyDown, @"j", 38, NSEventModifierFlagCommand, w);
    [D keyDown:down5]; [D keyUp:key(NSEventTypeKeyUp, @"j", 38, NSEventModifierFlagCommand, w)]; pause_(1.0);
    P(@"5. declined Cmd+J WITHOUT monitor | menu fired=%ld | D log: %@ | A log: '%@'", (long)target.fired, js(D, @"return log.splice(0).join(' ')"), js(A, @"return log.splice(0).join(' ')"));
    P(@"first responder still A=%d vetoes=%ld key=%d appActive=%d", w.firstResponder == A, (long)w.vetoCount, w.isKeyWindow, NSApp.isActive);
    P(@"=== done");
} return 0; }
