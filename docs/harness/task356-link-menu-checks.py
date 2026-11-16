#!/usr/bin/env python3
"""TASK-356's runtime check, through the automation endpoint (TASK-228): the
link menu's Open Link in New Tab and Open Link in New Window go where a Link
Route sends the link, as a routed Cmd+click does; Open Link in Split View and
Open Link in Quick Detour are never routed; with no route New Tab and New
Window open as before.

A loopback server serves a page of links on 127.0.0.1; the links to
`localhost` match a route to the space Work, the links to 127.0.0.1 match
none. Window 1 shows Personal with the links page; a second window is put on
Work by typing a localhost URL into it (a routed typed URL switches it).
Each case right-clicks a link (`click button=right`), reads the menu
(`list_menu`) and chooses the item by its title (`choose_menu_item`): the
real menu, WebKit's replayed item and `createWebViewWith`.

Needs the sandbox off (it launches an app and serves loopback HTTP). Usage:

  docs/harness/task356-link-menu-checks.py /path/to/Detour.app <output-dir> [data-dir-name]

The data directory (default DetourVerify-356), its WebKit stores, its
defaults suite and its window keys are removed when it ends. Each case
makes the links window key with set_window_frame activate=true, which brings
Detour to the front.
"""
import http.server, importlib.machinery, importlib.util, json, os, shutil, signal, subprocess, sys, threading, time

here = os.path.dirname(os.path.abspath(__file__))
app, out = sys.argv[1], sys.argv[2]
data_dir = sys.argv[3] if len(sys.argv) > 3 else "DetourVerify-356"
assert data_dir.startswith("DetourVerify"), "an isolated data directory only"
os.makedirs(out, exist_ok=True)
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("t324", os.path.join(here, "task324-endpoint-checks.py"))
spec = importlib.util.spec_from_loader("t324", loader); t324 = importlib.util.module_from_spec(spec); loader.exec_module(t324)
client = t324.load_client()

CASES = ["newtab", "newwindow", "split", "quickdetour", "plain-newtab", "plain-newwindow"]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_address[1]
        path = self.path.split("?")[0]
        if path == "/links":
            links = []
            for case in CASES:
                host = "127.0.0.1" if case.startswith("plain-") else "localhost"
                links.append(f'<p><a id="{case}" href="http://{host}:{port}/target?{case}">{case}</a></p>')
            self.reply("<!doctype html><title>Links</title><body>" + "".join(links) + "</body>")
        elif path == "/target":
            self.reply("<!doctype html><title>Target</title><body>target</body>")
        else:
            self.send_response(404); self.end_headers()

    def reply(self, text):
        data = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]
base = f"http://127.0.0.1:{port}"

fixture_path = os.path.join(out, "world.json")
json.dump({"version": 1,
           "profiles": [{"name": "Main"}],
           "spaces": [{"name": "Personal", "emoji": "P", "color": "007AFF", "profile": "Main",
                       "tabs": [{"url": f"{base}/links", "title": "Links", "selected": True}]},
                      {"name": "Work", "emoji": "W", "color": "FF9500", "profile": "Main",
                       "tabs": [{"url": f"http://localhost:{port}/target?seed", "title": "Target", "selected": True}]}],
           "link_routes": [{"match": "domain_is", "pattern": "localhost", "target": "space:Work"}],
           "active_space": "Work"}, open(fixture_path, "w"))

results = []
def check(name, ok, detail=""):
    results.append((name, ok)); print(("PASS " if ok else "FAIL ") + name + (f" -- {detail}" if detail else ""), flush=True)


def cleanup():
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    t324.remove_webkit_storage(support, data_dir)
    shutil.rmtree(support, ignore_errors=True)
    subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
    suite = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
    if os.path.exists(suite): os.remove(suite)
    for key in (f"NSWindow Frame BrowserWindow-{data_dir}", f"NSSplitView Subview Frames BrowserSplitView-{data_dir}"):
        subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)


support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
shutil.rmtree(support, ignore_errors=True)
env = dict(os.environ, DETOUR_MCP="1")
launched = subprocess.run([os.path.join(t324.REPO, "scripts", "launch-detour.sh"), app, data_dir,
                           os.path.join(out, "app.log")], env=env, capture_output=True, text=True)
pid = int(launched.stdout.strip().splitlines()[-1])
print("pid", pid, "data directory", data_dir, flush=True)
start_time = time.strftime("%Y-%m-%d %H:%M:%S")
try:
    ep = os.path.join(support, "mcp-endpoint.json")
    for _ in range(120):
        if os.path.exists(ep): break
        time.sleep(0.25)
    time.sleep(2)
    endpoint = json.load(open(ep))
    s = client.Session(endpoint["url"], endpoint["token"], "task356"); s.open()

    def call(tool, **a):
        r = s.call(tool, a); c = r.get("structuredContent")
        if r.get("isError"): raise RuntimeError(f"{tool}: {c}")
        return c

    def poll(fn, timeout=8):
        end = time.time() + timeout
        while time.time() < end:
            v = fn()
            if v: return v
            time.sleep(0.25)
        return fn()

    call("seed_world", fixture_path=fixture_path)
    spaces = {sp["name"]: sp["space_id"] for sp in call("list_spaces")["spaces"]}
    print("spaces", spaces, flush=True)

    def windows():
        return call("list_windows")["windows"]

    def window(wid):
        return next(w for w in windows() if w["window_id"] == wid)

    def space_tabs(name):
        return [t for t in call("list_tabs", space_id=spaces[name])["items"] if t.get("section") == "tab"]

    def tabs_with(name, query):
        return [t for t in space_tabs(name) if (t.get("url") or "").endswith("?" + query)]

    # Window 1 shows Work. Window 2, opened after it, shows Personal and the
    # links page; side by side, so either can be in front.
    work_window = windows()[0]["window_id"]
    call("run_menu_item", window_id=work_window, key="cmd+n")
    links_window = poll(lambda: next((w["window_id"] for w in windows()
                                      if w["window_id"] != work_window and w.get("kind") == "browser"), None))
    links = next(t for t in space_tabs("Personal") if (t.get("url") or "").endswith("/links"))
    call("select_tab", window_id=links_window, id=links["id"])
    poll(lambda: next((t for t in space_tabs("Personal") if t["id"] == links["id"] and t.get("live")
                       and t.get("title") == "Links" and not t.get("loading")), None))
    links = next(t for t in space_tabs("Personal") if t["id"] == links["id"])
    call("set_window_frame", window_id=work_window, x=980, y=60, width=900, height=700)
    call("set_window_frame", window_id=links_window, x=40, y=60, width=900, height=700)
    json.dump(windows(), open(os.path.join(out, "windows-start.json"), "w"), indent=1)
    check("window 1 shows Work", window(work_window).get("active_space_id") == spaces["Work"])
    check("window 2 shows Personal and the links page", window(links_window).get("active_space_id") == spaces["Personal"]
          and window(links_window).get("selected_tab_id") == links["tab_id"], window(links_window))

    def choose(case, title):
        # The links window in front and key, as a person's click on it makes it.
        call("set_window_frame", window_id=links_window, x=40, y=60, width=900, height=700, activate=True)
        time.sleep(0.5)
        call("click", context=links["tab_id"], selector=f"#{case}", button="right")
        items = [i.get("title") for i in call("list_menu")["items"]]
        print(case, "menu:", items, flush=True)
        if title not in items:
            check(f"{case}: the menu offers {title}", False, items)
            call("close_menu")
            return False
        call("choose_menu_item", title=title)
        return True

    # Routed: New Tab, New Window.
    personal_before = len(space_tabs("Personal"))
    for case, title in (("newtab", "Open Link in New Tab"), ("newwindow", "Open Link in New Window")):
        count_before = len(windows())
        if not choose(case, title): continue
        opened = poll(lambda: tabs_with("Work", case))
        time.sleep(1)
        check(f"{case}: opened in Work", len(opened) == 1, opened)
        work, here = window(work_window), window(links_window)
        check(f"{case}: selected in the window showing Work", bool(opened) and work.get("selected_tab_id") == opened[0]["tab_id"],
              work.get("selected_tab_id"))
        check(f"{case}: that window is in front (key)", work.get("is_key") is True and here.get("is_key") is False,
              (work.get("is_key"), here.get("is_key")))
        check(f"{case}: no new window", len(windows()) == count_before, len(windows()))
        check(f"{case}: no tab in Personal", len(space_tabs("Personal")) == personal_before)
        check(f"{case}: the links window keeps its space and page", here.get("selected_tab_id") == links["tab_id"]
              and here.get("active_space_id") == spaces["Personal"]
              and (here.get("selected_tab_url") or "").endswith("/links"), here)

    # Never routed: Split View, Quick Detour.
    if choose("split", "Open Link in Split View"):
        pane = poll(lambda: tabs_with("Personal", "split"))
        time.sleep(1)
        check("split: a pane in Personal", len(pane) == 1, pane)
        group = next((t.get("split_group_id") for t in space_tabs("Personal") if t["id"] == links["id"]), None)
        check("split: with the links page", bool(pane) and group is not None and pane[0].get("split_group_id") == group, group)
        check("split: nothing in Work", not tabs_with("Work", "split"))
        json.dump(space_tabs("Personal"), open(os.path.join(out, "personal-after-split.json"), "w"), indent=1)
    count_before = len(windows())
    if choose("quickdetour", "Open Link in Quick Detour"):
        qd = poll(lambda: [w for w in windows() if w.get("kind") == "quick_detour"])
        time.sleep(1)
        check("quickdetour: a Quick Detour window opened", len(qd) == 1, qd)
        check("quickdetour: nothing in Work", not tabs_with("Work", "quickdetour"))
        json.dump(windows(), open(os.path.join(out, "windows-after-quickdetour.json"), "w"), indent=1)
        for w in qd:
            call("run_menu_item", window_id=w["window_id"], key="cmd+w")
        poll(lambda: not [w for w in windows() if w.get("kind") == "quick_detour"])

    # No route: as before.
    personal_before = len(space_tabs("Personal"))
    if choose("plain-newtab", "Open Link in New Tab"):
        opened = poll(lambda: tabs_with("Personal", "plain-newtab"))
        time.sleep(1)
        check("plain-newtab: a tab in Personal", len(opened) == 1, opened)
        # Not selected anywhere (after the split, the window's selected tab is
        # that split's focused pane, not the links page).
        check("plain-newtab: in the background", bool(opened) and opened[0].get("selected_in_window_ids") == [], opened)
        check("plain-newtab: nothing in Work", not tabs_with("Work", "plain-newtab"))
    before_ids = {w["window_id"] for w in windows()}
    if choose("plain-newwindow", "Open Link in New Window"):
        new = poll(lambda: [w for w in windows() if w["window_id"] not in before_ids and w.get("kind") == "browser"])
        time.sleep(1)
        check("plain-newwindow: a new window", len(new) == 1, new)
        check("plain-newwindow: nothing in Work", not tabs_with("Work", "plain-newwindow"))
    json.dump(windows(), open(os.path.join(out, "windows-end.json"), "w"), indent=1)
    s.close()
finally:
    try:
        logs = subprocess.run(["/usr/bin/log", "show", "--info", "--start", start_time, "--predicate",
                               f'processIdentifier == {pid} AND subsystem == "com.detourbrowser.mac" AND category == "link-routing"'],
                              capture_output=True, text=True).stdout
        open(os.path.join(out, "link-routing.log"), "w").write(logs)
        routed = [l for l in logs.splitlines() if "Link routed" in l]
        print("\n".join(routed), flush=True)
        check("log: New Tab and New Window routed, nothing else",
              sum("linkMenuNewTab" in l for l in routed) == 1 and sum("linkMenuNewWindow" in l for l in routed) == 1
              and len(routed) == 2, len(routed))
    except Exception as e:
        print("log read failed:", e)
    os.kill(pid, signal.SIGTERM)
    for _ in range(40):
        try: os.kill(pid, 0); time.sleep(0.25)
        except ProcessLookupError: break
    cleanup()
    server.shutdown()
failed = [n for n, ok in results if not ok]
print("ALL PASS" if not failed else f"FAILED: {failed}")
sys.exit(1 if failed else 0)
