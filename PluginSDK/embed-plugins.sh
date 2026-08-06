#!/bin/bash
#
# embed-plugins.sh — build the bundled plugins into the app.
#
# Meant to run from an Xcode "Embed Plugins" build phase, which leaves every
# variable it needs in the environment:
#
#   ./embed-plugins.sh                 # inside Xcode: writes into the built app
#   ./embed-plugins.sh <destination>   # anywhere else: writes into <destination>
#
# Each subdirectory of Examples/ holding a plugin.conf is built with
# build-plugin.sh and dropped into the app's Contents/PlugIns. The app already
# looks there first (see PluginManager.builtInPluginsDirectory), and a plugin the
# user installs into their own plugins folder shadows a bundled one with the same
# identifier — so shipping these does not take away the ability to replace them.
#
# Three things this does that a plain loop would not:
#
#   * Signs with the app's identity rather than ad hoc. Nested code inside a
#     signed app has to carry a signature from the same identity, or the app
#     fails to validate at launch.
#   * Builds only the architectures the app is being built for, so a debug build
#     does not pay for a universal plugin it will not run.
#   * Skips a plugin whose sources have not changed, because otherwise every
#     incremental build would recompile all of them.
#
set -euo pipefail

SDK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Xcode points TMPDIR somewhere the script sandbox permits; /tmp may not be.
LOG="${TMPDIR:-/tmp}/embed-plugin-$$.log"
BUILDER="$SDK_DIR/build-plugin.sh"
EXAMPLES_DIR="$SDK_DIR/Examples"

if [ ! -x "$BUILDER" ]; then
    echo "error: $BUILDER is missing or not executable" >&2
    exit 1
fi

# Destination: the argument, or the app being built.
if [ $# -ge 1 ]; then
    DESTINATION="$1"
elif [ -n "${BUILT_PRODUCTS_DIR:-}" ] && [ -n "${CONTENTS_FOLDER_PATH:-}" ]; then
    DESTINATION="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/PlugIns"
else
    echo "error: no destination given and not running inside Xcode." >&2
    echo "       usage: $(basename "$0") <destination-directory>" >&2
    exit 1
fi

mkdir -p "$DESTINATION"

# Match the app's architectures when Xcode says what they are. Outside Xcode,
# build-plugin.sh keeps its own universal default.
if [ -n "${ARCHS:-}" ]; then
    export PLUGIN_ARCHS="$ARCHS"
fi

# Nested bundles must be signed with the identity that signs the app. Xcode
# leaves the resolved identity in EXPANDED_CODE_SIGN_IDENTITY; "-" means ad hoc,
# which is also what a local unsigned build uses.
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    export PLUGIN_SIGN_IDENTITY="$EXPANDED_CODE_SIGN_IDENTITY"
fi

# Anything newer than a built bundle means it has to be rebuilt. The API source
# counts too: it is compiled into every plugin.
API_SOURCE="$SDK_DIR/FourDSTEMPluginAPI.swift"

needs_rebuild() {
    local source_dir="$1" bundle="$2" name="$3"
    local binary="$bundle/Contents/MacOS/$name"
    [ -f "$binary" ] || return 0
    [ "$BUILDER" -nt "$binary" ] && return 0
    [ "$API_SOURCE" -nt "$binary" ] && return 0
    local newer
    newer="$(find "$source_dir" -maxdepth 1 \( -name '*.swift' -o -name '*.bib' -o -name 'plugin.conf' \) -newer "$binary" -print -quit)"
    [ -n "$newer" ] && return 0
    return 1
}

BUILT=0
SKIPPED=0
FAILED=()

for SOURCE_DIR in "$EXAMPLES_DIR"/*/; do
    [ -f "$SOURCE_DIR/plugin.conf" ] || continue

    NAME="$(sed -n 's/^NAME=//p' "$SOURCE_DIR/plugin.conf" | head -1)"
    if [ -z "$NAME" ]; then
        echo "warning: $(basename "$SOURCE_DIR")/plugin.conf sets no NAME, skipping" >&2
        continue
    fi

    BUNDLE="$DESTINATION/$NAME.bundle"

    if ! needs_rebuild "$SOURCE_DIR" "$BUNDLE" "$NAME"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if "$BUILDER" "$SOURCE_DIR" "$DESTINATION" > "$LOG" 2>&1; then
        BUILT=$((BUILT + 1))
        # Surface the citation line so the build log records what shipped.
        grep -E '^  citations' "$LOG" || true
        echo "  embedded        : $NAME.bundle"
    else
        FAILED+=("$NAME")
        # Prefix with the filename so Xcode shows it in the issue navigator.
        echo "$SOURCE_DIR/plugin.conf:1: error: $NAME failed to build" >&2
        sed 's/^/    /' "$LOG" >&2
    fi
    rm -f "$LOG"
done

echo "Plugins: $BUILT built, $SKIPPED unchanged, ${#FAILED[@]} failed -> $DESTINATION"

# A plugin that silently fails to ship is worse than a build that stops, since
# the app would launch looking complete and simply be missing a feature.
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "error: ${#FAILED[@]} plugin(s) did not build: ${FAILED[*]}" >&2
    exit 1
fi
