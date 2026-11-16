#!/usr/bin/env python3
"""TASK-381's runtime check through the automation endpoint: a web page must
never get an extension's non-web-accessible page loaded in a tab.

Launches the given Detour.app with the isolated data directory named on the
command line and the endpoint on (DETOUR_MCP=1), installs a fixture extension
(an options page, nothing web-accessible), and serves a loopback page whose
button calls window.open() on the options page's URL.

Launch 1:
  1. The extension's own options tab opens (open_extension_context) and shows
     "Opts" (positive control).
  2. A trusted click on the page's button opens the child tab. WebKit refuses
     the load: the child shows the error page naming the options URL, and its
     url (list_tabs) is not the extension page.
  3. Reload in the child (Cmd+R) is refused again.
  4. Cmd+Q; the session DB holds no extension page for the child.
Launch 2 (same data directory, the relaunch):
  5. The child is selected (it wakes) and reloaded: still no "Opts".
  6. The options tab is restored on the extension's new origin and shows "Opts".

Detour stays in the background. Needs the sandbox off. Usage:

  docs/harness/task381-endpoint-checks.py /path/to/Detour.app <data-dir-name> [output-dir]

Exit status 0 when every check passed. The data directory is left in place;
the caller removes it.
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load_client():
    sys.dont_write_bytecode = True
    path = os.path.join(REPO, "scripts", "detour-mcp")
    loader = importlib.machinery.SourceFileLoader("detour_mcp", path)
    spec = importlib.util.spec_from_loader("detour_mcp", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def serve(directory):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=directory, **k)

        def log_message(self, *a):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def write_fixtures(root):
    page_dir = os.path.join(root, "page")
    ext_dir = os.path.join(root, "extension")
    os.makedirs(page_dir)
    os.makedirs(ext_dir)
    with open(os.path.join(page_dir, "index.html"), "w") as f:
        f.write("""<!doctype html><html><head><title>Attacker</title></head><body>
<button id="open" style="font-size:24px;margin:40px"
  onclick="window.open(this.dataset.target)">Open the extension's options</button>
</body></html>""")
    with open(os.path.join(ext_dir, "manifest.json"), "w") as f:
        json.dump({"manifest_version": 3, "name": "TASK-381 Fixture", "version": "1.0.0",
                   "options_ui": {"page": "options.html"}}, f)
    with open(os.path.join(ext_dir, "options.html"), "w") as f:
        f.write("<!doctype html><html><head><title>Opts</title></head><body>options</body></html>")
    return page_dir, ext_dir


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    app = os.path.abspath(sys.argv[1])
    data_dir = sys.argv[2]
    out_dir = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else tempfile.mkdtemp(prefix="task381-")
    os.makedirs(out_dir, exist_ok=True)
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    endpoint_file = os.path.join(support, "mcp-endpoint.json")
    client = load_client()

    fixtures = tempfile.mkdtemp(prefix="task381-fixture-")
    page_dir, ext_dir = write_fixtures(fixtures)
    server = serve(page_dir)
    page_url = f"http://127.0.0.1:{server.server_address[1]}/index.html"
    env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1")
    results = []

    def check(name, ok, detail):
        results.append((name, ok))
        print(f"{'PASS' if ok else 'FAIL'}: {name}: {detail}")

    def launch():
        if os.path.exists(endpoint_file):
            os.remove(endpoint_file)
        process = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour")], env=env,
                                   stdout=open(os.path.join(out_dir, "app.log"), "a"), stderr=subprocess.STDOUT)
        for _ in range(120):
            if os.path.exists(endpoint_file):
                break
            time.sleep(0.25)
        else:
            raise RuntimeError("Detour did not open its endpoint")
        time.sleep(2)
        with open(endpoint_file) as f:
            endpoint = json.load(f)
        session = client.Session(endpoint["url"], endpoint["token"], "task381-checks")
        session.open()

        def call(tool, **arguments):
            result = session.call(tool, arguments)
            content = result.get("structuredContent")
            if result.get("isError"):
                raise RuntimeError(f"{tool}: {content}")
            return content
        return process, call

    def quit_app(process, call):
        try:
            call("run_menu_item", window_id=1, key="cmd+q")
        except Exception:
            pass   # the endpoint goes away with the app
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)

    def tabs(call):
        return call("list_tabs", window_id=1)["items"]

    def page_state(call, tab_id):
        try:
            return call("evaluate_js", context=tab_id, expression="[location.href, document.title]")["value"]
        except RuntimeError as error:
            return str(error)

    def poll(what, condition, timeout=10):
        deadline = time.monotonic() + timeout
        value = None
        while time.monotonic() < deadline:
            value = condition()
            if value:
                return value
            time.sleep(0.25)
        return value

    process = None
    try:
        # Launch 1.
        process, call = launch()
        installed = call("install_extension", path=ext_dir)
        check("fixture installed", installed.get("loaded") is True, json.dumps(installed)[:200])
        opened = call("open_extension_context", extension="TASK-381 Fixture", kind="options", window_id=1)
        options_tab = opened.get("tab_id")
        options_url = opened.get("url")
        state = poll("options", lambda: (s := page_state(call, options_tab)) and "Opts" in str(s) and s)
        check("the extension's own options tab loads", "Opts" in str(state), f"{options_url} -> {state}")

        call("open_url", window_id=1, url=page_url, in_place=False)
        page = poll("page", lambda: next((t["id"] for t in tabs(call) if t.get("url") == page_url), None))
        call("wait_for", context=page, selector="#open", visible=True, timeout_ms=5000)
        call("evaluate_js", context=page,
             expression=f"document.getElementById('open').dataset.target = {json.dumps(options_url)}")
        before = {t["id"] for t in tabs(call)}
        call("click", context=page, selector="#open")
        child = poll("child", lambda: next((t for t in tabs(call) if t["id"] not in before), None))
        if child is None:
            check("window.open opened a child tab", False, json.dumps(tabs(call))[:400])
            return 1
        child_id = child["id"]
        def on_error_page():
            s = page_state(call, child_id)
            return s if isinstance(s, list) and str(s[0]).startswith("browser-error") else None
        state = poll("error page", on_error_page)
        child = next(t for t in tabs(call) if t["id"] == child_id)
        call("screenshot", window_id=1, save_to=os.path.join(out_dir, "1-child-error.png"), include_image=False,
             overwrite=True)
        check("the child shows the error page naming the options page",
              isinstance(state, list) and state[0].startswith("browser-error") and "options.html" in state[0],
              str(state)[:300])
        check("the child's url is not the extension page", not str(child.get("url") or "").startswith("webkit-extension"),
              f"url={child.get('url')}")

        call("select_tab", window_id=1, id=child_id)
        call("run_menu_item", window_id=1, key="cmd+r")
        time.sleep(2)
        state = page_state(call, child_id)
        check("Reload is refused again", "Opts" not in str(state), str(state)[:300])

        time.sleep(2)   # the debounced save
        quit_app(process, call)
        process = None
        db = sqlite3.connect(f"file:{os.path.join(support, 'browser.db')}?mode=ro", uri=True)
        try:
            rows = db.execute("SELECT id, url, extensionID FROM tab").fetchall()
        finally:
            db.close()
        child_row = next((r for r in rows if r[0].lower() == child_id.lower()), None)
        options_row = next((r for r in rows if r[0].lower() == options_tab.lower()), None)
        check("the saved child is no extension page",
              child_row is not None and not str(child_row[1] or "").startswith("webkit-extension") and child_row[2] is None,
              f"row={child_row}")
        check("the saved options tab keeps its extension id", options_row is not None and options_row[2] is not None,
              f"row={options_row}")

        # Launch 2: the relaunch.
        process, call = launch()
        time.sleep(2)
        call("select_tab", window_id=1, id=child_id)
        time.sleep(2)
        call("run_menu_item", window_id=1, key="cmd+r")
        time.sleep(2)
        state = page_state(call, child_id)
        call("screenshot", window_id=1, save_to=os.path.join(out_dir, "2-child-after-relaunch.png"),
             include_image=False, overwrite=True)
        child = next((t for t in tabs(call) if t["id"] == child_id), {})
        check("after the relaunch the child never shows the options page",
              "Opts" not in str(state) and not str(child.get("url") or "").startswith("webkit-extension"),
              f"state={str(state)[:200]} url={child.get('url')}")

        call("select_tab", window_id=1, id=options_tab)
        state = poll("options again", lambda: (s := page_state(call, options_tab)) and "Opts" in str(s) and s)
        restored = next((t for t in tabs(call) if t["id"] == options_tab), {})
        check("the options tab is restored on the new origin and loads",
              "Opts" in str(state) and restored.get("url") != options_url,
              f"{restored.get('url')} -> {state}")
        quit_app(process, call)
        process = None
    finally:
        if process is not None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        server.shutdown()

    failed = [name for name, ok in results if not ok]
    print(f"{len(results) - len(failed)}/{len(results)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
