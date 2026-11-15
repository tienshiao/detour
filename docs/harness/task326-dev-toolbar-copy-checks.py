#!/usr/bin/env python3
"""TASK-326's runtime check of the user's decision (2026-11-14), through the
automation endpoint (TASK-228): the dev toolbar's link button copies the
pane's address as loaded, tracking parameters included, while Shift-Cmd-C
in the same window still copies the clean link.

A loopback page (127.0.0.1, so the tab is in dev mode and shows the dev
toolbar) is loaded with utm_source, gclid and a site parameter. The copy
button is found by hit-testing along the toolbar's middle line for the
"Copy URL" label, then clicked by window point. The clipboard's plain text
is saved first and put back at the end.

One launch of the given Detour.app with a fresh isolated data directory
(DETOUR_DATA_DIR, always set) and the endpoint on. Needs the sandbox off.
Usage:

  docs/harness/task326-dev-toolbar-copy-checks.py <worktree> /path/to/Detour.app <output-dir>
"""
import importlib.machinery, importlib.util, json, os, secrets, shutil, signal, subprocess, sys, time

wt, app, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("t324", os.path.join(wt, "docs/harness/task324-endpoint-checks.py"))
spec = importlib.util.spec_from_loader("t324", loader); t324 = importlib.util.module_from_spec(spec); loader.exec_module(t324)
client = t324.load_client()

fixture = os.path.join(out, "fixture"); os.makedirs(fixture, exist_ok=True)
with open(os.path.join(fixture, "app.html"), "w") as f:
    f.write("<!doctype html><title>Dev app</title><body><h1>Dev app</h1></body>")
server = t324.serve(fixture)
base = f"http://127.0.0.1:{server.server_address[1]}"
tracked = f"{base}/app.html?tab=1&utm_source=news&gclid=x"
clean = f"{base}/app.html?tab=1"

def pbpaste(): return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
def pbset(s): subprocess.run(["pbcopy"], input=s, text=True)

results = []
def check(name, ok, detail=""):
    results.append((name, ok)); print(("PASS " if ok else "FAIL ") + name + (f" -- {detail}" if detail else ""), flush=True)

def cleanup(data_dir):
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    t324.remove_webkit_storage(support, data_dir)
    shutil.rmtree(support, ignore_errors=True)
    subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
    suite = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
    if os.path.exists(suite): os.remove(suite)
    for key in (f"NSWindow Frame BrowserWindow-{data_dir}", f"NSSplitView Subview Frames BrowserSplitView-{data_dir}"):
        subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)

saved = pbpaste()
data_dir = f"DetourVerify-326-{secrets.token_hex(3)}"
print("data directory:", data_dir, flush=True)
support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1")
detour = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour")], env=env,
                          stdout=open(os.path.join(out, "app.log"), "w"), stderr=subprocess.STDOUT)
try:
    ep = os.path.join(support, "mcp-endpoint.json")
    for _ in range(80):
        if os.path.exists(ep): break
        time.sleep(0.25)
    time.sleep(2)
    endpoint = json.load(open(ep))
    s = client.Session(endpoint["url"], endpoint["token"], "task326-devtoolbar"); s.open()
    def call(tool, **a):
        r = s.call(tool, a); c = r.get("structuredContent")
        if r.get("isError"): raise RuntimeError(f"{tool}: {c}")
        return c
    call("open_url", window_id=1, url=tracked)
    tab = None
    for _ in range(40):
        items = call("list_tabs", window_id=1).get("items", [])
        tab = next((t for t in items if (t.get("title") or "") == "Dev app"), None)
        if tab: break
        time.sleep(0.25)
    check("page loaded with its parameters", tab is not None and tab.get("url") == tracked, tab and tab.get("url"))
    time.sleep(0.5)

    # The toolbar is a 30 pt bar across the top of the web content: find
    # the content's top edge under the page, then scan its middle line.
    window = next(w for w in call("list_windows")["windows"] if w["window_id"] == 1)
    width, height = int(window["frame"]["width"]), int(window["frame"]["height"])
    # First the toolbar's line: the right-most button (Select Element) on a
    # column near the window's right edge, then that line leftwards.
    button, line = None, None
    for y in range(2, 160, 3):
        for x in (width - 14, width - 20, width - 26):
            hit = call("hit_test", window_id=1, x=x, y=y)
            if hit.get("target") != "web_view" and (hit.get("label") or "") and "Button" in (hit.get("view") or ""):
                line = y; break
        if line: break
    if line is not None:
        for x in range(width - 14, width // 3, -4):
            hit = call("hit_test", window_id=1, x=x, y=line)
            if (hit.get("label") or "") == "Copy URL":
                button = hit; break
    check("found the dev toolbar's Copy URL button", button is not None, button)
    if button:
        f = button["frame"]
        pbset("SENTINEL")
        call("click", window_id=1, x=f["x"] + f["width"] / 2, y=f["y"] + f["height"] / 2)
        time.sleep(0.5)
        got = pbpaste()
        check("the dev toolbar's button copies the address as loaded", got == tracked, got)
    pbset("SENTINEL")
    call("run_menu_item", window_id=1, key="cmd+shift+c")
    time.sleep(0.4)
    got = pbpaste()
    check("Shift-Cmd-C in the same window still copies the clean link", got == clean, got)
    call("screenshot", window_id=1, save_to=os.path.join(out, "window.png"), include_image=False, overwrite=True)
    items = call("list_tabs", window_id=1).get("items", [])
    check("the tab keeps its tracked address", any(t.get("url") == tracked for t in items), [t.get("url") for t in items])
    s.close()
finally:
    detour.send_signal(signal.SIGTERM)
    try: detour.wait(10)
    except Exception: detour.kill()
    cleanup(data_dir)
    pbset(saved)
    server.shutdown()
failed = [n for n, ok in results if not ok]
print("ALL PASS" if not failed else f"FAILED: {failed}")
sys.exit(1 if failed else 0)
