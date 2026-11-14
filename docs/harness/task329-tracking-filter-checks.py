#!/usr/bin/env python3
"""TASK-329's runtime checks, through the automation endpoint (TASK-228):
Copy URL also leaves out the parameters the downloaded AdGuard URL Tracking
filter names for the page's site, and falls back to the built-in names when
the list cannot be downloaded.

Serves, from a local fixture server, the test excerpt of the list
(DetourTests/TrackingParameterFilterFixture.swift) plus three rules for the
loopback page's host, and a page at an address carrying site-specific
parameters. Two launches of the given Detour.app, each with a fresh isolated
data directory (DETOUR_DATA_DIR, always set), the endpoint on and
DETOUR_TRACKING_FILTER_URL (a Debug-build seam) pointing at the server:

  A. the list served: the list is fetched and cached; Shift-Cmd-C (key
     equivalent), Edit > Copy URL (menu path) put the clean address on the
     clipboard (site rules by host pattern and by domain=, a global list
     name, the built-in names); a page under the exception's path keeps the
     parameter the exception names; the tab keeps the tracked address.
  B. the list's URL answers 404: nothing cached, Shift-Cmd-C copies the
     address without the built-in names only, and the window shows no alert.

The clipboard's plain text is saved first and put back at the end.

Needs the sandbox off (it launches an app and uses the pasteboard). Usage:

  docs/harness/task329-tracking-filter-checks.py <worktree> /path/to/Detour.app <output-dir>

Each run's data directory, WebKit stores, defaults suite and window keys
are removed when it ends (the script prints the names).
"""
import importlib.machinery, importlib.util, json, os, re, secrets, shutil, signal, subprocess, sys, time

wt, app, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("t324", os.path.join(wt, "docs/harness/task324-endpoint-checks.py"))
spec = importlib.util.spec_from_loader("t324", loader); t324 = importlib.util.module_from_spec(spec); loader.exec_module(t324)
client = t324.load_client()

# The test excerpt, as the Swift raw string holds it, plus the loopback rules.
swift = open(os.path.join(wt, "DetourTests/TrackingParameterFilterFixture.swift")).read()
body = re.search(r'#"""\n(.*?)\n\s*"""#', swift, re.S).group(1)
excerpt = "\n".join(line[4:] if line.startswith("    ") else line for line in body.split("\n"))
excerpt += """  # (a port sits between host and path: hence ^* in the exception)
! (Detour runtime check) rules for the loopback page's host
||127.0.0.1^$removeparam=ref_
$removeparam=asc_campaign,domain=127.0.0.1
@@||127.0.0.1^*/keep/$removeparam=utm_source
"""

fixture = os.path.join(out, "fixture"); os.makedirs(os.path.join(fixture, "keep"), exist_ok=True)
with open(os.path.join(fixture, "17.txt"), "w") as f: f.write(excerpt)
for path, title in (("article.html", "Site article"), ("keep/page.html", "Kept page")):
    with open(os.path.join(fixture, path), "w") as f:
        f.write(f"<!doctype html><title>{title}</title><body><h1 id=c>{title}</h1></body>")
server = t324.serve(fixture)
base = f"http://127.0.0.1:{server.server_address[1]}"
tracked = f"{base}/article.html?id=42&ref_=nav&asc_campaign=fall&pjclid=7&utm_source=news&gclid=x&ref=home#c"
clean = f"{base}/article.html?id=42&ref=home#c"
builtin_only = f"{base}/article.html?id=42&ref_=nav&asc_campaign=fall&pjclid=7&ref=home#c"
kept = f"{base}/keep/page.html?utm_source=news&gclid=x&p=1"
kept_clean = f"{base}/keep/page.html?utm_source=news&p=1"

def pbpaste(): return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
def pbset(s): subprocess.run(["pbcopy"], input=s, text=True)

results = []
def check(name, ok, detail=""):
    results.append((name, ok)); print(("PASS " if ok else "FAIL ") + name + (f" -- {detail}" if detail else ""), flush=True)

def run(label, list_url, phase):
    data_dir = f"DetourVerify-329-{label}-{secrets.token_hex(3)}"
    print("data directory:", data_dir, flush=True)
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    cache = os.path.join(support, "ContentBlocker", "adguard-url-tracking.txt")
    env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1", DETOUR_TRACKING_FILTER_URL=list_url)
    detour = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour")], env=env,
                              stdout=open(os.path.join(out, f"app-{label}.log"), "w"), stderr=subprocess.STDOUT)
    try:
        ep = os.path.join(support, "mcp-endpoint.json")
        for _ in range(80):
            if os.path.exists(ep): break
            time.sleep(0.25)
        time.sleep(2)
        endpoint = json.load(open(ep))
        s = client.Session(endpoint["url"], endpoint["token"], f"task329-{label}"); s.open()
        def call(tool, **a):
            r = s.call(tool, a); c = r.get("structuredContent")
            if r.get("isError"): raise RuntimeError(f"{tool}: {c}")
            return c
        def load(url, title):
            call("open_url", window_id=1, url=url)
            for _ in range(40):
                items = call("list_tabs", window_id=1).get("items", [])
                tab = next((t for t in items if (t.get("title") or "") == title), None)
                if tab: return tab
                time.sleep(0.25)
            return None
        def copy(how):
            pbset("SENTINEL")
            if how == "key": call("run_menu_item", window_id=1, key="cmd+shift+c")
            else: call("run_menu_item", window_id=1, path=["Edit", "Copy URL"])
            time.sleep(0.4)
            return pbpaste()
        phase(call, load, copy, cache)
        call("screenshot", window_id=1, save_to=os.path.join(out, f"window-{label}.png"), include_image=False, overwrite=True)
        windows = call("list_windows")
        json.dump(windows, open(os.path.join(out, f"windows-{label}.json"), "w"), indent=1)
        s.close()
    finally:
        detour.send_signal(signal.SIGTERM)
        try: detour.wait(10)
        except Exception: detour.kill()
        cleanup(data_dir)

def cleanup(data_dir):
    """This run's data directory, its WebKit stores, its defaults suite and
    its window keys in the shared defaults domain."""
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    t324.remove_webkit_storage(support, data_dir)
    shutil.rmtree(support, ignore_errors=True)
    subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
    suite = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
    if os.path.exists(suite): os.remove(suite)
    for key in (f"NSWindow Frame BrowserWindow-{data_dir}", f"NSSplitView Subview Frames BrowserSplitView-{data_dir}"):
        subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)

def served(call, load, copy, cache):
    for _ in range(60):
        if os.path.exists(cache): break
        time.sleep(0.5)
    check("A: the list was downloaded and cached", os.path.exists(cache) and open(cache).read() == excerpt)
    tab = load(tracked, "Site article")
    check("A: page loaded with its parameters", tab is not None and tab.get("url") == tracked, tab and tab.get("url"))
    got = copy("key"); check("A: Shift-Cmd-C copies the clean URL (site, list and built-in names)", got == clean, got)
    got = copy("menu"); check("A: Edit > Copy URL copies the clean URL", got == clean, got)
    tab = load(kept, "Kept page")
    got = copy("key"); check("A: the exception keeps utm_source under /keep/", got == kept_clean, got)
    items = call("list_tabs", window_id=1).get("items", [])
    check("A: the tabs keep their tracked addresses",
          {t.get("url") for t in items} >= {tracked, kept}, [t.get("url") for t in items])

def missing(call, load, copy, cache):
    time.sleep(3)
    check("B: nothing cached when the list answers 404", not os.path.exists(cache))
    tab = load(tracked, "Site article")
    check("B: page loaded", tab is not None)
    got = copy("key"); check("B: Shift-Cmd-C falls back to the built-in names", got == builtin_only, got)
    windows = call("list_windows")
    check("B: no alert sheet or extra window", len(windows.get("items", windows.get("windows", []))) == 1, windows)

saved = pbpaste()
try:
    run("served", f"{base}/17.txt", served)
    run("missing", f"{base}/missing-17.txt", missing)
finally:
    pbset(saved)
    server.shutdown()
failed = [n for n, ok in results if not ok]
print("ALL PASS" if not failed else f"FAILED: {failed}")
sys.exit(1 if failed else 0)
