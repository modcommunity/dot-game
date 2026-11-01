#!/usr/bin/env bash
# Plays the clips of the game's tools/filmstrip_scenarios.json on a GPU box (xvfb, never the desktop session) and brings
# back screenshots/filmstrip/<clip>_sheet.png, <clip>.mp4 and <clip>_report.txt. A game's tools/filmstrip.sh execs this.
#   tools/filmstrip.sh [clip...]     # default: every clip
# Needs a tools/filmstrip_run.sh in the game (gpu.sh only runs tools/*.sh): exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_filmstrip_run.sh" "$@"
#   GPU_SHOT_BOXES=staging FPS=30 tools/filmstrip.sh walk
set -euo pipefail
cd "$(dirname "$0")/../../.."
out=screenshots/filmstrip
mkdir -p "$out"
proj=$(basename "$PWD")
clips=("$@")
[[ ${#clips[@]} -gt 0 ]] || mapfile -t clips < <(python3 -c 'import json;print("\n".join(c["name"] for c in json.load(open("tools/filmstrip_scenarios.json"))["clips"]))')
box=${GPU_SHOT_BOXES:-staging02}
host=gamedev@${box%%[ ,]*}.deacon.internal
for clip in "${clips[@]}"; do
  GPU_SHOT_BOXES=$box ../gpu.sh shot "$proj" tools/filmstrip_run.sh "$clip" "${FPS:-30}"
  rsync -az -e "ssh -i ${GPU_KEY:-$HOME/.ssh/gpu-laptop} -o BatchMode=yes" \
    "$host:gpu/shot/$proj/$out/$clip.mp4" "$host:gpu/shot/$proj/$out/${clip}_sheet.png" "$host:gpu/shot/$proj/$out/${clip}_report.txt" "$out/" || true  # no report without metrics
done
echo "sheets in $out/"
