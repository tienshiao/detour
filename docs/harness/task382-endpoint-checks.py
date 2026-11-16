#!/usr/bin/env python3
"""TASK-382's runtime check through the automation endpoint: web content in a
tab built from an extension's configuration must not send that tab to the
extension's pages.

Launches the given Detour.app with the isolated data directory named on the
command line and the endpoint on (DETOUR_MCP=1), installs a fixture extension
and serves a loopback page. The extension's options page (nothing in it is
web-accessible) has:
  - #frame-it: a button that frames the loopback /attacker.html, whose script
    sends the top frame to the extension's other.html at once (no gesture);
  - #web: a link to the loopback /web.html;
  - #own: a link to its own other.html;
  - #update: a button that calls chrome.tabs.update on its own tab.

Checks:
  1. The options tab opens and shows "Opts".
  2. The framed attacker loads, its navigation is refused (the
     navigation-policy log line), and the tab stays on "Opts".
  3. The link to the web page goes nowhere: WebKit keeps an extension's tab on
     the extension; the server sees no request for /web.html.
  4. The extension's own link opens "Other"; Back returns to "Opts".
  5. tabs.update on its own tab loads options.html?updated=1.

Detour stays in the background. Needs the sandbox off. Usage:

  docs/harness/task382-endpoint-checks.py /path/to/Detour.app <data-dir-name> [output-dir]

Exit status 0 when every check passed. The data directory is left in place;
the caller removes it.
"""

import datetime
import http.server
import importlib.machinery
import importlib.util
import json
import os
import signal
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


def serve(directory, requested):
    class Recording(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=directory, **k)

        def do_GET(self):
            requested.append(self.path.split("?")[0])
            super().do_GET()

        def log_message(self, *a):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Recording)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def write_fixtures(root, base):
    page_dir = os.path.join(root, "page")
    ext_dir = os.path.join(root, "extension")
    os.makedirs(page_dir)
    os.makedirs(ext_dir)
    with open(os.path.join(page_dir, "attacker.html"), "w") as f:
        f.write("<!doctype html><html><body>attacker<script>"
                "top.location = decodeURIComponent(location.hash.slice(1));</script></body></html>")
    with open(os.path.join(page_dir, "web.html"), "w") as f:
        f.write("<!doctype html><html><head><title>Web</title></head><body>web</body></html>")
    with open(os.path.join(ext_dir, "manifest.json"), "w") as f:
        json.dump({"manifest_version": 3, "name": "TASK-382 Fixture", "version": "1.0.0",
                   "description": "TASK-382 runtime check", "options_ui": {"page": "options.html"}}, f)
    with open(os.path.join(ext_dir, "options.html"), "w") as f:
        f.write(f"""<!doctype html><html><head><title>Opts</title></head><body>options
<button id="frame-it" style="font-size:20px">Frame the attacker</button>
<a id="web" href="{base}/web.html">web</a> <a id="own" href="other.html">own</a>
<button id="update">tabs.update</button>
<script src="options.js"></script></body></html>""")
    with open(os.path.join(ext_dir, "options.js"), "w") as f:
        f.write(f"""document.getElementById('frame-it').addEventListener('click', () => {{
  const frame = document.createElement('iframe');
  frame.src = {json.dumps(base + "/attacker.html")} + '#' + encodeURIComponent(location.origin + '/other.html');
  document.body.appendChild(frame);
}});
document.getElementById('update').addEventListener('click', async () => {{
  const tab = await chrome.tabs.getCurrent();
  await chrome.tabs.update(tab.id, {{ url: 'options.html?updated=1' }});
}});
""")
    with open(os.path.join(ext_dir, "other.html"), "w") as f:
        f.write("<!doctype html><html><head><title>Other</title></head><body>private other</body></html>")
    return ext_dir


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    app = os.path.abspath(sys.argv[1])
    data_dir = sys.argv[2]
    out_dir = os.path.abspath(sys.argv[3]) if len(sys.argv) > 3 else tempfile.mkdtemp(prefix="task382-")
    os.makedirs(out_dir, exist_ok=True)
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    endpoint_file = os.path.join(support, "mcp-endpoint.json")
    client = load_client()

    requested = []
    fixtures = tempfile.mkdtemp(prefix="task382-fixture-")
    server = serve(os.path.join(fixtures, "page"), requested)
    base = f"http://127.0.0.1:{server.server_address[1]}"
    ext_dir = write_fixtures(fixtures, base)
    env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1")
    results = []

    def check(name, ok, detail):
        results.append((name, ok))
        print(f"{'PASS' if ok else 'FAIL'}: {name}: {detail}")

    if os.path.exists(endpoint_file):
        os.remove(endpoint_file)
    started = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    process = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour")], env=env,
                               stdout=open(os.path.join(out_dir, "app.log"), "a"), stderr=subprocess.STDOUT)
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
        session = client.Session(endpoint["url"], endpoint["token"], "task382-checks")
        session.open()

        def call(tool, **arguments):
            result = session.call(tool, arguments)
            content = result.get("structuredContent")
            if result.get("isError"):
                raise RuntimeError(f"{tool}: {content}")
            return content

        def state(tab_id):
            try:
                return call("evaluate_js", context=tab_id, expression="[location.href, document.title]")["value"]
            except RuntimeError as error:
                return str(error)

        def poll(condition, timeout=8):
            deadline = time.monotonic() + timeout
            value = None
            while time.monotonic() < deadline:
                value = condition()
                if value:
                    return value
                time.sleep(0.25)
            return value

        def shows(tab_id, title):
            s = state(tab_id)
            return s if isinstance(s, list) and s[1] == title else None

        installed = call("install_extension", path=ext_dir)
        check("fixture installed", installed.get("loaded") is True, json.dumps(installed)[:160])
        opened = call("open_extension_context", extension="TASK-382 Fixture", kind="options", window_id=1)
        tab = opened["tab_id"]
        check("1. the options tab shows its page", bool(poll(lambda: shows(tab, "Opts"))), str(state(tab)))

        call("click", context=tab, selector="#frame-it")
        framed = poll(lambda: "/attacker.html" in requested)
        time.sleep(3)
        s = state(tab)
        call("screenshot", window_id=1, save_to=os.path.join(out_dir, "2-after-attacker.png"), include_image=False,
             overwrite=True)
        log = subprocess.run(
            ["/usr/bin/log", "show", "--info", "--start", started, "--predicate",
             f'processIdentifier == {process.pid} AND subsystem == "com.detourbrowser.mac" '
             f'AND category == "navigation-policy"'],
            capture_output=True, text=True).stdout
        refused = [line for line in log.splitlines() if "Refused a frame of http://" in line]
        check("2. the framed web page cannot send the tab to other.html",
              bool(framed) and isinstance(s, list) and s[1] == "Opts" and "other.html" not in s[0] and refused,
              f"framed={bool(framed)} state={s} log={refused[:1]}")

        call("click", context=tab, selector="#web")
        time.sleep(3)
        s = state(tab)
        check("3. WebKit keeps the extension's tab off the web page",
              "/web.html" not in requested and isinstance(s, list) and s[1] == "Opts",
              f"requested={requested} state={s}")

        call("click", context=tab, selector="#own")
        other = poll(lambda: shows(tab, "Other"))
        call("select_tab", window_id=1, id=tab)
        call("run_menu_item", window_id=1, key="cmd+[")
        back = poll(lambda: shows(tab, "Opts"))
        check("4. its own link opens other.html, and Back returns", bool(other) and bool(back),
              f"other={other} back={back}")

        call("click", context=tab, selector="#update")
        updated = poll(lambda: (s := state(tab)) and isinstance(s, list) and s[0].endswith("options.html?updated=1")
                       and s[1] == "Opts" and s)
        check("5. tabs.update on its own tab loads its page", bool(updated), str(state(tab)))
        call("screenshot", window_id=1, save_to=os.path.join(out_dir, "5-end.png"), include_image=False,
             overwrite=True)
    finally:
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
