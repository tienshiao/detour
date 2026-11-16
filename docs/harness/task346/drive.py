"""TASK-346 runtime check: Cmd+Z / Shift+Cmd+Z and Edit > Undo/Redo in the Quick Detour launcher's field.

Drives a running Detour (DETOUR_MCP=1, an isolated DETOUR_DATA_DIR) through scripts/detour-mcp and posts
real keys to its pid with docs/harness/task327/axdrive.swift; reads the launcher's field and the Edit menu
with docs/harness/task346/axlauncher.swift (build both into $TOOLS; sandbox off, Accessibility for the
shell's host). Detour is brought to the front before the keys: the launcher is opened with its menu
item's shortcut (Opt+Cmd+N), not the global hotkey (not registered in a Debug build, and the user's own
Detour holds it). A tab closed with a real Cmd+W is on the browser's undo list throughout.

  DETOUR_DATA_DIR=<name> TOOLS=/path/to/built/helpers python3 -I drive.py
"""
import importlib.machinery, importlib.util, json, os, subprocess, sys, time
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
# The helpers (axlauncher, axdrive) are built into $TOOLS (default: this folder).
S = os.environ.get("TOOLS", os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("detour_mcp", os.path.join(REPO, "scripts", "detour-mcp"))
spec = importlib.util.spec_from_loader("detour_mcp", loader); mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
ep = json.load(open(os.path.expanduser(f"~/Library/Application Support/{os.environ['DETOUR_DATA_DIR']}/mcp-endpoint.json")))
PID = ep["pid"]
sess = mod.Session(ep["url"], ep["token"], "task346"); sess.open()
def call(tool, **a):
    r = sess.call(tool, a); c = r.get("structuredContent")
    if r.get("isError"): raise RuntimeError(f"{tool}: {c}")
    return c
results = []
def check(name, ok, detail=""):
    results.append(ok); print(("PASS " if ok else "FAIL ") + name + (" -- " + str(detail) if detail else ""), flush=True)
def ax(*a): return subprocess.run([os.path.join(S, "axlauncher"), *a, str(PID)], capture_output=True, text=True).stdout.strip()
def field(): return ax("field")
def key(code, mods=""):
    subprocess.run([os.path.join(S, "axdrive"), "key", str(PID), str(code), mods], check=True, stdout=subprocess.DEVNULL)
    time.sleep(0.6)
def activate():
    w = call("list_windows")["windows"][0]
    b = w["screen_bounds"]
    r = call("set_window_frame", window_id=w["window_id"], x=b["x"], y=b["y"], width=b["width"], height=b["height"], activate=True)
    time.sleep(0.5)
    return r
def ntabs():
    return len([i for i in call("list_tabs", window_id=1)["items"] if i.get("section") == "tab"])

# A closed tab on the browser's undo list: open two pages, close one with a real Cmd+W.
call("open_url", window_id=1, url="http://127.0.0.1:9/a")
time.sleep(1)
before = ntabs()
activate()
key(13, "cmd")  # Cmd+W
closed = ntabs()
check("a tab closed (on the undo list)", closed == before - 1, f"{before} -> {closed}")

# The launcher, from File > New Quick Detour Window's real shortcut.
activate()
key(45, "opt,cmd")  # Opt+Cmd+N
time.sleep(0.8)
check("the launcher is up with an empty field", field() == 'value=""', field())
print("Edit menu, nothing typed:", ax("editmenu").replace("\n", " | "), flush=True)
key(6, "cmd")  # Cmd+Z, nothing typed
check("Cmd+Z with nothing typed: field unchanged, no tab reopened", field() == 'value=""' and ntabs() == closed,
      f"{field()} tabs={ntabs()}")
key(12); key(2)  # q d
check("typed qd", field() == 'value="qd"', field())
menu = ax("editmenu")
print("Edit menu, typed:", menu.replace("\n", " | "), flush=True)
check("Edit > Undo is 'Undo Typing', enabled", "Undo Typing enabled=true" in menu, menu)
check("the launcher is still up after the menu", field().startswith("value="), field())
key(6, "cmd")  # Cmd+Z
check("Cmd+Z undid the typing", field() == 'value=""', field())
check("no tab reopened", ntabs() == closed, ntabs())
key(6, "shift,cmd")  # Shift+Cmd+Z
check("Shift+Cmd+Z redid it", field() == 'value="qd"', field())
check("still no tab reopened", ntabs() == closed, ntabs())
w = call("list_windows")
print("app_active:", w["app_active"], flush=True)
# Back to the browser window (the launcher closes when it stops being key).
activate()
key(6, "cmd")  # Cmd+Z in the browser window: the browser's undo
check("in the browser window Cmd+Z reopens the tab (TASK-345, unchanged)", ntabs() == before, ntabs())
print(f"{sum(results)}/{len(results)} passed")
