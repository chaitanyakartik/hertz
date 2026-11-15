#!/bin/sh
# Build Hertz.app with the Command Line Tools (no Xcode needed).
#   sh build.sh            build + install to ~/Applications + relaunch
#   sh build.sh check      build, run the self-test and render panel snapshots into build/
#   sh build.sh release    public build (never personal/), universal arm64 + x86_64, zipped to build/Hertz.zip
#   sh build.sh record     public build, then record the panel to build/record/ (hertz.mp4, hertz.gif)
#
# personal/ (gitignored) adds your own mixes to local builds: personal/Personal.swift lists them and
# personal/tracks.py tells tools/make_loops.py how to build their loops.
set -e
cd "$(dirname "$0")"
MODE="$1"
APP=build/Hertz.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

IDS="sharp brown lofi rain pink"
SRCS=$(ls Sources/*.swift)
if [ -f personal/Personal.swift ] && [ "$MODE" != release ] && [ "$MODE" != record ]; then
  IDS="$IDS $(grep -o 'id: "[a-z0-9]*"' personal/Personal.swift | cut -d'"' -f2 | tr '\n' ' ')"
  SRCS="$(ls Sources/*.swift | grep -v '/Personal.swift$') personal/Personal.swift"
fi

# The mixes are loop files (gitignored, rebuilt by tools/make_loops.py). No loop, no build.
for id in $IDS; do
  f="audio/loops/$id.caf"
  [ -f "$f" ] || { echo "missing $f: run /usr/bin/python3 tools/make_loops.py" >&2; exit 1; }
  cp "$f" "$APP/Contents/Resources/"
done

ARCHS="arm64"
[ "$MODE" = release ] && ARCHS="arm64 x86_64"
APPEX="$APP/Contents/PlugIns/HertzWidget.appex"
mkdir -p "$APPEX/Contents/MacOS" build/obj
for a in $ARCHS; do
  swiftc -O -swift-version 5 -target $a-apple-macos14.0 $SRCS -o build/obj/Hertz-$a
  # Widget extension, built by hand (no Xcode): a sandboxed .appex inside Contents/PlugIns.
  swiftc -O -swift-version 5 -target $a-apple-macos14.0 -parse-as-library -application-extension \
    Widget/HertzWidget.swift Sources/Shared.swift -o build/obj/HertzWidget-$a
done
lipo -create build/obj/Hertz-* -output "$APP/Contents/MacOS/Hertz"
lipo -create build/obj/HertzWidget-* -output "$APPEX/Contents/MacOS/HertzWidget"
rm -rf build/obj
cp Widget/Info.plist "$APPEX/Contents/"
cp Info.plist "$APP/Contents/"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
"$APP/Contents/MacOS/Hertz" --icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signed (no Apple Developer ID). Inside-out: the extension keeps its own entitlements,
# then the app is sealed around it.
codesign --force -s - --entitlements Widget/HertzWidget.entitlements "$APPEX"
codesign --force -s - "$APP"
codesign --verify --deep --strict "$APP"

case "$MODE" in
  check)
    "$APP/Contents/MacOS/Hertz" --selftest
    "$APP/Contents/MacOS/Hertz" --snapshot build
    exit 0 ;;
  release)
    rm -f build/Hertz.zip
    ditto -c -k --norsrc --noextattr --keepParent "$APP" build/Hertz.zip
    lipo -archs "$APP/Contents/MacOS/Hertz"
    echo "built build/Hertz.zip ($(du -h build/Hertz.zip | cut -f1))"
    exit 0 ;;
  record)
    rm -rf build/record && mkdir -p build/record/frames
    # The spectrum reads the app's own mixer, so the recording works with the Mac's output muted.
    WAS_MUTED=$(osascript -e 'output muted of (get volume settings)')
    osascript -e 'set volume output muted true'
    "$APP/Contents/MacOS/Hertz" --record build/record/frames || true
    osascript -e "set volume output muted $WAS_MUTED"
    ffmpeg -v error -y -framerate 30 -i build/record/frames/%05d.png -c:v libx264 -pix_fmt yuv420p -crf 16 \
      -vf "pad=ceil(iw/2)*2:ceil(ih/2)*2" build/record/hertz.mp4
    ffmpeg -v error -y -i build/record/hertz.mp4 -vf "fps=20,scale=420:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=none" build/record/hertz.gif
    rm -rf build/record/frames
    ls -lh build/record
    exit 0 ;;
esac

pkill -x Hertz 2>/dev/null || true; pkill -x Lull 2>/dev/null || true
while pgrep -x Hertz >/dev/null || pgrep -x Lull >/dev/null; do sleep 0.2; done
mkdir -p ~/Applications
rm -rf ~/Applications/Hertz.app ~/Applications/Lull.app   # Lull.app: the old name
cp -R "$APP" ~/Applications/
open ~/Applications/Hertz.app || { sleep 1; open ~/Applications/Hertz.app; }
pluginkit -a ~/Applications/Hertz.app/Contents/PlugIns/HertzWidget.appex 2>/dev/null || true
echo "installed ~/Applications/Hertz.app"
