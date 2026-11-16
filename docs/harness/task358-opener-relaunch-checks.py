#!/usr/bin/env python3
"""TASK-358's runtime checks: a pinned or favourite tab's opener link survives
a relaunch, and a favourite counts as an opener, through the automation
endpoint (TASK-228.1) and its Debug-only navigation_swipe tool. Reuses the
fixture, server and cleanup helpers of task325-swipe-checks.py.

  Launch 1: a target=_blank child of the opener is pinned (Cmd+D); a second
            child stays a normal tab. Quit.
  Launch 2: Navigate > Back (Cmd+[) on the pinned child selects its opener
            (the link came back from the database). Quit; the opener's row is
            turned into a favourite's backing row with sqlite3.
  Launch 3: the normal child closes to the favourite by Cmd+[ (own swipe,
            opener_id = the favourite); Cmd+[ on the pinned child selects the
            favourite; a lone child of the favourite closed by Cmd+W returns
            to the favourite, not to its neighbour.

Needs a Debug build and the sandbox off (it launches an app). Usage:

  docs/harness/task358-opener-relaunch-checks.py /path/to/Detour.app [output-dir]

Exit status 0 when every check passed.
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DATA_DIR = "DetourVerify-358"


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
    out_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="task358-")
    os.makedirs(out_dir, exist_ok=True)
    support = os.path.expanduser(f"~/Library/Application Support/{DATA_DIR}")
    if os.path.exists(support):
        print(f"FAIL: {support} exists from an earlier run; remove it first")
        return 1
    client = t325.load_client()
    fixture = tempfile.mkdtemp(prefix="task358-fixture-")
    t325.write_fixture(fixture)
    server = t325.serve(fixture)
    base = f"http://127.0.0.1:{server.server_address[1]}"
    endpoint_file = os.path.join(support, "mcp-endpoint.json")
    db_path = os.path.join(support, "browser.db")
    results = []
    state = {"pid": None, "session": None}

    def check(name, ok, detail):
        results.append((name, ok))
        print(f"{'PASS' if ok else 'FAIL'}: {name}: {detail}")

    def launch(n):
        out = subprocess.run([os.path.join(REPO, "scripts", "launch-detour.sh"), app, DATA_DIR,
                              os.path.join(out_dir, f"launch{n}.log")],
                             env=dict(os.environ, DETOUR_MCP="1"), capture_output=True, text=True, check=True)
        state["pid"] = int(out.stdout.strip().splitlines()[-1])
        print(f"launch {n}: pid {state['pid']}")
        for _ in range(80):
            if os.path.exists(endpoint_file):
                break
            time.sleep(0.25)
        else:
            raise RuntimeError("Detour did not open its endpoint")
        time.sleep(2)
        with open(endpoint_file) as f:
            endpoint = json.load(f)
        session = client.Session(endpoint["url"], endpoint["token"], "task358-checks")
        session.open()
        state["session"] = session

    def quit_app():
        if state["session"] is not None:
            state["session"].close()
            state["session"] = None
        pid = state["pid"]
        if pid is None:
            return
        os.kill(pid, signal.SIGTERM)
        for _ in range(60):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.25)
        state["pid"] = None
        time.sleep(0.5)

    def call(tool, **arguments):
        result = state["session"].call(tool, arguments)
        content = result.get("structuredContent")
        if result.get("isError"):
            raise RuntimeError(f"{tool}: {content}")
        return content

    def shoot(name):
        call("screenshot", window_id=1, save_to=os.path.join(out_dir, f"{name}.png"), include_image=False,
             overwrite=True)

    def pane(tab_id):
        panes = call("navigation_swipe", window_id=1, action="state")["panes"]
        return next((p for p in panes if p["tab_id"] == tab_id), None)

    def selected():
        return call("list_windows")["windows"][0]

    def items(section=None):
        listed = call("list_tabs", window_id=1)["items"]
        return [i for i in listed if section is None or i["section"] == section]

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

    def select(item_id, suffix):
        call("select_tab", window_id=1, id=item_id)
        wait_selected_url(suffix)
        time.sleep(0.8)

    def back():
        call("run_menu_item", window_id=1, key="cmd+[")
        time.sleep(0.8)

    def db_row(sql, args=()):
        connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        try:
            return connection.execute(sql, args).fetchone()
        finally:
            connection.close()

    try:
        # Launch 1: the opener, a pinned child and a normal child.
        launch(1)
        call("open_url", window_id=1, url=f"{base}/opener.html", in_place=False)
        wait_selected_url("/opener.html")
        time.sleep(1)
        opener = selected()["selected_tab_id"]
        call("click", context=f"tab:{opener}", selector="#blank")
        wait_selected_url("/child.html")
        time.sleep(1)
        pinned_child = selected()["selected_tab_id"]
        call("run_menu_item", window_id=1, key="cmd+d")
        pinned_item = wait(lambda: next((i for i in items("pinned") if i.get("tab_id") == pinned_child), None))
        check("The child is pinned", pinned_item is not None, pinned_item)
        select(opener, "/opener.html")
        call("click", context=f"tab:{opener}", selector="#blank")
        wait(lambda: selected()["selected_tab_id"] not in (opener, pinned_child)
             and (selected().get("selected_tab_url") or "").endswith("/child.html"))
        time.sleep(1)
        normal_child = selected()["selected_tab_id"]
        time.sleep(2)  # the debounced save
        quit_app()
        row = db_row("SELECT parentID, sortOrder FROM tab WHERE UPPER(id) = UPPER(?)", (pinned_child,))
        check("The pinned child's backing row carries its opener",
              row is not None and (row[0] or "").upper() == opener.upper() and row[1] == -1, row)

        # Launch 2: the pinned child's link came back.
        launch(2)
        pinned_item = next((i for i in items("pinned") if i.get("tab_id") == pinned_child), None)
        check("The pinned child is back after the relaunch", pinned_item is not None, pinned_item)
        select(pinned_item["id"], "/child.html")
        shoot("2-pinned-child-after-relaunch")
        back()
        still = any(i.get("tab_id") == pinned_child for i in items("pinned"))
        check("After a relaunch, Cmd+[ on the pinned child selects its opener and keeps the pinned tab",
              selected()["selected_tab_id"] == opener and still,
              f"selected {selected()['selected_tab_url']}, pinned kept {still}")
        time.sleep(1.5)
        quit_app()

        # Make the opener a favourite: its row becomes a favourite's backing
        # row (sortOrder -2) under the same space, as a save writes it.
        connection = sqlite3.connect(db_path)
        try:
            space_id, url, title = connection.execute(
                "SELECT spaceID, url, title FROM tab WHERE UPPER(id) = UPPER(?)", (opener,)).fetchone()
            profile_id = connection.execute("SELECT profileID FROM space WHERE id = ?", (space_id,)).fetchone()[0]
            opener_row_id = connection.execute("SELECT id FROM tab WHERE UPPER(id) = UPPER(?)",
                                               (opener,)).fetchone()[0]
            connection.execute("UPDATE tab SET sortOrder = -2 WHERE id = ?", (opener_row_id,))
            connection.execute("INSERT INTO favorite (id, profileID, url, title, sortOrder, tabID) VALUES (?, ?, ?, ?, 0, ?)",
                               (str(uuid.uuid4()).upper(), profile_id, url, title, opener_row_id))
            connection.execute("UPDATE space SET selectedTabID = ? WHERE id = ?", (opener_row_id, space_id))
            connection.commit()
        finally:
            connection.close()

        # Launch 3: the favourite is an opener.
        launch(3)
        favourite = wait(lambda: next((i for i in items("favorite") if i.get("tab_id") == opener), None))
        check("The opener is a favourite now", favourite is not None, favourite)
        normal_item = next((i for i in items("tab") if i.get("tab_id") == normal_child), None)
        select(normal_item["id"], "/child.html")
        p = wait(lambda: (lambda q: q if q and q["own_swipe"] else None)(pane(normal_child)), timeout=5) \
            or pane(normal_child)
        check("A child of a favourite gets the own swipe, its opener the favourite",
              p is not None and p["own_swipe"] and p["opener_id"] == opener, p)
        shoot("3-child-of-favourite")
        back()
        gone = not any(i.get("tab_id") == normal_child for i in items("tab"))
        check("Cmd+[ closes a child of a favourite and selects the favourite",
              gone and selected()["selected_tab_id"] == opener,
              f"closed {gone}, selected {selected()['selected_tab_url']}")

        pinned_item = next((i for i in items("pinned") if i.get("tab_id") == pinned_child), None)
        select(pinned_item["id"], "/child.html")
        back()
        check("Cmd+[ on the pinned child selects the favourite it was opened from",
              selected()["selected_tab_id"] == opener, selected()["selected_tab_url"])

        # A lone child of the favourite, a neighbour after it: Cmd+W returns
        # to the favourite.
        call("open_url", window_id=1, url=f"{base}/page2.html", in_place=False)
        wait_selected_url("/page2.html")
        time.sleep(0.8)
        neighbour = selected()["selected_tab_id"]
        select(favourite["id"], "/opener.html")
        # Cmd+click: a background tab whose parent is the selected favourite
        # (a target=_blank link on a favourite would peek instead).
        call("click", context=f"tab:{opener}", selector="#blank", modifiers=["cmd"])
        lone = wait(lambda: next((i for i in items("tab") if (i.get("url") or "").endswith("/child.html")), None))
        lone_child = lone["tab_id"]
        select(lone["id"], "/child.html")
        order = [i.get("tab_id") for i in items("tab")]
        call("run_menu_item", window_id=1, path=["File", "Close Tab"])
        wait(lambda: not any(i.get("tab_id") == lone_child for i in items("tab")))
        time.sleep(0.5)
        check("Cmd+W on a lone child of a favourite returns to the favourite, not the neighbour",
              selected()["selected_tab_id"] == opener and order == [lone_child, neighbour],
              f"order before {order}, selected {selected()['selected_tab_url']}")
        shoot("3-after-close")

        active = call("list_windows")["app_active"]
        check("Detour stayed in the background", active is False, f"app_active={active}")
    except Exception as error:
        check("The run finished", False, repr(error))
    finally:
        try:
            quit_app()
        except Exception as error:
            print(f"quit: {error!r}")
        server.shutdown()
        for key in (f"NSWindow Frame BrowserWindow-{DATA_DIR}", f"NSSplitView Subview Frames BrowserSplitView-{DATA_DIR}"):
            subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)
        if os.path.basename(support) == DATA_DIR:
            subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{DATA_DIR}"], capture_output=True)
            plist = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{DATA_DIR}.plist")
            if os.path.exists(plist):
                os.remove(plist)
            t325.remove_webkit_storage(support, DATA_DIR)
            shutil.rmtree(support, ignore_errors=True)
        if os.path.basename(fixture).startswith("task358-fixture-"):
            shutil.rmtree(fixture, ignore_errors=True)

    print(f"Screenshots: {out_dir}")
    failed = [name for name, ok in results if not ok]
    print("ALL PASSED" if results and not failed else f"FAILED: {', '.join(failed) or 'nothing ran'}")
    return 0 if results and not failed else 1


if __name__ == "__main__":
    sys.exit(main())
