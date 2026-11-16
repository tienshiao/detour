#!/usr/bin/env python3
"""TASK-377's runtime checks: the sidebar Back button and Navigate > Back
follow whether Back has anywhere to go, through the automation endpoint
(TASK-228.1). Reuses the fixture, server and cleanup helpers of
task325-swipe-checks.py.

  1. A root tab (no history, no opener): Navigate > Back is refused as
     disabled, and the sidebar button is drawn dimmed (the reference).
  2. A target=_blank child of the opener: Back is enabled (button drawn
     like an enabled one, not like the reference).
  3. The opener is archived from its sidebar row's menu while the child stays
     selected: Navigate > Back (and Cmd+[) is refused as disabled, the
     button is drawn dimmed again, and the child is still open.

The button's state is read from screenshots: the darkest pixel in a box
around the chevron, compared with the root tab's.

Needs a Debug build and the sandbox off (it launches an app). Usage:

  docs/harness/task377-back-enabled-checks.py /path/to/Detour.app [output-dir]

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
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DATA_DIR = "DetourVerify-377"
BACK_BUTTON = (145, 26)  # the sidebar Back button, window points, top-left origin (task325)


def load_325():
    sys.dont_write_bytecode = True
    path = os.path.join(HERE, "task325-swipe-checks.py")
    loader = importlib.machinery.SourceFileLoader("task325_checks", path)
    spec = importlib.util.spec_from_loader("task325_checks", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def png_rows(path):
    """(width, height, bytes per pixel, rows) of an 8-bit non-interlaced PNG."""
    with open(path, "rb") as f:
        data = f.read()
    pos, idat = 8, b""
    while pos < len(data):
        length = int.from_bytes(data[pos:pos + 4], "big")
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height = int.from_bytes(body[0:4], "big"), int.from_bytes(body[4:8], "big")
            depth, colour = body[8], body[9]
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    assert depth == 8 and colour in (2, 6), f"unsupported PNG (depth {depth}, colour type {colour})"
    bpp = 3 if colour == 2 else 4
    raw, stride = zlib.decompress(idat), width * bpp
    rows, previous = [], bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = previous[i]
            c = previous[i - bpp] if i >= bpp else 0
            if kind == 1:
                line[i] = (line[i] + a) & 0xFF
            elif kind == 2:
                line[i] = (line[i] + b) & 0xFF
            elif kind == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 0xFF
        rows.append(line)
        previous = line
    return width, height, bpp, rows


def chevron_ink(path, window_width):
    """The darkest luma in a 16 x 16 pt box around the Back button."""
    width, height, bpp, rows = png_rows(path)
    scale = width / window_width
    cx, cy = BACK_BUTTON
    darkest = 255
    for y in range(int((cy - 8) * scale), int((cy + 8) * scale)):
        row = rows[y]
        for x in range(int((cx - 8) * scale), int((cx + 8) * scale)):
            r, g, b = row[x * bpp], row[x * bpp + 1], row[x * bpp + 2]
            darkest = min(darkest, int(0.299 * r + 0.587 * g + 0.114 * b))
    return darkest


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    t325 = load_325()
    app = os.path.abspath(sys.argv[1])
    out_dir = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else tempfile.mkdtemp(prefix="task377-")
    os.makedirs(out_dir, exist_ok=True)
    support = os.path.expanduser(f"~/Library/Application Support/{DATA_DIR}")
    if os.path.exists(support):
        print(f"FAIL: {support} exists from an earlier run; remove it first")
        return 1
    client = t325.load_client()
    fixture = tempfile.mkdtemp(prefix="task377-fixture-")
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
        session = client.Session(endpoint["url"], endpoint["token"], "task377-checks")
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

    def ink(name):
        path = os.path.join(out_dir, f"{name}.png")
        call("screenshot", window_id=1, save_to=path, include_image=False, overwrite=True)
        return chevron_ink(path, selected()["frame"]["width"])

    def menu_back_refused():
        return refusal("run_menu_item", window_id=1, path=["Navigate", "Back"])

    def row_point(tab_id):
        """The middle of a normal tab's sidebar row: the table hit-tests as a
        whole, so the row is found by its place. With no pinned tabs, the
        first tab row is at y = 184 (below Home, the separator and New
        Tab), rows 36 pt apart (measured on this layout's screenshot)."""
        order = [i.get("tab_id") for i in items("tab")]
        return (120, 184 + 36 * order.index(tab_id)) if tab_id in order else None

    try:
        launch()
        # 1. A root tab.
        call("open_url", window_id=1, url=f"{base}/page2.html", in_place=False)
        wait_selected_url("/page2.html")
        time.sleep(1.5)
        refused = menu_back_refused()
        check("On a root tab Navigate > Back is disabled", refused is not None and refused.get("code") == "menu_item_disabled",
              refused)
        reference = ink("1-root-tab")
        print(f"  root tab chevron ink: {reference}")

        # 2. A child of the opener.
        call("open_url", window_id=1, url=f"{base}/opener.html", in_place=False)
        wait_selected_url("/opener.html")
        time.sleep(1)
        opener = selected()["selected_tab_id"]
        call("click", context=f"tab:{opener}", selector="#blank")
        wait_selected_url("/child.html")
        time.sleep(1.5)
        child = selected()["selected_tab_id"]
        enabled = ink("2-child")
        print(f"  child chevron ink: {enabled}")
        check("On a child the Back button is drawn enabled (darker than on the root tab)",
              enabled < reference - 20, f"child {enabled}, root {reference}")

        # 3. Archive (close) the opener from its sidebar row's menu; the child stays selected.
        point = row_point(opener)
        check("The opener's sidebar row is found", point is not None, point)
        hit = call("hit_test", window_id=1, x=point[0], y=point[1])
        print(f"  opener row at {point}: {hit.get('view')}")
        call("click", window_id=1, x=point[0], y=point[1], button="right")
        menu = call("list_menu")
        print(f"  row menu: {[i.get('title') for i in menu['items']]}")
        call("choose_menu_item", title="Archive Tab")
        wait(lambda: not any(i.get("tab_id") == opener for i in items("tab")))
        time.sleep(1)
        gone = not any(i.get("tab_id") == opener for i in items("tab"))
        check("The opener closed and the child stays selected", gone and selected()["selected_tab_id"] == child,
              f"opener closed {gone}, selected {selected().get('selected_tab_url')}")
        refused = menu_back_refused()
        check("After the opener closed, Navigate > Back is disabled",
              refused is not None and refused.get("code") == "menu_item_disabled", refused)
        refused_key = refusal("run_menu_item", window_id=1, key="cmd+[")
        check("And Cmd+[ is refused too", refused_key is not None, refused_key)
        after = ink("3-opener-closed")
        print(f"  after-close chevron ink: {after}")
        check("The Back button is drawn disabled again (as on the root tab)",
              abs(after - reference) <= 10 and after > enabled + 20, f"after {after}, root {reference}, child {enabled}")
        still = any(i.get("tab_id") == child for i in items("tab"))
        check("The child is still open", still, still)

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
        if os.path.basename(fixture).startswith("task377-fixture-"):
            shutil.rmtree(fixture, ignore_errors=True)

    print(f"Screenshots: {out_dir}")
    failed = [name for name, ok in results if not ok]
    print("ALL PASSED" if results and not failed else f"FAILED: {', '.join(failed) or 'nothing ran'}")
    return 0 if results and not failed else 1


if __name__ == "__main__":
    sys.exit(main())
