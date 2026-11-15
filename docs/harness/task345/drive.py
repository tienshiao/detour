"""TASK-345 runtime checks: Cmd+Z / Shift+Cmd+Z routing between a page and Detour's undo.

Drives a running Detour (DETOUR_MCP=1, an isolated DETOUR_DATA_DIR) through
scripts/detour-mcp, and posts real key events to its pid with
docs/harness/task327/axdrive.swift (build it to $AXDRIVE; posting needs the
sandbox off and Accessibility for the shell's host). Detour is brought to the
front before each key (set_window_frame activate=true): the key a page leaves
reaches Edit > Undo only in an active app. Serve this folder on
127.0.0.1:8745 (undo.html, and filler pages a.html, b.html, c.html with any
content), with the server's request log written to $HTTP_LOG (the quick mode
reads a Quick Detour page's input from the fixture's beacon there). Modes, in
order: setup, matrix, outside (palette), find (find bar), order (a page that
swallows focusout: the Cmd+Z report's order), quick (a Quick Detour window),
extra (tab switch, removed input; leaves #inp removed until a reload).

  DETOUR_DATA_DIR=<name> AXDRIVE=/path/to/axdrive HTTP_LOG=/path/http.log python3 -I drive.py setup
"""
import importlib.machinery, importlib.util, json, os, subprocess, sys, time
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
AXDRIVE = os.environ["AXDRIVE"]
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("detour_mcp", os.path.join(REPO, "scripts", "detour-mcp"))
spec = importlib.util.spec_from_loader("detour_mcp", loader); mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
ep = json.load(open(os.path.expanduser(f"~/Library/Application Support/{os.environ['DETOUR_DATA_DIR']}/mcp-endpoint.json")))
PID = ep["pid"]
sess = mod.Session(ep["url"], ep["token"], "task345"); sess.open()
BASE = "http://127.0.0.1:8745"
def call(tool, **a):
    r = sess.call(tool, a); c = r.get("structuredContent")
    if r.get("isError"): raise RuntimeError(f"{tool}: {c}")
    return c
results = []
def check(name, ok, detail=""):
    results.append((name, ok, detail)); print(("PASS " if ok else "FAIL ") + name + (" -- " + str(detail) if detail else ""), flush=True)
def tabs():
    return [t for t in call("list_tabs", window_id=1)["items"] if t.get("kind", "") in ("tab", "normal", "normal_tab") or t.get("section") == "normal"]
def tab_titles():
    items = call("list_tabs", window_id=1)["items"]
    return [i.get("title") for i in items]
def js(ctx, expr):
    if ";" in expr:
        return call("evaluate_js", context=ctx, script=expr.replace("; 0", "; return 0")).get("value")
    return call("evaluate_js", context=ctx, expression=expr).get("value")
ACTIVE_LOG = []
def key(mods, code="6"):
    activate(quiet=True)
    subprocess.run([AXDRIVE, "key", str(PID), code, mods], check=True, stdout=subprocess.DEVNULL)
    time.sleep(0.8)
    w = call("list_windows")
    ACTIVE_LOG.append(w["app_active"] and w["windows"][0]["is_key"])
    if not ACTIVE_LOG[-1]: print(f"WARNING: Detour not active/key after {mods} (code {code}): app_active={w['app_active']} is_key={w['windows'][0]['is_key']} windows={len(w['windows'])}", flush=True)

mode = sys.argv[1] if len(sys.argv) > 1 else "setup"

def ntabs():
    return len([i for i in call("list_tabs", window_id=1)["items"] if i.get("section") == "tab"])
def fixture_ctx():
    for i in call("list_tabs", window_id=1)["items"]:
        if i.get("title") == "Undo fixture": return i["context"]
def activate(quiet=False):
    w = call("list_windows")["windows"][0]
    b = w["screen_bounds"]
    r = call("set_window_frame", window_id=1, x=b["x"], y=b["y"], width=b["width"], height=b["height"], activate=True)
    time.sleep(0.5)
    if not quiet or not r.get("is_key"): print("activate:", {k: r.get(k) for k in ("is_key", "app_active")}, flush=True)
def state(ctx):
    return js(ctx, "JSON.stringify({log: keyLog, cu: canvasUndo, cr: canvasRedo, inp: (document.getElementById('inp')||{value:'(gone)'}).value, ce: document.getElementById('ce').textContent, active: (document.activeElement||{}).id || (document.activeElement||{}).tagName})")

if mode == "setup":
    call("open_url", window_id=1, url=BASE + "/undo.html")
    time.sleep(1.5)
    for n in ("a", "b"):
        call("open_url", window_id=1, url=f"{BASE}/{n}.html"); time.sleep(1.2)
        key("cmd", code="13")
    print([i.get("title") for i in call("list_tabs", window_id=1)["items"]])

if mode == "matrix":
    ctx = fixture_ctx()
    call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.5)
    activate()
    n0 = ntabs()
    print("tabs at start", n0, flush=True)
    # B1: body focus, ⌘Z: page sees it, then Detour's undo once (one of two closed tabs back)
    call("click", context=ctx, selector="#blank"); time.sleep(0.4)
    js(ctx, "keyLog.length = 0; document.activeElement.blur && document.activeElement.blur(); 0")
    key("cmd"); time.sleep(0.6)
    st = json.loads(state(ctx)); n1 = ntabs()
    check("B1 body ⌘Z: page saw the key", any(l.startswith("cmd+z") for l in st["log"]), st["log"])
    check("B1 body ⌘Z: exactly one closed tab back", n1 == n0 + 1, f"{n0}->{n1}")
    call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.5)
    # A: canvas handles ⌘Z / ⇧⌘Z itself; undo and redo both pending in Detour
    call("click", context=ctx, selector="#canvas"); time.sleep(0.4)
    js(ctx, "keyLog.length = 0; 0")
    key("cmd"); key("cmd,shift"); time.sleep(0.4)
    st = json.loads(state(ctx)); n2 = ntabs()
    check("A canvas: ⌘Z counted once by the page", st["cu"] == 1, st)
    check("A canvas: ⇧⌘Z counted once by the page", st["cr"] == 1, st)
    check("A canvas: Detour's undo/redo did not run", n2 == n1, f"{n1}->{n2}")
    # B2: body ⇧⌘Z redoes Detour's (re-closes the reopened tab), once
    call("click", context=ctx, selector="#blank"); time.sleep(0.3)
    js(ctx, "keyLog.length = 0; 0")
    key("cmd,shift"); time.sleep(0.4)
    st = json.loads(state(ctx)); n3 = ntabs()
    check("B2 body ⇧⌘Z: page saw the key", any(l.startswith("shift+cmd+z") for l in st["log"]), st["log"])
    check("B2 body ⇧⌘Z: Detour's redo ran once", n3 == n2 - 1, f"{n2}->{n3}")
    call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.4)
    # C: input
    for sel, prop in (("#inp", "inp"), ("#ce", "ce")):
        nb = ntabs()
        call("type_text", context=ctx, selector=sel, text="abc"); time.sleep(0.5)
        st = json.loads(state(ctx)); check(f"{sel} typed", st[prop] == "abc", st)
        key("cmd"); st = json.loads(state(ctx))
        check(f"{sel} ⌘Z undid the typing", st[prop] == "", st)
        check(f"{sel} ⌘Z: no tab reopened", ntabs() == nb)
        key("cmd,shift"); st = json.loads(state(ctx))
        check(f"{sel} ⇧⌘Z redid the typing", st[prop] == "abc", st)
        check(f"{sel} ⇧⌘Z: no tab change", ntabs() == nb)
        r = call("run_menu_item", window_id=1, key="cmd+z"); time.sleep(0.5); st = json.loads(state(ctx))
        check(f"{sel} Edit>Undo (menu) undid the typing", st[prop] == "", (r, st))
        check(f"{sel} Edit>Undo: no tab reopened", ntabs() == nb)
        r = call("run_menu_item", window_id=1, key="cmd+shift+z"); time.sleep(0.5); st = json.loads(state(ctx))
        check(f"{sel} Edit>Redo (menu) redid the typing", st[prop] == "abc", (r, st))
        key("cmd"); key("cmd"); st = json.loads(state(ctx))
        check(f"{sel} ⌘Z with the page's stack empty: Detour's list untouched", ntabs() == nb and st[prop] == "", (nb, ntabs(), st))
    print("active after every key:", all(ACTIVE_LOG), len(ACTIVE_LOG))
    print("SUMMARY", sum(1 for r in results if r[1]), "passed,", sum(1 for r in results if not r[1]), "failed")

if mode == "outside":
    ctx = fixture_ctx()
    call("open_url", window_id=1, url=BASE + "/a.html"); time.sleep(1.2)
    key("cmd", code="13")
    call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.5)
    js(ctx, "document.getElementById('inp').value = ''; document.getElementById('ce').textContent = ''; keyLog.length = 0; 0")
    call("type_text", context=ctx, selector="#inp", text="xyz"); time.sleep(0.4)
    n0 = ntabs()
    # palette (Open Location) focused
    call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.4)
    call("run_menu_item", window_id=1, key="cmd+l"); time.sleep(0.6)
    key("cmd"); n3 = ntabs(); st = json.loads(state(ctx))
    check("F palette focus ⌘Z: Detour's undo ran once", n3 == n0 + 1, f"{n0}->{n3}")
    # Case-blind: macOS's automatic capitalization can turn "xyz" into "Xyz" when the field loses focus.
    check("F palette focus ⌘Z: the page's field untouched", st["inp"].lower() == "xyz" and not st["log"], st)
    subprocess.run([AXDRIVE, "key", str(PID), "53", ""], stdout=subprocess.DEVNULL)  # escape
    print("SUMMARY", sum(1 for r in results if r[1]), "passed,", sum(1 for r in results if not r[1]), "failed; active after every key:", all(ACTIVE_LOG))

if mode == "order":
    # The page swallows focusout: after clicking out of the typed input the
    # focus flag is stale (true). Only the Cmd+Z keydown report, arriving
    # before WebKit's "not handled", makes the key Detour's undo.
    call("open_url", window_id=1, url=BASE + "/undo.html?swallow=1"); time.sleep(1.5)
    sw = [i for i in call("list_tabs", window_id=1)["items"] if "swallow" in (i.get("url") or "")][0]["context"]
    for attempt in range(3):
        call("select_tab", window_id=1, id=sw.split(":")[1]); time.sleep(0.4)
        js(sw, "document.getElementById('inp').value = ''; keyLog.length = 0; 0")
        call("type_text", context=sw, selector="#inp", text="ord"); time.sleep(0.4)
        call("click", context=sw, selector="#blank"); time.sleep(0.4)
        st = json.loads(state(sw)); n0 = ntabs()
        key("cmd"); st2 = json.loads(state(sw)); n1 = ntabs()
        check(f"O{attempt} stale flag (focusout swallowed), body focused: ⌘Z is Detour's undo", n1 == n0 + 1 and st2["inp"] == "ord", (st["active"], f"{n0}->{n1}", st2))
        if n1 == n0 + 1:
            key("cmd", code="13")  # close the reopened tab again (selected after the undo)
        time.sleep(0.5)
    print("SUMMARY", sum(1 for r in results if r[1]), "passed,", sum(1 for r in results if not r[1]), "failed; active after every key:", all(ACTIVE_LOG))

if mode == "quick":
    # A Quick Detour window: type in its page's input, then ⌘Z with it key and
    # a closed tab on the browser's list. The page's value comes from the
    # server's request log (HTTP_LOG), which the fixture's beacon writes.
    import re
    log_path = os.environ["HTTP_LOG"]
    def last_value():
        values = re.findall(r"GET /log\?inp=([^&]*)&", open(log_path).read())
        return values[-1] if values else None
    n0 = ntabs()
    before = {w["window_id"] for w in call("list_windows")["windows"]}
    ctx = fixture_ctx()
    call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.4)
    js(ctx, "location.reload(); 0"); time.sleep(1.5)
    call("click", context=ctx, selector="#qdlink", button="right"); time.sleep(0.5)
    call("choose_menu_item", title="Open Link in Quick Detour"); time.sleep(2)
    qd = [w for w in call("list_windows")["windows"] if w["window_id"] not in before][0]
    print("quick detour window:", qd["window_id"], qd["kind"], flush=True)
    b = call("list_windows")["windows"]
    qd = [w for w in b if w["window_id"] == qd["window_id"]][0]
    print("quick detour page:", qd.get("selected_tab_url"), flush=True)
    sb = qd["screen_bounds"]
    call("set_window_frame", window_id=qd["window_id"], x=sb["x"], y=sb["y"], width=sb["width"], height=sb["height"], activate=True)
    time.sleep(0.4)
    call("type_text", window_id=qd["window_id"], text="qd"); time.sleep(0.8)
    typed = last_value()
    def qd_key(mods):
        call("set_window_frame", window_id=qd["window_id"], x=sb["x"], y=sb["y"], width=sb["width"], height=sb["height"], activate=True)
        subprocess.run([AXDRIVE, "key", str(PID), "6", mods], check=True, stdout=subprocess.DEVNULL)
        time.sleep(0.8)
        w = [x for x in call("list_windows")["windows"] if x["window_id"] == qd["window_id"]][0]
        return w["is_key"]
    key_after = qd_key("cmd"); after = last_value(); n1 = ntabs()
    print(f"QD: typed={typed!r} after Cmd+Z={after!r} qd key={key_after} browser tabs {n0}->{n1}", flush=True)
    check("Q Quick Detour ⌘Z: the browser window's undo did not run", n1 == n0, f"{n0}->{n1}")
    try:
        r = call("run_menu_item", window_id=qd["window_id"], key="cmd+z"); print("QD Edit>Undo:", r, flush=True)
    except Exception as e:
        print("QD Edit>Undo refused:", e, flush=True)
    print("QD after the menu:", repr(last_value()), "browser tabs", ntabs(), flush=True)
    print("SUMMARY", sum(1 for r in results if r[1]), "passed,", sum(1 for r in results if not r[1]), "failed")

if mode == "quickundo":
    # TASK-345 follow-up: a Quick Detour and a quarantine window each get
    # their page's own undo, and never TabStore's list. Run in a data
    # directory seeded with world.json (its quarantine route) and with
    # AutomationAllowPrivate on in its defaults suite (a quarantine is a
    # Private window to the endpoint). Detour is activated once per window.
    import re
    log_path = os.environ["HTTP_LOG"]
    def values():
        return re.findall(r"GET /log\?inp=([^&]*)&", open(log_path).read())
    activations = 0
    if not fixture_ctx():
        call("open_url", window_id=1, url=BASE + "/undo.html"); time.sleep(1.5)
    for n in ("a", "b"):
        call("open_url", window_id=1, url=f"{BASE}/{n}.html"); time.sleep(1.0)
        call("run_menu_item", window_id=1, path=["File", "Close Tab"]); time.sleep(0.5)
    ctx = fixture_ctx()
    n0 = ntabs()
    only = os.environ.get("QUICKUNDO_ONLY")
    for kind, link in (("quick_detour", None), ("quarantine", "#qrtlink")):
        if only and kind != only: continue
        before = {w["window_id"] for w in call("list_windows")["windows"]}
        call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.4)
        if link is None:
            call("click", context=ctx, selector="#qdlink", button="right"); time.sleep(0.5)
            call("choose_menu_item", title="Open Link in Quick Detour")
        else:
            call("click", context=ctx, selector=link)
        time.sleep(2.5)
        new = [w for w in call("list_windows")["windows"] if w["window_id"] not in before]
        check(f"{kind}: a window opened", len(new) == 1 and new[0]["kind"] == kind, new)
        if not new: continue
        wid = new[0]["window_id"]
        call("type_text", window_id=wid, text="qd"); time.sleep(0.8)
        typed = values()[-1] if values() else None
        sb = [w for w in call("list_windows")["windows"] if w["window_id"] == wid][0]["screen_bounds"]
        r = call("set_window_frame", window_id=wid, x=sb["x"], y=sb["y"], width=sb["width"], height=sb["height"], activate=True)
        activations += 1
        time.sleep(0.3)
        subprocess.run([AXDRIVE, "key", str(PID), "6", "cmd"], check=True, stdout=subprocess.DEVNULL); time.sleep(0.8)
        after_undo = values()[-1]
        subprocess.run([AXDRIVE, "key", str(PID), "6", "cmd,shift"], check=True, stdout=subprocess.DEVNULL); time.sleep(0.8)
        after_redo = values()[-1]
        w = [x for x in call("list_windows")["windows"] if x["window_id"] == wid][0]
        print(f"{kind}: typed={typed!r} after Cmd+Z={after_undo!r} after Shift+Cmd+Z={after_redo!r} key={w['is_key']} active={call('list_windows')['app_active']}", flush=True)
        check(f"{kind}: ⌘Z undid the page's typing", typed == "qd" and after_undo == "", (typed, after_undo))
        check(f"{kind}: ⇧⌘Z redid it", after_redo == "qd", after_redo)
        m1 = call("run_menu_item", window_id=wid, key="cmd+z"); time.sleep(0.6)
        v1 = values()[-1]
        m2 = call("run_menu_item", window_id=wid, key="cmd+shift+z"); time.sleep(0.6)
        v2 = values()[-1]
        check(f"{kind}: Edit > Undo / Redo (menu) are the page's", v1 == "" and v2 == "qd", (m1.get("title"), v1, m2.get("title"), v2))
        print(f"{kind}: menu titles {m1.get('title')!r} / {m2.get('title')!r}", flush=True)
        check(f"{kind}: TabStore's list untouched", ntabs() == n0, (n0, ntabs()))
        call("run_menu_item", window_id=wid, key="cmd+w"); time.sleep(0.8)
    print("activations:", activations)
    print("SUMMARY", sum(1 for r in results if r[1]), "passed,", sum(1 for r in results if not r[1]), "failed")

if mode == "find":
    ctx = fixture_ctx()
    # a fresh close on Detour's list (real Cmd+W)
    call("open_url", window_id=1, url=BASE + "/a.html"); time.sleep(1.2)
    key("cmd", code="13")
    call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.5)
    js(ctx, "location.reload(); 0"); time.sleep(1.5)
    js(ctx, "document.getElementById('inp').value = ''; keyLog.length = 0; 0")
    call("type_text", context=ctx, selector="#inp", text="xyz"); time.sleep(0.4)
    n0 = ntabs()
    call("run_menu_item", window_id=1, key="cmd+f"); time.sleep(0.6)
    st = json.loads(state(ctx))
    print("after find bar opens:", st, flush=True)
    key("cmd"); st = json.loads(state(ctx)); n1 = ntabs()
    check("G find-bar focus ⌘Z: Detour's undo ran once", n1 == n0 + 1, f"{n0}->{n1}")
    check("G find-bar focus ⌘Z: the page neither saw it nor lost its text", st["inp"].lower() == "xyz" and not any(l.startswith("cmd+z") for l in st["log"]), st)
    call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.4)
    print("SUMMARY", sum(1 for r in results if r[1]), "passed,", sum(1 for r in results if not r[1]), "failed; active after every key:", all(ACTIVE_LOG))

if mode == "extra":
    ctx = fixture_ctx()
    if not [i for i in call("list_tabs", window_id=1)["items"] if i.get("title") == "Filler c"]:
        call("open_url", window_id=1, url=BASE + "/c.html"); time.sleep(1.2)
    other = [i for i in call("list_tabs", window_id=1)["items"] if i.get("title") == "Filler c"][0]["id"]
    call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.5)
    # T: typing in the contenteditable, tab switch away and back, then Cmd+Z: the page's undo
    js(ctx, "document.getElementById('ce').textContent = ''; keyLog.length = 0; 0")
    call("type_text", context=ctx, selector="#ce", text="tab"); time.sleep(0.4)
    n0 = ntabs()
    call("select_tab", window_id=1, id=other); time.sleep(0.6)
    call("select_tab", window_id=1, id=ctx.split(":")[1]); time.sleep(0.6)
    st = json.loads(state(ctx)); print("after switching back:", st, flush=True)
    key("cmd"); st = json.loads(state(ctx)); n1 = ntabs()
    check("T after a tab switch ⌘Z: the page saw it", any(l.startswith("cmd+z") for l in st["log"]), st)
    print("T note: the page's text after ⌘Z:", st["ce"], flush=True)
    check("T after a tab switch ⌘Z: Detour's list untouched", n1 == n0, f"{n0}->{n1}")
    try:
        r = call("run_menu_item", window_id=1, key="cmd+z"); print("T Edit>Undo after the switch:", r, flush=True)
    except Exception as e:
        print("T Edit>Undo after the switch refused:", e, flush=True)
    check("T Edit>Undo after the switch: Detour's list untouched", ntabs() == n0)
    # V: the focused input removed by the page (no focusout): Cmd+Z is Detour's
    js(ctx, "keyLog.length = 0; 0")
    call("type_text", context=ctx, selector="#inp", text="gone"); time.sleep(0.4)
    js(ctx, "document.getElementById('inp').remove(); 0"); time.sleep(0.3)
    st = json.loads(state(ctx)); print("after removing the input:", st, flush=True)
    n2 = ntabs()
    key("cmd"); st = json.loads(state(ctx)); n3 = ntabs()
    check("V focused input removed: ⌘Z reached the page", any(l.startswith("cmd+z") for l in st["log"]), st)
    check("V focused input removed: Detour's undo ran once", n3 == n2 + 1, f"{n2}->{n3}")
    print("SUMMARY", sum(1 for r in results if r[1]), "passed,", sum(1 for r in results if not r[1]), "failed; active after every key:", all(ACTIVE_LOG))
