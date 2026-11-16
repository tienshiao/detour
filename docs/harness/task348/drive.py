"""TASK-348 runtime check: browser-window shortcuts typed in the Quick Detour launcher's field.

Drives a running Detour (DETOUR_MCP=1, an isolated DETOUR_DATA_DIR) through scripts/detour-mcp, posts real
keys to its pid with docs/harness/task327/axdrive.swift and reads the launcher's field with
docs/harness/task346/axlauncher.swift (build both into $TOOLS; sandbox off, Accessibility for the shell's
host). Detour is brought to the front before each key; the launcher is opened with its menu item's
shortcut (Opt+Cmd+N; the global hotkey is not registered in a Debug build).

For each shortcut: the launcher is shown over the browser window (which has tabs, one pinned candidate
and a closed tab on its undo list), the key is posted, and the browser window's state is compared before
and after (tab count, pinned count, selected tab), with whether the launcher is still up.

  DETOUR_DATA_DIR=<name> TOOLS=/path/to/built/helpers python3 -I drive.py [--fixed]

Without --fixed it only reports what each key did (the measurement before the fix); with --fixed it checks
that no key acts on the browser window and that Cmd+W closes the launcher.
"""
import importlib.machinery, importlib.util, json, os, subprocess, sys, time
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
S = os.environ.get("TOOLS", os.path.dirname(os.path.abspath(__file__)))
FIXED = "--fixed" in sys.argv
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("detour_mcp", os.path.join(REPO, "scripts", "detour-mcp"))
spec = importlib.util.spec_from_loader("detour_mcp", loader); mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
ep = json.load(open(os.path.expanduser(f"~/Library/Application Support/{os.environ['DETOUR_DATA_DIR']}/mcp-endpoint.json")))
PID = ep["pid"]
sess = mod.Session(ep["url"], ep["token"], "task348"); sess.open()
def call(tool, **a):
    r = sess.call(tool, a); c = r.get("structuredContent")
    if r.get("isError"): raise RuntimeError(f"{tool}: {c}")
    return c
results = []
def check(name, ok, detail=""):
    results.append(ok); print(("PASS " if ok else "FAIL ") + name + (" -- " + str(detail) if detail else ""), flush=True)
def field(): return subprocess.run([os.path.join(S, "axlauncher"), "field", str(PID)], capture_output=True, text=True).stdout.strip()
def launcher_up(): return field().startswith("value=")
def key(code, mods=""):
    subprocess.run([os.path.join(S, "axdrive"), "key", str(PID), str(code), mods], check=True, stdout=subprocess.DEVNULL)
    time.sleep(0.8)
def browser():
    return [w for w in call("list_windows")["windows"] if w["window_id"] == 1][0]
def activate():
    b = browser()["screen_bounds"]
    call("set_window_frame", window_id=1, x=b["x"], y=b["y"], width=b["width"], height=b["height"], activate=True)
    time.sleep(0.5)
def state():
    items = call("list_tabs", window_id=1)["items"]
    w = browser()
    return {"tabs": len([i for i in items if i.get("section") == "tab"]),
            "pinned": len([i for i in items if i.get("section") == "pinned"]),
            "selected": w["selected_tab_url"], "browser_key": w["is_key"]}

def show_launcher():
    for _ in range(3):
        if launcher_up(): return True
        activate()
        key(45, "opt,cmd")  # Opt+Cmd+N
        time.sleep(0.5)
    return launcher_up()

# Three pages, one closed with a real Cmd+W: a close on the browser's undo list for Shift+Cmd+T.
for page in ("a", "b", "c"):
    call("open_url", window_id=1, url=f"http://127.0.0.1:9/{page}")
time.sleep(1)
activate()
before = state()["tabs"]
key(13, "cmd")  # Cmd+W in the browser window
check("a tab closed in the browser window (setup)", state()["tabs"] == before - 1, f"{before} -> {state()['tabs']}")

KEYS = [  # (name, keycode, modifiers)
    ("Cmd+W Close Tab", 13, "cmd"),
    ("Shift+Cmd+T Reopen Closed Tab", 17, "shift,cmd"),
    ("Cmd+D Pin Tab", 2, "cmd"),
    ("Cmd+T New Tab", 17, "cmd"),
    ("Cmd+L Open Location", 37, "cmd"),
    ("Cmd+Y Show All History", 16, "cmd"),
    ("Cmd+R Reload Page", 15, "cmd"),
    ("Opt+Cmd+Down Next Tab", 125, "opt,cmd"),
]
reached = []
for name, code, mods in KEYS:
    if not show_launcher():
        check(f"[{name}] the launcher is up", False, field()); continue
    s0 = state()
    key(code, mods)
    up = launcher_up()
    s1 = state()
    acted = {k: (s0[k], s1[k]) for k in ("tabs", "pinned", "selected") if s0[k] != s1[k]}
    print(f"[{name}] launcher still up: {up}; browser window changed: {acted or 'nothing'}; "
          f"browser key after: {s1['browser_key']}", flush=True)
    if acted: reached.append(name)
    if FIXED:
        check(f"[{name}] nothing changed in the browser window", not acted, acted)
        if name.startswith("Cmd+W"):
            check(f"[{name}] closed the launcher", not up, field())
        else:
            check(f"[{name}] the launcher is still up", up, field())
    # Escape twice: clear and close the launcher if it is still up; else Escape in the browser window
    # closes a palette the key may have opened there.
    if launcher_up():
        key(53); key(53)
    else:
        activate(); key(53)

print("acted on the browser window behind the launcher:", reached or "none", flush=True)
if FIXED:
    activate()
    t = state()["tabs"]
    key(13, "cmd")  # Cmd+W in the browser window itself: still closes its tab
    check("in the browser window Cmd+W still closes a tab", state()["tabs"] == t - 1, f"{t} -> {state()['tabs']}")
    print(f"{sum(results)}/{len(results)} passed")
