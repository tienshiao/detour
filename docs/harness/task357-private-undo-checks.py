#!/usr/bin/env python3
"""TASK-357's runtime check, through the automation endpoint: a closed
Private window's undo entries are gone, and a normal window's are not.

One launch of the given Detour.app with a fresh isolated data directory
(DETOUR_DATA_DIR, always set), the endpoint on, and Private windows allowed
by a launch argument (-AutomationAllowPrivate YES, the argument domain), so
nothing is written to any defaults domain. A local server counts requests.

  1. window 1 opens /normal.html, then closes it (Cmd+W): a normal entry.
  2. File > New Private Window; it opens /secret.html and closes it (Cmd+W),
     then Cmd+W until the Private window itself closes.
  3. Cmd+Z in window 1: the normal page comes back on the first press, and
     /secret.html is never requested again (before TASK-357 an undo rebuilt
     the Private tab, loading its page, in a space no window shows).
  4. A second Cmd+Z: still no /secret.html request.

Needs the sandbox off. Usage:

  docs/harness/task357-private-undo-checks.py <worktree> /path/to/Detour.app <output-dir>
"""
import http.server, importlib.machinery, importlib.util, json, os, secrets, shutil, signal, subprocess, sys, threading, time

wt, app, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("t324", os.path.join(wt, "docs/harness/task324-endpoint-checks.py"))
spec = importlib.util.spec_from_loader("t324", loader); t324 = importlib.util.module_from_spec(spec); loader.exec_module(t324)
client = t324.load_client()

hits = {}
hits_lock = threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        titles = {"/normal.html": "Normal page", "/secret.html": "Secret page"}
        if path not in titles:
            self.send_response(404); self.end_headers(); return
        with hits_lock:
            hits[path] = hits.get(path, 0) + 1
        data = f"<!doctype html><title>{titles[path]}</title><body>{titles[path]}</body>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"

def secret_hits():
    with hits_lock:
        return hits.get("/secret.html", 0)

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

data_dir = f"DetourVerify-357-{secrets.token_hex(3)}"
print("data directory:", data_dir, flush=True)
support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1")
detour = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour"), "-AutomationAllowPrivate", "YES"], env=env,
                          stdout=open(os.path.join(out, "app.log"), "w"), stderr=subprocess.STDOUT)
try:
    ep = os.path.join(support, "mcp-endpoint.json")
    for _ in range(80):
        if os.path.exists(ep): break
        time.sleep(0.25)
    time.sleep(2)
    endpoint = json.load(open(ep))
    s = client.Session(endpoint["url"], endpoint["token"], "task357"); s.open()
    def raw(tool, **a):
        r = s.call(tool, a); return r.get("structuredContent"), bool(r.get("isError"))
    def call(tool, **a):
        c, err = raw(tool, **a)
        if err: raise RuntimeError(f"{tool}: {c}")
        return c
    def tabs(window_id):
        return call("list_tabs", window_id=window_id).get("items", [])
    def wait_title(window_id, title, present=True):
        items = []
        for _ in range(40):
            items = tabs(window_id)
            if any((t.get("title") or "") == title for t in items) == present: return True, items
            time.sleep(0.25)
        return False, items

    # 1. A normal close.
    call("open_url", window_id=1, url=f"{base}/normal.html")
    ok, items = wait_title(1, "Normal page")
    check("normal page loaded in window 1", ok, [t.get("title") for t in items])
    call("run_menu_item", window_id=1, key="cmd+w")
    ok, items = wait_title(1, "Normal page", present=False)
    check("normal page closed", ok, [t.get("title") for t in items])
    time.sleep(0.5)

    # 2. A Private window: open and close a page, then close the window.
    call("run_menu_item", window_id=1, path=["File", "New Private Window"])
    private = None
    for _ in range(40):
        private = next((w for w in call("list_windows")["windows"] if w.get("is_private")), None)
        if private: break
        time.sleep(0.25)
    check("a Private window opened", private is not None)
    if private is None:
        raise RuntimeError("no Private window opened")
    pid_ = private["window_id"]
    call("open_url", window_id=pid_, url=f"{base}/secret.html")
    ok, items = wait_title(pid_, "Secret page")
    check("secret page loaded in the Private window", ok and secret_hits() >= 1, (secret_hits(), [t.get("title") for t in items]))
    call("run_menu_item", window_id=pid_, key="cmd+w")
    ok, items = wait_title(pid_, "Secret page", present=False)
    check("secret page closed", ok, [t.get("title") for t in items])
    time.sleep(0.5)
    for _ in range(6):
        if not any(w["window_id"] == pid_ for w in call("list_windows")["windows"]): break
        raw("run_menu_item", window_id=pid_, key="cmd+w")
        time.sleep(0.5)
    listed = call("list_windows")
    check("the Private window closed", not any(w["window_id"] == pid_ for w in listed["windows"])
          and listed.get("hidden_private_windows", 0) == 0, listed)
    before = secret_hits()

    # 3. Undo in the normal window.
    undo, err = raw("run_menu_item", window_id=1, key="cmd+z")
    print("first cmd+z:", undo, err, flush=True)
    ok, items = wait_title(1, "Normal page")
    check("the first Cmd+Z in window 1 brings the normal page back", ok, [t.get("title") for t in items])
    time.sleep(2)
    check("no request for the Private page after the undo", secret_hits() == before, (before, secret_hits()))

    # 4. Nothing else to undo.
    undo2, err2 = raw("run_menu_item", window_id=1, key="cmd+z")
    print("second cmd+z:", undo2, err2, flush=True)
    time.sleep(2)
    check("a second Cmd+Z requests the Private page neither", secret_hits() == before, (before, secret_hits()))
    windows = call("list_windows")
    check("no Private window came back", windows.get("hidden_private_windows", 0) == 0
          and not any(w.get("is_private") for w in windows["windows"]), windows)
    json.dump({"hits": hits, "windows": windows, "second_undo": undo2, "second_undo_error": err2},
              open(os.path.join(out, "result.json"), "w"), indent=1)
    s.close()
finally:
    detour.send_signal(signal.SIGTERM)
    try: detour.wait(10)
    except Exception: detour.kill()
    cleanup(data_dir)
    server.shutdown()

failed = [n for n, ok in results if not ok]
print("ALL PASS" if not failed else f"FAILED: {failed}")
sys.exit(1 if failed else 0)
