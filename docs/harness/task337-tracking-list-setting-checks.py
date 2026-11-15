#!/usr/bin/env python3
"""TASK-337's runtime checks: the AdGuard URL Tracking list's switch in
Settings > Content Blocking gates every fetch of the list, and Copy URL uses
the built-in names alone while it is off.

A local server serves the TASK-329 test excerpt plus rules for the loopback
page's host at /17.txt and logs every request it gets; Detour's Debug build
fetches the list from it (DETOUR_TRACKING_FILTER_URL). One isolated data
directory (DETOUR_DATA_DIR, always set) across two launches:

  1. launch, switch on (the default): the list is requested and cached;
     Shift-Cmd-C copies the address without the list's site parameters.
  2. switch off in Settings (Accessibility press): Shift-Cmd-C keeps the
     list's parameters (built-in names only); Update All Now makes no request.
  3. relaunch: no request at launch; the switch shows off; the cache is kept.
  4. the server answers 503; switch on: one request, and the cached rules are
     back in use (Shift-Cmd-C clean again) although the download failed.
  5. switch off, server back: Clear Cache & Redownload makes no request and
     deletes the cached text.
  6. switch on: the list is requested in full and cached again; Copy is clean.

The positive steps (1, 4, 6) are the control for the empty logs of 2, 3, 5.
Needs the sandbox off (it launches an app, posts Accessibility actions and
uses the pasteboard) and Accessibility for the shell's host. Usage:

  docs/harness/task337-tracking-list-setting-checks.py <worktree> /path/to/Detour.app <output-dir> <axdrive>

<axdrive> is docs/harness/task327/axdrive.swift compiled. The run's data
directory, WebKit stores, defaults suite and window keys are removed at the end.
"""
import http.server, importlib.machinery, importlib.util, json, os, re, secrets, shutil, signal, subprocess, sys, threading, time

wt, app, out, axdrive = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
os.makedirs(out, exist_ok=True)
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("t324", os.path.join(wt, "docs/harness/task324-endpoint-checks.py"))
spec = importlib.util.spec_from_loader("t324", loader); t324 = importlib.util.module_from_spec(spec); loader.exec_module(t324)
client = t324.load_client()

swift = open(os.path.join(wt, "DetourTests/TrackingParameterFilterFixture.swift")).read()
body = re.search(r'#"""\n(.*?)\n\s*"""#', swift, re.S).group(1)
excerpt = "\n".join(line[4:] if line.startswith("    ") else line for line in body.split("\n"))
excerpt += """
! (Detour runtime check) rules for the loopback page's host
||127.0.0.1^$removeparam=ref_
$removeparam=asc_campaign,domain=127.0.0.1
"""

fixture = os.path.join(out, "fixture"); os.makedirs(fixture, exist_ok=True)
with open(os.path.join(fixture, "17.txt"), "w") as f: f.write(excerpt)
with open(os.path.join(fixture, "article.html"), "w") as f:
    f.write("<!doctype html><title>Site article</title><body><h1 id=c>Site article</h1></body>")

requests = []          # (time, path, If-None-Match) of every list request
mode = {"list": "ok"}  # "ok" serves the list, "fail" answers 503
lock = threading.Lock()

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=fixture, **k)
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/17.txt"):
            with lock: requests.append((time.time(), self.path, self.headers.get("If-None-Match")))
            if mode["list"] == "fail":
                self.send_response(503); self.send_header("Content-Length", "0"); self.end_headers(); return
        return super().do_GET()

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"
tracked = f"{base}/article.html?id=42&ref_=nav&asc_campaign=fall&utm_source=news&gclid=x#c"
clean = f"{base}/article.html?id=42#c"
builtin_only = f"{base}/article.html?id=42&ref_=nav&asc_campaign=fall#c"

def list_requests():
    with lock: return list(requests)

def pbpaste(): return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
def pbset(s): subprocess.run(["pbcopy"], input=s, text=True)

results = []
def check(name, ok, detail=""):
    results.append((name, ok)); print(("PASS " if ok else "FAIL ") + name + (f" -- {detail}" if detail else ""), flush=True)

data_dir = f"DetourVerify-337-{secrets.token_hex(3)}"
support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
cache = os.path.join(support, "ContentBlocker", "adguard-url-tracking.txt")
print("data directory:", data_dir, "server:", base, flush=True)

def launch(label):
    ep = os.path.join(support, "mcp-endpoint.json")
    if os.path.exists(ep): os.remove(ep)
    env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1", DETOUR_TRACKING_FILTER_URL=f"{base}/17.txt")
    detour = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour")], env=env,
                              stdout=open(os.path.join(out, f"app-{label}.log"), "w"), stderr=subprocess.STDOUT)
    for _ in range(80):
        if os.path.exists(ep): break
        time.sleep(0.25)
    time.sleep(2)
    endpoint = json.load(open(ep))
    s = client.Session(endpoint["url"], endpoint["token"], f"task337-{label}"); s.open()
    def call(tool, **a):
        r = s.call(tool, a); c = r.get("structuredContent")
        if r.get("isError"): raise RuntimeError(f"{tool}: {c}")
        return c
    return detour, s, call

def stop(detour, s):
    try: s.close()
    except Exception: pass
    detour.send_signal(signal.SIGTERM)
    try: detour.wait(10)
    except Exception: detour.kill()

def ax(*args):
    r = subprocess.run([axdrive, *args], capture_output=True, text=True, env=dict(os.environ, AXWINDOW="Settings"))
    return r.stdout.strip()

def settings(call, pid):
    call("open_ui", what="settings", pane="contentblocker"); time.sleep(1)
    return ax("find", str(pid), "trackingParameterListEnabled")

def press(pid, identifier):
    got = ax("press", str(pid), identifier); time.sleep(0.5); return got

def load_page(call):
    call("open_url", window_id=1, url=tracked)
    for _ in range(40):
        items = call("list_tabs", window_id=1).get("items", [])
        if any((t.get("title") or "") == "Site article" for t in items): return True
        time.sleep(0.25)
    return False

def copy(call):
    pbset("SENTINEL"); call("run_menu_item", window_id=1, key="cmd+shift+c"); time.sleep(0.4); return pbpaste()

def wait_for(predicate, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if predicate(): return True
        time.sleep(0.25)
    return predicate()

saved = pbpaste()
try:
    # 1. On by default: fetched at launch.
    detour, s, call = launch("1")
    pid = detour.pid
    check("1: the list is requested at launch", wait_for(lambda: len(list_requests()) >= 1, 20), list_requests())
    check("1: and cached", wait_for(lambda: os.path.exists(cache), 10))
    check("1: page loaded", load_page(call))
    got = copy(call); check("1: Shift-Cmd-C leaves out the list's site parameters", got == clean, got)
    state = settings(call, pid)
    check("1: the switch is on and named", "value=1" in state and "desc=" in state, state)
    status = ax("find", str(pid), "trackingParameterListStatus")
    check("1: the status line gives the rule count", "rules" in status, status)
    n = len(list_requests())

    # 2. Off: no use, no fetch on Update All Now.
    press(pid, "trackingParameterListEnabled")
    state = ax("find", str(pid), "trackingParameterListEnabled")
    check("2: the switch is off", "value=0" in state, state)
    got = copy(call); check("2: Shift-Cmd-C uses the built-in names only", got == builtin_only, got)
    press(pid, "contentBlockerUpdateAll"); time.sleep(4)
    check("2: Update All Now makes no request for the list", len(list_requests()) == n, list_requests()[n:])
    check("2: the cache is kept", os.path.exists(cache))
    stop(detour, s)

    # 3. Relaunch while off.
    detour, s, call = launch("3"); pid = detour.pid
    time.sleep(6)
    check("3: no request at launch while off", len(list_requests()) == n, list_requests()[n:])
    check("3: page loaded", load_page(call))
    got = copy(call); check("3: Shift-Cmd-C uses the built-in names only", got == builtin_only, got)
    state = settings(call, pid)
    check("3: the switch shows off", "value=0" in state, state)
    check("3: the cache is still on disk", os.path.exists(cache))

    # 4. On with the list unreachable: the cached rules are used.
    mode["list"] = "fail"
    press(pid, "trackingParameterListEnabled")
    check("4: turning it on requests the list", wait_for(lambda: len(list_requests()) == n + 1, 10), list_requests()[n:])
    time.sleep(1)
    got = copy(call); check("4: offline, the cached rules are in use again", got == clean, got)
    n = len(list_requests())

    # 5. Off, then Clear Cache & Redownload.
    mode["list"] = "ok"
    press(pid, "trackingParameterListEnabled")
    press(pid, "contentBlockerClearCache"); time.sleep(4)
    check("5: Clear Cache & Redownload makes no request for the list", len(list_requests()) == n, list_requests()[n:])
    check("5: and deletes its cached text", not os.path.exists(cache))
    got = copy(call); check("5: Shift-Cmd-C uses the built-in names only", got == builtin_only, got)

    # 6. On again: downloaded in full.
    press(pid, "trackingParameterListEnabled")
    check("6: turning it on requests the list", wait_for(lambda: len(list_requests()) == n + 1, 10), list_requests()[n:])
    check("6: in full (no If-None-Match)", len(list_requests()) > n and list_requests()[n][2] is None, list_requests()[n:])
    check("6: and caches it", wait_for(lambda: os.path.exists(cache), 10))
    got = copy(call); check("6: Shift-Cmd-C leaves out the list's site parameters", got == clean, got)
    status = ax("find", str(pid), "trackingParameterListStatus")
    check("6: the status line gives the rule count", "rules" in status, status)
    call("screenshot", window_id=1, save_to=os.path.join(out, "window.png"), include_image=False, overwrite=True)
    stop(detour, s)
    json.dump(list_requests(), open(os.path.join(out, "requests.json"), "w"), indent=1)
    print("list requests:", list_requests(), flush=True)
finally:
    pbset(saved)
    server.shutdown()
    t324.remove_webkit_storage(support, data_dir)
    shutil.rmtree(support, ignore_errors=True)
    subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
    suite = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
    if os.path.exists(suite): os.remove(suite)
    for key in (f"NSWindow Frame BrowserWindow-{data_dir}", f"NSSplitView Subview Frames BrowserSplitView-{data_dir}"):
        subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)
    print("removed", data_dir, flush=True)
failed = [n for n, ok in results if not ok]
print("ALL PASS" if not failed else f"FAILED: {failed}")
sys.exit(1 if failed else 0)
