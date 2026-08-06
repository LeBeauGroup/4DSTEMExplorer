#!/bin/bash
#
# collect.sh — refresh the third-party licence texts and the file the app ships.
#
# The app statically links HDF5 and libaec, so their BSD licences require their
# copyright notices to travel with the binary. Run this after upgrading either
# library, and commit the result:
#
#   ./ThirdPartyLicenses/collect.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HDF5_PREFIX="${HDF5_PREFIX:-/opt/homebrew/opt/hdf5}"
LIBAEC_PREFIX="${LIBAEC_PREFIX:-/opt/homebrew/opt/libaec}"
OUTPUT="$HERE/../4DSTEM Explorer/THIRD-PARTY-LICENSES.txt"

version_of() {
    # The keg path carries the version: .../Cellar/<name>/<version>
    local resolved
    resolved="$(cd "$1" && pwd -P)"
    basename "$resolved"
}

find_licence() {
    local prefix="$1"
    for candidate in LICENSE LICENSE.txt COPYING COPYING.txt share/LICENSE; do
        if [ -f "$prefix/$candidate" ]; then echo "$prefix/$candidate"; return 0; fi
    done
    return 1
}

HDF5_LICENCE="$(find_licence "$HDF5_PREFIX")" || {
    echo "error: no licence file under $HDF5_PREFIX" >&2; exit 1; }
LIBAEC_LICENCE="$(find_licence "$LIBAEC_PREFIX")" || {
    echo "error: no licence file under $LIBAEC_PREFIX" >&2; exit 1; }

cp "$HDF5_LICENCE" "$HERE/HDF5-LICENSE.txt"
cp "$LIBAEC_LICENCE" "$HERE/libaec-LICENSE.txt"

HDF5_VERSION="$(version_of "$HDF5_PREFIX")"
LIBAEC_VERSION="$(version_of "$LIBAEC_PREFIX")"

{
    cat <<HEADER
Third-party software in 4DSTEM Explorer
======================================

4DSTEM Explorer is distributed under the MIT licence; see LICENSE at the root of
the source tree.

The application links the libraries below. HDF5 and libaec are linked
statically, so their code is part of the application binary and their licences
require these notices to accompany it. zlib is used through the copy that ships
with macOS at /usr/lib/libz.1.dylib and is not redistributed here.

Refresh this file with ThirdPartyLicenses/collect.sh after upgrading a library.

HEADER

    # Built with printf so the columns line up whatever the version strings are.
    printf '  %-10s %-9s %-18s %s\n' "HDF5" "$HDF5_VERSION" "statically linked" "3-clause BSD"
    printf '  %-10s %-9s %-18s %s\n' "libaec" "$LIBAEC_VERSION" "statically linked" "2-clause BSD"
    printf '  %-10s %-9s %-18s %s\n' "" "" "" "(provides libsz, the SZIP codec HDF5 calls)"
    printf '  %-10s %-9s %-18s %s\n' "HDF5Kit" "" "source, vendored" "MIT"
    printf '  %-10s %-9s %-18s %s\n' "" "" "" "see 4DSTEM Explorer/HDF5Kit/LICENSE"
    echo

    echo "-------------------------------------------------------------------------------"
    echo "HDF5 $HDF5_VERSION"
    echo "-------------------------------------------------------------------------------"
    echo
    cat "$HERE/HDF5-LICENSE.txt"
    echo
    echo "-------------------------------------------------------------------------------"
    echo "libaec $LIBAEC_VERSION"
    echo "-------------------------------------------------------------------------------"
    echo
    cat "$HERE/libaec-LICENSE.txt"
    echo
    echo "-------------------------------------------------------------------------------"
    echo "HDF5Kit"
    echo "-------------------------------------------------------------------------------"
    echo
    cat "$HERE/../4DSTEM Explorer/HDF5Kit/LICENSE"
} > "$OUTPUT"

echo "wrote $(basename "$OUTPUT") — HDF5 $HDF5_VERSION, libaec $LIBAEC_VERSION, $(wc -l < "$OUTPUT" | tr -d ' ') lines"
