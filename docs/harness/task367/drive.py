"""TASK-367 runtime check: Cmd+Z / Shift+Cmd+Z and Edit > Undo/Redo in a page's prompt() dialog (an alert
sheet with a text field) in a browser window and in a Quick Detour window, with a closed tab on the
browser's undo list.

Drives a running Detour (DETOUR_MCP=1, an isolated DETOUR_DATA_DIR) through scripts/detour-mcp, posts real
keys to its pid with docs/harness/task327/axdrive.swift and reads the sheet's field and the Edit menu with
docs/harness/task349/axundo.swift (build both into $TOOLS; sandbox off, Accessibility for the shell's
host). Serves prompt.html (which calls prompt() after it loads) on 127.0.0.1:8765 itself. The browser
window opens it with the endpoint; the Quick Detour is opened from the launcher with real keys
(Opt+Cmd+N, "127.0.0.1:8765", Return).

  DETOUR_DATA_DIR=<name> TOOLS=/path/to/built/helpers python3 -I drive.py [browser] [quick]
"""
import http.server, importlib.machinery, importlib.util, json, os, subprocess, sys, threading, time
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
S = os.environ.get("TOOLS", HERE)
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("detour_mcp", os.path.join(REPO, "scripts", "detour-mcp"))
spec = importlib.util.spec_from_loader("detour_mcp", loader); mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
ep = json.load(open(os.path.expanduser(f"~/Library/Application Support/{os.environ['DETOUR_DATA_DIR']}/mcp-endpoint.json")))
PID = ep["pid"]
sess = mod.Session(ep["url"], ep["token"], "task367"); sess.open()
PAGE = open(os.path.join(HERE, "prompt.html"), "rb").read()
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(PAGE)
    def log_message(self, *a): pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
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

def focus_sheet_field():
    """The sheet's text field: focused already, or focused through Accessibility."""
    f = focused()
    if f.startswith("role=AXTextField"): return f
    title = ax("focusedwindow")
    name = title.split('"')[1] if '"' in title else ""
    print("fields:", ax("fields", name).replace("\n", " | "), flush=True)
    print(ax("focus", name, os.environ.get("FIELD", "0")), flush=True)
    time.sleep(0.4)
    return focused()

def undo_round(where, closed):
    print(f"[{where}] focused when the sheet opened: {focused()}", flush=True)
    start = focus_sheet_field()
    check(f"[{where}] the sheet's field has the keys", start.startswith("role=AXTextField"), start)
    print(f"[{where}] Edit menu, nothing typed: " + ax("editmenu").replace("\n", " | "), flush=True)
    key(6, "cmd")  # Cmd+Z, nothing typed
    check(f"[{where}] Cmd+Z with nothing typed: no tab reopened", ntabs() == closed, f"{focused()} tabs={ntabs()}")
    key(12); key(2)  # q d
    typed = focused()
    check(f"[{where}] typed qd", "qd" in typed, typed)
    menu = ax("editmenu")
    print(f"[{where}] Edit menu, typed: " + menu.replace("\n", " | "), flush=True)
    check(f"[{where}] Edit > Undo is 'Undo Typing', enabled", "Undo Typing enabled=true" in menu, menu)
    key(6, "cmd")  # Cmd+Z
    check(f"[{where}] Cmd+Z undid the typing", "qd" not in focused(), focused())
    check(f"[{where}] no tab reopened", ntabs() == closed, ntabs())
    key(6, "shift,cmd")  # Shift+Cmd+Z
    check(f"[{where}] Shift+Cmd+Z redid it", "qd" in focused(), focused())
    check(f"[{where}] still no tab reopened", ntabs() == closed, ntabs())
    key(53)  # Escape: Cancel
    time.sleep(0.5)

def browser():
    activate()
    call("open_url", window_id=1, url="http://127.0.0.1:8765/browser")
    time.sleep(2)
    undo_round("browser window prompt", ntabs())

def quick():
    activate()
    key(45, "opt,cmd")  # Opt+Cmd+N
    for code, mods in [(18, ""), (19, ""), (26, ""), (47, ""), (29, ""), (47, ""), (29, ""), (47, ""), (18, ""),
                       (41, "shift"), (28, ""), (26, ""), (22, ""), (23, "")]:
        key(code, mods)  # 127.0.0.1:8765
    key(36)  # Return
    time.sleep(2.5)
    # The sheet has the keys; the Quick Detour is main.
    q = [w for w in windows() if w["kind"] == "quick_detour" and w["is_main"]]
    check("[quick detour prompt] a Quick Detour window is main", bool(q), [(w["kind"], w["is_main"]) for w in windows()])
    undo_round("quick detour prompt", ntabs())

if __name__ == "__main__":
    steps = sys.argv[1:] or ["browser", "quick"]
    call("open_url", window_id=1, url="http://127.0.0.1:9/a")
    call("open_url", window_id=1, url="http://127.0.0.1:9/b")
    time.sleep(1)
    activate()
    before = ntabs()
    key(13, "cmd")  # Cmd+W: a close on the browser's undo list
    closed = ntabs()
    check("a tab closed (on the undo list)", closed == before - 1, f"{before} -> {closed}")
    for step in steps:
        globals()[step]()
    print(f"{sum(results)}/{len(results)} passed")
    server.shutdown()
