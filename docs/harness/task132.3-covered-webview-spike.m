// TASK-132.3 spike: can a web view that is in a window but covered by a sibling (an "attached" background tab)
// be snapshotted and driven with synthesized NSEvents, without becoming first responder or key?
// Controls: C = web view in no window, D = web view in the window but isHidden.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
@interface WKWebView (SpikeSPI)
- (pid_t)_webProcessIdentifier;
@end
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
static NSString *snapshotColor(WKWebView *wv) {
    __block NSImage *img = nil; __block NSError *err = nil; __block BOOL fin = NO;
    [wv takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *i, NSError *e) { img = i; err = e; fin = YES; }];
    if (!spin(8, ^BOOL{ return fin; })) return @"SNAPSHOT TIMEOUT";
    if (!img) return [NSString stringWithFormat:@"no image: %@", err.localizedDescription];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:[img TIFFRepresentation]];
    NSColor *c = [[rep colorAtX:rep.pixelsWide / 2 y:rep.pixelsHigh * 3 / 4] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return [NSString stringWithFormat:@"%ldx%ld px, sample rgb=(%.2f,%.2f,%.2f) a=%.2f", (long)rep.pixelsWide, (long)rep.pixelsHigh, c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent];
}
static NSString *page(NSString *bg) {
    return [NSString stringWithFormat:@"<!doctype html><body style='margin:0;background:%@'>"
        "<button id=b style='position:absolute;left:20px;top:20px;width:120px;height:40px'>btn</button>"
        "<input id=i style='position:absolute;left:20px;top:100px;width:200px;height:30px'>"
        "<div id=h style='position:absolute;left:20px;top:160px;width:120px;height:40px;background:#888'>hover</div>"
        "<script>window.log=[];for(const t of ['pointerdown','mousedown','mouseup','click','dblclick','mouseover','keydown','keypress','beforeinput','input','keyup','focusin','focusout'])document.addEventListener(t,e=>log.push(t+'/'+(e.isTrusted?'T':'u')+'/'+(e.target.id||e.target.nodeName)+(e.key?'/'+e.key:'')),true);"
        "window.ticks=0;setInterval(()=>ticks++,100);window.raf=0;(function f(){raf++;requestAnimationFrame(f)})();</script>", bg];
}
@interface VetoWindow : NSWindow @property (weak) NSView *vetoed; @property NSInteger vetoCount; @end
@implementation VetoWindow
- (BOOL)makeFirstResponder:(NSResponder *)r { if (r && r == self.vetoed) { self.vetoCount++; return NO; } return [super makeFirstResponder:r]; }
@end
static NSEvent *mouse(NSEventType type, NSPoint inWindow, NSWindow *w, NSInteger clicks) {
    return [NSEvent mouseEventWithType:type location:inWindow modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:clicks pressure:(type == NSEventTypeLeftMouseDown ? 1.0 : 0.0)];
}
static NSEvent *key(NSEventType type, NSString *chars, unsigned short code, NSWindow *w) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
}
int main(int argc, const char **argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    int showWindow = argc > 1 ? atoi(argv[1]) : 1;
    VetoWindow *w = [[VetoWindow alloc] initWithContentRect:NSMakeRect(60, 60, 800, 600) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    WKWebView *(^make)(void) = ^WKWebView *{ return [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:[WKWebViewConfiguration new]]; };
    WKWebView *A = make(), *B = make(), *C = make(), *D = make();
    // z-order: D (hidden), B (covered), A (front). C is in no window.
    BOOL clip = argc > 2 && atoi(argv[2]);
    D.hidden = YES; [w.contentView addSubview:D];
    if (clip) { NSView *clipView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)]; clipView.wantsLayer = YES; clipView.layer.masksToBounds = YES; [clipView addSubview:B]; [w.contentView addSubview:clipView]; P(@"B is inside a 1x1 clipping view"); }
    else [w.contentView addSubview:B];
    [w.contentView addSubview:A];
    if (showWindow == 2) [w orderFrontRegardless]; else if (showWindow) [w orderBack:nil];   // ordered in, never made key, app never activated
    [A loadHTMLString:page(@"#00c") baseURL:[NSURL URLWithString:@"https://a.example/"]];
    [B loadHTMLString:page(@"#c00") baseURL:[NSURL URLWithString:@"https://b.example/"]];
    [C loadHTMLString:page(@"#0a0") baseURL:[NSURL URLWithString:@"https://c.example/"]];
    [D loadHTMLString:page(@"#cc0") baseURL:[NSURL URLWithString:@"https://d.example/"]];
    spin(15, ^BOOL{ return !A.isLoading && !B.isLoading && !C.isLoading && !D.isLoading; }); pause_(1.0);
    P(@"window visible=%d key=%d appActive=%d firstResponder=%@", w.isVisible, w.isKeyWindow, NSApp.isActive, [w.firstResponder class]);
    P(@"pids A=%d B(covered)=%d C(no window)=%d D(hidden)=%d", A._webProcessIdentifier, B._webProcessIdentifier, C._webProcessIdentifier, D._webProcessIdentifier);
    NSString *stateJS = @"return JSON.stringify({vis: document.visibilityState, focus: document.hasFocus(), ticks: window.ticks, raf: window.raf})";
    for (NSArray *pair in @[@[@"A front", A], @[@"B covered", B], @[@"C no window", C], @[@"D hidden", D]]) P(@"state %@: %@", pair[0], js(pair[1], stateJS));
    pause_(3.0);
    for (NSArray *pair in @[@[@"A front", A], @[@"B covered", B], @[@"C no window", C], @[@"D hidden", D]]) P(@"state +3s %@: %@   snapshot: %@", pair[0], js(pair[1], stateJS), snapshotColor(pair[1]));

    // Fresh paint check: change the page after it went quiet, then snapshot.
    for (NSArray *pair in @[@[@"A front", A], @[@"B covered", B], @[@"C no window", C], @[@"D hidden", D]]) { js(pair[1], @"document.body.style.background = '#ffffff'; return 1"); P(@"after DOM change to white, %@ snapshot: %@", pair[0], snapshotColor(pair[1])); }
    // --- Input to B (covered), delivered straight to the view.
    NSString *(^who)(id) = ^NSString *(id r) { return r == A ? @"A" : r == B ? @"B" : r == D ? @"D" : r == w ? @"window" : NSStringFromClass([r class]); };
    P(@"first responder at start: %@", who(w.firstResponder));
    [w makeFirstResponder:A]; if (argc > 3 && atoi(argv[3])) { w.vetoed = B; P(@"window vetoes makeFirstResponder(B)"); }
    js(A, @"document.getElementById('i').focus(); return 1");
    id frBefore = w.firstResponder; P(@"first responder set to: %@", who(frBefore));
    NSPoint btn = NSMakePoint(80, 600 - 40), input = NSMakePoint(120, 600 - 115), hover = NSMakePoint(80, 600 - 180);
    [B mouseMoved:mouse(NSEventTypeMouseMoved, hover, w, 0)]; pause_(0.2);
    [B mouseDown:mouse(NSEventTypeLeftMouseDown, btn, w, 1)]; [B mouseUp:mouse(NSEventTypeLeftMouseUp, btn, w, 1)]; pause_(0.4);
    P(@"\nB after hover + click on button: %@", js(B, @"const l = log.splice(0); return l.join(' ')"));
    [B mouseDown:mouse(NSEventTypeLeftMouseDown, input, w, 1)]; [B mouseUp:mouse(NSEventTypeLeftMouseUp, input, w, 1)]; pause_(0.4);
    P(@"B after click on input: %@  activeElement=%@", js(B, @"const l = log.splice(0); return l.join(' ')"), js(B, @"return document.activeElement.id"));
    [B keyDown:key(NSEventTypeKeyDown, @"a", 0, w)]; [B keyUp:key(NSEventTypeKeyUp, @"a", 0, w)]; pause_(0.4);
    P(@"B after keyDown 'a' (view not first responder): %@  value=%@", js(B, @"const l = log.splice(0); return l.join(' ')"), js(B, @"return document.getElementById('i').value"));
    @try { [(id)B insertText:@"héllo" replacementRange:NSMakeRange(NSNotFound, 0)]; } @catch (NSException *e) { P(@"insertText threw: %@", e); } pause_(0.4);
    P(@"B after insertText: %@  value=%@", js(B, @"const l = log.splice(0); return l.join(' ')"), js(B, @"return document.getElementById('i').value"));
    [B keyDown:key(NSEventTypeKeyDown, @"\r", 36, w)]; [B keyUp:key(NSEventTypeKeyUp, @"\r", 36, w)]; pause_(0.3);
    P(@"B after Return: %@", js(B, @"const l = log.splice(0); return l.join(' ')"));
    P(@"A (front) saw: '%@'   first responder unchanged=%d (%@)  key=%d", js(A, @"return log.join(' ')"), w.firstResponder == frBefore, who(w.firstResponder), w.isKeyWindow);

    // --- Same input to C (no window), for comparison.
    [C mouseDown:mouse(NSEventTypeLeftMouseDown, btn, w, 1)]; [C mouseUp:mouse(NSEventTypeLeftMouseUp, btn, w, 1)]; pause_(0.4);
    P(@"\nC (no window) after click on button: '%@'", js(C, @"const l = log.splice(0); return l.join(' ')"));
    // --- Same input to D (in the window, isHidden): can a parked view be driven WITHOUT counting as visible?
    w.vetoed = D;
    [D mouseDown:mouse(NSEventTypeLeftMouseDown, btn, w, 1)]; [D mouseUp:mouse(NSEventTypeLeftMouseUp, btn, w, 1)]; pause_(0.4);
    [D mouseDown:mouse(NSEventTypeLeftMouseDown, input, w, 1)]; [D mouseUp:mouse(NSEventTypeLeftMouseUp, input, w, 1)]; pause_(0.4);
    [D keyDown:key(NSEventTypeKeyDown, @"a", 0, w)]; [D keyUp:key(NSEventTypeKeyUp, @"a", 0, w)]; pause_(0.4);
    @try { [(id)D insertText:@"héllo" replacementRange:NSMakeRange(NSNotFound, 0)]; } @catch (NSException *e) { P(@"insertText threw: %@", e); } pause_(0.4);
    P(@"D (hidden, in window) after click button, click input, key a, insertText: %@ value=%@ state=%@", js(D, @"const l = log.splice(0); return l.join(' ')"), js(D, @"return document.getElementById('i').value"), js(D, @"return JSON.stringify({vis: document.visibilityState, ticks: window.ticks, raf: window.raf})"));
    js(D, @"document.body.style.background = '#000000'; return 1"); P(@"D snapshot after DOM change to black: %@", snapshotColor(D));
    w.vetoed = B;
    // --- Now make the first responder explicit on A and repeat keys to B: does B still take them?
    [w makeFirstResponder:A];
    [B mouseDown:mouse(NSEventTypeLeftMouseDown, input, w, 1)]; [B mouseUp:mouse(NSEventTypeLeftMouseUp, input, w, 1)]; pause_(0.3);
    [B keyDown:key(NSEventTypeKeyDown, @"z", 6, w)]; [B keyUp:key(NSEventTypeKeyUp, @"z", 6, w)]; pause_(0.4);
    P(@"with A first responder — B: %@ value=%@ | first responder now %@ (A=%d)", js(B, @"const l = log.splice(0); return l.join(' ')"), js(B, @"return document.getElementById('i').value"), [w.firstResponder class], w.firstResponder == A);
    P(@"veto count=%ld  final first responder=%@  A activeElement=%@ A log='%@'", (long)w.vetoCount, who(w.firstResponder), js(A, @"return document.activeElement.id"), js(A, @"return log.join(' ')"));
    P(@"B visibleRect=%@ frame=%@ trackingAreas=%lu", NSStringFromRect(B.visibleRect), NSStringFromRect(B.frame), (unsigned long)B.trackingAreas.count);
    for (NSTrackingArea *t in B.trackingAreas) P(@"  tracking rect=%@ options=0x%lx", NSStringFromRect(t.rect), (unsigned long)t.options);
    P(@"=== done");
} return 0; }
