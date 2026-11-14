#!/usr/bin/env python3
"""TASK-326's runtime checks, through the automation endpoint (TASK-228):
Copy URL copies the page's address without its tracking parameters, and the
page, its history and its session keep the address as loaded.

Launches the given Detour.app with a fresh isolated data directory
(DETOUR_DATA_DIR, always set) and the endpoint on, serves a local fixture
page at an address carrying utm_*, fbclid, gclid and _ga, and checks:
Edit > Copy URL by menu path, Shift-Cmd-C by key equivalent, the faux
address bar's Copy Link button (found by hit test), the sidebar row's
context menu Copy URL (a right click on the row), the tab's URL before and
after, and after quitting the history and session databases. The clipboard's plain
text is saved first and put back at the end (pbpaste/pbcopy: an image, a
file or rich text on it is not restored).

Needs the sandbox off (it launches an app and uses the pasteboard). Usage:

  docs/harness/task326-copy-url-checks.py <worktree> /path/to/Detour.app <output-dir>

Afterwards delete the run's NSWindow Frame / NSSplitView Subview Frames
defaults keys and its data directory (the script prints its name).
"""
import importlib.machinery, importlib.util, json, os, secrets, signal, sqlite3, subprocess, sys, time

wt, app, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("t324", os.path.join(wt, "docs/harness/task324-endpoint-checks.py"))
spec = importlib.util.spec_from_loader("t324", loader); t324 = importlib.util.module_from_spec(spec); loader.exec_module(t324)
client = t324.load_client()

fixture = os.path.join(out, "fixture"); os.makedirs(fixture, exist_ok=True)
with open(os.path.join(fixture, "article.html"), "w") as f:
    f.write("<!doctype html><title>Tracked article</title><body><h1 id=comments>Article</h1></body>")
server = t324.serve(fixture)
base = f"http://127.0.0.1:{server.server_address[1]}"
tracked = f"{base}/article.html?id=42&utm_source=news&utm_medium=email&fbclid=abc&gclid=def&_ga=1.2.3&ref=home#comments"
clean = f"{base}/article.html?id=42&ref=home#comments"

def pbpaste(): return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
def pbset(s): subprocess.run(["pbcopy"], input=s, text=True)

saved = pbpaste()
run = secrets.token_hex(3)
data_dir = f"DetourVerify-326-{run}"
support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1")
results = []
def check(name, ok, detail=""):
    results.append((name, ok)); print(("PASS " if ok else "FAIL ") + name + (f" -- {detail}" if detail else ""), flush=True)

detour = None
try:
    detour = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour")], env=env,
                              stdout=open(os.path.join(out, "app.log"), "w"), stderr=subprocess.STDOUT)
    ep = os.path.join(support, "mcp-endpoint.json")
    for _ in range(80):
        if os.path.exists(ep): break
        time.sleep(0.25)
    time.sleep(2)
    endpoint = json.load(open(ep))
    s = client.Session(endpoint["url"], endpoint["token"], "task326-verify"); s.open()
    def call(tool, **a):
        r = s.call(tool, a); c = r.get("structuredContent")
        if r.get("isError"): raise RuntimeError(f"{tool}: {c}")
        return c
    call("open_url", window_id=1, url=tracked)
    tab = None
    for _ in range(40):
        tabs = call("list_tabs", window_id=1)
        items = tabs.get("items", [])
        tab = next((t for t in items if (t.get("title") or "") == "Tracked article"), None)
        if tab: break
        time.sleep(0.25)
    json.dump(tabs, open(os.path.join(out, "tabs-before.json"), "w"), indent=1)
    check("page loaded", tab is not None)
    check("loaded URL keeps its parameters (before)", tab and tab.get("url") == tracked, tab and tab.get("url"))

    pbset("SENTINEL")
    call("run_menu_item", window_id=1, path=["Edit", "Copy URL"])
    time.sleep(0.3)
    got = pbpaste(); check("Edit > Copy URL copies the clean URL", got == clean, got)

    pbset("SENTINEL")
    call("run_menu_item", window_id=1, key="cmd+shift+c")
    time.sleep(0.3)
    got = pbpaste(); check("Shift-Cmd-C (key equivalent) copies the clean URL", got == clean, got)

    # Faux address bar's link button: find it by hit-testing the sidebar's top.
    button = None
    for y in range(20, 140, 4):
        for x in range(150, 300, 6):
            h = call("hit_test", window_id=1, x=x, y=y)
            label = json.dumps(h)
            if "Copy Link" in label:
                button = (x, y); break
        if button: break
    check("found the address bar's Copy Link button", button is not None)
    if button:
        pbset("SENTINEL")
        call("click", window_id=1, x=button[0], y=button[1])
        time.sleep(0.4)
        got = pbpaste(); check("address bar Copy Link copies the clean URL", got == clean, got)

    # Sidebar row context menu: a right click on the row's own background
    # (its label and icon take a right click without opening a menu).
    row = None
    for y in range(100, 700, 6):
        h = call("hit_test", window_id=1, x=80, y=y)
        if "Tracked article" in json.dumps(h):
            row = (80, y); break
    check("found the tab's sidebar row", row is not None)
    if row:
        pbset("SENTINEL")
        menu = None
        for x in range(6, 226, 4):
            v = call("hit_test", window_id=1, x=x, y=row[1]).get("view")
            if v in ("NSTextField", "NSImageView", "BrowserWebView", "NSSplitView", "HoverButton"): continue
            r = call("click", window_id=1, x=x, y=row[1], button="right")
            if r.get("menu_open"):
                menu = call("list_menu", timeout_ms=2000); break
        if menu is None: raise RuntimeError("no sidebar menu opened")
        print("menu:", [i.get("title") for i in menu.get("items", [])])
        titles = [i.get("title") for i in menu.get("items", [])]
        title = "Copy URL" if "Copy URL" in titles else "Copy Link"
        call("choose_menu_item", title=title)
        time.sleep(0.3)
        got = pbpaste(); check(f"sidebar menu {title} copies the clean URL", got == clean, got)

    call("screenshot", window_id=1, save_to=os.path.join(out, "window.png"), include_image=False, overwrite=True)
    tabs = call("list_tabs", window_id=1)
    tab = next((t for t in tabs.get("items", []) if (t.get("title") or "") == "Tracked article"), None)
    check("loaded URL keeps its parameters (after)", tab and tab.get("url") == tracked, tab and tab.get("url"))
    s.close()
finally:
    if detour:
        detour.send_signal(signal.SIGTERM)
        try: detour.wait(10)
        except Exception: detour.kill()
    # History and session records after quit.
    try:
        h = sqlite3.connect(f"file:{os.path.join(support, 'history.db')}?mode=ro", uri=True)
        urls = [r[0] for r in h.execute("SELECT url FROM historyURL")]
        check("history keeps the tracked URL", any("utm_source=news" in u for u in urls), urls)
        b = sqlite3.connect(f"file:{os.path.join(support, 'browser.db')}?mode=ro", uri=True)
        turls = [r[0] for r in b.execute("SELECT url FROM tab")]
        check("session keeps the tracked URL", tracked in turls, turls)
    except Exception as e:
        check("read history/session", False, repr(e))
    pbset(saved)
    server.shutdown()
    t324.remove_webkit_storage(support, data_dir)
    print("support dir:", support)
print("ALL PASS" if all(ok for _, ok in results) else "SOME FAILED")
