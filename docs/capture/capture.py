#!/usr/bin/env python3
"""Website captures for Detour (TASK-228.3): one script instead of a harness.

Launches a Detour build with its own data directory and the automation
endpoint on (DETOUR_MCP=1), seeds a demo world from a fixture (seed_world),
puts the window on a 2x virtual display (vdisplay.m, list_displays,
set_window_frame), sets the wallpaper to the site's background, and records
the shots asked for with screencapture: loops are encoded with encode.sh,
stills cropped from the screen with the native window shadow. Nothing in the
app is patched. See README.md for the kit and wiki/features/automation-endpoint.md
for the tools.

Usage:
  docs/capture/capture.py APP --out DIR [--fixture FILE] [--shots spaces,split]
                          [--offline] [--favicons DIR] [--appearance light|dark]
                          [--wallpaper F7F2EA | --no-wallpaper] [--keep]

  APP          a Detour.app (Debug for open_ui; never /Applications/Detour.app)
  --fixture    the world to seed (default: demo-world.json next to this script)
  --shots      which shots to take (default: all): see SHOTS below
  --offline    serve every page of the fixture from a local server instead of
               the real sites (titles kept; icons from --favicons when a file
               there is named after the site, e.g. github.png, else a letter)
  --keep       leave Detour, the virtual display and the wallpaper as they are
               at the end (for looking around); otherwise everything is undone

Changes what is on screen: it adds a virtual display, brings Detour to the
front for each take (taking focus from the app in use: a recording of an
active window needs it) and changes the wallpaper of every display (restored
at the end, also on failure). Run it while nobody is using the Mac. Needs the sandbox off and Screen Recording for the
terminal. Exit status 0 when every shot was taken.
"""

import argparse
import http.server
import importlib.machinery
import importlib.util
import json
import os
import re
import secrets
import shutil
import signal
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
import zlib

KIT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(KIT))
DATA_DIR_PREFIX = "DetourCapture-"
# The site's background (#F7F2EA) and the margins around a window, in points,
# so the native shadow fades out inside the frame (README: second pass).
MARGIN = {"left": 70, "right": 70, "top": 60, "bottom": 120}


def load_client():
    """scripts/detour-mcp as a module, for its Session class."""
    sys.dont_write_bytecode = True
    path = os.path.join(REPO, "scripts", "detour-mcp")
    loader = importlib.machinery.SourceFileLoader("detour_mcp", path)
    spec = importlib.util.spec_from_loader("detour_mcp", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def front_app():
    """The frontmost app's name, for the log."""
    asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(["lsappinfo", "info", "-only", "name", asn], capture_output=True, text=True).stdout
    match = re.search(r'="(.*)"', info)
    return match.group(1) if match else info.strip() or "?"


# MARK: - Offline pages

def png_square(rgb, size=64):
    """A solid PNG, standard library only."""
    row = b"\x00" + bytes(rgb) * size
    raw = row * size

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def site_name(host):
    """github.com -> github, en.wikipedia.org -> wikipedia, www.apple.com -> apple."""
    parts = [p for p in host.lower().split(".") if p not in ("www", "en", "docs", "news", "developer")]
    return parts[-2] if len(parts) >= 2 else (parts[0] if parts else host)


def offline_world(world, base, favicons):
    """The fixture with every page served by the local server at `base`:
    http://127.0.0.1:N/p/<host>/<path>. Titles stay, so the sidebar reads the
    same; each page gets an icon (`favicons`/<site>.png when there is one).
    Link Routes keep their patterns (they no longer match these pages)."""
    pages = {}

    def rewrite(item, icons):
        if isinstance(item, dict):
            item = dict(item)
            if "url" in item:
                parsed = urllib.parse.urlsplit(item["url"])
                local = f"{base}/p/{parsed.netloc}{parsed.path or '/'}"
                pages[urllib.parse.urlsplit(local).path] = item.get("title") or parsed.netloc
                item["url"] = local
                if icons:
                    item.setdefault("favicon_url", f"{base}/icon/{site_name(parsed.netloc)}.png")
            for key, value in list(item.items()):
                if key not in ("url", "favicon_url"):
                    item[key] = rewrite(value, icons)
            return item
        if isinstance(item, list):
            return [rewrite(value, icons) for value in item]
        return item

    rewritten = dict(world)
    for key in ("profiles", "spaces"):
        if key in world:
            rewritten[key] = rewrite(world[key], True)
    if "history" in world:
        rewritten["history"] = rewrite(world["history"], False)
    return rewritten, pages


def serve_offline(pages, favicons):
    palette = [(0x1F, 0x6F, 0xEB), (0xE9, 0x4F, 0x8C), (0x1F, 0xB6, 0xA8), (0xFF, 0x76, 0x00), (0x7C, 0x5C, 0xFF)]

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send(self, body, kind):
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = urllib.parse.urlsplit(self.path).path
            if path.startswith("/icon/") and path.endswith(".png"):
                name = os.path.basename(path)
                file = os.path.join(favicons, name) if favicons else None
                if file and os.path.isfile(file):
                    with open(file, "rb") as f:
                        return self.send(f.read(), "image/png")
                return self.send(png_square(palette[sum(map(ord, name)) % len(palette)]), "image/png")
            title = pages.get(path) or pages.get(path.rstrip("/")) or path
            host = path.split("/")[2] if path.count("/") >= 2 else ""
            icon = f"/icon/{site_name(host)}.png"
            words = " ".join(["Lorem ipsum dolor sit amet, consectetur adipiscing elit."] * 6)
            body = f"""<!doctype html><html><head><meta charset="utf-8"><title>{title}</title>
<link rel="icon" href="{icon}"><style>body{{font:15px -apple-system,sans-serif;margin:0;color:#222}}
header{{padding:18px 28px;border-bottom:1px solid #ddd;font-weight:600}} main{{padding:24px 28px;max-width:720px}}
h1{{font-size:28px;margin:0 0 16px}} p{{line-height:1.6;color:#555}}</style></head>
<body><header>{host}</header><main><h1>{title}</h1>{''.join(f'<p>{words}</p>' for _ in range(6))}</main></body></html>"""
            return self.send(body.encode(), "text/html; charset=utf-8")

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


# MARK: - Cleanup of an isolated run (as docs/harness/task324-endpoint-checks.py)

WEBKIT_NAMESPACE = uuid.UUID("9DC6C971-6D72-44C8-9541-D6DEBE44E0A3")
WEBKIT_DIR = os.path.expanduser("~/Library/WebKit/com.detourbrowser.mac")


def remove_run(data_dir):
    """The run's data directory, its WebKit stores (recorded in its database),
    its preferences domain and its window keys in the shared domain."""
    support = os.path.expanduser(f"~/Library/Application Support/{data_dir}")
    for key in (f"NSWindow Frame BrowserWindow-{data_dir}", f"NSSplitView Subview Frames BrowserSplitView-{data_dir}"):
        subprocess.run(["defaults", "delete", "com.detourbrowser.mac", key], capture_output=True)
    if not data_dir.startswith(DATA_DIR_PREFIX) or os.path.basename(support) != data_dir:
        return
    subprocess.run(["defaults", "delete", f"com.detourbrowser.mac.{data_dir}"], capture_output=True)
    plist = os.path.expanduser(f"~/Library/Preferences/com.detourbrowser.mac.{data_dir}.plist")
    if os.path.exists(plist):
        os.remove(plist)
    db = os.path.join(support, "browser.db")
    if os.path.exists(db):
        try:
            connection = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            try:
                rows = connection.execute("SELECT identifier, profileID FROM webKitStorageIdentifier").fetchall()
            finally:
                connection.close()
        except sqlite3.Error:
            rows = []
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
    shutil.rmtree(support, ignore_errors=True)


# MARK: - The run

class Capture:
    def __init__(self, args):
        self.args = args
        self.app = os.path.abspath(args.app)
        self.out = os.path.abspath(args.out)
        self.data_dir = f"{DATA_DIR_PREFIX}{secrets.token_hex(3)}"
        self.support = os.path.expanduser(f"~/Library/Application Support/{self.data_dir}")
        self.detour = None
        self.vdisplay = None
        self.server = None
        self.session = None
        self.wallpaper_set = False
        self.display = None
        self.taken = []

    # Endpoint

    def call(self, tool, **arguments):
        result = self.session.call(tool, arguments)
        content = result.get("structuredContent")
        if result.get("isError"):
            raise RuntimeError(f"{tool}: {json.dumps(content)}")
        return content

    def log(self, message):
        print(f"[capture] {message}", flush=True)

    # Setup

    def start_virtual_display(self):
        binary = os.path.join(self.out, "vdisplay")
        if not os.path.exists(binary):
            subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics",
                            os.path.join(KIT, "vdisplay.m"), "-o", binary], check=True)
        self.vdisplay = subprocess.Popen([binary], stdout=subprocess.PIPE, text=True)
        line = self.vdisplay.stdout.readline()
        match = re.search(r"displayID=(\d+)", line)
        if not match:
            raise RuntimeError(f"vdisplay: {line.strip() or 'no display'}")
        display_id = int(match.group(1))
        self.log(f"virtual display {display_id}")
        return display_id

    def launch(self):
        if self.app.startswith("/Applications/"):
            raise RuntimeError("refusing to drive the installed app; build one")
        env = dict(os.environ, DETOUR_DATA_DIR=self.data_dir, DETOUR_MCP="1")
        self.detour = subprocess.Popen([os.path.join(self.app, "Contents/MacOS/Detour")], env=env,
                                       stdout=open(os.path.join(self.out, "app.log"), "w"), stderr=subprocess.STDOUT)
        endpoint_file = os.path.join(self.support, "mcp-endpoint.json")
        for _ in range(120):
            if os.path.exists(endpoint_file):
                break
            if self.detour.poll() is not None:
                raise RuntimeError("Detour exited at launch (see app.log)")
            time.sleep(0.25)
        else:
            raise RuntimeError("Detour did not open its endpoint")
        time.sleep(1.5)
        with open(endpoint_file) as f:
            endpoint = json.load(f)
        self.session = load_client().Session(endpoint["url"], endpoint["token"], "capture.py")
        self.session.open()
        self.log(f"Detour pid {self.detour.pid}, data directory {self.data_dir}")

    def seed(self):
        with open(self.args.fixture) as f:
            world = json.load(f)
        if self.args.offline:
            pages = {}
            self.server = serve_offline(pages, self.args.favicons)
            world, served = offline_world(world, f"http://127.0.0.1:{self.server.server_address[1]}", self.args.favicons)
            pages.update(served)
        path = os.path.join(self.out, "world.json")
        with open(path, "w") as f:
            json.dump(world, f, indent=1, ensure_ascii=False)
        seeded = self.call("seed_world", fixture_path=path)
        self.spaces = seeded["space_ids"]
        self.profiles = seeded["profile_ids"]
        self.log(f"seeded {seeded['counts']}")
        self.call("set_appearance", appearance=self.args.appearance)
        # The connected-agent capsule would be in every take (Debug builds).
        self.call("set_debug_override", name="automation_indicator", value="off")

    def find_display(self, display_id):
        for _ in range(20):
            displays = self.call("list_displays")["displays"]
            found = [d for d in displays if d["display_id"] == display_id]
            if found:
                return found[0]
            time.sleep(0.25)
        raise RuntimeError(f"display {display_id} not listed")

    # Staging

    def place(self, width, height, dy=0):
        """The browser window mid virtual display (away from the Dock), front
        and key; returns the window server's bounds of it."""
        visible = self.display["visible_frame"]
        frame = self.display["frame"]
        x = round(visible["x"] - frame["x"] + (visible["width"] - width) / 2)
        y = round(visible["y"] - frame["y"] + (visible["height"] - height) / 2 + dy)
        placed = self.call("set_window_frame", window_id=1, x=x, y=y, width=width, height=height,
                           display_id=self.display["display_id"], activate=True)
        time.sleep(0.6)
        if not self.window_is_front():
            # Not fought over: another app in front means someone is using
            # the Mac (or an app took the front), and the take would be grey.
            raise RuntimeError(f"Detour did not keep the front ({front_app()} has it); capture while the Mac is idle")
        # Read back right before recording: the README's first loops drifted.
        window = [w for w in self.call("list_windows")["windows"] if w["window_id"] == 1][0]
        bounds = window["screen_bounds"]
        if bounds is None:
            raise RuntimeError("the window is not on screen")
        if abs(bounds["x"] - placed["screen_bounds"]["x"]) > 0.5 or abs(bounds["y"] - placed["screen_bounds"]["y"]) > 0.5:
            self.log(f"the window moved after placing: {placed['screen_bounds']} -> {bounds}")
        return bounds, window["window_number"]

    def region(self, bounds):
        return (round(bounds["x"] - MARGIN["left"]), round(bounds["y"] - MARGIN["top"]),
                round(bounds["width"] + MARGIN["left"] + MARGIN["right"]),
                round(bounds["height"] + MARGIN["top"] + MARGIN["bottom"]))

    def select_space(self, name, tab_title=None):
        """Switches the window to the space, selecting its first tab (or the
        one whose title starts with tab_title)."""
        items = self.call("list_tabs", space_id=self.spaces[name])["items"]
        tabs = [i for i in items if i["section"] == "tab"]
        chosen = next((i for i in tabs if tab_title and i["title"].startswith(tab_title)), tabs[0])
        self.call("select_tab", window_id=1, id=chosen["id"], space_id=self.spaces[name])
        return chosen

    def wait_loaded(self, timeout=15):
        window = [w for w in self.call("list_windows")["windows"] if w["window_id"] == 1][0]
        tab = window.get("selected_tab_id")
        if tab:
            try:
                self.call("wait_for", context=tab, load=True, timeout_ms=timeout * 1000)
            except RuntimeError as error:
                self.log(f"page not loaded in time: {error}")

    def record(self, name, region, seconds, steps, settle=0.8):
        """screencapture -v of `region` for `seconds` while `steps` run, then
        encode.sh trims it from 0.4 s to `settle` after the last step (which
        `steps` returns, in seconds since it started). Not to the end of the
        recording: Detour was seen losing the front in a take's last second
        or two, and a loop must end where it starts."""
        movie = os.path.join(self.out, f"{name}.mov")
        if os.path.exists(movie):
            os.remove(movie)   # screencapture will not replace a file
        x, y, w, h = region
        recorder = subprocess.Popen(["screencapture", "-x", "-v", "-V", str(seconds), f"-R{x},{y},{w},{h}", movie])
        time.sleep(1.0)
        last = 1.0 + steps()
        recorder.wait(timeout=seconds + 30)
        if not os.path.exists(movie):
            raise RuntimeError("screencapture wrote no movie (Screen Recording for the terminal?)")
        end = min(seconds - 0.2, last + settle)
        env = dict(os.environ, CAPTURE_OUT=self.out)
        subprocess.run([os.path.join(KIT, "encode.sh"), movie, name, "0.4", f"{end:.2f}"], env=env, check=True)
        self.taken.append(f"{name}.mp4")

    def still(self, name, region):
        x, y, w, h = region
        png = os.path.join(self.out, f"{name}.png")
        subprocess.run(["screencapture", "-x", f"-R{x},{y},{w},{h}", png], check=True)
        subprocess.run(["cwebp", "-quiet", "-q", "86", png, "-o", os.path.join(self.out, f"{name}.webp")], check=True)
        self.taken.append(f"{name}.webp")

    # MARK: Shots

    def window_is_front(self):
        """Whether Detour is the active app with window 1 key: what the take
        needs (traffic lights in colour)."""
        listing = self.call("list_windows")
        window = [w for w in listing["windows"] if w["window_id"] == 1][0]
        return listing["app_active"] and window["is_key"]

    def shot_spaces(self, attempts=1):
        """The Spaces loop: Work → Personal → Reading → Side and back, as on the
        site (560 × 700 pt window). Checked after every step: a take during
        which another app took the front is refused, not kept."""
        # Show every space's page once first: a page loads only when it is
        # shown, and the first take's Personal split came out blank.
        for name in ("Personal", "Reading", "Side"):
            self.select_space(name)
            self.wait_loaded()
        for attempt in range(1, attempts + 1):
            self.select_space("Work")
            self.wait_loaded()
            bounds, _ = self.place(560, 700)
            time.sleep(1.5)
            spoiled = []

            def steps():
                start = time.time()
                time.sleep(0.8)
                for index, path in enumerate([["Spaces", "Next Space"]] * 3 + [["Spaces", "Previous Space"]] * 3):
                    if index:
                        time.sleep(1.7)
                    self.call("run_menu_item", window_id=1, path=path)
                    if not self.window_is_front():
                        spoiled.append(index)
                elapsed = time.time() - start
                time.sleep(0.8)
                if not self.window_is_front():
                    spoiled.append("end")
                return elapsed
            self.record("spaces", self.region(bounds), 14, steps)
            if not spoiled:
                return
            self.log(f"Detour lost the front during take {attempt} (after steps {spoiled}; front: {front_app()})")
            self.taken.remove("spaces.mp4")
        raise RuntimeError("the spaces loop never kept the front: another app took it (the log names it). "
                           "Someone using the Mac takes it back; capture while it is idle")

    def shot_split(self):
        """The split-tabs still: the Personal space's split, 1280 × 680 pt."""
        self.select_space("Personal")
        self.wait_loaded()
        bounds, _ = self.place(1280, 680)
        time.sleep(2.0)
        x, y, w, h = bounds["x"], bounds["y"], bounds["width"], bounds["height"]
        # The site's still has smaller margins than the loops.
        self.still("split", (round(x - 56), round(y - 38), round(w + 112), round(h + 112)))

    def shot_space_editor(self):
        """The space editor still (Debug builds: open_ui): a new space typed
        into the editor at a person's pace, over the Reading space."""
        self.select_space("Reading")
        self.wait_loaded()
        bounds, _ = self.place(560, 700)
        self.call("open_ui", what="space_editor", window_id=1, name="", emoji="🍳", color="5DA37A",
                  profile_id=self.profiles["Personal"])
        time.sleep(0.6)
        self.call("type_text", window_id=1, text="Recipes", interval_ms=110)
        time.sleep(1.0)
        self.still("spaces-editor", self.region(bounds))
        self.call("press_key", window_id=1, key="escape")
        time.sleep(0.6)

    SHOTS = {"spaces": shot_spaces, "split": shot_split, "space-editor": shot_space_editor}

    # MARK: Run

    def run(self):
        os.makedirs(self.out, exist_ok=True)
        try:
            display_id = self.start_virtual_display()
            self.launch()
            self.display = self.find_display(display_id)
            self.seed()
            if self.args.wallpaper:
                subprocess.run([os.path.join(KIT, "demo.sh"), "wallpaper", self.args.wallpaper, str(display_id)],
                               check=True)
                self.wallpaper_set = True
                time.sleep(1.5)
            for name in self.args.shots:
                self.log(f"shot {name}")
                self.SHOTS[name](self)
            return 0
        finally:
            if not self.args.keep:
                self.cleanup()

    def cleanup(self):
        if self.session is not None:
            try:
                self.session.close()
            except Exception:
                pass
        if self.detour is not None:
            try:
                self.detour.send_signal(signal.SIGTERM)
                self.detour.wait(timeout=15)
            except Exception:
                self.detour.kill()
                self.detour.wait()
        if self.wallpaper_set:
            subprocess.run([os.path.join(KIT, "demo.sh"), "wallpaper-restore"])
        if self.vdisplay is not None:
            self.vdisplay.terminate()
            try:
                self.vdisplay.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.vdisplay.kill()
        if self.server is not None:
            self.server.shutdown()
        remove_run(self.data_dir)
        self.log("cleaned up: Detour stopped and its data directory removed"
                 + ("; virtual display gone" if self.vdisplay is not None else "")
                 + ("; wallpaper restored" if self.wallpaper_set else ""))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("app")
    parser.add_argument("--out", required=True, help="where movies, stills and logs go (never the repository)")
    parser.add_argument("--fixture", default=os.path.join(KIT, "demo-world.json"))
    parser.add_argument("--shots", default=",".join(Capture.SHOTS))
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--favicons", default=None)
    parser.add_argument("--appearance", choices=["light", "dark"], default="light")
    parser.add_argument("--wallpaper", default="F7F2EA")
    parser.add_argument("--no-wallpaper", dest="wallpaper", action="store_const", const=None)
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    args.shots = [s for s in args.shots.split(",") if s]
    unknown = [s for s in args.shots if s not in Capture.SHOTS]
    if unknown:
        parser.error(f"unknown shots {unknown}; there are {list(Capture.SHOTS)}")
    if os.path.abspath(args.out).startswith(REPO + os.sep):
        parser.error("--out must be outside the repository")
    capture = Capture(args)

    def stop(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    try:
        status = capture.run()
    except Exception as error:
        print(f"[capture] FAILED: {error}", file=sys.stderr)
        return 1
    print(f"[capture] taken: {', '.join(capture.taken)} in {capture.out}")
    return status


if __name__ == "__main__":
    sys.exit(main())
