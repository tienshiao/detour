#!/usr/bin/env python3
"""TASK-228.2's end-to-end extension run through the automation endpoint:
install fixture extensions, drive a popup and a content script, read the
console, fetch each extension's compatibility report, and save a baseline or
diff against one.

Launches the given Detour.app with a fresh isolated data directory, the
endpoint on (DETOUR_MCP=1) and an empty DETOUR_NATIVE_MESSAGING_HOSTS_DIR (so
no extension reaches a real native host), serves a local fixture page, then:

  1. installs TestExtensions/api-explorer and hello-world (and vimium with
     --vimium) and waits for each worker;
  2. opens the fixture in a tab, opens API Explorer's popup, reads the tab's
     WebKit id with chrome.tabs.query from the popup and sends the tab's
     content script a "highlight" message from the popup
     (chrome.tabs.sendMessage); the content script outlines the page and
     answers (both checked);
  3. clicks "Query All Tabs" in the popup (a real click) and reads the
     result;
  4. reads each extension's console (console_messages stable) and list entry
     (list_extensions stable);
  5. fetches extension_compat_report for each one.

Writes <out>/<extension>.json per extension: the stable part of the report
(everything but `run`), the stable list entry, and the console's warnings and
errors as a sorted, de-duplicated list of "context_kind level text" lines
(the fixture's origin written http://<fixture>), with the extension's id
written <folder name> (a keyless unpacked extension gets a new random id in
every new data directory); <out>/<extension>.run.json with the report's `run`
object; and <out>/<extension>.console.txt with every console line, which is
not compared (extensions log tab ids and other data of the run). With
--baseline DIR it compares each stable file with DIR's and prints the
differences.

Detour stays in the background and the pointer never moves. Needs the sandbox
off (it launches an app). Usage:

  docs/harness/task2282-compat-run.py /path/to/Detour.app OUT_DIR [--baseline DIR] [--vimium]

Exit status 0 when the scenario's checks passed (and, with --baseline, nothing
differed).
"""

import argparse
import http.server
import importlib.machinery
import importlib.util
import json
import os
import secrets
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES = os.path.join(REPO, "TestExtensions")


def load_client():
    """scripts/detour-mcp as a module, for its Session class."""
    sys.dont_write_bytecode = True   # no __pycache__ left in scripts/
    path = os.path.join(REPO, "scripts", "detour-mcp")
    loader = importlib.machinery.SourceFileLoader("detour_mcp", path)
    spec = importlib.util.spec_from_loader("detour_mcp", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def serve(directory):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **k):
            super().__init__(*a, directory=directory, **k)

        def log_message(self, *a):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


# WebKitStorageScope.namespace: an isolated data directory's WebKit stores are
# named uuid5(namespace, "<data dir>/<profile id>").
WEBKIT_NAMESPACE = uuid.UUID("9DC6C971-6D72-44C8-9541-D6DEBE44E0A3")
WEBKIT_DIR = os.path.expanduser("~/Library/WebKit/com.detourbrowser.mac")


def remove_webkit_storage(support, data_dir):
    """This run's website data stores and extension controller directories,
    which WebKit keeps outside the data directory; only identifiers recorded in
    this run's own database and derived from its own data directory name."""
    db = os.path.join(support, "browser.db")
    if not os.path.exists(db):
        return
    try:
        connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        try:
            rows = connection.execute("SELECT identifier, profileID FROM webKitStorageIdentifier").fetchall()
        finally:
            connection.close()
    except sqlite3.Error:
        return
    for identifier, profile_id in rows:
        try:
            ident, profile = uuid.UUID(identifier), uuid.UUID(profile_id)
        except (ValueError, TypeError, AttributeError):
            continue
        if ident.version != 5 or ident != uuid.uuid5(WEBKIT_NAMESPACE, f"{data_dir}/{str(profile).upper()}"):
            continue
        for path in (os.path.join(WEBKIT_DIR, "WebsiteDataStore", str(ident)),
                     os.path.join(WEBKIT_DIR, "WebExtensions", str(ident).upper())):
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)


def diff(a, b, path="$"):
    """The paths where two JSON values differ."""
    if type(a) is not type(b):
        return [f"{path}: {json.dumps(a)[:120]} != {json.dumps(b)[:120]}"]
    if isinstance(a, dict):
        out = []
        for key in sorted(set(a) | set(b)):
            if key not in a:
                out.append(f"{path}.{key}: added")
            elif key not in b:
                out.append(f"{path}.{key}: removed")
            else:
                out += diff(a[key], b[key], f"{path}.{key}")
        return out
    if isinstance(a, list):
        if len(a) != len(b):
            only_a = [x for x in a if x not in b]
            only_b = [x for x in b if x not in a]
            return [f"{path}: {len(a)} items != {len(b)}; only in baseline {json.dumps(only_a)[:300]}, "
                    f"only now {json.dumps(only_b)[:300]}"]
        out = []
        for index, (x, y) in enumerate(zip(a, b)):
            out += diff(x, y, f"{path}[{index}]")
        return out
    return [] if a == b else [f"{path}: {json.dumps(a)[:120]} != {json.dumps(b)[:120]}"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("app")
    parser.add_argument("out")
    parser.add_argument("--baseline")
    parser.add_argument("--vimium", action="store_true")
    args = parser.parse_args()
    app = os.path.abspath(args.app)
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)
    run = secrets.token_hex(3)
    data_dir = f"DetourCompat2282-{run}"
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    client = load_client()

    fixture = tempfile.mkdtemp(prefix="task2282-fixture-")
    with open(os.path.join(fixture, "index.html"), "w") as f:
        f.write("<!doctype html><html><head><title>Compat fixture</title></head>"
                "<body><h1 id=\"title\">Compat fixture</h1><p>Content scripts run here.</p></body></html>")
    hosts = tempfile.mkdtemp(prefix="task2282-no-native-hosts-")
    server = serve(fixture)
    base = f"http://127.0.0.1:{server.server_address[1]}"

    env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1", DETOUR_NATIVE_MESSAGING_HOSTS_DIR=hosts)
    endpoint_file = os.path.join(support, "mcp-endpoint.json")
    results = []
    differences = []
    detour = None
    try:
        detour = subprocess.Popen([os.path.join(app, "Contents/MacOS/Detour")], env=env,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(80):
            if os.path.exists(endpoint_file):
                break
            time.sleep(0.25)
        else:
            print("FAIL: Detour did not open its endpoint")
            return 1
        time.sleep(2)
        with open(endpoint_file) as f:
            endpoint = json.load(f)
        session = client.Session(endpoint["url"], endpoint["token"], "task2282-compat")
        session.open()

        def call(tool, **arguments):
            result = session.call(tool, arguments)
            content = result.get("structuredContent")
            if result.get("isError"):
                raise RuntimeError(f"{tool} {json.dumps(arguments)[:200]}: {content}")
            return content

        def check(name, ok, detail):
            results.append((name, ok))
            print(f"{'PASS' if ok else 'FAIL'}: {name}: {detail}")

        # 1. Install.
        names = ["api-explorer", "hello-world"] + (["vimium"] if args.vimium else [])
        ids = {}
        for name in names:
            installed = call("install_extension", path=os.path.join(FIXTURES, name), timeout_ms=30000)
            ids[name] = installed["extension"]["id"]
            started = call("wait_for", context=f"worker:{ids[name]}", worker_started=True, timeout_ms=20000)
            check(f"install {name}", installed["loaded"] and started["matched"],
                  f"id {ids[name]}, worker {started.get('value')}")

        # 2. A popup and a content script.
        explorer = ids["api-explorer"]
        popup = f"popup:{explorer}"
        call("open_url", window_id=1, url=f"{base}/index.html", in_place=False)
        tab = call("list_windows")["windows"][0]["selected_tab_id"]
        call("wait_for", context=tab, load=True, timeout_ms=15000)
        call("open_extension_context", extension=explorer, kind="popup", window_id=1)
        call("wait_for", context=popup, load=True, timeout_ms=15000)
        active = call("call_extension_api", context=popup, path="chrome.tabs.query",
                      args=json.dumps([{"active": True, "currentWindow": True}]))["value"]
        webkit_tab = active[0]["id"] if active else None
        check("the popup sees the fixture tab", bool(active) and active[0].get("url", "").startswith(base),
              f"{active}")
        # The popup sends the content script its "highlight" message, as
        # its "Send to Tab" button does. (That button is below the popover's
        # 600 points, and WebKit's autosized popup page does not scroll from
        # script, so the endpoint cannot click it; see the playbook's traps.)
        reply = call("call_extension_api", context=popup, path="chrome.tabs.sendMessage",
                     args=json.dumps([webkit_tab, {"type": "highlight"}]))["value"]
        outlined = call("wait_for", context=tab, expression="document.body.style.outline.includes('blue')",
                        timeout_ms=10000)
        check("the content script answered the popup's message",
              outlined["matched"] and reply == {"highlighted": True},
              f"tab outline set, reply {reply}")

        # 3. Another popup action.
        call("click", context=popup, selector="#btn-query-all")
        call("wait_for", context=popup, expression="document.getElementById('res-query-all').textContent.length > 0",
             timeout_ms=10000)
        listed = call("read_page", context=popup, selector="#res-query-all")["text"]
        check("Query All Tabs lists the fixture", "Compat fixture" in listed, listed.strip().splitlines()[:2])
        call("close_extension_context", context=popup)

        # 4 and 5. Console, list entry and report per extension.
        for name in names:
            ext = ids[name]
            messages = call("console_messages", context=f"extension:{ext}", stable=True, limit=1000)["messages"]
            lines = sorted({f"{m.get('context_kind')} {m.get('level')} {m.get('text')}".replace(base, "http://<fixture>")
                            for m in messages})
            entry = call("list_extensions", extension=ext, stable=True)["extensions"][0]
            report = call("extension_compat_report", extension=ext)
            run_part = report.pop("run")
            # Only the warnings and errors are compared: what an extension
            # logs otherwise carries tab ids and other data of the run.
            problems = [line for line in lines if line.split(" ", 2)[1] in ("warn", "error")]
            stable = {"report": report, "list": entry, "console_problems": problems}
            # A keyless unpacked extension gets a new random id in every new
            # data directory, so the baseline names it by its folder instead.
            text = json.dumps(stable, indent=2, sort_keys=True).replace(ext, f"<{name}>")
            with open(os.path.join(out_dir, f"{name}.json"), "w") as f:
                f.write(text)
            stable = json.loads(text)
            with open(os.path.join(out_dir, f"{name}.run.json"), "w") as f:
                json.dump(run_part, f, indent=2, sort_keys=True)
            with open(os.path.join(out_dir, f"{name}.console.txt"), "w") as f:
                f.write("\n".join(lines) + "\n")
            summary = report["summary"]
            check(f"report {name}", report["worker"]["started"] is True,
                  f"{len(report['references'])} references, missing in worker {summary['missing_in_worker']}, "
                  f"stubbed {summary['stubbed_referenced']}, stubs called {summary['stubs_called']}, "
                  f"errors {summary['runtime_error_apis']}, unsupported keys {summary['unsupported_manifest_keys']}, "
                  f"permissions {summary['unsupported_permissions']}")
            if args.baseline:
                baseline_file = os.path.join(os.path.abspath(args.baseline), f"{name}.json")
                if not os.path.exists(baseline_file):
                    differences.append(f"{name}: no baseline")
                    continue
                with open(baseline_file) as f:
                    found = diff(json.load(f), stable)
                differences += [f"{name}: {line}" for line in found]

        active_app = call("list_windows")["app_active"]
        check("Detour stayed in the background", active_app is False, f"app_active={active_app}")
        session.close()
    finally:
        if detour is not None:
            try:
                detour.send_signal(signal.SIGTERM)
                detour.wait(timeout=15)
            except Exception:
                detour.kill()
                detour.wait()
        server.shutdown()
        for key in (f"NSWindow Frame BrowserWindow-{data_dir}", f"NSSplitView Subview Frames BrowserSplitView-{data_dir}"):
            subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)
        # Only this run's own preferences domain, WebKit stores and directories.
        if os.path.basename(support) == data_dir and data_dir.startswith("DetourCompat2282-"):
            subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
            plist = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
            if os.path.exists(plist):
                os.remove(plist)
            remove_webkit_storage(support, data_dir)
            shutil.rmtree(support, ignore_errors=True)
        for directory, prefix in ((fixture, "task2282-fixture-"), (hosts, "task2282-no-native-hosts-")):
            if os.path.basename(directory).startswith(prefix):
                shutil.rmtree(directory, ignore_errors=True)

    print(f"Output: {out_dir}")
    if args.baseline:
        print("Baseline: " + ("no differences" if not differences else f"{len(differences)} differences"))
        for line in differences:
            print(f"  {line}")
    failed = [name for name, ok in results if not ok]
    print("ALL PASSED" if results and not failed else f"FAILED: {', '.join(failed) or 'nothing ran'}")
    return 0 if results and not failed and not differences else 1


if __name__ == "__main__":
    sys.exit(main())
