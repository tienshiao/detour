#!/usr/bin/env python3
"""TASK-372's runtime check through the automation endpoint: what the error
page names, what the tab's URL becomes and what Reload does after a link in a
page fails.

Launches the given Detour.app with the isolated data directory named on the
command line and the endpoint on (DETOUR_MCP=1), installs a fixture extension
(an options page, nothing web-accessible) and serves a loopback page with a
link to a closed loopback port, a link to the options page and a button that
window.open()s the options page. Trusted clicks through the endpoint:

  1. The dead-port link: the error page and the tab's url name the dead URL;
     Cmd+R retries it (a fresh error page naming it).
  2. The options-page link (refused, -1008, the error names no URL): the error
     page names the options URL, the tab's url stays the page; Cmd+R loads the
     page again (the user's decision, 2026-11-16).
  3. The window.open button: the child's error page names the options URL and
     its url is empty; Cmd+R is refused again.

Detour stays in the background. Needs the sandbox off. Usage:

  docs/harness/task372-endpoint-checks.py /path/to/Detour.app <data-dir-name> [output-dir]

Exit status 0 when every check passed. The data directory is left in place;
the caller removes it.
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

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
        f.write("""<!doctype html><html><head><title>Links</title></head><body style="font-size:24px">
<p><a id="dead" href="#">A link to a closed port</a></p>
<p><a id="ext" href="#">A link to the extension's options</a></p>
<p><button id="open" onclick="window.open(this.dataset.target)">window.open the options</button></p>
</body></html>""")
    with open(os.path.join(ext_dir, "manifest.json"), "w") as f:
        json.dump({"manifest_version": 3, "name": "TASK-372 Fixture", "version": "1.0.0",
                   "options_ui": {"page": "options.html"}}, f)
    with open(os.path.join(ext_dir, "options.html"), "w") as f:
        f.write("<!doctype html><html><head><title>Opts</title></head><body>options</body></html>")
    return page_dir, ext_dir


def closed_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    app = os.path.abspath(sys.argv[1])
    data_dir = sys.argv[2]
    out_dir = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else tempfile.mkdtemp(prefix="task372-")
    os.makedirs(out_dir, exist_ok=True)
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    endpoint_file = os.path.join(support, "mcp-endpoint.json")
    client = load_client()

    fixtures = tempfile.mkdtemp(prefix="task372-fixture-")
    page_dir, ext_dir = write_fixtures(fixtures)
    server = serve(page_dir)
    page_url = f"http://127.0.0.1:{server.server_address[1]}/index.html"
    dead_url = f"http://127.0.0.1:{closed_port()}/target"
    env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1")
    results = []

    def check(name, ok, detail):
        results.append((name, ok))
        print(f"{'PASS' if ok else 'FAIL'}: {name}: {detail}")

    if os.path.exists(endpoint_file):
        os.remove(endpoint_file)
    app_log = open(os.path.join(out_dir, "app.log"), "a")
    process = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour")], env=env,
                               stdout=app_log, stderr=subprocess.STDOUT)
    try:
        for _ in range(120):
            if os.path.exists(endpoint_file):
                break
            time.sleep(0.25)
        else:
            raise RuntimeError("Detour did not open its endpoint")
        time.sleep(2)
        with open(endpoint_file) as f:
            endpoint = json.load(f)
        session = client.Session(endpoint["url"], endpoint["token"], "task372-checks")
        session.open()

        def call(tool, **arguments):
            result = session.call(tool, arguments)
            content = result.get("structuredContent")
            if result.get("isError"):
                raise RuntimeError(f"{tool}: {content}")
            return content

        def tabs():
            return call("list_tabs", window_id=1)["items"]

        def tab(tab_id):
            return next((t for t in tabs() if t["id"] == tab_id), {})

        def page_state(tab_id):
            try:
                return call("evaluate_js", context=tab_id, expression="[location.href, document.title]")["value"]
            except RuntimeError as error:
                return str(error)

        def poll(condition, timeout=10):
            deadline = time.monotonic() + timeout
            value = None
            while time.monotonic() < deadline:
                value = condition()
                if value:
                    return value
                time.sleep(0.25)
            return value

        def named(state):
            if isinstance(state, list) and str(state[0]).startswith("browser-error"):
                query = urllib.parse.urlparse(state[0]).query
                return urllib.parse.parse_qs(query).get("failedURL", [None])[0]
            return None

        def mark(tab_id):
            call("evaluate_js", context=tab_id, expression="window.__task372 = 1")

        def next_document(tab_id):
            def fresh():
                try:
                    marked = call("evaluate_js", context=tab_id, expression="window.__task372 === 1")["value"]
                except RuntimeError:
                    return None
                return page_state(tab_id) if marked is False else None
            return poll(fresh)

        def reload(tab_id):
            call("select_tab", window_id=1, id=tab_id)
            mark(tab_id)
            call("run_menu_item", window_id=1, key="cmd+r")
            return next_document(tab_id)

        def open_page():
            before = {t["id"] for t in tabs()}
            call("open_url", window_id=1, url=page_url, in_place=False)
            page = poll(lambda: next((t["id"] for t in tabs() if t["id"] not in before), None))
            set_targets(page)
            return page

        def set_targets(page):
            call("wait_for", context=page, selector="#dead", visible=True, timeout_ms=5000)
            call("evaluate_js", context=page, expression=(
                f"(document.getElementById('dead').href = {json.dumps(dead_url)},"
                f" document.getElementById('ext').href = {json.dumps(options_url)},"
                f" document.getElementById('open').dataset.target = {json.dumps(options_url)})"))

        installed = call("install_extension", path=ext_dir)
        check("fixture installed", installed.get("loaded") is True, json.dumps(installed)[:200])
        opened = call("open_extension_context", extension=installed["extension"]["id"], kind="options", window_id=1)
        options_url = opened.get("url")

        # 1. A link to a closed port.
        page = open_page()
        call("click", context=page, selector="#dead")
        state = poll(lambda: (s := page_state(page)) and named(s) and s)
        check("dead link: the error page names the dead URL", named(state) == dead_url, str(state)[:200])
        check("dead link: the tab's url is the dead URL", tab(page).get("url") == dead_url, f"url={tab(page).get('url')}")
        state = reload(page)
        check("dead link: Reload retries it", named(state) == dead_url, str(state)[:200])

        # 2. A link to the extension's options page.
        page = open_page()
        call("click", context=page, selector="#ext")
        state = poll(lambda: (s := page_state(page)) and named(s) and s)
        call("screenshot", window_id=1, save_to=os.path.join(out_dir, "1-refused-link.png"), include_image=False,
             overwrite=True)
        check("extension link: the error page names the options URL", named(state) == options_url, str(state)[:200])
        check("extension link: the tab's url stays the page", tab(page).get("url") == page_url,
              f"url={tab(page).get('url')}")
        state = reload(page)
        check("extension link: Reload loads the page the tab was on",
              isinstance(state, list) and state[0] == page_url and state[1] == "Links", str(state)[:200])

        # 3. window.open of the options page (the reloaded page lost the targets).
        set_targets(page)
        before = {t["id"] for t in tabs()}
        call("click", context=page, selector="#open")
        child = poll(lambda: next((t["id"] for t in tabs() if t["id"] not in before), None))
        state = poll(lambda: (s := page_state(child)) and named(s) and s)
        check("window.open: the error page names the options URL", named(state) == options_url, str(state)[:200])
        check("window.open: the child keeps no url", not tab(child).get("url"), f"url={tab(child).get('url')}")
        state = reload(child)
        check("window.open: Reload is refused again", named(state) == options_url and "Opts" not in str(state),
              str(state)[:200])
        call("screenshot", window_id=1, save_to=os.path.join(out_dir, "2-child-after-reload.png"),
             include_image=False, overwrite=True)

        try:
            call("run_menu_item", window_id=1, key="cmd+q")
        except Exception:
            pass
        try:
            process.wait(timeout=20)
            process = None
        except subprocess.TimeoutExpired:
            pass   # SIGTERM below
    finally:
        if process is not None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        server.shutdown()
        app_log.close()
        shutil.rmtree(fixtures, ignore_errors=True)

    failed = [name for name, ok in results if not ok]
    print(f"{len(results) - len(failed)}/{len(results)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
