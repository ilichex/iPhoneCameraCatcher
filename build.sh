#!/bin/zsh
set -euo pipefail

cd -- "${0:A:h}"
app="$PWD/dist/iPhone Camera Catcher.app"
iconset="$PWD/.build/AppIcon.iconset"
mkdir -p "$iconset" "$app/Contents/MacOS" "$app/Contents/Resources"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
swiftc -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$PWD/.build/modules" \
  -parse-as-library -O -whole-module-optimization Sources/IPhoneCameraCatcher/*.swift \
  -o "$app/Contents/MacOS/IPhoneCameraCatcher"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf 'Приложение: %s\n' "$app"
