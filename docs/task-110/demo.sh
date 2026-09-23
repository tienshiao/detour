#!/bin/zsh
# usage: demo.sh cmd "<command>" | demo.sh shot <name> | demo.sh wid
#        demo.sh wallpaper <RRGGBB> | demo.sh wallpaper-restore
#
# Wallpaper: macOS applies setDesktopImageURL to every display and Space, not
# just the capture display (it replaced the user's Aerial on all desktops in
# the first TASK-110 session). So `wallpaper` snapshots the wallpaper store
# first and the harness refuses to run without that snapshot;
# `wallpaper-restore` puts the snapshot back and restarts WallpaperAgent.
# Run it as soon as capturing is done — it also reverts any wallpaper change
# made by hand in between.
D=${0:A:h}
STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
BACKUP=$D/wallpaper-backup.plist
case $1 in
  cmd) print -r -- "$2" >> $D/cmd ;;
  wid) grep -o 'window=[0-9]*' $D/log.txt | tail -1 | cut -d= -f2 ;;
  shot) W=$(grep -o 'window=[0-9]*' $D/log.txt | tail -1 | cut -d= -f2); screencapture -x -o -l $W $D/shots/$2.png && sips -g pixelWidth -g pixelHeight $D/shots/$2.png | tail -2 | tr '\n' ' '; echo ;;
  wallpaper)
    # Keep the FIRST snapshot: a second `wallpaper` must not overwrite the
    # user's original with the already-changed store.
    [ -f $BACKUP ] || cp "$STORE" $BACKUP || { echo "could not back up $STORE"; exit 1; }
    print -r -- "wallpaper $2" >> $D/cmd
    echo "wallpaper store saved to $BACKUP — run 'demo.sh wallpaper-restore' when done" ;;
  wallpaper-restore)
    [ -f $BACKUP ] || { echo "no wallpaper backup in $D — nothing to restore"; exit 1; }
    cp $BACKUP "$STORE" && killall WallpaperAgent 2>/dev/null
    rm $BACKUP && echo "wallpaper restored" ;;
  *) echo "unknown: $1"; exit 1 ;;
esac
