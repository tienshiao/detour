#!/bin/zsh
# usage: demo.sh wallpaper <RRGGBB> [displayID] | demo.sh wallpaper-restore
#
# Wallpaper: macOS applies setDesktopImageURL to every display and Space, not
# just the capture display (it replaced the user's Aerial on all desktops in
# the first TASK-110 session). So `wallpaper` snapshots the wallpaper store
# first, and refuses to run without that snapshot; `wallpaper-restore` puts
# the snapshot back and restarts WallpaperAgent. Run it as soon as capturing
# is done; it also reverts any wallpaper change made by hand in between.
# The snapshot and the compiled helper live in $CAPTURE_STATE (default
# ~/Library/Caches/detour-capture), never in the repository.
setopt extendedglob
D=${0:A:h}
STATE=${CAPTURE_STATE:-$HOME/Library/Caches/detour-capture}
STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
BACKUP=$STATE/wallpaper-backup.plist
mkdir -p $STATE
case $1 in
  wallpaper)
    [[ $2 == [0-9A-Fa-f](#c6) ]] || { echo "usage: demo.sh wallpaper <RRGGBB> [displayID]"; exit 2; }
    # Keep the FIRST snapshot: a second `wallpaper` must not overwrite the
    # user's original with the already-changed store.
    [ -f $BACKUP ] || cp "$STORE" $BACKUP || { echo "could not back up $STORE"; exit 1; }
    [ -x $STATE/wallpaper ] && [ $STATE/wallpaper -nt $D/wallpaper.swift ] \
      || swiftc -O $D/wallpaper.swift -o $STATE/wallpaper || exit 1
    $STATE/wallpaper $2 $STATE/wallpaper-$2.png $3 || exit 1
    echo "wallpaper store saved to $BACKUP; run 'demo.sh wallpaper-restore' when done" ;;
  wallpaper-restore)
    [ -f $BACKUP ] || { echo "no wallpaper backup in $STATE; nothing to restore"; exit 1; }
    # Keep the snapshot unless it went back: it is the only copy of the
    # user's wallpaper.
    cp $BACKUP "$STORE" || { echo "could not restore $STORE; the snapshot stays in $BACKUP"; exit 1; }
    killall WallpaperAgent 2>/dev/null
    rm $BACKUP && echo "wallpaper restored" ;;
  *) echo "unknown: $1"; exit 1 ;;
esac
