#!/bin/bash
# Downloads the bipbop_16x9 low variant and its alternate audio rendition (byte-range segments of
# one main.ts each) into src/ for gen.py.
set -e
cd "$(dirname "$0")"; B=https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9
for d in gear1 alternate_audio_aac; do
  mkdir -p src/$d
  curl -sf -m 60 -o src/$d/prog_index.m3u8 $B/$d/prog_index.m3u8
  curl -sf -m 600 -o src/$d/main.ts $B/$d/main.ts
done
echo "sources in $(pwd)/src"
