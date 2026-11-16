#!/usr/bin/env python3
"""TASK-378's runtime checks: a pinned tab that goes dormant keeps its own
opener link, through the automation endpoint (TASK-228.1). Reuses the
fixture, server and cleanup helpers of task325-swipe-checks.py.

  1. A target=_blank child of the opener is pinned (Cmd+D).
  2. Cmd+W on the pinned child leaves a dormant tile (no backing tab).
  3. Selecting the tile wakes it (a new tab); Cmd+[ on it selects the
     opener and keeps the pinned tab.
  4. Cmd+W again, then the opener is archived; the woken tile has no opener
     any more: Navigate > Back is refused as disabled (TASK-377).

Needs a Debug build and the sandbox off (it launches an app). Usage:

  docs/harness/task378-dormant-opener-checks.py /path/to/Detour.app [output-dir]

Exit status 0 when every check passed.
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DATA_DIR = "DetourVerify-377"


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
    out_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="task378-")
    os.makedirs(out_dir, exist_ok=True)
    support = os.path.expanduser(f"~/Library/Application Support/{DATA_DIR}")
    if os.path.exists(support):
        print(f"FAIL: {support} exists from an earlier run; remove it first")
        return 1
    client = t325.load_client()
    fixture = tempfile.mkdtemp(prefix="task378-fixture-")
    t325.write_fixture(fixture)
    server = t325.serve(fixture)
    base = f"http://127.0.0.1:{server.server_address[1]}"
    endpoint_file = os.path.join(support, "mcp-endpoint.json")
    results = []
    state = {"pid": None, "session": None}

    def check(name, ok, detail):
        results.append((name, ok))
        print(f"{'PASS' if ok else 'FAIL'}: {name}: {detail}")

    def launch():
        out = subprocess.run([os.path.join(REPO, "scripts", "launch-detour.sh"), app, DATA_DIR,
                              os.path.join(out_dir, "launch.log")],
                             env=dict(os.environ, DETOUR_MCP="1"), capture_output=True, text=True, check=True)
        state["pid"] = int(out.stdout.strip().splitlines()[-1])
        print(f"launch: pid {state['pid']}")
        for _ in range(80):
            if os.path.exists(endpoint_file):
                break
            time.sleep(0.25)
        else:
            raise RuntimeError("Detour did not open its endpoint")
        time.sleep(2)
        with open(endpoint_file) as f:
            endpoint = json.load(f)
        session = client.Session(endpoint["url"], endpoint["token"], "task378-checks")
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

    def refusal(tool, **arguments):
        """The error a call is refused with, or None when it ran."""
        result = state["session"].call(tool, arguments)
        return (result.get("structuredContent") or {}).get("error") if result.get("isError") else None

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

    try:
        launch()
        call("open_url", window_id=1, url=f"{base}/opener.html", in_place=False)
        wait_selected_url("/opener.html")
        time.sleep(1)
        opener = selected()["selected_tab_id"]
        call("click", context=f"tab:{opener}", selector="#blank")
        wait_selected_url("/child.html")
        time.sleep(1)
        child = selected()["selected_tab_id"]
        call("run_menu_item", window_id=1, key="cmd+d")
        entry = wait(lambda: next((i for i in items("pinned") if i.get("tab_id") == child), None))
        check("1. The child is pinned", entry is not None, entry)

        call("run_menu_item", window_id=1, key="cmd+w")
        dormant = wait(lambda: next((i for i in items("pinned") if i["id"] == entry["id"] and not i["live"]), None))
        check("2. Cmd+W leaves the pinned child a dormant tile", dormant is not None, dormant)

        call("select_tab", window_id=1, id=entry["id"])
        woken = wait(lambda: next((i for i in items("pinned") if i["id"] == entry["id"] and i["live"]), None))
        wait_selected_url("/child.html")
        time.sleep(1)
        check("3. Selecting the tile wakes it as a new tab",
              woken is not None and woken["tab_id"] != child and selected()["selected_tab_id"] == woken["tab_id"],
              woken)
        call("screenshot", window_id=1, save_to=os.path.join(out_dir, "3-woken.png"), include_image=False,
             overwrite=True)
        call("run_menu_item", window_id=1, key="cmd+[")
        time.sleep(0.8)
        kept = any(i["id"] == entry["id"] and i["live"] for i in items("pinned"))
        check("3. Cmd+[ on the woken pinned tab selects its opener and keeps the pinned tab",
              selected()["selected_tab_id"] == opener and kept,
              f"selected {selected().get('selected_tab_url')}, pinned live {kept}")

        # 4. Dormant again, the opener archived meanwhile: no opener on waking.
        call("select_tab", window_id=1, id=entry["id"])
        wait_selected_url("/child.html")
        time.sleep(0.5)
        call("run_menu_item", window_id=1, key="cmd+w")
        wait(lambda: next((i for i in items("pinned") if i["id"] == entry["id"] and not i["live"]), None))
        call("select_tab", window_id=1, id=opener)
        wait_selected_url("/opener.html")
        time.sleep(0.5)
        call("run_menu_item", window_id=1, key="cmd+w")
        wait(lambda: not any(i.get("tab_id") == opener for i in items("tab")))
        call("select_tab", window_id=1, id=entry["id"])
        wait_selected_url("/child.html")
        time.sleep(1)
        refused = refusal("run_menu_item", window_id=1, path=["Navigate", "Back"])
        check("4. Woken after its opener closed: Navigate > Back is disabled",
              refused is not None and refused.get("code") == "menu_item_disabled", refused)

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
        if os.path.basename(fixture).startswith("task378-fixture-"):
            shutil.rmtree(fixture, ignore_errors=True)

    print(f"Screenshots: {out_dir}")
    failed = [name for name, ok in results if not ok]
    print("ALL PASSED" if results and not failed else f"FAILED: {', '.join(failed) or 'nothing ran'}")
    return 0 if results and not failed else 1


if __name__ == "__main__":
    sys.exit(main())
