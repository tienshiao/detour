#!/usr/bin/env python3
"""TASK-324's hands-on download checks, run through the automation endpoint
(TASK-228.1) with no manual steps and no harness patch.

Launches the given Detour.app with a fresh isolated data directory and the
endpoint on (DETOUR_MCP=1), serves a local fixture, and checks where each
download's flight starts and ends, from the "Download flight" log line
(category "downloads"):

  1. Download Linked File: a right click on a link, then the context menu
     item; the flight starts at the right click and lands in the sidebar's
     Downloads button.
  2. A download in a split pane: a link opened with "Open Link in Split
     View", then a download link clicked in the right pane; the flight starts
     at that click.
  3. With the sidebar hidden (Cmd+S): the flight ends at the window's
     corner, with nothing to catch it.
  4. With Reduce Motion (the Debug override): nothing flies.

Detour stays in the background and the pointer never moves. Screenshots of
each step go to the output directory. Needs the sandbox off (it launches an
app and reads the unified log). Usage:

  docs/harness/task324-endpoint-checks.py /path/to/Detour.app [output-dir]

Exit status 0 when every check passed.
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import re
import secrets
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load_client():
    """scripts/detour-mcp as a module, for its Session class."""
    sys.dont_write_bytecode = True   # no __pycache__ left in scripts/
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


def write_fixture(directory, run):
    names = {n: f"detour-check-{run}-{n}.txt" for n in range(1, 5)}
    for n, name in names.items():
        with open(os.path.join(directory, name), "w") as f:
            f.write(f"check {n}\n")
    with open(os.path.join(directory, "index.html"), "w") as f:
        f.write(f"""<!doctype html><html><head><title>Download checks</title>
<style>body{{font:16px sans-serif;margin:40px}} a{{display:block;margin:24px 0;font-size:18px}}</style></head><body>
<a id="menu" href="/{names[1]}">Linked file (for Download Linked File)</a>
<a id="split" href="/pane.html">Open me in a split</a>
<a id="hidden" href="/{names[3]}" download>Download with the sidebar hidden</a>
<a id="reduced" href="/{names[4]}" download>Download with Reduce Motion</a>
</body></html>""")
    with open(os.path.join(directory, "pane.html"), "w") as f:
        f.write(f"""<!doctype html><html><head><title>Split pane</title>
<style>body{{font:16px sans-serif;margin:40px}} a{{display:block;margin-top:300px;font-size:18px}}</style></head>
<body><a id="pane" href="/{names[2]}" download>Download in the split pane</a></body></html>""")
    return names


FLIGHT = re.compile(r"Download flight from (-?\d+),(-?\d+) to (-?\d+),(-?\d+); catcher ([^;]+); motion (.+)$")


def flights(pid, since):
    """The flight log lines of process `pid` since `since` (a log show date)."""
    out = subprocess.run(["/usr/bin/log", "show", "--info", "--start", since, "--predicate",
                          f'processIdentifier == {pid} AND subsystem == "com.detourbrowser.mac" AND category == "downloads"'],
                         capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        m = FLIGHT.search(line)
        if m:
            x0, y0, x1, y1 = map(int, m.groups()[:4])
            found.append({"from": (x0, y0), "to": (x1, y1), "catcher": m.group(5), "motion": m.group(6).strip()})
    return found


def log_time():
    return time.strftime("%Y-%m-%d %H:%M:%S")


# WebKitStorageScope.namespace: an isolated data directory's WebKit stores are
# named uuid5(namespace, "<data dir>/<profile id>").
WEBKIT_NAMESPACE = uuid.UUID("9DC6C971-6D72-44C8-9541-D6DEBE44E0A3")
WEBKIT_DIR = os.path.expanduser("~/Library/WebKit/com.detourbrowser.mac")


def remove_webkit_storage(support, data_dir):
    """This run's website data stores and extension controller directories,
    which WebKit keeps outside the data directory. Only identifiers recorded in
    this run's own database and derived from its own data directory name, as
    WebKitStorageScope.refusalToRemove requires. Runs before the data
    directory (and with it the record) is removed."""
    db = os.path.join(support, "browser.db")
    if not os.path.exists(db):
        return
    try:
        connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        try:
            rows = connection.execute("SELECT identifier, profileID FROM webKitStorageIdentifier").fetchall()
        finally:
            connection.close()
    except sqlite3.Error:
        return
    for identifier, profile_id in rows:
        try:
            ident, profile = uuid.UUID(identifier), uuid.UUID(profile_id)
        except (ValueError, TypeError, AttributeError):
            continue
        if ident.version != 5 or ident != uuid.uuid5(WEBKIT_NAMESPACE, f"{data_dir}/{str(profile).upper()}"):
            continue
        for path in (os.path.join(WEBKIT_DIR, "WebsiteDataStore", str(ident)),
                     os.path.join(WEBKIT_DIR, "WebExtensions", str(ident).upper())):
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    app = os.path.abspath(sys.argv[1])
    out_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="task324-")
    os.makedirs(out_dir, exist_ok=True)
    run = secrets.token_hex(3)
    data_dir = f"DetourCheck324-{run}"
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    downloads = os.path.expanduser("~/Downloads")
    client = load_client()

    fixture = tempfile.mkdtemp(prefix="task324-fixture-")
    names = write_fixture(fixture, run)
    server = serve(fixture)
    base = f"http://127.0.0.1:{server.server_address[1]}"

    env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1")
    endpoint_file = os.path.join(support, "mcp-endpoint.json")
    results = []
    detour = None
    try:
        launched = log_time()
        detour = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour")], env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(80):
            if os.path.exists(endpoint_file):
                break
            time.sleep(0.25)
        else:
            print("FAIL: Detour did not open its endpoint")
            return 1
        time.sleep(2)
        with open(endpoint_file) as f:
            endpoint = json.load(f)
        session = client.Session(endpoint["url"], endpoint["token"], "task324-checks")
        session.open()

        def call(tool, **arguments):
            result = session.call(tool, arguments)
            content = result.get("structuredContent")
            if result.get("isError"):
                raise RuntimeError(f"{tool}: {content}")
            return content

        def shoot(name):
            call("screenshot", window_id=1, save_to=os.path.join(out_dir, f"{name}.png"), include_image=False,
                 overwrite=True)

        def wait_for_file(name, timeout=10):
            path = os.path.join(downloads, name)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if os.path.exists(path):
                    return True
                time.sleep(0.2)
            return False

        window = call("list_windows")["windows"][0]
        height = window["frame"]["height"]

        def to_window(point):
            """A tool's content point (top-left origin) in window points (bottom-left)."""
            return (round(point["x"]), round(height - point["y"]))

        def near(a, b, slack=3):
            return abs(a[0] - b[0]) <= slack and abs(a[1] - b[1]) <= slack

        seen = [0]   # flights earlier cases already took

        def wait_for_flight(timeout=10):
            """The first flight after the ones earlier cases took, counted from
            launch: `log show --start` has whole seconds, so a per-case start
            could hand back the previous case's flight. Polled to a deadline,
            since each `log show` itself takes a while."""
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                found = flights(detour.pid, launched)
                if len(found) > seen[0]:
                    flight = found[seen[0]]
                    seen[0] = len(found)
                    return flight
                time.sleep(0.5)
            return None

        def check(name, ok, detail):
            results.append((name, ok))
            print(f"{'PASS' if ok else 'FAIL'}: {name}: {detail}")

        call("open_url", window_id=1, url=f"{base}/index.html", in_place=False)
        time.sleep(2)
        page = call("list_windows")["windows"][0]["selected_tab_id"]

        # 1. Download Linked File, from the right click.
        clicked = call("click", context=page, selector="#menu", button="right")
        call("choose_menu_item", title="Download Linked File")
        flight = wait_for_flight()
        got = wait_for_file(names[1])
        shoot("1-download-linked-file")
        check("Download Linked File", got and flight is not None and near(flight["from"], to_window(clicked["point"]))
              and flight["catcher"] == "downloads button" and flight["motion"] == "toss",
              f"downloaded={got}, right click at {to_window(clicked['point'])}, flight {flight}")

        # 2. A download in a split pane.
        call("click", context=page, selector="#split", button="right")
        call("choose_menu_item", title="Open Link in Split View")
        time.sleep(2.5)
        items = call("list_tabs", window_id=1)["items"]
        pane = next((i for i in items if (i.get("url") or "").endswith("/pane.html")), None)
        if pane is None:
            check("Split pane", False, f"no split pane opened: {[i.get('url') for i in items]}")
        else:
            clicked = call("click", context=pane["tab_id"], selector="#pane")
            flight = wait_for_flight()
            got = wait_for_file(names[2])
            shoot("2-split-pane")
            in_right_half = to_window(clicked["point"])[0] > window["frame"]["width"] / 2
            check("Download in a split pane", got and flight is not None and in_right_half
                  and near(flight["from"], to_window(clicked["point"])) and flight["catcher"] == "downloads button",
                  f"downloaded={got}, click at {to_window(clicked['point'])} (right half: {in_right_half}), "
                  f"split group {pane.get('split_group_id')}, flight {flight}")

        # 3. With the sidebar hidden.
        call("run_menu_item", window_id=1, key="cmd+s")
        time.sleep(1.5)
        clicked = call("click", context=page, selector="#hidden")
        flight = wait_for_flight()
        got = wait_for_file(names[3])
        shoot("3-sidebar-hidden")
        # To triggerDownloadAnimation's corner, (20, 20), with the sidebar collapsed.
        check("Sidebar hidden", got and flight is not None and flight["catcher"] == "none"
              and near(flight["from"], to_window(clicked["point"])) and near(flight["to"], (20, 20)),
              f"downloaded={got}, flight {flight}")
        call("run_menu_item", window_id=1, key="cmd+s")
        time.sleep(1.0)

        # 4. With Reduce Motion.
        call("set_debug_override", name="reduce_motion", value="on")
        call("click", context=page, selector="#reduced")
        flight = wait_for_flight()
        got = wait_for_file(names[4])
        shoot("4-reduce-motion")
        call("set_debug_override", name="reduce_motion", value="default")
        check("Reduce Motion", got and flight is not None and flight["motion"].startswith("reduced"),
              f"downloaded={got}, flight {flight}")

        active = call("list_windows")["app_active"]
        check("Detour stayed in the background", active is False, f"app_active={active}")
        session.close()
    finally:
        if detour is not None:
            try:
                detour.send_signal(signal.SIGTERM)
                detour.wait(timeout=15)
            except Exception:
                detour.kill()
                detour.wait()
        server.shutdown()
        for name in names.values():
            path = os.path.join(downloads, name)
            if os.path.exists(path):
                os.remove(path)
        for key in (f"NSWindow Frame BrowserWindow-{data_dir}", f"NSSplitView Subview Frames BrowserSplitView-{data_dir}"):
            subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)
        # Only this run's own preferences domain, WebKit stores and directories.
        if os.path.basename(support) == data_dir and data_dir.startswith("DetourCheck324-"):
            # UserDefaultsScope.suiteName: where an isolated run keeps its own preferences.
            subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
            # `defaults delete` empties the domain but can leave its file behind.
            plist = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
            if os.path.exists(plist):
                os.remove(plist)
            remove_webkit_storage(support, data_dir)
            shutil.rmtree(support, ignore_errors=True)
        if os.path.basename(fixture).startswith("task324-fixture-"):
            shutil.rmtree(fixture, ignore_errors=True)

    print(f"Screenshots: {out_dir}")
    failed = [name for name, ok in results if not ok]
    print("ALL PASSED" if results and not failed else f"FAILED: {', '.join(failed) or 'nothing ran'}")
    return 0 if results and not failed else 1


if __name__ == "__main__":
    sys.exit(main())
