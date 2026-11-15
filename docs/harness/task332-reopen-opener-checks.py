#!/usr/bin/env python3
"""TASK-332's runtime checks: Reopen Closed Tab brings a child tab back with
its link to its opener, through the automation endpoint (TASK-228.1) and its
Debug-only navigation_swipe tool. Reuses the fixture, server and cleanup of
task325-swipe-checks.py.

  1. A target=_blank child closed with Cmd+W writes its opener into its
     closed-tab record; Reopen Closed Tab brings it back with that opener
     (own swipe, opener_id), and Navigate > Back (Cmd+[) with the page
     focused closes it to the opener.
  2. Reopened again, a completed back swipe (scripted tracker) closes it to
     the opener; reopened once more, so does the sidebar's Back button.
  3. Closed again, then the opener closed too: Reopen Closed Tab twice brings
     back the opener (a new tab) and then the child with no opener: WebKit's
     gesture, and Cmd+[ leaves it open.

Needs a Debug build and the sandbox off (it launches an app). Usage:

  docs/harness/task332-reopen-opener-checks.py /path/to/Detour.app [output-dir]

Exit status 0 when every check passed.
"""

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
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_325():
    sys.dont_write_bytecode = True
    path = os.path.join(HERE, "task325-swipe-checks.py")
    loader = importlib.machinery.SourceFileLoader("task325_checks", path)
    spec = importlib.util.spec_from_loader("task325_checks", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    t325 = load_325()
    app = os.path.abspath(sys.argv[1])
    out_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="task332-")
    os.makedirs(out_dir, exist_ok=True)
    data_dir = f"DetourVerify332-{secrets.token_hex(3)}"
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    client = t325.load_client()

    fixture = tempfile.mkdtemp(prefix="task332-fixture-")
    t325.write_fixture(fixture)
    server = t325.serve(fixture)
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
        session = client.Session(endpoint["url"], endpoint["token"], "task332-checks")
        session.open()

        def call(tool, **arguments):
            result = session.call(tool, arguments)
            content = result.get("structuredContent")
            if result.get("isError"):
                raise RuntimeError(f"{tool}: {content}")
            return content

        def check(name, ok, detail):
            results.append((name, ok))
            print(f"{'PASS' if ok else 'FAIL'}: {name}: {detail}")

        def shoot(name):
            call("screenshot", window_id=1, save_to=os.path.join(out_dir, f"{name}.png"), include_image=False,
                 overwrite=True)

        def pane(tab_id):
            state = call("navigation_swipe", window_id=1, action="state")
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

        def closed_record(tab_id):
            """(parentID,) of the closed-tab row of `tab_id`, read-only."""
            db = os.path.join(support, "browser.db")
            connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            try:
                return connection.execute("SELECT parentID FROM closedTab WHERE UPPER(tabID) = UPPER(?)",
                                          (tab_id,)).fetchone()
            finally:
                connection.close()

        def reopen(suffix):
            call("run_menu_item", window_id=1, path=["File", "Reopen Closed Tab"])
            wait_selected_url(suffix)
            time.sleep(0.8)
            return selected()["selected_tab_id"]

        def focus_page_and_go_back(tab_id):
            call("click", context=ctx(tab_id), selector="h1")
            time.sleep(0.3)
            call("run_menu_item", window_id=1, key="cmd+[")
            time.sleep(0.8)

        # The opener and a target=_blank child.
        call("open_url", window_id=1, url=f"{base}/opener.html", in_place=False)
        wait_selected_url("/opener.html")
        time.sleep(1)
        opener = selected()["selected_tab_id"]
        call("click", context=ctx(opener), selector="#blank")
        wait_selected_url("/child.html")
        time.sleep(1)
        child = selected()["selected_tab_id"]
        p = pane(child)
        check("Child opened from a link has its opener", p and p["opener_id"] == opener and p["own_swipe"], p)

        # 1. Cmd+W, then Reopen Closed Tab, then Cmd+[ with the page focused.
        call("run_menu_item", window_id=1, path=["File", "Close Tab"])
        wait(lambda: not any(t["tab_id"] == child for t in tabs()))
        row = wait(lambda: closed_record(child), timeout=5)
        check("The closed-tab record carries the opener", row is not None and (row[0] or "").upper() == opener.upper(),
              row)
        reopened = reopen("/child.html")
        p = wait(lambda: (lambda q: q if q and q["own_swipe"] else None)(pane(reopened)), timeout=5) or pane(reopened)
        check("Reopened child closes to its opener again (own swipe, opener_id)",
              reopened != child and p and p["opener_id"] == opener and p["own_swipe"]
              and not p["gestures_enabled"], p)
        shoot("1-reopened-child")
        focus_page_and_go_back(reopened)
        gone = not any(t["tab_id"] == reopened for t in tabs())
        check("Cmd+[ with the page focused closes the reopened child to its opener",
              gone and selected()["selected_tab_id"] == opener, f"closed {gone}, selected {selected()['selected_tab_url']}")

        # 1b. Reopened again: a completed back swipe (scripted tracker).
        reopened = reopen("/child.html")
        wait(lambda: (lambda q: q if q and q["own_swipe"] else None)(pane(reopened)), timeout=5)
        began = call("navigation_swipe", window_id=1, action="begin", direction="back", progress=0.6)
        time.sleep(0.2)
        call("navigation_swipe", window_id=1, action="finish", complete=True)
        time.sleep(0.8)
        gone = not any(t["tab_id"] == reopened for t in tabs())
        check("A back swipe closes the reopened child to its opener",
              began["began"] is True and gone and selected()["selected_tab_id"] == opener,
              f"began {began['began']}, closed {gone}, selected {selected()['selected_tab_url']}")

        # 2. Reopened again: the sidebar's Back button.
        reopened = reopen("/child.html")
        p = pane(reopened)
        print(f"  hit test at the back button: {call('hit_test', window_id=1, x=145, y=26)}")
        call("click", window_id=1, x=145, y=26)
        time.sleep(0.8)
        gone = not any(t["tab_id"] == reopened for t in tabs())
        check("The Back button closes the twice-reopened child to its opener",
              p and p["opener_id"] == opener and gone and selected()["selected_tab_id"] == opener,
              f"pane {p}, closed {gone}, selected {selected()['selected_tab_url']}")

        # 3. Reopen the child, close it, close the opener, reopen both.
        reopened = reopen("/child.html")
        call("run_menu_item", window_id=1, path=["File", "Close Tab"])
        wait(lambda: not any(t["tab_id"] == reopened for t in tabs()))
        call("select_tab", window_id=1, id=opener)
        wait_selected_url("/opener.html")
        call("run_menu_item", window_id=1, path=["File", "Close Tab"])
        wait(lambda: not any(t["tab_id"] == opener for t in tabs()))
        new_opener = reopen("/opener.html")
        orphan = reopen("/child.html")
        p = pane(orphan)
        check("With its opener closed meanwhile, the reopened child has none (WebKit's gesture)",
              new_opener != opener and p and p["opener_id"] is None and not p["own_swipe"]
              and p["gestures_enabled"], p)
        shoot("3-orphan-child")
        focus_page_and_go_back(orphan)
        still = any(t["tab_id"] == orphan for t in tabs())
        check("Cmd+[ leaves the orphan open", still and selected()["selected_tab_id"] == orphan,
              f"open {still}, selected {selected()['selected_tab_url']}")

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
        if os.path.basename(support) == data_dir and data_dir.startswith("DetourVerify332-"):
            subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
            plist = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
            if os.path.exists(plist):
                os.remove(plist)
            t325.remove_webkit_storage(support, data_dir)
            shutil.rmtree(support, ignore_errors=True)
        if os.path.basename(fixture).startswith("task332-fixture-"):
            shutil.rmtree(fixture, ignore_errors=True)

    print(f"Screenshots: {out_dir}")
    failed = [name for name, ok in results if not ok]
    print("ALL PASSED" if results and not failed else f"FAILED: {', '.join(failed) or 'nothing ran'}")
    return 0 if results and not failed else 1


if __name__ == "__main__":
    sys.exit(main())
