import json, sys, os, sqlite3, time
out = sys.argv[1]
items = []
def item(id, parent, data, title=None, children=()):
    items.append((id, {"id": id, "parentID": parent, "title": title, "childrenIds": list(children),
                       "data": data, "isUnread": False, "createdAt": 780000000.0}))
def tab(id, parent, url, saved, title=None):
    item(id, parent, {"tab": {"savedURL": url, "savedTitle": saved, "savedMuteStatus": "allowAudio",
                              "timeLastActiveAt": 811838010.0}}, title)
def folder(id, parent, title, children):
    item(id, parent, {"list": {}}, title, children)
def container(id, space, children):
    item(id, None, {"itemContainer": {"containerType": {"spaceItems": {"_0": space}}}}, None, children)
def topapps(id, profile, children):
    item(id, None, {"itemContainer": {"containerType": {"topApps": {"_0": profile}}}}, None, children)
DEF = {"default": True}
P1 = {"custom": {"_0": {"directoryBasename": "Profile 1", "machineID": "DEMO-MACHINE"}}}
def color(r, g, b): return {"red": r, "green": g, "blue": b, "alpha": 1, "colorSpace": "extendedSRGB"}
def hexc(h): return color(int(h[0:2],16)/255, int(h[2:4],16)/255, int(h[4:6],16)/255)
spaces = []
def space(id, title, profile, emoji, hexcol, pinned, unpinned):
    s = {"id": id, "title": title, "profile": profile,
         "customInfo": {"iconType": {"emoji_v2": emoji, "emoji": ord(emoji[0])},
                        "windowTheme": {"primaryColorPalette": {"shaded": hexc(hexcol), "midTone": hexc(hexcol)}}},
         "containerIDs": ["unpinned", unpinned, "pinned", pinned],
         "newContainerIDs": [{"pinned": {}}, pinned, {"unpinned": {"_0": {"shared": {}}}}, unpinned]}
    spaces.append((id, s))

# Home (Personal / Default)
space("HOME", "Home", DEF, "🏠", "E07A3F", "HOME-P", "HOME-U")
container("HOME-P", "HOME", ["h1", "hF1"])
tab("h1", "HOME-P", "https://www.theverge.com/", "The Verge")
folder("hF1", "HOME-P", "Weekend", ["h2", "h3"])
tab("h2", "hF1", "https://en.wikipedia.org/wiki/Hiking", "Hiking - Wikipedia")
tab("h3", "hF1", "https://www.nps.gov/index.htm", "National Park Service")
container("HOME-U", "HOME", ["hu1"])
tab("hu1", "HOME-U", "https://www.apple.com/mac/", "Mac - Apple")

# Work (Profile 1)
space("WORK", "Work", P1, "💼", "3F6FD8", "WORK-P", "WORK-U")
container("WORK-P", "WORK", ["w1", "w2", "wF1", "wF2"])
tab("w1", "WORK-P", "https://github.com/", "GitHub")
tab("w2", "WORK-P", "https://linear.app/", "Linear")
folder("wF1", "WORK-P", "Docs", ["w3", "w4"])
tab("w3", "wF1", "https://developer.apple.com/documentation/webkit", "WebKit | Apple Developer Documentation")
tab("w4", "wF1", "https://developer.mozilla.org/en-US/docs/Web/HTML", "HTML | MDN")
folder("wF2", "WORK-P", "Design", ["w5"])
tab("w5", "wF2", "https://developer.apple.com/design/human-interface-guidelines", "Human Interface Guidelines")
container("WORK-U", "WORK", ["wu1"])
tab("wu1", "WORK-U", "https://news.ycombinator.com/", "Hacker News")

# Reading (Default)
space("READ", "Reading", DEF, "📚", "1FA6A0", "READ-P", "READ-U")
container("READ-P", "READ", ["r1", "r2", "rF1"])
tab("r1", "READ-P", "https://daringfireball.net/", "Daring Fireball")
tab("r2", "READ-P", "https://arstechnica.com/", "Ars Technica")
folder("rF1", "READ-P", "Long reads", ["r3", "r4"])
tab("r3", "rF1", "https://en.wikipedia.org/wiki/Hypertext", "Hypertext - Wikipedia")
tab("r4", "rF1", "https://en.wikipedia.org/wiki/Project_Xanadu", "Project Xanadu - Wikipedia")
container("READ-U", "READ", [])

# Side (Profile 1)
space("SIDE", "Side Project", P1, "🎨", "D9468B", "SIDE-P", "SIDE-U")
container("SIDE-P", "SIDE", ["s1", "s2"])
tab("s1", "SIDE-P", "https://www.figma.com/community", "Figma Community")
tab("s2", "SIDE-P", "https://sparkle-project.org/", "Sparkle")
container("SIDE-U", "SIDE", [])

# Travel (Default)
space("TRAVEL", "Travel", DEF, "✈️", "6A55D0", "TRAV-P", "TRAV-U")
container("TRAV-P", "TRAVEL", ["t1", "tF1"])
tab("t1", "TRAV-P", "https://www.openstreetmap.org/", "OpenStreetMap")
folder("tF1", "TRAV-P", "Lisbon", ["t2", "t3"])
tab("t2", "tF1", "https://en.wikipedia.org/wiki/Lisbon", "Lisbon - Wikipedia")
tab("t3", "tF1", "https://en.wikivoyage.org/wiki/Lisbon", "Lisbon – Travel guide at Wikivoyage")
container("TRAV-U", "TRAVEL", [])

# Recipes (Default)
space("COOK", "Recipes", DEF, "🍳", "4E9A5E", "COOK-P", "COOK-U")
container("COOK-P", "COOK", ["c1", "c2"])
tab("c1", "COOK-P", "https://en.wikibooks.org/wiki/Cookbook:Table_of_Contents", "Cookbook - Wikibooks")
tab("c2", "COOK-P", "https://en.wikipedia.org/wiki/Sourdough", "Sourdough - Wikipedia")
container("COOK-U", "COOK", [])

# Favorites
topapps("TOP-D", DEF, ["f1", "f2", "f3", "f4"])
tab("f1", "TOP-D", "https://www.youtube.com/", "YouTube")
tab("f2", "TOP-D", "https://en.wikipedia.org/", "Wikipedia")
tab("f3", "TOP-D", "https://www.reddit.com/", "Reddit")
tab("f4", "TOP-D", "https://www.apple.com/", "Apple")
topapps("TOP-1", P1, ["f5", "f6", "f7"])
tab("f5", "TOP-1", "https://github.com/", "GitHub")
tab("f6", "TOP-1", "https://www.notion.com/", "Notion")
tab("f7", "TOP-1", "https://www.figma.com/", "Figma")

root = {"version": 1, "sidebar": {"containers": [
    {"global": {}},
    {"spaces": [x for s in spaces for x in s],
     "items": [x for i in items for x in i],
     "topAppsContainerIDs": [DEF, "TOP-D", P1, "TOP-1"]}]},
    "firebaseSyncState": {}, "sidebarSyncState": {}}
json.dump(root, open(os.path.join(out, "StorableSidebar.json"), "w"), ensure_ascii=False)
ls = {"profile": {"info_cache": {"Default": {"name": "Personal", "is_using_default_name": False},
                                 "Profile 1": {"name": "Work", "is_using_default_name": False}}}}
json.dump(ls, open(os.path.join(out, "User Data", "Local State"), "w"))

# Small fake Chromium History per profile (public URLs only).
def chromium(t): return int((t + 11644473600) * 1_000_000)
now = time.time()
for prof, urls in [("Default", ["https://en.wikipedia.org/wiki/Hypertext", "https://www.theverge.com/", "https://arstechnica.com/", "https://en.wikipedia.org/wiki/Lisbon"]),
                   ("Profile 1", ["https://github.com/", "https://developer.apple.com/documentation/webkit", "https://news.ycombinator.com/"])]:
    p = os.path.join(out, "User Data", prof, "History")
    if os.path.exists(p): os.remove(p)
    db = sqlite3.connect(p)
    db.executescript("""CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
    INSERT INTO meta VALUES('version','70');
    CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR,
        visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL,
        last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
    CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL,
        visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL);""")
    for i, u in enumerate(urls, 1):
        db.execute("INSERT INTO urls(id,url,title,last_visit_time) VALUES(?,?,?,0)", (i, u, ""))
        for d in (1, 3, 8):
            db.execute("INSERT INTO visits(url,visit_time,transition) VALUES(?,?,0)", (i, chromium(now - d*86400 - i*600)))
    db.commit(); db.close()
print("ok", len(spaces), "spaces", len(items), "items")
