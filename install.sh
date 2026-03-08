#!/bin/sh
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"

case "$(uname -s)" in
    Darwin)
        DEST="$HOME/Library/Application Support/Aseprite/extensions/white-block"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        DEST="$APPDATA/Aseprite/extensions/white-block"
        ;;
    *)
        echo "Unsupported platform: $(uname -s)" >&2
        exit 1
        ;;
esac

rm -rf "$DEST"
mkdir -p "$DEST"

for f in "$SRC"/*.lua "$SRC"/*.json; do
    [ -e "$f" ] || continue
    ln -s "$f" "$DEST/$(basename "$f")"
done

echo "Installed to: $DEST"
