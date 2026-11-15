#!/usr/bin/env python3
"""TASK-228.7's runtime check of the user's decision (2026-11-14), through the
automation endpoint: a quarantine window (a Quick Detour on the Private
profile with a store of its own) follows "Allow agents to use Private
windows" as Private browser windows do.

A Link Route sends a link clicked on a localhost page to Quarantine. Two
launches of the given Detour.app, each with a fresh isolated data directory
(DETOUR_DATA_DIR, always set) and the endpoint on; the setting comes from a
launch argument (-AutomationAllowPrivate YES/NO, the argument domain), so
nothing is written to any defaults domain:

  off: list_windows leaves the quarantine out (hidden_private_windows 1);
       screenshot and hit_test by its window_id (the next id after the
       browser window's: one counter hands ids out in window order) are
       private_unreachable.
  on:  list_windows lists it with kind quarantine and is_private true, its
       page the routed link; screenshot and hit_test by its window_id work.

Needs the sandbox off. Usage:

  docs/harness/task228-7-private-quick-detour-checks.py <worktree> /path/to/Detour.app <output-dir>
"""
import http.server, importlib.machinery, importlib.util, json, os, secrets, shutil, signal, subprocess, sys, threading, time

wt, app, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("t324", os.path.join(wt, "docs/harness/task324-endpoint-checks.py"))
spec = importlib.util.spec_from_loader("t324", loader); t324 = importlib.util.module_from_spec(spec); loader.exec_module(t324)
client = t324.load_client()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_address[1]
        path = self.path.split("?")[0]
        if path == "/start.html":
            body = f'<!doctype html><title>Start</title><body><a id="l" href="http://127.0.0.1:{port}/probe.html">probe</a></body>'
        elif path == "/probe.html":
            body = "<!doctype html><title>Quarantined probe</title><body>probe</body>"
        else:
            self.send_response(404); self.end_headers(); return
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
start = f"http://localhost:{server.server_address[1]}/start.html"

fixture_path = os.path.join(out, "world.json")
json.dump({"version": 1,
           "profiles": [{"name": "Main"}],
           "spaces": [{"name": "Check", "emoji": "Q", "color": "007AFF", "profile": "Main"}],
           "link_routes": [{"match": "contains", "pattern": "/probe.html", "target": "quarantine"}],
           "active_space": "Check"}, open(fixture_path, "w"))

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

def run(label, allowed):
    data_dir = f"DetourVerify-2287-{label}-{secrets.token_hex(3)}"
    print("data directory:", data_dir, flush=True)
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1")
    detour = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour"), "-AutomationAllowPrivate",
                               "YES" if allowed else "NO"], env=env,
                              stdout=open(os.path.join(out, f"app-{label}.log"), "w"), stderr=subprocess.STDOUT)
    try:
        ep = os.path.join(support, "mcp-endpoint.json")
        for _ in range(80):
            if os.path.exists(ep): break
            time.sleep(0.25)
        time.sleep(2)
        endpoint = json.load(open(ep))
        s = client.Session(endpoint["url"], endpoint["token"], f"task2287-{label}"); s.open()
        def raw(tool, **a):
            r = s.call(tool, a); return r.get("structuredContent"), bool(r.get("isError"))
        def call(tool, **a):
            c, err = raw(tool, **a)
            if err: raise RuntimeError(f"{tool}: {c}")
            return c
        call("seed_world", fixture_path=fixture_path)
        call("open_url", window_id=1, url=start)
        tab = None
        for _ in range(40):
            items = call("list_tabs", window_id=1).get("items", [])
            tab = next((t for t in items if (t.get("title") or "") == "Start"), None)
            if tab: break
            time.sleep(0.25)
        check(f"{label}: start page loaded", tab is not None)
        call("click", context=tab["id"], selector="#l")
        listed = None
        for _ in range(40):
            listed = call("list_windows")
            if listed.get("hidden_private_windows", 0) + len(listed["windows"]) >= 2: break
            time.sleep(0.25)
        json.dump(listed, open(os.path.join(out, f"windows-{label}.json"), "w"), indent=1)
        quarantine = next((w for w in listed["windows"] if w["kind"] == "quarantine"), None)
        if allowed:
            check("on: list_windows lists the quarantine, is_private true",
                  quarantine is not None and quarantine.get("is_private") is True and listed["hidden_private_windows"] == 0,
                  listed)
            if quarantine:
                for _ in range(40):
                    if quarantine.get("selected_tab_title") == "Quarantined probe": break
                    time.sleep(0.25)
                    quarantine = next((w for w in call("list_windows")["windows"] if w["kind"] == "quarantine"), quarantine)
                check("on: its page is the routed link", quarantine.get("selected_tab_title") == "Quarantined probe",
                      quarantine.get("selected_tab_title"))
                shot, err = raw("screenshot", window_id=quarantine["window_id"], include_image=False,
                                save_to=os.path.join(out, "quarantine-on.png"), overwrite=True)
                check("on: screenshot by its window_id works", not err, shot)
                hit, err = raw("hit_test", window_id=quarantine["window_id"], x=200, y=200)
                check("on: hit_test by its window_id works", not err, hit)
        else:
            check("off: list_windows leaves it out and counts it",
                  quarantine is None and listed.get("hidden_private_windows") == 1, listed)
            # Ids come from one counter in the order windows are first seen:
            # the browser window is 1, so the quarantine is the next id.
            ids = [w["window_id"] for w in listed["windows"]]
            guess = max(ids) + 1
            shot, err = raw("screenshot", window_id=guess, include_image=False)
            code = (shot or {}).get("error", {}).get("code")
            check("off: screenshot by its window_id is private_unreachable", err and code == "private_unreachable", shot)
            hit, err = raw("hit_test", window_id=guess, x=200, y=200)
            check("off: hit_test by its window_id is private_unreachable",
                  err and (hit or {}).get("error", {}).get("code") == "private_unreachable", hit)
        s.close()
    finally:
        detour.send_signal(signal.SIGTERM)
        try: detour.wait(10)
        except Exception: detour.kill()
        cleanup(data_dir)

try:
    run("off", False)
    run("on", True)
finally:
    server.shutdown()
failed = [n for n, ok in results if not ok]
print("ALL PASS" if not failed else f"FAILED: {failed}")
sys.exit(1 if failed else 0)
