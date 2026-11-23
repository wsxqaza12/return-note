#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $(uname -s) != Darwin ]]; then
    printf '%s\n' '請在 macOS 上建置。' >&2
    exit 1
fi

mode=${1:-universal}
case "$mode" in
    universal) arches=(arm64 x86_64); archive=return-note-macos-universal.zip ;;
    native) arches=("$(uname -m)"); archive=return-note-macos-$(uname -m).zip ;;
    *) printf '%s\n' "用法：bash scripts/build-macos.sh [universal|native]" >&2; exit 2 ;;
esac
export MACOSX_DEPLOYMENT_TARGET=13.0
if [[ -n ${CARGO_TARGET_DIR:-} ]]; then
    case "$CARGO_TARGET_DIR" in /*) ;; *) CARGO_TARGET_DIR="$PWD/$CARGO_TARGET_DIR" ;; esac
fi
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$PWD/target"}
version=$(cargo metadata --locked --offline --no-deps --format-version 1 | /usr/bin/plutil -extract packages.0.version raw -o - -)
mkdir -p dist
build=$(mktemp -d "${TMPDIR:-/tmp}/return-note-build.XXXXXX")
trap 'rm -rf -- "$build"' EXIT
app="$build/Return Note.app"
mkdir -p "$app/Contents/Resources" "$app/Contents/MacOS"
cp macos/Info.plist "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"

# Reuse the PNG entry from the Windows icon; include all standard Retina sizes.
iconset="$build/AppIcon.iconset"
mkdir "$iconset"
/usr/bin/python3 - "$iconset" <<'PY'
from pathlib import Path
from struct import unpack_from
import sys
ico = Path('assets/app.ico').read_bytes()
entries = [unpack_from('<BBBBHHII', ico, 6 + 16*i) for i in range(unpack_from('<H', ico, 4)[0])]
_, _, _, _, _, _, length, offset = max(entries, key=lambda e: e[0] or 256)
image = ico[offset:offset+length]
assert image.startswith(b'\x89PNG\r\n\x1a\n'), 'ICO does not contain a PNG icon'
(Path(sys.argv[1]) / 'source.png').write_bytes(image)
PY
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" "$iconset/source.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    /usr/bin/sips -z "$((size*2))" "$((size*2))" "$iconset/source.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
rm "$iconset/source.png"
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

slices=()
for arch in "${arches[@]}"; do
    case "$arch" in
        arm64) rust_target=aarch64-apple-darwin ;;
        x86_64) rust_target=x86_64-apple-darwin ;;
        *) printf '%s\n' "不支援此架構：$arch" >&2; exit 2 ;;
    esac
    cargo rustc --locked --lib --release --target "$rust_target" --crate-type staticlib
    xcrun --sdk macosx swiftc -swift-version 5 -O -whole-module-optimization \
        -target "$arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" -module-name ReturnNote \
        -import-objc-header macos/include/ReturnNoteCore.h macos/Sources/*.swift \
        "$CARGO_TARGET_DIR/$rust_target/release/libreturn_note.a" -o "$build/return-note-$arch"
    slices+=("$build/return-note-$arch")
done
if [[ ${#slices[@]} -eq 1 ]]; then
    cp "${slices[0]}" "$app/Contents/MacOS/return-note"
else
    xcrun lipo -create "${slices[@]}" -output "$app/Contents/MacOS/return-note"
fi
/usr/bin/codesign --force --sign "${SIGN_IDENTITY:--}" --timestamp=none "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$build/$archive"
# Replace only outputs owned by this script, after the staged build verifies.
rm -rf -- "$PWD/dist/Return Note.app"
/usr/bin/ditto "$app" 'dist/Return Note.app'
mv -f "$build/$archive" "dist/$archive"
printf '完成：%s/dist/%s\n' "$PWD" "$archive"
