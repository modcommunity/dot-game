#!/usr/bin/env bash
# Records one clip of tools/filmstrip_scenarios.json with --write-movie at a fixed frame rate (the game's
# tools/filmstrip_capture.gd) and makes its contact sheet. Needs a display: dot_game_filmstrip.sh runs it on a GPU box.
#   dot_game_filmstrip_run.sh <clip> [fps]
set -euo pipefail
cd "$(dirname "$0")/../../.."
clip=${1:?clip}; fps=${2:-30}
out=screenshots/filmstrip
mkdir -p "$out"
log=$out/$clip.log
timeout 240 xvfb-run -a godot --path . --resolution 640x480 --fixed-fps "$fps" \
  --write-movie "$out/$clip.avi" --script res://tools/filmstrip_capture.gd -- "$clip" > "$log" 2>&1 || true
grep -E "^(clip |PASS|FAIL|SKIP|SCRIPT ERROR|ERROR)" "$log" | head -n 30
# A capture that has a lead-in (cover, settle) prints its first and last clip frame so the movie is cut to the clip.
read -r first count < <(sed -n 's/^FILMSTRIP_CLIP start_frame=\([0-9]*\) frames=\([0-9]*\)/\1 \2/p' "$log")
if [[ -n ${first:-} ]]; then
  ffmpeg -v error -y -i "$out/$clip.avi" -vf "select=gte(n\\,$first),setpts=N/(FRAME_RATE*TB)" -vsync passthrough -frames:v "$count" -c:v mjpeg -q:v 3 "$out/$clip.cut.avi"
  mv "$out/$clip.cut.avi" "$out/$clip.avi"
fi
bash addons/dot_core/tools/dot_filmstrip.sh "$out/$clip.avi" "$out/$clip" --views tp
