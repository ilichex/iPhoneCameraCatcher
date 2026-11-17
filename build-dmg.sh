#!/bin/zsh
set -euo pipefail

cd -- "${0:A:h}"
./build.sh

staging="$(mktemp -d "$PWD/.build/dmg.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
ditto "dist/iPhone Camera Catcher.app" "$staging/iPhone Camera Catcher.app"
ln -s /Applications "$staging/Applications"

build_arch="${BUILD_ARCH:-$(uname -m)}"
dmg="$PWD/dist/iPhoneCameraCatcher-macOS-$build_arch.dmg"
hdiutil create -ov -volname "iPhone Camera Catcher" -srcfolder "$staging" -format UDZO "$dmg"
hdiutil verify "$dmg"
