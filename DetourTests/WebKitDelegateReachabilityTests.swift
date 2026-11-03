import AppKit
import ObjectiveC
import UserNotifications
import WebKit
import XCTest
@testable import Detour

/// Every optional Objective-C protocol method the app implements is still
/// visible to the Objective-C runtime, so the framework actually calls it.
///
/// A Swift method only gets an Objective-C entry point by witnessing an
/// `@objc` protocol requirement. If its signature drifts from the SDK's (the
/// SDK's closure parameters gaining `@MainActor @Sendable` under complete
/// concurrency checking did this to twelve WebKit methods), the method stops
/// witnessing the requirement, loses its entry point, and WebKit silently stops
/// calling it: no JS alerts, no file panel, no auth sheet. The compiler warns
/// ("nearly matches") only when the method sits in the extension that declares
/// the conformance; this test catches the rest. Required methods are not listed:
/// a mismatch there is a compile error.
///
/// Each selector is also checked against the protocol, so a typo here fails
/// instead of passing vacuously.
final class WebKitDelegateReachabilityTests: XCTestCase {

    private struct Expectation {
        let cls: NSObject.Type
        let protocolName: String
        let selectors: [String]
    }

    private static let navigationDelegateShared = [
        "webView:decidePolicyForNavigationAction:preferences:decisionHandler:",
        "webView:decidePolicyForNavigationResponse:decisionHandler:",
        "webView:navigationResponse:didBecomeDownload:",
        "webView:navigationAction:didBecomeDownload:",
        "webView:didCommitNavigation:",
        "webView:didFailProvisionalNavigation:withError:",
        "webView:didStartProvisionalNavigation:",
    ]

    private static let windowUIDelegate = [
        "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
        "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
        "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
        "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
        "webViewDidClose:",
    ]

    private static let extensionWindow = [
        "tabsForWebExtensionContext:",
        "activeTabForWebExtensionContext:",
        "windowTypeForWebExtensionContext:",
        "isPrivateForWebExtensionContext:",
        "frameForWebExtensionContext:",
        "screenFrameForWebExtensionContext:",
        "windowStateForWebExtensionContext:",
        "focusForWebExtensionContext:completionHandler:",
        "closeForWebExtensionContext:completionHandler:",
    ]

    private static let expectations: [Expectation] = [
        Expectation(cls: BrowserWindowController.self, protocolName: "WKNavigationDelegate",
                    selectors: navigationDelegateShared + [
                        "webView:didFinishNavigation:",
                        "webView:didReceiveAuthenticationChallenge:completionHandler:",
                        "webViewWebContentProcessDidTerminate:",
                    ]),
        Expectation(cls: BrowserWindowController.self, protocolName: "WKUIDelegate",
                    selectors: windowUIDelegate),
        Expectation(cls: BrowserWindowController.self, protocolName: "WKWebExtensionWindow",
                    selectors: extensionWindow),

        Expectation(cls: QuickDetourWindowController.self, protocolName: "WKNavigationDelegate",
                    selectors: navigationDelegateShared + [
                        "webView:didReceiveAuthenticationChallenge:completionHandler:",
                        "webViewWebContentProcessDidTerminate:",
                    ]),
        Expectation(cls: QuickDetourWindowController.self, protocolName: "WKUIDelegate",
                    selectors: windowUIDelegate),
        Expectation(cls: QuickDetourWindowController.self, protocolName: "WKWebExtensionWindow",
                    selectors: extensionWindow),

        Expectation(cls: BrowserTab.self, protocolName: "WKNavigationDelegate",
                    selectors: navigationDelegateShared),
        Expectation(cls: BrowserTab.self, protocolName: "WKWebExtensionTab",
                    selectors: [
                        "webViewForWebExtensionContext:",
                        "windowForWebExtensionContext:",
                        "titleForWebExtensionContext:",
                        "urlForWebExtensionContext:",
                        "isLoadingCompleteForWebExtensionContext:",
                        "isPlayingAudioForWebExtensionContext:",
                        "isMutedForWebExtensionContext:",
                        "isPinnedForWebExtensionContext:",
                        "activateForWebExtensionContext:completionHandler:",
                        "loadURL:forWebExtensionContext:completionHandler:",
                        "reloadFromOrigin:forWebExtensionContext:completionHandler:",
                        "shouldGrantPermissionsOnUserGestureForWebExtensionContext:",
                        "closeForWebExtensionContext:completionHandler:",
                    ]),

        Expectation(cls: ExtensionManager.self, protocolName: "WKWebExtensionControllerDelegate",
                    selectors: [
                        "webExtensionController:openWindowsForExtensionContext:",
                        "webExtensionController:focusedWindowForExtensionContext:",
                        "webExtensionController:openOptionsPageForExtensionContext:completionHandler:",
                        "webExtensionController:openNewTabUsingConfiguration:forExtensionContext:completionHandler:",
                        "webExtensionController:openNewWindowUsingConfiguration:forExtensionContext:completionHandler:",
                        "webExtensionController:presentPopupForAction:forExtensionContext:completionHandler:",
                        "webExtensionController:promptForPermissions:inTab:forExtensionContext:completionHandler:",
                        "webExtensionController:promptForPermissionToAccessURLs:inTab:forExtensionContext:completionHandler:",
                        "webExtensionController:promptForPermissionMatchPatterns:inTab:forExtensionContext:completionHandler:",
                        "webExtensionController:didUpdateAction:forExtensionContext:",
                        "webExtensionController:sendMessage:toApplicationWithIdentifier:forExtensionContext:replyHandler:",
                        "webExtensionController:connectUsingMessagePort:forExtensionContext:completionHandler:",
                    ]),
        Expectation(cls: ExtensionPopoverController.self, protocolName: "WKUIDelegate",
                    selectors: ["webViewDidClose:"]),
        Expectation(cls: OffscreenDocumentHost.self, protocolName: "WKNavigationDelegate",
                    selectors: [
                        "webView:didFinishNavigation:",
                        "webView:didFailNavigation:withError:",
                        "webView:didFailProvisionalNavigation:withError:",
                    ]),

        Expectation(cls: DownloadManager.self, protocolName: "WKDownloadDelegate",
                    selectors: ["downloadDidFinish:", "download:didFailWithError:resumeData:"]),
        Expectation(cls: QuarantineDownloadGate.self, protocolName: "WKDownloadDelegate",
                    selectors: ["download:didFailWithError:resumeData:"]),

        Expectation(cls: ExtensionNotificationManager.self, protocolName: "UNUserNotificationCenterDelegate",
                    selectors: [
                        "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:",
                        "userNotificationCenter:willPresentNotification:withCompletionHandler:",
                    ]),
    ]

    func testEveryImplementedOptionalDelegateMethodIsReachableFromObjectiveC() {
        for expectation in Self.expectations {
            let className = NSStringFromClass(expectation.cls)
            guard let proto = objc_getProtocol(expectation.protocolName) else {
                XCTFail("No Objective-C protocol named \(expectation.protocolName)")
                continue
            }
            XCTAssertTrue(expectation.cls.conforms(to: proto),
                          "\(className) does not conform to \(expectation.protocolName)")
            for name in expectation.selectors {
                let selector = NSSelectorFromString(name)
                let declared = protocol_getMethodDescription(proto, selector, false, true).name != nil
                    || protocol_getMethodDescription(proto, selector, true, true).name != nil
                XCTAssertTrue(declared, "\(expectation.protocolName) declares no method \(name) (typo in this test?)")
                XCTAssertTrue(expectation.cls.instancesRespond(to: selector),
                              "\(className) implements \(name) in Swift but WebKit cannot see it: "
                              + "its signature no longer matches \(expectation.protocolName)'s requirement")
            }
        }
    }
}
