#!/usr/bin/env bash
# Turns every "<name>.seq/NNN.png" directory (DotShotSeq) under SRC into DEST/<name>.mp4 for a QA post. Quiet when there is none.
#   seq_to_mp4.sh SRC DEST [FPS]   (FPS default 8, the 16-frame / 2 s sequence)
set -uo pipefail
src=$1; dest=$2; fps=${3:-8}
mkdir -p "$dest"
find "$src" -maxdepth 2 -type d -name '*.seq' 2>/dev/null | while read -r d; do
    ls "$d"/*.png >/dev/null 2>&1 || continue
    name=$(basename "$d" .seq)
    ffmpeg -v error -y -framerate "$fps" -i "$d/%03d.png" -c:v libx264 -pix_fmt yuv420p -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -movflags +faststart "$dest/$name.mp4" || echo "seq_to_mp4: $name failed" >&2
done
exit 0
