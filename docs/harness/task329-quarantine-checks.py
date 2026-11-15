#!/usr/bin/env python3
"""TASK-329 AC #4's runtime checks, through the automation endpoint (TASK-228):
a quarantine navigation also leaves out the parameters the downloaded AdGuard
URL Tracking filter names, and falls back to the built-in names when the list
cannot be downloaded.

A local server (it records every request's path and query) serves the test
excerpt of the list (DetourTests/TrackingParameterFilterFixture.swift) plus
one rule for the loopback host, a start page and a probe page. The start
page links to the probe page with a site parameter (ref_, a rule for the
loopback host), a global list name (pjclid) and a built-in name
(utm_source). A Link Route sends links containing /probe.html to Quarantine,
so a trusted click on that link (from the start page on localhost: a click
to the same host is never routed) opens a quarantine window, which loads the
link through `QuickDetourWindowController.openQuarantine` and so through the
same rule as its later navigations (`TrackingParameters.cleanLink`).

Two launches of the given Detour.app, each with a fresh isolated data
directory (DETOUR_DATA_DIR, always set), the endpoint on and
DETOUR_TRACKING_FILTER_URL (a Debug-build seam) pointing at the server:

  A. the list served: once it is cached, the click opens a quarantine
     window and the server sees /probe.html?id=1 only: no list or built-in
     parameter ever reaches it.
  B. the list's URL answers 404: the server sees
     /probe.html?id=1&ref_=nav&pjclid=7 (the built-in utm_source removed,
     the list's parameters kept).

Needs the sandbox off (it launches an app and serves loopback HTTP). Usage:

  docs/harness/task329-quarantine-checks.py <worktree> /path/to/Detour.app <output-dir>

Each run's data directory, WebKit stores, defaults suite and window keys
are removed when it ends (the script prints the names).
"""
import http.server, importlib.machinery, importlib.util, json, os, re, secrets, shutil, signal, subprocess, sys, threading, time

wt, app, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("t324", os.path.join(wt, "docs/harness/task324-endpoint-checks.py"))
spec = importlib.util.spec_from_loader("t324", loader); t324 = importlib.util.module_from_spec(spec); loader.exec_module(t324)
client = t324.load_client()

swift = open(os.path.join(wt, "DetourTests/TrackingParameterFilterFixture.swift")).read()
body = re.search(r'#"""\n(.*?)\n\s*"""#', swift, re.S).group(1)
excerpt = "\n".join(line[4:] if line.startswith("    ") else line for line in body.split("\n"))
excerpt += """
! (Detour runtime check) a rule for the loopback page's host
||127.0.0.1^$removeparam=ref_
"""

requests = []
lock = threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with lock: requests.append(self.path)
        path = self.path.split("?")[0]
        port = self.server.server_address[1]
        if path == "/17.txt":
            self.reply(200, excerpt, "text/plain")
        elif path == "/start.html":
            link = f"http://127.0.0.1:{port}/probe.html?id=1&ref_=nav&pjclid=7&utm_source=news"
            self.reply(200, f'<!doctype html><title>Start</title><body><a id="l" href="{link}">probe</a></body>')
        elif path == "/probe.html":
            self.reply(200, "<!doctype html><title>Probe</title><body>probe</body>")
        else:
            self.reply(404, "missing", "text/plain")

    def reply(self, status, text, kind="text/html"):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", kind + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_address[1]}"
# The start page on another host: a click to the same host is never routed
# (`isSameLinkRoutingHost`).
start_base = f"http://localhost:{server.server_address[1]}"

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

def run(label, list_url, expected_query, wait_for_cache):
    data_dir = f"DetourVerify-329q-{label}-{secrets.token_hex(3)}"
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
        s = client.Session(endpoint["url"], endpoint["token"], f"task329q-{label}"); s.open()
        def call(tool, **a):
            r = s.call(tool, a); c = r.get("structuredContent")
            if r.get("isError"): raise RuntimeError(f"{tool}: {c}")
            return c
        if wait_for_cache:
            for _ in range(60):
                if os.path.exists(cache): break
                time.sleep(0.5)
            check(f"{label}: the list was downloaded and cached", os.path.exists(cache))
        else:
            time.sleep(3)
            check(f"{label}: nothing cached when the list answers 404", not os.path.exists(cache))
        call("seed_world", fixture_path=fixture_path)
        call("open_url", window_id=1, url=f"{start_base}/start.html")
        tab = None
        for _ in range(40):
            items = call("list_tabs", window_id=1).get("items", [])
            tab = next((t for t in items if (t.get("title") or "") == "Start"), None)
            if tab: break
            time.sleep(0.25)
        check(f"{label}: start page loaded", tab is not None)
        with lock: requests.clear()
        call("click", context=tab["id"], selector="#l")
        probes = []
        for _ in range(40):
            with lock: probes = [p for p in requests if p.startswith("/probe.html")]
            if probes: break
            time.sleep(0.25)
        time.sleep(1)
        with lock: probes = [p for p in requests if p.startswith("/probe.html")]
        check(f"{label}: the quarantine requested only {expected_query}",
              probes == [f"/probe.html?{expected_query}"], probes)
        windows = call("list_windows")
        json.dump(windows, open(os.path.join(out, f"windows-{label}.json"), "w"), indent=1)
        check(f"{label}: a quarantine window opened (hidden from agents)",
              windows.get("hidden_private_windows", 0) >= 1, windows.get("hidden_private_windows"))
        items = call("list_tabs", window_id=1).get("items", [])
        check(f"{label}: the clicked page's tab stays on the start page",
              any(t.get("url") == f"{start_base}/start.html" for t in items), [t.get("url") for t in items])
        s.close()
    finally:
        detour.send_signal(signal.SIGTERM)
        try: detour.wait(10)
        except Exception: detour.kill()
        cleanup(data_dir)

try:
    run("served", f"{base}/17.txt", "id=1", True)
    run("missing", f"{base}/missing-17.txt", "id=1&ref_=nav&pjclid=7", False)
finally:
    server.shutdown()
failed = [n for n, ok in results if not ok]
print("ALL PASS" if not failed else f"FAILED: {failed}")
sys.exit(1 if failed else 0)
