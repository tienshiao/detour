#!/usr/bin/env python3
"""TASK-228.5 runtime check: the user's automation endpoint with per-client approval.

Launches the given Debug build with the user's setting on (no DETOUR_MCP) in its
own data directory, then, through the real bundled helper:
  1. the endpoint file has no token and a leftover mcp-token is deleted;
  2. the helper asks for a token and Detour's approval panel appears (found with
     CGWindowList, pictured with screencapture -l); Allow is pressed through
     Accessibility (AXPress on `automationApprovalAllow`), which does not
     activate Detour. With --preapprove (a locked screen, where Accessibility
     sees no windows) the client is approved beforehand instead;
  3. the helper's token file is 0600 in a 0700 folder and mcp-clients.json holds
     only its hash;
  4. the Private opt-in followed at once (a Private window, the key written from
     outside, list_windows);
  5. the indicator's Disconnect, reached with the endpoint's own click and
     choose_menu_item, revokes: the next request is refused, the token file is
     gone, the old token and the leftover shared token get 401.
Then it stops the app (SIGTERM) and removes its data directory, preferences
domain, window-frame keys and WebKit stores.

Usage: docs/harness/task2285-approval-check.py <path/to/Detour.app> [--preapprove]
Needs the sandbox off (the app, Accessibility, screencapture, loopback).
"""

import hashlib, json, os, secrets, shutil, sqlite3, subprocess, sys, tempfile, time, urllib.error, urllib.request, uuid

LISTER = r'''
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerPID"] as? Int) == pid && (w["kCGWindowName"] as? String) == "Detour Automation" {
    let b = w["kCGWindowBounds"] as! [String: Any]
    print(w["kCGWindowNumber"]!, w["kCGWindowIsOnscreen"] as? Bool ?? false, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
}
'''

AXPRESS = r'''
import ApplicationServices
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
let wanted = CommandLine.arguments[2]
let app = AXUIElementCreateApplication(pid)
func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}
func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
    if attr(e, "AXIdentifier") as? String == wanted { return e }
    guard depth < 10, let children = attr(e, "AXChildren") as? [AXUIElement] else { return nil }
    for child in children where !CFEqual(child, app) { if let found = find(child, depth + 1) { return found } }
    return nil
}
guard AXIsProcessTrusted() else { print("not trusted for Accessibility"); exit(2) }
for window in attr(app, "AXWindows") as? [AXUIElement] ?? [] where !CFEqual(window, app) {
    if let button = find(window, 0) { print("press", AXUIElementPerformAction(button, "AXPress" as CFString).rawValue); exit(0) }
}
print("no window shows \(wanted) to Accessibility (a locked screen shows none)"); exit(1)
'''

NAMESPACE = uuid.UUID("9DC6C971-6D72-44C8-9541-D6DEBE44E0A3")  # WebKitStorageScope.namespace
WEBKIT_DIR = os.path.expanduser("~/Library/WebKit/com.detourbrowser.mac")


def log(*parts):
    print(*parts, flush=True)


def build_tools(work):
    tools = {}
    for name, source in (("lister", LISTER), ("axpress", AXPRESS)):
        path = os.path.join(work, f"{name}.swift")
        open(path, "w").write(source)
        subprocess.run(["swiftc", "-O", "-o", os.path.join(work, name), path,
                        "-module-cache-path", os.path.join(work, "mc")], check=True)
        tools[name] = os.path.join(work, name)
    return tools


def cleanup(data_dir, support, pid):
    if pid:
        try:
            os.kill(pid, 15)
        except ProcessLookupError:
            pass
    db = os.path.join(support, "browser.db")
    if os.path.exists(db):
        connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = connection.execute("SELECT identifier, profileID FROM webKitStorageIdentifier").fetchall()
        connection.close()
        for identifier, profile in rows:
            ident = uuid.UUID(identifier)
            if ident != uuid.uuid5(NAMESPACE, f"{data_dir}/{str(uuid.UUID(profile)).upper()}"):
                continue
            for path in (os.path.join(WEBKIT_DIR, "WebsiteDataStore", str(ident)),
                         os.path.join(WEBKIT_DIR, "WebExtensions", str(ident).upper())):
                shutil.rmtree(path, ignore_errors=True)
    for key in (f"NSWindow Frame BrowserWindow-{data_dir}", f"NSSplitView Subview Frames BrowserSplitView-{data_dir}"):
        subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)
    subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
    plist = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
    if os.path.exists(plist):
        os.remove(plist)
    shutil.rmtree(support, ignore_errors=True)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    app_path = sys.argv[1].rstrip("/")
    preapprove = "--preapprove" in sys.argv
    if app_path.startswith("/Applications/"):
        print("refusing the installed app")
        return 2
    data_dir = f"DetourCheck2285-{secrets.token_hex(3)}"
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    endpoint_path = os.path.join(support, "mcp-endpoint.json")
    work = tempfile.mkdtemp(prefix="task2285-")
    tools = build_tools(work)
    app = helper = None
    failures = []

    def check(condition, what):
        log(("ok   " if condition else "FAIL ") + what)
        if not condition:
            failures.append(what)

    try:
        subprocess.run(["defaults", "write", f"com.detourbrowser.mac.{data_dir}", "AutomationEndpointEnabled",
                        "-bool", "YES"], check=True)
        os.makedirs(support)
        open(os.path.join(support, "mcp-token"), "w").write("leftover-shared-token-0123456789abcdef01234567\n")
        name = "claude-code"
        token_file = os.path.join(support, "mcp-clients", hashlib.sha256(name.encode()).hexdigest() + ".token")
        if preapprove:
            token = secrets.token_urlsafe(32)
            record = {"client_id": str(uuid.uuid4()), "name": name, "title": "Claude Code (check)", "version": "1",
                      "created": "2026-11-14T00:00:00Z", "token_sha256": hashlib.sha256(token.encode()).hexdigest()}
            json.dump({"version": 1, "clients": [record]}, open(os.path.join(support, "mcp-clients.json"), "w"))
            os.makedirs(os.path.dirname(token_file), mode=0o700)
            with open(os.open(token_file, os.O_WRONLY | os.O_CREAT, 0o600), "w") as handle:
                handle.write(token + "\n")

        app = subprocess.Popen([app_path + "/Contents/MacOS/Detour"], env={**os.environ, "DETOUR_DATA_DIR": data_dir},
                               stdout=open(os.path.join(work, "app.log"), "w"), stderr=subprocess.STDOUT)
        for _ in range(60):
            if os.path.exists(endpoint_path):
                break
            time.sleep(0.5)
        endpoint = json.load(open(endpoint_path))
        check("token" not in endpoint and endpoint.get("test_run") is False, "the endpoint file carries no token")
        check(not os.path.exists(os.path.join(support, "mcp-token")), "the leftover mcp-token is deleted")

        helper = subprocess.Popen([app_path + "/Contents/MacOS/detour-mcp"], env={**os.environ, "DETOUR_DATA_DIR": data_dir},
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)

        def send(message):
            helper.stdin.write(json.dumps(message) + "\n")
            helper.stdin.flush()

        def receive():
            return json.loads(helper.stdout.readline())

        counter = [100]

        def call(tool, arguments=None):
            counter[0] += 1
            send({"jsonrpc": "2.0", "id": counter[0], "method": "tools/call",
                  "params": {"name": tool, "arguments": arguments or {}}})
            return receive()

        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": name, "title": "Claude Code (check)", "version": "1"}}})
        if not preapprove:
            panel = None
            for _ in range(40):
                out = subprocess.run([tools["lister"], str(app.pid)], capture_output=True, text=True).stdout.split()
                if out:
                    panel = out
                    break
                time.sleep(0.25)
            check(panel is not None, f"the approval panel is on screen: {panel}")
            if panel:
                shot = os.path.join(work, "panel.png")
                subprocess.run(["screencapture", "-o", "-x", "-l", panel[0], shot])
                log("     panel picture:", shot if os.path.exists(shot) else "none (locked screen?)")
            time.sleep(1.3)  # the buttons arm after 1 s
            pressed = subprocess.run([tools["axpress"], str(app.pid), "automationApprovalAllow"],
                                     capture_output=True, text=True)
            log("     AXPress:", pressed.stdout.strip())
            if pressed.returncode != 0:
                check(False, "Allow pressed through Accessibility (rerun with --preapprove on a locked screen)")
                return 1
        initialized = receive()
        check(initialized.get("result", {}).get("serverInfo", {}).get("name") == "detour", "the helper's session starts")
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})

        windows = call("list_windows")["result"]["structuredContent"]
        check(windows["app_active"] is False, "Detour stayed in the background")
        clients = json.load(open(os.path.join(support, "mcp-clients.json")))["clients"]
        token = open(token_file).read().strip()
        check(len(clients) == 1 and token not in json.dumps(clients), "mcp-clients.json holds one record and no token")
        check(oct(os.stat(token_file).st_mode & 0o777) == "0o600"
              and oct(os.stat(os.path.dirname(token_file)).st_mode & 0o777) == "0o700",
              "the helper's token is 0600 in a 0700 folder")

        call("run_menu_item", {"window_id": 1, "path": ["File", "New Private Window"]})
        time.sleep(1.5)
        off = call("list_windows")["result"]["structuredContent"]
        subprocess.run(["defaults", "write", f"com.detourbrowser.mac.{data_dir}", "AutomationAllowPrivate", "-bool", "YES"])
        time.sleep(1)
        on = call("list_windows")["result"]["structuredContent"]
        subprocess.run(["defaults", "write", f"com.detourbrowser.mac.{data_dir}", "AutomationAllowPrivate", "-bool", "NO"])
        time.sleep(1)
        off_again = call("list_windows")["result"]["structuredContent"]
        check(off["hidden_private_windows"] == 1 and on["hidden_private_windows"] == 0
              and off_again["hidden_private_windows"] == 1, "the Private opt-in follows the setting at once")

        window = [w for w in off_again["windows"] if not w.get("is_private")][0]
        width, height = window["frame"]["width"], window["frame"]["height"]
        spot = None
        for dy in (21, 22, 24, 30):
            for dx in (30, 50, 70):
                hit = call("hit_test", {"window_id": window["window_id"], "x": width - dx, "y": height - dy})
                if "AutomationIndicator" in json.dumps(hit):
                    spot = (width - dx, height - dy)
                    break
            if spot:
                break
        check(spot is not None, "the indicator is found")
        call("click", {"window_id": window["window_id"], "x": spot[0], "y": spot[1]})
        menu = call("list_menu", {"timeout_ms": 2000})["result"]["structuredContent"]
        titles = [item.get("title") for item in menu.get("items", [])]
        check("Disconnect Claude Code (check)" in titles, f"the indicator names the approved client: {titles}")
        call("choose_menu_item", {"title": "Disconnect Claude Code (check)"})
        refused = call("list_windows")
        check("revoked" in json.dumps(refused), "the next request is refused as revoked")
        check(not os.path.exists(token_file), "the helper deleted its token")
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for label, bearer in (("the old token", token), ("the leftover shared token",
                                                          "leftover-shared-token-0123456789abcdef01234567")):
            request = urllib.request.Request(endpoint["url"], data=b"{}", method="POST",
                                             headers={"Content-Type": "application/json", "Authorization": f"Bearer {bearer}"})
            try:
                opener.open(request, timeout=5)
                check(False, f"{label} is refused")
            except urllib.error.HTTPError as error:
                check(error.code == 401, f"{label} is refused ({error.code})")
    finally:
        if helper:
            helper.stdin.close()
            helper.wait(5)
        if app:
            app.terminate()  # SIGTERM: removes the endpoint file
            app.wait(10)
        cleanup(data_dir, support, None)
        log("work folder (logs, panel picture):", work)
    log("PASSED" if not failures else f"FAILED: {failures}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
