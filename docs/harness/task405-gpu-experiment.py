#!/usr/bin/env python3
"""TASK-405: do closed tabs give their IOSurfaces back to WebKit's GPU process?

Launches the given Detour.app with a fresh isolated data directory and the
automation endpoint on, then, reading `gpu_process_stats` at each step:

  1. baseline, a few seconds after launch;
  2. opens each URL in its own new tab (each is shown as it opens) and waits
     for it to settle;
  3. shows every opened tab again, --cycles times (each show is a
     hidden -> visible transition, which is what grows the pool);
  4. closes every opened tab (Cmd+W on each), then samples after --settle
     seconds and again after twice that.

It prints a table of total / non-resident IOSurface regions, live web views,
tab processes and process pools per step, and the JSON of every sample to
<output-dir>/samples.json. "Freed" is how much of what the tabs added came back
after closing them.

Real pages are the default on purpose: synthetic `will-change` layers do not
land in the GPU process (TASK-104), so a local fixture would measure nothing.
The numbers depend on the network and the sites' current markup; compare runs
made back to back, not across days.

Needs the sandbox off (it launches an app). Usage:

  docs/harness/task405-gpu-experiment.py /path/to/Detour.app [--cycles 3]
      [--settle 30] [--out DIR] [--env NAME=VALUE ...] [URL ...]

--env passes extra environment variables to Detour (repeatable), for comparing
variants, e.g. --env DETOUR_WEB_PROCESS_CACHE=0.
"""

import argparse
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
import time
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DEFAULT_URLS = [
    "https://www.youtube.com/",
    "https://www.youtube.com/feed/trending",
    "https://github.com/WebKit/WebKit",
    "https://www.apple.com/",
    "https://www.apple.com/macbook-pro/",
    "https://developer.apple.com/documentation/webkit",
]

# WebKitStorageScope.namespace: an isolated data directory's WebKit stores are
# named uuid5(namespace, "<data dir>/<PROFILE UUID>").
WEBKIT_NAMESPACE = uuid.UUID("9DC6C971-6D72-44C8-9541-D6DEBE44E0A3")
WEBKIT_DIR = os.path.expanduser("~/Library/WebKit/com.detourbrowser.mac")


def load_client():
    """scripts/detour-mcp as a module, for its Session class."""
    sys.dont_write_bytecode = True
    path = os.path.join(REPO, "scripts", "detour-mcp")
    loader = importlib.machinery.SourceFileLoader("detour_mcp", path)
    spec = importlib.util.spec_from_loader("detour_mcp", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def remove_webkit_storage(support, data_dir):
    """This run's own WebKit data stores and extension directories, named from
    its data directory, as WebKitStorageScope.refusalToRemove allows."""
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app")
    parser.add_argument("urls", nargs="*")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--settle", type=float, default=30)
    parser.add_argument("--rounds", type=int, default=1,
                        help="repeat open / show / close this many times, to see whether what stays behind grows")
    parser.add_argument("--out")
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("--mode", choices=["close", "bfcache"], default="close",
                        help="close: open/show/close tabs (TASK-405). bfcache: navigate each tab through --hops "
                             "more URLs to fill its back/forward cache, hide them all, then trim the caches with "
                             "trim_back_forward_cache (TASK-408)")
    parser.add_argument("--hops", type=int, default=3)
    args = parser.parse_args()

    app = os.path.abspath(args.app)
    urls = args.urls or DEFAULT_URLS
    out_dir = os.path.abspath(args.out) if args.out else tempfile.mkdtemp(prefix="task405-")
    os.makedirs(out_dir, exist_ok=True)
    data_dir = f"DetourCheck405-{secrets.token_hex(3)}"
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    client = load_client()

    env = dict(os.environ, DETOUR_DATA_DIR=data_dir, DETOUR_MCP="1",
               # No recycle in the middle of a measurement.
               DETOUR_GPU_RECYCLE_SOFT_LIMIT="1000000", DETOUR_GPU_RECYCLE_HARD_LIMIT="1000000",
               DETOUR_GPU_RECYCLE_EXHAUSTED_LIMIT="1000000", DETOUR_GPU_RECYCLE_AWAY_LIMIT="1000000")
    for item in args.env:
        name, _, value = item.partition("=")
        env[name] = value
    endpoint_file = os.path.join(support, "mcp-endpoint.json")
    samples = []
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
        with open(endpoint_file) as f:
            endpoint = json.load(f)
        session = client.Session(endpoint["url"], endpoint["token"], "task405-experiment")
        session.open()

        def call(tool, **arguments):
            result = session.call(tool, arguments)
            content = result.get("structuredContent")
            if result.get("isError"):
                raise RuntimeError(f"{tool}: {content}")
            return content

        def sample(step):
            stats = call("gpu_process_stats", detail=True)
            stats["step"] = step
            stats["at"] = time.strftime("%H:%M:%S")
            samples.append(stats)
            pools = stats["process_pools"]
            stats["pool_web_processes"] = sum(p.get("web_processes") or 0 for p in pools)
            print(f"{step:<28} total={stats['total']!s:>6} non_resident={stats['non_resident']!s:>6} "
                  f"views={stats['live_web_views']:>3} processes={stats['tab_processes']:>3} "
                  f"mem={stats.get('tab_process_footprint_mb')!s:>5}MB "
                  f"pools={len(pools)} pool_processes={stats['pool_web_processes']:>3} gpu={stats['gpu_pid']}", flush=True)
            return stats

        time.sleep(5)
        base = sample("baseline")

        if args.mode == "bfcache":
            hops = [u for u in DEFAULT_URLS] if not args.urls else urls
            opened = []
            before = {t["tab_id"] for t in call("list_tabs", window_id=1)["items"]}
            for index, url in enumerate(urls):
                call("open_url", window_id=1, url=url)
                time.sleep(8)
                for hop in range(1, args.hops + 1):
                    # Cross-site hops, so WebKit keeps the previous page frozen
                    # (possibly in its own suspended process).
                    call("open_url", window_id=1, url=hops[(index + hop) % len(hops)], in_place=True)
                    time.sleep(6)
            for item in call("list_tabs", window_id=1)["items"]:
                if item["tab_id"] not in before:
                    opened.append(item["tab_id"])
            sample(f"navigated {len(opened)}x{args.hops + 1}")
            # Hide them all behind one light tab.
            call("open_url", window_id=1, url="https://example.com/")
            time.sleep(5)
            sample("all hidden, +0s")
            time.sleep(args.settle)
            hidden = sample(f"all hidden, +{args.settle:.0f}s")
            trimmed = call("trim_back_forward_cache")["trimmed"]
            print(f"trimmed {len(trimmed)} tabs")
            sample("trimmed, +0s")
            time.sleep(args.settle)
            sample(f"trimmed, +{args.settle:.0f}s")
            time.sleep(args.settle)
            after = sample(f"trimmed, +{2 * args.settle:.0f}s")
            print(f"\ntrim freed {(hidden['total'] or 0) - (after['total'] or 0)} IOSurfaces "
                  f"({hidden['non_resident']} -> {after['non_resident']} non-resident), "
                  f"pool processes {hidden['pool_web_processes']} -> {after['pool_web_processes']}")
            session.close()
            return 0

        shown = closed = base
        residuals = []
        for round_number in range(1, args.rounds + 1):
            tag = f"r{round_number} " if args.rounds > 1 else ""
            before = {t["tab_id"] for t in call("list_tabs", window_id=1)["items"]}
            opened = []
            for url in urls:
                call("open_url", window_id=1, url=url)
                time.sleep(8)
            for item in call("list_tabs", window_id=1)["items"]:
                if item["tab_id"] not in before:
                    opened.append(item["tab_id"])
            sample(f"{tag}opened {len(opened)}")

            for cycle in range(args.cycles):
                for tab_id in opened:
                    call("select_tab", window_id=1, id=tab_id)
                    time.sleep(2)
            shown = sample(f"{tag}after {args.cycles} show cycles")

            for tab_id in opened:
                call("select_tab", window_id=1, id=tab_id)
                time.sleep(0.5)
                call("run_menu_item", window_id=1, key="cmd+w")
                time.sleep(1)
            sample(f"{tag}closed, +0s")
            time.sleep(args.settle)
            sample(f"{tag}closed, +{args.settle:.0f}s")
            time.sleep(args.settle)
            closed = sample(f"{tag}closed, +{2 * args.settle:.0f}s")
            residuals.append(closed["total"])

        freed = (shown["total"] or 0) - (closed["total"] or 0)
        print(f"\nlast round: peak {shown['total']}, freed after closing: {freed}")
        if args.rounds > 1:
            print(f"left behind after each round: {residuals}")
        print(f"process pools: {json.dumps(closed['process_pools'])}")
        session.close()
    finally:
        with open(os.path.join(out_dir, "samples.json"), "w") as f:
            json.dump(samples, f, indent=1)
        if detour is not None:
            try:
                detour.send_signal(signal.SIGTERM)
                detour.wait(timeout=15)
            except Exception:
                detour.kill()
                detour.wait()
        for key in (f"NSWindow Frame BrowserWindow-{data_dir}", f"NSSplitView Subview Frames BrowserSplitView-{data_dir}"):
            subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)
        if os.path.basename(support) == data_dir and data_dir.startswith("DetourCheck405-"):
            subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
            plist = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
            if os.path.exists(plist):
                os.remove(plist)
            remove_webkit_storage(support, data_dir)
            shutil.rmtree(support, ignore_errors=True)
    print(f"Samples: {os.path.join(out_dir, 'samples.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
