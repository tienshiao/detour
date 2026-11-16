"""TASK-366 runtime check: Cmd+Z / Shift+Cmd+Z and Edit > Undo/Redo in an extension's popup shown from a
Quick Detour window, with a closed tab on the browser's undo list.

Drives a running Detour (DETOUR_MCP=1, an isolated DETOUR_DATA_DIR: a test run, so extension installs are
reachable) through scripts/detour-mcp, posts real keys to its pid with docs/harness/task327/axdrive.swift
and reads and presses through Accessibility with docs/harness/task349/axundo.swift (build both into $TOOLS;
sandbox off, Accessibility for the shell's host). API Explorer is installed and pinned (its profileExtension
row's isPinned set in the isolated browser.db, so the Quick Detour's title bar shows its button); the Quick
Detour is opened from the launcher with real keys (Opt+Cmd+N, "127.0.0.1:9", Return), and the popup with an
Accessibility press on that button, as a click would.

  DETOUR_DATA_DIR=<name> TOOLS=/path/to/built/helpers python3 -I drive.py
"""
import importlib.machinery, importlib.util, json, os, sqlite3, subprocess, sys, time
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
S = os.environ.get("TOOLS", os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.expanduser(f"~/Library/Application Support/{os.environ['DETOUR_DATA_DIR']}")
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("detour_mcp", os.path.join(REPO, "scripts", "detour-mcp"))
spec = importlib.util.spec_from_loader("detour_mcp", loader); mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
ep = json.load(open(os.path.join(DATA, "mcp-endpoint.json")))
PID = ep["pid"]
sess = mod.Session(ep["url"], ep["token"], "task366"); sess.open()
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
def windows(): return call("list_windows")["windows"]
def activate(window_id=1):
    b = [w for w in windows() if w["window_id"] == window_id][0]["screen_bounds"]
    call("set_window_frame", window_id=window_id, x=b["x"], y=b["y"], width=b["width"], height=b["height"], activate=True)
    time.sleep(0.5)
def ntabs():
    return len([i for i in call("list_tabs", window_id=1)["items"] if i.get("section") == "tab"])

# API Explorer installed and pinned.
if "API Explorer" not in [e.get("name") for e in call("list_extensions")["extensions"]]:
    call("install_extension", path=os.path.join(REPO, "TestExtensions", "api-explorer"))
    time.sleep(2)
ext_id = [e for e in call("list_extensions")["extensions"] if e.get("name") == "API Explorer"][0]["id"]
db = sqlite3.connect(os.path.join(DATA, "browser.db"))
db.execute("UPDATE profileExtension SET isPinned = 1 WHERE extensionID = ?", (ext_id,)); db.commit(); db.close()

# A close on the browser's undo list.
call("open_url", window_id=1, url="http://127.0.0.1:9/a")
call("open_url", window_id=1, url="http://127.0.0.1:9/b")
time.sleep(1)
activate()
before = ntabs()
key(13, "cmd")  # Cmd+W
closed = ntabs()
check("a tab closed (on the undo list)", closed == before - 1, f"{before} -> {closed}")

# A Quick Detour from the launcher: Opt+Cmd+N, "127.0.0.1:9", Return.
key(45, "opt,cmd")
for code, mods in [(18, ""), (19, ""), (26, ""), (47, ""), (29, ""), (47, ""), (29, ""), (47, ""), (18, ""),
                   (41, "shift"), (25, "")]:
    key(code, mods)
key(36)  # Return
time.sleep(1.5)
quick = [w for w in windows() if w["kind"] == "quick_detour"]
check("a Quick Detour window is open and key", bool(quick) and quick[0]["is_key"], quick)

# Its title bar's API Explorer button.
title = ax("focusedwindow")
print("focused window:", title, flush=True)
qd_title = title.split('"')[1] if '"' in title else ""
print(ax("press", qd_title, "API Explorer"), flush=True)
time.sleep(1.5)
print("windows:", ax("windows").replace("\n", " | "), flush=True)
print("popup fields:", ax("fields", "").replace("\n", " | ")[:300], flush=True)
print(ax("focus", "", os.environ.get("FIELD", "0")), flush=True)
time.sleep(0.5)

start = focused()
print("focused before typing:", start, flush=True)
print("Edit menu, nothing typed:", ax("editmenu").replace("\n", " | "), flush=True)
key(6, "cmd")  # Cmd+Z, nothing typed
check("Cmd+Z with nothing typed: no tab reopened", ntabs() == closed, f"{focused()} tabs={ntabs()}")
key(12); key(2)  # q d
after_typing = focused()
check("typed qd in the popup", "qd" in after_typing, after_typing)
menu = ax("editmenu")
print("Edit menu, typed:", menu.replace("\n", " | "), flush=True)
check("Edit > Undo is 'Undo Typing', enabled", "Undo Typing enabled=true" in menu, menu)
key(6, "cmd")  # Cmd+Z
check("Cmd+Z undid the typing", "qd" not in focused(), focused())
check("no tab reopened", ntabs() == closed, ntabs())
key(6, "shift,cmd")  # Shift+Cmd+Z
check("Shift+Cmd+Z redid it", "qd" in focused(), focused())
check("still no tab reopened", ntabs() == closed, ntabs())
key(53)  # Escape: close the popup
activate()
key(6, "cmd")  # Cmd+Z in the browser window: the browser's undo
check("in the browser window Cmd+Z reopens the tab (TASK-345, unchanged)", ntabs() == closed + 1, ntabs())
print(f"{sum(results)}/{len(results)} passed")
