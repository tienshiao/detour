#!/bin/zsh
# encode.sh <in.mov> <out-basename> <start> <end> [crop-filter]
# Writes <out-basename>.mp4, -poster.png and -poster.webp to $CAPTURE_OUT
# (default: an out/ folder next to the input).
# - screencapture -v writes variable-frame-rate video: convert to CFR first, then crop/trim.
# - Its colours land slightly off the stills (wallpaper #F7F2EA records as 246,241,230):
#   a tone curve pinned at 0 and 1 restores the page background exactly.
# - Explicit BT.709 limited-range conversion with accurate rounding, tagged in the file.
OUT=${CAPTURE_OUT:-${1:A:h}/out}
mkdir -p $OUT
CROP=${5:+${5},}
SWS="flags=accurate_rnd+full_chroma_int"
CURVE="curves=r='0/0 0.9647/0.9686 1/1':g='0/0 0.9451/0.9490 1/1':b='0/0 0.9020/0.9176 1/1'"
ffmpeg -loglevel error -y -i $1 -an -vf "fps=30,${CROP}trim=start=${3}:end=${4},setpts=PTS-STARTPTS,scale=in_color_matrix=bt709:in_range=tv:$SWS,format=gbrp,$CURVE,scale=out_color_matrix=bt709:out_range=tv:$SWS,format=yuv420p" \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv -c:v libx264 -preset slow -crf 24 -movflags +faststart $OUT/$2.mp4
ffmpeg -loglevel error -y -i $OUT/$2.mp4 -frames:v 1 -vf "scale=in_color_matrix=bt709:in_range=tv:$SWS,format=rgb24" $OUT/$2-poster.png
cwebp -quiet -q 82 $OUT/$2-poster.png -o $OUT/$2-poster.webp
ls -la $OUT/$2.mp4 $OUT/$2-poster.webp | awk '{print $5, $9}'
