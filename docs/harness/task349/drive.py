"""TASK-349 runtime check: Cmd+Z / Shift+Cmd+Z and Edit > Undo/Redo in Settings' text fields (a pane's
field and the site search sheet) and in an extension's action popup, with a closed tab on the browser's
undo list.

Drives a running Detour (DETOUR_MCP=1, an isolated DETOUR_DATA_DIR: a test run, so Settings and extension
installs are reachable) through scripts/detour-mcp, posts real keys to its pid with
docs/harness/task327/axdrive.swift and reads fields and the Edit menu with docs/harness/task349/axundo.swift
(build both into $TOOLS; sandbox off, Accessibility for the shell's host). Detour is brought to the front
before the keys.

  DETOUR_DATA_DIR=<name> TOOLS=/path/to/built/helpers python3 -I drive.py [settings|sheet|popup ...]
"""
import importlib.machinery, importlib.util, json, os, subprocess, sys, time
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
S = os.environ.get("TOOLS", os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("detour_mcp", os.path.join(REPO, "scripts", "detour-mcp"))
spec = importlib.util.spec_from_loader("detour_mcp", loader); mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
ep = json.load(open(os.path.expanduser(f"~/Library/Application Support/{os.environ['DETOUR_DATA_DIR']}/mcp-endpoint.json")))
PID = ep["pid"]
sess = mod.Session(ep["url"], ep["token"], "task349"); sess.open()
def call(tool, **a):
    r = sess.call(tool, a); c = r.get("structuredContent")
    if r.get("isError"): raise RuntimeError(f"{tool}: {c}")
    return c
results = []
def check(name, ok, detail=""):
    results.append(ok); print(("PASS " if ok else "FAIL ") + name + (" -- " + str(detail) if detail else ""), flush=True)
def ax(*a): return subprocess.run([os.path.join(S, "axundo"), a[0], str(PID), *a[1:]], capture_output=True, text=True).stdout.strip()
def focused(): return ax("focused")
def key(code, mods=""):
    subprocess.run([os.path.join(S, "axdrive"), "key", str(PID), str(code), mods], check=True, stdout=subprocess.DEVNULL)
    time.sleep(0.6)
def activate(window_id=1, window_number=None):
    if window_number is not None:
        return call("set_window_frame", window_number=window_number, activate=True,
                    **{k: v for k, v in frame_of(window_number).items()})
    w = [w for w in call("list_windows")["windows"] if w["window_id"] == window_id][0]
    b = w["screen_bounds"]
    r = call("set_window_frame", window_id=window_id, x=b["x"], y=b["y"], width=b["width"], height=b["height"], activate=True)
    time.sleep(0.5)
    return r
FRAMES = {}
def frame_of(n): return FRAMES[n]
def ntabs():
    return len([i for i in call("list_tabs", window_id=1)["items"] if i.get("section") == "tab"])
def app_active(): return call("list_windows")["app_active"]

def close_a_tab():
    """Two pages, one closed with a real Cmd+W: a close on the browser's undo list."""
    call("open_url", window_id=1, url="http://127.0.0.1:9/a")
    call("open_url", window_id=1, url="http://127.0.0.1:9/b")
    time.sleep(1)
    before = ntabs()
    activate()
    key(13, "cmd")  # Cmd+W
    after = ntabs()
    check("a tab closed (on the undo list)", after == before - 1, f"{before} -> {after}")
    return after

def undo_round(where, closed, typed="qd"):
    """In the focused field: Edit menu, Cmd+Z, Shift+Cmd+Z; the closed tab must stay closed."""
    start = focused()
    print(f"[{where}] focused before typing: {start}", flush=True)
    print(f"[{where}] Edit menu, nothing typed: " + ax("editmenu").replace("\n", " | "), flush=True)
    key(6, "cmd")  # Cmd+Z, nothing typed
    check(f"[{where}] Cmd+Z with nothing typed: no tab reopened", ntabs() == closed, f"{focused()} tabs={ntabs()}")
    for code in {"qd": [12, 2]}[typed]:
        key(code)
    after_typing = focused()
    check(f"[{where}] typed {typed}", typed in after_typing, after_typing)
    menu = ax("editmenu")
    print(f"[{where}] Edit menu, typed: " + menu.replace("\n", " | "), flush=True)
    check(f"[{where}] Edit > Undo is 'Undo Typing', enabled", "Undo Typing enabled=true" in menu, menu)
    key(6, "cmd")  # Cmd+Z
    after_undo = focused()
    check(f"[{where}] Cmd+Z undid the typing", typed not in after_undo, after_undo)
    check(f"[{where}] no tab reopened", ntabs() == closed, ntabs())
    key(6, "shift,cmd")  # Shift+Cmd+Z
    after_redo = focused()
    check(f"[{where}] Shift+Cmd+Z redid it", typed in after_redo, after_redo)
    check(f"[{where}] still no tab reopened", ntabs() == closed, ntabs())
    print(f"[{where}] app_active: {app_active()}", flush=True)

def open_settings(pane, **extra):
    r = call("open_ui", what="settings", pane=pane, **extra)
    n = r["window_number"]; f = r["frame"]
    FRAMES[n] = {"x": f["x"], "y": f["y"], "width": f["width"], "height": f["height"]}
    time.sleep(0.6)
    return n

def settings(closed):
    n = open_settings("profiles", row=1)  # Default: its name field
    activate(window_number=n)
    print("fields:", ax("fields", "Settings").replace("\n", " | "), flush=True)
    print(ax("focus", "Settings", os.environ.get("FIELD", "0")), flush=True)
    time.sleep(0.4)
    # Focusing a field selects its text: move to the end so typing appends.
    key(124, "cmd")  # Cmd+Right
    undo_round("settings profiles", closed)

def spaces(closed):
    """Settings > Spaces, the first space: its name field."""
    n = open_settings("spaces", row=0)
    activate(window_number=n)
    print("fields:", ax("fields", "Settings").replace("\n", " | "), flush=True)
    print(ax("focus", "Settings", "0"), flush=True)
    time.sleep(0.4)
    key(124, "cmd")  # Cmd+Right
    undo_round("settings spaces", closed)

def sheet(closed):
    """Settings > Search > Add Site Search: the sheet's Name field."""
    n = open_settings("search")
    activate(window_number=n)
    print(ax("press", "Settings", "Add Site Search"), flush=True)
    time.sleep(0.8)
    windows = [(w["kind"], w["is_key"], w["is_main"]) for w in call("list_windows")["windows"]]
    check("[site search sheet] the sheet has the keys, Settings is main", ("settings", False, True) in windows, windows)
    undo_round("site search sheet", closed)
    key(53)  # Escape: Cancel
    time.sleep(0.6)

def addprofile(closed):
    """Settings > Profiles > Add: the Add Profile sheet's name field."""
    n = open_settings("profiles", row=1)
    activate(window_number=n)
    print(ax("press", "Settings", "Add"), flush=True)
    time.sleep(0.8)
    windows = [(w["kind"], w["is_key"], w["is_main"]) for w in call("list_windows")["windows"]]
    check("[add profile sheet] the sheet has the keys, Settings is main", ("settings", False, True) in windows, windows)
    undo_round("add profile sheet", closed)
    key(53)  # Escape: Cancel
    time.sleep(0.6)

def routes(closed):
    """Settings > Links > New Route: the new route's pattern field."""
    n = open_settings("links")
    activate(window_number=n)
    print(ax("press", "Settings", "newRoute"), flush=True)
    time.sleep(0.8)
    print("fields:", ax("fields", "Settings").replace("\n", " | "), flush=True)
    undo_round("link route pattern", closed)

def popup(closed):
    if "API Explorer" not in [e.get("name") for e in call("list_extensions")["extensions"]]:
        call("install_extension", path=os.path.join(REPO, "TestExtensions", "api-explorer"))
        time.sleep(2)
    activate()
    call("open_extension_context", extension="API Explorer", kind="popup", window_id=1)
    time.sleep(1.5)
    print("windows:", ax("windows").replace("\n", " | "), flush=True)
    call("click", context="popup:API Explorer", selector="#input-create-url")
    time.sleep(0.5)
    undo_round("extension popup", closed)
    call("close_extension_context", context="popup:API Explorer")
    time.sleep(0.8)

if __name__ == "__main__":
    steps = sys.argv[1:] or ["settings", "spaces", "sheet", "addprofile", "routes", "popup"]
    closed = close_a_tab()
    for step in steps:
        globals()[step](closed)
    activate()
    key(6, "cmd")  # Cmd+Z in the browser window: the browser's undo
    check("in the browser window Cmd+Z reopens the tab (TASK-345, unchanged)", ntabs() == closed + 1, ntabs())
    print(f"{sum(results)}/{len(results)} passed")
