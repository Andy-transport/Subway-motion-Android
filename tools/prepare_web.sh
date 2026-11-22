#!/bin/bash
# Fetch the web core from the (public) Subway-motion repo, build its
# self-contained offline page exactly like the iOS build does, strip the
# Apple-only features, and copy the result into assets/web/.
set -e
cd "$(dirname "$0")/.."

SRC="${SUBWAY_MOTION_DIR:-/tmp/Subway-motion}"
# Android is a test build (1.0.0test3) and tracks the iOS TEST branch
# (user, 2026-11-22: the Android side syncs the iOS test version's
# updates - Structure tab, second-round station diagrams, second
# Douyin author). Set SUBWAY_MOTION_BRANCH=main to build from the
# formal line again.
BRANCH="${SUBWAY_MOTION_BRANCH:-test/structure}"
if [ ! -d "$SRC/web" ]; then
  git clone --depth 1 --branch "$BRANCH" https://github.com/Andy-transport/Subway-motion.git "$SRC"
fi

(cd "$SRC/web" && python3 build_offline.py)

mkdir -p assets/web
cp "$SRC/web/offline/index.html" assets/web/index.html
cp "$SRC/web/offline/vue.global.prod.js" assets/web/
cp "$SRC/web/offline/hammer.min.js" assets/web/
cp "$SRC/web/offline/svg-pan-zoom.js" assets/web/
cp "$SRC/web/offline/MTR2.8.0.pdf" assets/web/
# trains.json is fetched relative to the page by the web core; its first
# fallback is the iOS repo's raw file, so bundling it keeps Android fully
# offline too.
cp "$SRC/web/trains.json" assets/web/trains.json

python3 tools/strip_apple_features.py assets/web/index.html
ls -lh assets/web/
