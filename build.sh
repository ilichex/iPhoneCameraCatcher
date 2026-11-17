#!/bin/zsh
set -euo pipefail

cd -- "${0:A:h}"
app="$PWD/dist/iPhone Camera Catcher.app"
mkdir -p .build "$app/Contents/MacOS"
swiftc -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$PWD/.build/modules" \
  -parse-as-library -O -whole-module-optimization Sources/IPhoneCameraCatcher/*.swift \
  -o "$app/Contents/MacOS/IPhoneCameraCatcher"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf 'Приложение: %s\n' "$app"
