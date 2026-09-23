#!/bin/zsh
# usage: demo.sh cmd "<command>" | demo.sh shot <name> | demo.sh wid
D=${0:A:h}
case $1 in
  cmd) print -r -- "$2" >> $D/cmd ;;
  wid) grep -o 'window=[0-9]*' $D/log.txt | tail -1 | cut -d= -f2 ;;
  shot) W=$(grep -o 'window=[0-9]*' $D/log.txt | tail -1 | cut -d= -f2); screencapture -x -o -l $W $D/shots/$2.png && sips -g pixelWidth -g pixelHeight $D/shots/$2.png | tail -2 | tr '\n' ' '; echo ;;
esac
