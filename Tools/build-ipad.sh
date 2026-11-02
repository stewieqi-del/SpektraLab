#!/usr/bin/env bash
#
#  Tools/build-ipad.sh -- build SpektraPad.app for a real device from WSL,
#  with xtool, and print how to install it. Run it inside WSL:
#
#      bash Tools/build-ipad.sh                 # debug, unsigned
#      bash Tools/build-ipad.sh -c release --sign --ipa
#
#  Why this script exists rather than calling xtool directly: xtool builds the
#  *current directory*, and the working tree lives on a Windows drive that WSL
#  reaches through /mnt, where SwiftPM's file watching and case sensitivity
#  both misbehave. So the tree is synced into the Linux filesystem first --
#  the same shape `D:\Core AI Keyboard\Tools\build.sh` uses.
#
#  The two Metal libraries are inputs here, not products: `metal` and
#  `metallib` are Mach-O binaries that ship inside Xcode and cannot execute
#  under WSL ("Exec format error"). They are produced once -- by the
#  `ipad-metallib` workflow on a macOS runner, or on a Mac -- and staged into
#  `modern_UI/Spektrafilm/SpektraPadResources/` (`Tools/fetch-metallibs.sh`
#  downloads the published pair). This script refuses to start without them,
#  because the failure they cause at runtime (a black canvas, or "no engine")
#  is much further from the cause.

set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_root="$(cd -- "$here/.." && pwd)"
build_root="${SPEKTRAFILM_PAD_BUILD_ROOT:-$HOME/Projects/SpektraPad}"
resources="$source_root/modern_UI/Spektrafilm/SpektraPadResources"

usage() {
    sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^#  \{0,1\}//'
    cat <<'EOF'

Options:
  -c, --configuration debug|release   SwiftPM configuration (default: debug)
      --sign                          Codesign the app (needs `xtool auth`)
      --ipa                           Emit a .ipa instead of a .app
  -h, --help                          This text
EOF
}

configuration=debug
sign=0
ipa=0

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--configuration) configuration="${2:-}"; shift 2 ;;
        --sign) sign=1; shift ;;
        --ipa) ipa=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "build-ipad.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

case "$configuration" in
    debug|release) ;;
    *) echo "build-ipad.sh: configuration must be debug or release" >&2; exit 2 ;;
esac

missing=0
for required in \
    "$resources/Resources/engine/spektrafilm_constants.bin" \
    "$resources/Resources/engine/spektrafilm.metallib" \
    "$resources/default.metallib"
do
    if [ ! -f "$required" ]; then
        echo "build-ipad.sh: missing ${required#"$source_root/"}" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    cat >&2 <<'EOF'

The Metal libraries are built with Apple's compiler, which does not run here.
Two ways to get them, both once:

  * no Mac: let the repository's own workflow build them (it runs on a macOS
    runner for every push to `ipad-port`), then fetch the published assets:

        bash Tools/fetch-metallibs.sh

  * on a Mac:

        engine/build.sh ipad        # -> engine/resources, then staged by its bundle step
        Tools/build-metallib.sh     # -> SpektraPadResources/default.metallib (canvas)

Everything else in this build is cross-compiled here: Swift, the C++20 engine,
linking and signing.
EOF
    exit 1
fi

mkdir -p "$build_root"

# The staged resources are a build product (~25 MB of constants, LUTs, covers
# and the two metallibs). Excluded from the tree sync and copied afterwards so
# that `--delete` can never remove the metallibs this script just required.
rsync -a --delete \
    --exclude '.git' \
    --exclude 'build' \
    --exclude '.build' \
    --exclude 'DerivedData' \
    --exclude 'SpektraPadResources' \
    --exclude '.swiftpm' \
    "$source_root/" "$build_root/"

rsync -a --delete "$resources/" "$build_root/modern_UI/Spektrafilm/SpektraPadResources/"

cd "$build_root"

# A SwiftPM build writes `.build`; keeping it inside the synced copy means the
# second build is incremental. `--delete` above leaves it alone because it is
# excluded from the sync.
args=(dev build --configuration "$configuration")
[ "$sign" -eq 1 ] && args+=(--sign)
[ "$ipa" -eq 1 ] && args+=(--ipa)

echo "build-ipad.sh: ${SPEKTRAFILM_XTOOL:-xtool} ${args[*]} (in $build_root)"
"${SPEKTRAFILM_XTOOL:-xtool}" "${args[@]}"

echo
echo "Next, with the device plugged in and its cable trusted:"
echo "  node <xtool checkout>/Tools/apple-usb-relay.mjs &   # or run inside WSL"
echo "  export USBMUXD_SOCKET_ADDRESS=\$(ip route show default | awk '{print \$3}'):27015"
echo "  xtool devices"
echo "  xtool install <path to SpektraPad.app>"
echo "  xtool launch com.hanze.filmify.pad"
