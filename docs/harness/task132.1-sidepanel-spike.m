// TASK-132.1 spike: does shipped WebKit vend chrome.sidePanel, and does it hand the app a sidebar?
// usage: spike <flag: 0|1> <manifestSidePanelKey: 0|1>
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

@interface WKPreferences (SpikeSPI)
+ (NSArray *)_features;
- (BOOL)_isEnabledForFeature:(id)feature;
- (void)_setEnabled:(BOOL)value forFeature:(id)feature;
@end
@interface NSObject (SpikeSidebarSPI)
- (id)sidebarForTab:(id)tab;
- (WKWebView *)webView;
- (void)willOpenSidebar;
- (void)willCloseSidebar;
- (BOOL)isEnabled;
- (id)associatedTab;
@end

static void P(NSString *fmt, ...) { va_list a; va_start(a, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a); printf("%s\n", s.UTF8String); fflush(stdout); }
static BOOL spin(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done()) { if ([end timeIntervalSinceNow] < 0) return NO; [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]]; }
    return YES;
}
static id evalJS(WKWebView *wv, NSString *body, NSTimeInterval timeout) {
    __block id out = nil; __block BOOL fin = NO;
    [wv callAsyncJavaScript:body arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id r, NSError *e) { out = e ? [NSString stringWithFormat:@"JSERROR: %@", e.userInfo[@"WKJavaScriptExceptionMessage"] ?: e.localizedDescription] : r; fin = YES; }];
    if (!spin(timeout, ^BOOL{ return fin; })) return @"EVAL TIMEOUT";
    return out;
}

@interface Tab : NSObject <WKWebExtensionTab> @property (strong) WKWebView *wv; @property (weak) id win; @end
@interface Win : NSObject <WKWebExtensionWindow> @property (strong) NSMutableArray *tabs; @end
@implementation Tab
- (WKWebView *)webViewForWebExtensionContext:(WKWebExtensionContext *)c { return self.wv; }
- (id<WKWebExtensionWindow>)windowForWebExtensionContext:(WKWebExtensionContext *)c { return self.win; }
- (NSURL *)urlForWebExtensionContext:(WKWebExtensionContext *)c { return self.wv.URL; }
- (NSString *)titleForWebExtensionContext:(WKWebExtensionContext *)c { return self.wv.title; }
- (BOOL)isSelectedForWebExtensionContext:(WKWebExtensionContext *)c { return [[self.win tabs] firstObject] == self; }
- (BOOL)isLoadingCompleteForWebExtensionContext:(WKWebExtensionContext *)c { return !self.wv.isLoading; }
@end
@implementation Win
- (NSArray *)tabsForWebExtensionContext:(WKWebExtensionContext *)c { return self.tabs; }
- (id<WKWebExtensionTab>)activeTabForWebExtensionContext:(WKWebExtensionContext *)c { return self.tabs.firstObject; }
- (WKWebExtensionWindowType)windowTypeForWebExtensionContext:(WKWebExtensionContext *)c { return WKWebExtensionWindowTypeNormal; }
- (WKWebExtensionWindowState)windowStateForWebExtensionContext:(WKWebExtensionContext *)c { return WKWebExtensionWindowStateNormal; }
- (CGRect)frameForWebExtensionContext:(WKWebExtensionContext *)c { return CGRectMake(0, 0, 1000, 700); }
@end

@interface Delegate : NSObject <WKWebExtensionControllerDelegate>
@property (strong) Win *win; @property (strong) NSMutableArray *presented; @property (strong) NSMutableArray *closed; @property BOOL implementSidebar;
@end
@implementation Delegate
- (NSArray *)webExtensionController:(WKWebExtensionController *)c openWindowsForExtensionContext:(WKWebExtensionContext *)x { return @[self.win]; }
- (id)webExtensionController:(WKWebExtensionController *)c focusedWindowForExtensionContext:(WKWebExtensionContext *)x { return self.win; }
- (void)_webExtensionController:(WKWebExtensionController *)c presentSidebar:(id)sidebar forExtensionContext:(WKWebExtensionContext *)x completionHandler:(void (^)(NSError *))done {
    P(@"  DELEGATE presentSidebar: %@", sidebar); [self.presented addObject:sidebar]; done(nil);
}
- (void)_webExtensionController:(WKWebExtensionController *)c closeSidebar:(id)sidebar forExtensionContext:(WKWebExtensionContext *)x completionHandler:(void (^)(NSError *))done {
    P(@"  DELEGATE closeSidebar: %@", sidebar); [self.closed addObject:sidebar]; done(nil);
}
- (BOOL)respondsToSelector:(SEL)s {
    if (!self.implementSidebar && (s == @selector(_webExtensionController:presentSidebar:forExtensionContext:completionHandler:) || s == @selector(_webExtensionController:closeSidebar:forExtensionContext:completionHandler:))) return NO;
    return [super respondsToSelector:s];
}
@end

int main(int argc, const char **argv) { @autoreleasepool {
    BOOL flagOn = argc > 1 && atoi(argv[1]); BOOL manifestKey = argc > 2 && atoi(argv[2]);
    [NSApplication sharedApplication];
    P(@"=== run: flag=%d manifest side_panel key=%d  macOS %@", flagOn, manifestKey, NSProcessInfo.processInfo.operatingSystemVersionString);

    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sp-ext-%d-%d", flagOn, manifestKey]];
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *manifest = [NSString stringWithFormat:@"{\"manifest_version\":3,\"name\":\"SP Spike\",\"version\":\"1\",\"description\":\"spike\",\"action\":{\"default_title\":\"x\"},\"permissions\":[\"sidePanel\",\"tabs\",\"storage\"],\"host_permissions\":[\"<all_urls>\"],\"background\":{\"service_worker\":\"bg.js\"}%@}", manifestKey ? @",\"side_panel\":{\"default_path\":\"panel.html\"}" : @""];
    NSString *bg = @"const probe = () => ({ sidePanel: typeof chrome.sidePanel, keys: chrome.sidePanel ? Object.getOwnPropertyNames(chrome.sidePanel).concat(['open','setOptions','getOptions','close','setPanelBehavior','getPanelBehavior','getLayout'].filter(k => typeof chrome.sidePanel[k] === 'function').map(k => 'fn:' + k)) : [], sidebarAction: typeof chrome.sidebarAction, tabGroups: typeof chrome.tabGroups, dbg: typeof chrome.debugger, getContexts: typeof chrome.runtime.getContexts, ContextType: typeof chrome.runtime.ContextType, identity: typeof chrome.identity, downloads: typeof chrome.downloads, dnr: typeof chrome.declarativeNetRequest, tabsGroup: typeof chrome.tabs.group });\n"
      "(async () => { const before = probe(); let defineError = null; try { Object.defineProperty(chrome, 'sidePanel', { value: { marker: 'polyfilled', open() { return Promise.resolve('opened'); } }, configurable: true, enumerable: true, writable: false }); } catch (e) { defineError = String(e); }\n"
      "  let junk = []; for (let i = 0; i < 300; i++) { junk.push(new Array(20000).fill(i)); if (junk.length > 20) junk = []; }\n"
      "  await new Promise(r => setTimeout(r, 300));\n"
      "  await chrome.storage.local.set({ workerProbe: { before, defineError, afterDefine: typeof chrome.sidePanel, marker: chrome.sidePanel && chrome.sidePanel.marker, viaBrowser: typeof browser.sidePanel, sameObject: chrome === browser } }); })();\n"
      "chrome.runtime.onMessage.addListener((m, s, reply) => { (async () => { try {\n"
      "  if (m.q === 'probe') return reply(probe());\n"
      "  const tabs = await chrome.tabs.query({}); const t = tabs[m.index || 0];\n"
      "  if (m.q === 'tabs') return reply(tabs.map(x => ({id: x.id, url: x.url, active: x.active, index: x.index})));\n"
      "  if (m.q === 'setOptions') { await chrome.sidePanel.setOptions({tabId: t.id, path: 'panel.html?tabId=' + t.id, enabled: true}); return reply({ok: true, tabId: t.id}); }\n"
      "  if (m.q === 'getOptions') return reply(await chrome.sidePanel.getOptions({tabId: t.id}));\n"
      "  if (m.q === 'open') { await chrome.sidePanel.open({tabId: t.id}); return reply({ok: true, tabId: t.id}); }\n"
      "  if (m.q === 'openWindow') { const w = await chrome.windows.getCurrent(); await chrome.sidePanel.open({windowId: w.id}); return reply({ok: true}); }\n"
      "  if (m.q === 'close') { await chrome.sidePanel.close({tabId: t.id}); return reply({ok: true}); }\n"
      "  reply({error: 'unknown q'});\n"
      "} catch (e) { reply({error: String(e && e.message || e)}); } })(); return true; });\n";
    [manifest writeToFile:[dir stringByAppendingPathComponent:@"manifest.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [bg writeToFile:[dir stringByAppendingPathComponent:@"bg.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"<!doctype html><title>page</title><body>page" writeToFile:[dir stringByAppendingPathComponent:@"page.html"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"<!doctype html><title>panel</title><body>panel<script src=panel.js></script>" writeToFile:[dir stringByAppendingPathComponent:@"panel.html"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"window.__panelLoaded = true;" writeToFile:[dir stringByAppendingPathComponent:@"panel.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    __block WKWebExtension *ext = nil; __block NSError *extErr = nil; __block BOOL fin = NO;
    [WKWebExtension extensionWithResourceBaseURL:[NSURL fileURLWithPath:dir] completionHandler:^(WKWebExtension *e, NSError *err) { ext = e; extErr = err; fin = YES; }];
    spin(10, ^BOOL{ return fin; });
    if (!ext) { P(@"extension failed to load: %@", extErr); return 1; }
    P(@"requestedPermissions: %@  errors: %@", [[ext.requestedPermissions allObjects] componentsJoinedByString:@","], ext.errors);

    WKWebExtensionControllerConfiguration *config = [WKWebExtensionControllerConfiguration nonPersistentConfiguration];
    WKWebsiteDataStore *store = [WKWebsiteDataStore nonPersistentDataStore];
    config.defaultWebsiteDataStore = store;
    config.webViewConfiguration.websiteDataStore = store;
    [config.webViewConfiguration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:@"globalThis.__spikeMarker = 'marker-from-controller-config';" injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];

    id feature = nil;
    for (NSString *listSel in @[@"_features", @"_experimentalFeatures", @"_internalDebugFeatures"]) {
        if (![WKPreferences respondsToSelector:NSSelectorFromString(listSel)]) { P(@"+[WKPreferences %@] absent", listSel); continue; }
        NSArray *list = [WKPreferences performSelector:NSSelectorFromString(listSel)];
        NSMutableArray *hits = [NSMutableArray new];
        for (id f in list) { NSString *key = [f valueForKey:@"key"]; if ([key rangeOfString:@"Extension" options:NSCaseInsensitiveSearch].location != NSNotFound || [key rangeOfString:@"Sidebar" options:NSCaseInsensitiveSearch].location != NSNotFound) [hits addObject:key]; if ([key isEqualToString:@"WebExtensionSidebarEnabled"]) feature = f; }
        P(@"+[WKPreferences %@] count %lu, extension/sidebar keys: %@", listSel, (unsigned long)list.count, [hits componentsJoinedByString:@", "]);
    }
    WKPreferences *prefs = config.webViewConfiguration.preferences;
    if (!feature) P(@"FEATURE WebExtensionSidebarEnabled: NOT in +[WKPreferences _features] (count %lu)", (unsigned long)[WKPreferences _features].count);
    else {
        P(@"FEATURE WebExtensionSidebarEnabled: present, default on this WebKit = %d", [prefs _isEnabledForFeature:feature]);
        [prefs _setEnabled:flagOn forFeature:feature];
        P(@"  set to %d -> reads back %d", flagOn, [prefs _isEnabledForFeature:feature]);
    }

    WKWebExtensionController *controller = [[WKWebExtensionController alloc] initWithConfiguration:config];
    Delegate *delegate = [Delegate new]; delegate.presented = [NSMutableArray new]; delegate.closed = [NSMutableArray new]; delegate.implementSidebar = YES;
    controller.delegate = delegate;

    WKWebExtensionContext *context = [WKWebExtensionContext contextForExtension:ext];
    context.uniqueIdentifier = @"spikespikespikespikespikespikesp";
    for (NSString *perm in ext.requestedPermissions) [context setPermissionStatus:WKWebExtensionContextPermissionStatusGrantedExplicitly forPermission:perm];
    [context setPermissionStatus:WKWebExtensionContextPermissionStatusGrantedExplicitly forPermission:@"sidePanel"];
    [context setPermissionStatus:WKWebExtensionContextPermissionStatusGrantedExplicitly forMatchPattern:[WKWebExtensionMatchPattern allURLsMatchPattern]];
    P(@"granted: %@   unsupportedAPIs: %@", [context.grantedPermissions.allKeys componentsJoinedByString:@","], context.unsupportedAPIs);
    P(@"context webViewConfiguration prefs flag (pre-load): %@", feature && context.webViewConfiguration ? @([context.webViewConfiguration.preferences _isEnabledForFeature:feature]) : @"(nil config)");

    Win *win = [Win new]; win.tabs = [NSMutableArray new]; delegate.win = win;
    NSError *loadErr = nil;
    if (![controller loadExtensionContext:context error:&loadErr]) { P(@"load failed: %@", loadErr); return 1; }
    P(@"context webViewConfiguration prefs flag (loaded): %@", feature ? @([context.webViewConfiguration.preferences _isEnabledForFeature:feature]) : @"n/a");

    // Two ordinary tabs in one window.
    NSWindow *nsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    for (int i = 0; i < 2; i++) {
        WKWebViewConfiguration *tc = [WKWebViewConfiguration new]; tc.webExtensionController = controller; tc.websiteDataStore = store;
        Tab *tab = [Tab new]; tab.wv = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:tc]; tab.win = win;
        [tab.wv loadHTMLString:[NSString stringWithFormat:@"<title>tab %d</title>tab %d", i, i] baseURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://tab%d.example/", i]]];
        [win.tabs addObject:tab]; if (i == 0) [nsWindow.contentView addSubview:tab.wv];
    }
    [controller didOpenWindow:win]; for (Tab *t in win.tabs) [controller didOpenTab:t]; [controller didFocusWindow:win];

    fin = NO; __block NSError *bgErr = nil;
    [context loadBackgroundContentWithCompletionHandler:^(NSError *e) { bgErr = e; fin = YES; }];
    if (!spin(15, ^BOOL{ return fin; })) P(@"background load TIMED OUT"); else P(@"background loaded, error: %@", bgErr);

    WKWebView *page = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300) configuration:context.webViewConfiguration];
    [page loadRequest:[NSURLRequest requestWithURL:[context.baseURL URLByAppendingPathComponent:@"page.html"]]];
    spin(10, ^BOOL{ return !page.isLoading && page.URL != nil; }); spin(0.5, ^BOOL{ return NO; });
    P(@"\n-- extension PAGE: %@", evalJS(page, @"return JSON.stringify({url: location.href, sidePanel: typeof chrome.sidePanel, sidebarAction: typeof chrome.sidebarAction, marker: globalThis.__spikeMarker || null, getContexts: typeof chrome.runtime.getContexts})", 5));
    NSString *(^ask)(NSString *) = ^NSString *(NSString *msg) {
        return [evalJS(page, [NSString stringWithFormat:@"return await new Promise(r => { const t = setTimeout(() => r('ASK TIMEOUT'), 8000); chrome.runtime.sendMessage(%@, x => { clearTimeout(t); r(JSON.stringify(x === undefined ? {undefinedReply: true, lastError: chrome.runtime.lastError && chrome.runtime.lastError.message} : x)); }); })", msg], 10) description];
    };
    P(@"-- WORKER start-up probe (via storage): %@", evalJS(page, @"for (let i = 0; i < 40; i++) { const r = await chrome.storage.local.get('workerProbe'); if (r.workerProbe) return JSON.stringify(r.workerProbe); await new Promise(x => setTimeout(x, 250)); } return 'no workerProbe in storage'", 15));
    P(@"-- PAGE define own property: %@", evalJS(page, @"let err = null; try { Object.defineProperty(chrome, 'sidePanel', { value: { marker: 'polyfilled' }, configurable: true, enumerable: true }); } catch (e) { err = String(e); } let junk = []; for (let i = 0; i < 300; i++) { junk.push(new Array(20000).fill(i)); if (junk.length > 20) junk = []; } await new Promise(r => setTimeout(r, 300)); return JSON.stringify({ err, after: typeof chrome.sidePanel, marker: chrome.sidePanel && chrome.sidePanel.marker, viaBrowser: typeof browser.sidePanel, sameObject: chrome === browser })", 10));
    P(@"-- WORKER probe: %@", ask(@"{q:'probe'}"));
    P(@"-- WORKER tabs: %@", ask(@"{q:'tabs'}"));

    Tab *tab0 = win.tabs[0], *tab1 = win.tabs[1];
    BOOL ctxResponds = [context respondsToSelector:@selector(sidebarForTab:)];
    P(@"\n-- sidebarForTab: responds=%d  tab0 before setOptions: %@", ctxResponds, ctxResponds ? [(id)context sidebarForTab:tab0] : nil);
    P(@"-- WORKER getOptions(tab0) before: %@", ask(@"{q:'getOptions'}"));
    P(@"-- WORKER setOptions(tab0): %@", ask(@"{q:'setOptions'}"));
    P(@"-- WORKER getOptions(tab0) after: %@", ask(@"{q:'getOptions'}"));
    id sb0 = ctxResponds ? [(id)context sidebarForTab:tab0] : nil, sb1 = ctxResponds ? [(id)context sidebarForTab:tab1] : nil;
    P(@"-- sidebarForTab after setOptions: tab0=%@ tab1=%@ same=%d", sb0, sb1, sb0 == sb1);
    P(@"-- WORKER open(tab0) [delegate implements presentSidebar]: %@", ask(@"{q:'open'}"));
    spin(1.0, ^BOOL{ return NO; });
    P(@"-- delegate presented count: %lu", (unsigned long)delegate.presented.count);
    id sidebar = delegate.presented.firstObject ?: sb0;
    if (sidebar) {
        @try {
            P(@"-- sidebar: enabled=%d associatedTab==tab0:%d title=%@", [sidebar isEnabled], [sidebar associatedTab] == tab0, [sidebar valueForKey:@"title"]);
            WKWebView *sw = [sidebar webView];
            P(@"-- sidebar.webView (before willOpen): %@ url=%@", sw.class, sw.URL);
            [sidebar willOpenSidebar];
            spin(8, ^BOOL{ return sw.URL != nil && !sw.isLoading; }); spin(0.5, ^BOOL{ return NO; });
            P(@"-- sidebar.webView after willOpenSidebar: url=%@", sw.URL);
            P(@"-- sidebar webView store == controller store: %d   userScripts: %lu   controller config scripts: %lu", sw.configuration.websiteDataStore == store, (unsigned long)sw.configuration.userContentController.userScripts.count, (unsigned long)config.webViewConfiguration.userContentController.userScripts.count);
            P(@"-- sidebar PAGE: %@", evalJS(sw, @"return JSON.stringify({url: location.href, loaded: !!window.__panelLoaded, marker: globalThis.__spikeMarker || null, sidePanel: typeof chrome.sidePanel, tabsGetCurrent: await new Promise(r => chrome.tabs.getCurrent(t => r(t === undefined ? 'undefined' : t.id)))})", 5));
            P(@"-- sidebar viewController: %@", [sidebar valueForKey:@"viewController"]);
            P(@"-- WORKER tabs after panel open (panel must not be a tab): %@", ask(@"{q:'tabs'}"));
            P(@"-- WORKER close(tab0): %@", ask(@"{q:'close'}"));
            spin(0.5, ^BOOL{ return NO; });
            P(@"-- delegate closed count: %lu", (unsigned long)delegate.closed.count);
        } @catch (NSException *e) { P(@"EXCEPTION inspecting sidebar: %@", e); }
    }
    P(@"-- WORKER open(tab1, no tab-specific options): %@", ask(@"{q:'open', index: 1}"));
    delegate.implementSidebar = NO;
    P(@"-- WORKER open(tab0) [delegate does NOT implement presentSidebar]: %@", ask(@"{q:'open'}"));
    P(@"=== done");
} return 0; }
