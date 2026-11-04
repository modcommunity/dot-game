#!/usr/bin/env bash
# One phone-size frame (844x390, touch on) of a game's real client, HUD and menu built, written to screenshots/phone.png.
# A game's tools/phone_shot.sh execs this (gpu.sh only runs tools/*.sh):
#   exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_phone_shot.sh" "$@"
#
#   tools/phone_shot.sh                              main scene, touch on
#   tools/phone_shot.sh --scene=res://game/arena.tscn --out=res://screenshots/a.png --set=map=dm_box
#   RESOLUTION=1280x720 tools/phone_shot.sh --size=1280x720 --no-touch
#   MOVIE=1 tools/phone_shot.sh                      under --write-movie, as the filmstrip tools run
#   RENDERER=gl_compatibility ...                    a 3D map in Forward+ on llvmpipe can pass the 2.5 GB heavy cap and be OOM-killed
# Needs xvfb: --headless gives a null renderer and a 64 x 64 viewport. Options: see dot_game_phone_shot.gd.
set -euo pipefail
cd "$(dirname "$0")/../../.."
args=()
touch=--touch
for a in "$@"; do
  if [[ $a == --no-touch ]]; then touch=; else args+=("$a"); fi
done
res=${RESOLUTION:-844x390}
movie=()
if [[ ${MOVIE:-0} == 1 ]]; then
  movie=(--write-movie "$(mktemp -u /tmp/phone_shot_XXXXXX.avi)" --fixed-fps 30)
fi
exec xvfb-run -a -s "-screen 0 ${res}x24" godot --path . --resolution "$res" "${movie[@]}" ${RENDERER:+--rendering-method "$RENDERER"} \
  --script res://addons/dot_game/tools/dot_game_phone_shot.gd -- $touch "${args[@]}"
