#!/usr/bin/env python3
"""TASK-325's runtime checks of the back swipe on a tab opened from another
tab, through the automation endpoint (TASK-228.1) and its Debug-only
navigation_swipe tool.

Synthetic events cannot drive NSEvent.trackSwipeEvent, so the hand swipe on a
trackpad is not checked here (it is owed by a person). What is checked: the
mode each pane's web view is in (WebKit's gesture flag and rubber-band edges)
as the tab gains and loses history and its opener, and a swipe's completion
and cancellation run through the same code a trackpad swipe runs, with a
scripted tracker in place of the real one:

  1. A tab with no opener keeps WebKit's gesture.
  2. A target=_blank child gets the own swipe (gesture off, left edge 14) and
     a picture of its opener.
  3. A cancelled back swipe leaves it open and selected.
  4. A page 2 gives the gesture back to WebKit; Back to page 1 brings the own
     swipe back with forward (edges 10); a forward swipe goes forward.
  5. A completed back swipe closes it and selects the opener; Reopen Closed
     Tab brings it back.
  6. The sidebar's Back button still closes a child to its opener.
  7. A child in a split (Open Link in Split View) closes from its own pane.
  8. Under a Peek nothing starts.

Needs a Debug build and the sandbox off (it launches an app). Usage:

  docs/harness/task325-swipe-checks.py /path/to/Detour.app [output-dir]

Exit status 0 when every check passed.
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
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


# WebKitStorageScope.namespace: an isolated data directory's WebKit stores are
# named uuid5(namespace, "<data dir>/<profile id>") (as in task324-endpoint-checks.py).
WEBKIT_NAMESPACE = uuid.UUID("9DC6C971-6D72-44C8-9541-D6DEBE44E0A3")
WEBKIT_DIR = os.path.expanduser("~/Library/WebKit/com.detourbrowser.mac")


def remove_webkit_storage(support, data_dir):
    """This run's own website data stores: only identifiers recorded in its
    database and derived from its data directory name."""
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


PAGE = """<!doctype html><html><head><title>{title}</title>
<style>body{{font:20px system-ui;background:{color};margin:0;padding:40px;height:2000px}}a{{display:block;margin:20px 0}}</style>
</head><body><h1>{title}</h1>{body}</body></html>"""


def write_fixture(directory):
    pages = {
        "opener.html": ("Opener", "#cfe8ff", '<a id="blank" href="child.html" target="_blank">Open child</a>'
                        '<a id="split" href="child.html">Child for a split</a>'),
        "child.html": ("Child 1", "#ffe2c4", '<a id="next" href="page2.html">Page 2</a>'
                       '<a id="peek" href="page2.html">Peek page 2</a>'),
        "page2.html": ("Child 2", "#d8f5d0", ""),
    }
    for name, (title, color, body) in pages.items():
        with open(os.path.join(directory, name), "w") as f:
            f.write(PAGE.format(title=title, color=color, body=body))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    app = os.path.abspath(sys.argv[1])
    out_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="task325-")
    os.makedirs(out_dir, exist_ok=True)
    data_dir = f"DetourVerify325-{secrets.token_hex(3)}"
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    client = load_client()

    fixture = tempfile.mkdtemp(prefix="task325-fixture-")
    write_fixture(fixture)
    server = serve(fixture)
    base = f"http://127.0.0.1:{server.server_address[1]}"

    env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1")
    endpoint_file = os.path.join(support, "mcp-endpoint.json")
    results = []
    detour = None
    try:
        detour = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour")], env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"pid {detour.pid}, data dir {data_dir}")
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
        session = client.Session(endpoint["url"], endpoint["token"], "task325-checks")
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

        def check(name, ok, detail):
            results.append((name, ok))
            print(f"{'PASS' if ok else 'FAIL'}: {name}: {detail}")

        def swipe(action="state", **arguments):
            return call("navigation_swipe", window_id=1, action=action, **arguments)

        def pane(tab_id, state=None):
            state = state or swipe()
            return next((p for p in state["panes"] if p["tab_id"] == tab_id), None)

        def selected():
            return call("list_windows")["windows"][0]

        def tabs():
            return [i for i in call("list_tabs", window_id=1)["items"] if i["section"] == "tab"]

        def wait(predicate, timeout=8):
            deadline = time.monotonic() + timeout
            value = None
            while time.monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                time.sleep(0.25)
            return value

        def wait_selected_url(suffix):
            return wait(lambda: (selected().get("selected_tab_url") or "").endswith(suffix))

        def ctx(tab_id):
            return f"tab:{tab_id}"

        # 1. A tab with no opener.
        call("open_url", window_id=1, url=f"{base}/opener.html", in_place=False)
        wait_selected_url("/opener.html")
        time.sleep(1)
        opener = selected()["selected_tab_id"]
        p = pane(opener)
        check("No opener keeps WebKit's gesture", p and not p["own_swipe"] and p["gestures_enabled"]
              and p["rubber_band_edges"] == 15, p)

        # 2. A target=_blank child.
        call("click", context=ctx(opener), selector="#blank")
        wait_selected_url("/child.html")
        time.sleep(1)
        child = selected()["selected_tab_id"]
        p = wait(lambda: (lambda q: q if q and q["opener_picture"] else None)(pane(child)), timeout=5) or pane(child)
        check("Child gets the own swipe", p and p["own_swipe"] and not p["gestures_enabled"]
              and p["rubber_band_edges"] == 14 and p["opener_id"] == opener, p)
        check("Opener was pictured as it left", bool(p and p["opener_picture"]), p)

        # 3. Cancelled.
        began = swipe("begin", direction="back", progress=0.5)
        time.sleep(0.3)
        shoot("3-back-swipe-half-way")
        swipe("finish", complete=False)
        time.sleep(0.4)
        still = any(t["tab_id"] == child for t in tabs())
        check("A cancelled swipe leaves the child open and selected",
              began["began"] is True and still and selected()["selected_tab_id"] == child
              and swipe()["swipe_active"] is False, f"began {began['began']}, open {still}")

        # 4. History.
        call("click", context=ctx(child), selector="#next")
        wait_selected_url("/page2.html")
        p = wait(lambda: (lambda q: q if q and not q["own_swipe"] else None)(pane(child)))
        check("Page 2 gives the gesture back to WebKit", p and p["can_go_back"] and p["gestures_enabled"]
              and p["rubber_band_edges"] == 15, p)
        call("run_menu_item", window_id=1, path=["Navigate", "Back"])
        wait_selected_url("/child.html")
        p = wait(lambda: (lambda q: q if q and q["own_swipe"] else None)(pane(child)))
        check("Back on page 1: the own swipe with forward", p and p["own_swipe_forward"] and p["can_go_forward"]
              and not p["gestures_enabled"] and p["rubber_band_edges"] == 10, p)
        began = swipe("begin", direction="forward", progress=0.5)
        time.sleep(0.3)
        shoot("4-forward-swipe-half-way")
        swipe("finish", complete=True)
        went = wait_selected_url("/page2.html")
        # Committed (it has a back item again) before Back is pressed.
        went = went and wait(lambda: (lambda q: q if q and q["can_go_back"] and not q["own_swipe"] else None)(pane(child)))
        check("A forward swipe goes forward", began["began"] is True and bool(went), selected().get("selected_tab_url"))
        call("run_menu_item", window_id=1, path=["Navigate", "Back"])
        wait_selected_url("/child.html")
        wait(lambda: (lambda q: q if q and q["own_swipe"] else None)(pane(child)))

        # 5. Completed, then Reopen Closed Tab.
        began = swipe("begin", direction="back", progress=0.6)
        time.sleep(0.2)
        swipe("finish", complete=True)
        time.sleep(0.6)
        shoot("5-after-back-swipe")
        gone = not any(t["tab_id"] == child for t in tabs())
        check("A completed back swipe closes the child and selects its opener",
              began["began"] is True and gone and selected()["selected_tab_id"] == opener,
              f"closed {gone}, selected {selected()['selected_tab_url']}")
        call("run_menu_item", window_id=1, path=["File", "Reopen Closed Tab"])
        back = wait_selected_url("/child.html")
        check("Reopen Closed Tab brings it back", bool(back), selected().get("selected_tab_url"))
        reopened = selected()["selected_tab_id"]
        print(f"  reopened tab's pane: {pane(reopened)}")
        call("select_tab", window_id=1, id=opener)
        wait_selected_url("/opener.html")

        # 6. The Back button.
        call("click", context=ctx(opener), selector="#blank")
        wait_selected_url("/child.html")
        time.sleep(0.8)
        child2 = selected()["selected_tab_id"]
        # The sidebar's button: with the page focused, Navigate > Back (Cmd+[)
        # reaches WKWebView's own goBack: action first, which is disabled on a
        # page with no back item.
        print(f"  hit test at the back button: {call('hit_test', window_id=1, x=145, y=26)}")
        call("click", window_id=1, x=145, y=26)
        time.sleep(0.8)
        gone = not any(t["tab_id"] == child2 for t in tabs())
        check("The Back button closes a child to its opener", gone and selected()["selected_tab_id"] == opener,
              f"closed {gone}, selected {selected()['selected_tab_url']}")

        # 7. A split child.
        call("click", context=ctx(opener), selector="#split", button="right")
        call("choose_menu_item", title="Open Link in Split View")
        time.sleep(2)
        split_child = next((t["tab_id"] for t in tabs() if (t.get("url") or "").endswith("/child.html")
                            and t.get("split_group_id") and t["tab_id"] != reopened), None)
        state = swipe()
        p = pane(split_child, state) if split_child else None
        check("A split child gets the own swipe in its pane", p and p["own_swipe"] and len(state["panes"]) == 2,
              state)
        if split_child:
            began = swipe("begin", context=ctx(split_child), direction="back", progress=0.5)
            time.sleep(0.3)
            shoot("7-split-pane-half-way")
            swipe("finish", complete=True)
            time.sleep(0.8)
            gone = not any(t["tab_id"] == split_child for t in tabs())
            state = swipe()
            check("A swipe closes the split child from its own pane",
                  began["began"] is True and gone and selected()["selected_tab_id"] == opener
                  and len(state["panes"]) == 1, f"closed {gone}, panes {len(state['panes'])}")
            shoot("7-after-split-swipe")

        # 8. Under a Peek: a child that would swipe back to its opener.
        call("click", context=ctx(opener), selector="#blank")
        wait(lambda: selected()["selected_tab_id"] not in (opener, reopened)
             and (selected().get("selected_tab_url") or "").endswith("/child.html"))
        time.sleep(0.8)
        child3 = selected()["selected_tab_id"]
        before = pane(child3)
        call("click", context=ctx(child3), selector="#peek", modifiers=["shift"])
        time.sleep(1.5)
        shoot("8-peek")
        began = swipe("begin", direction="back", progress=0.5)
        check("Nothing starts under a Peek", bool(before and before["own_swipe"]) and began["began"] is False
              and any(t["tab_id"] == child3 for t in tabs()), f"before the Peek {before}, began {began['began']}")

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
        for key in (f"NSWindow Frame BrowserWindow-{data_dir}", f"NSSplitView Subview Frames BrowserSplitView-{data_dir}"):
            subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)
        if os.path.basename(support) == data_dir and data_dir.startswith("DetourVerify325-"):
            subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
            plist = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
            if os.path.exists(plist):
                os.remove(plist)
            remove_webkit_storage(support, data_dir)
            shutil.rmtree(support, ignore_errors=True)
        if os.path.basename(fixture).startswith("task325-fixture-"):
            shutil.rmtree(fixture, ignore_errors=True)

    print(f"Screenshots: {out_dir}")
    failed = [name for name, ok in results if not ok]
    print("ALL PASSED" if results and not failed else f"FAILED: {', '.join(failed) or 'nothing ran'}")
    return 0 if results and not failed else 1


if __name__ == "__main__":
    sys.exit(main())
