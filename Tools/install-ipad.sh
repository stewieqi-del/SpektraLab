#!/usr/bin/env bash
#
#  Tools/install-ipad.sh -- install and launch SpektraPad on the attached iPad,
#  from inside WSL. Run `Tools/build-ipad.sh --sign` first; this script does not
#  build.
#
#      bash Tools/install-ipad.sh                     # newest build in $HOME/Projects/SpektraPad
#      bash Tools/install-ipad.sh path/to/SpekPad.app
#      bash Tools/install-ipad.sh path/to/SpekPad.ipa
#
#  Why the environment variable: usbmuxd inside WSL cannot see the iPad on its
#  own -- Windows owns the USB device. The relay (`apple-usb-relay.mjs` from the
#  xtool toolchain, or its Windows equivalent) forwards USB mux traffic to the
#  WSL-facing vEthernet address on port 27015, and `USBMUXD_SOCKET_ADDRESS`
#  tells `xtool`/`idevice_id` to use it instead of a local socket. The default
#  route's gateway is that vEthernet address, which is why it is derived rather
#  than hard-coded to 172.19.80.1 (that address changes when WSL restarts).

set -euo pipefail

build_root="${SPEKTRAFILM_PAD_BUILD_ROOT:-$HOME/Projects/SpektraPad}"
bundle_id="${SPEKTRAFILM_PAD_BUNDLE_ID:-com.hanze.filmify.pad}"

target="${1:-}"
if [ -z "$target" ]; then
    for candidate in "$build_root/xtool/SpekPad.app" "$build_root/xtool/SpekPad.ipa"; do
        if [ -e "$candidate" ]; then target="$candidate"; fi
    done
fi
if [ -z "$target" ] || [ ! -e "$target" ]; then
    cat >&2 <<EOF
install-ipad.sh: no build found under $build_root/xtool.
Build one first:

    Tools/build-ipad.sh -c debug --sign            # on this machine, or
    Tools/build-ipad.sh -c debug --sign --ipa
EOF
    exit 1
fi

if [ -z "${USBMUXD_SOCKET_ADDRESS:-}" ]; then
    gateway=$(ip route show default | awk '{print $3; exit}')
    if [ -z "$gateway" ]; then
        echo "install-ipad.sh: no default route; set USBMUXD_SOCKET_ADDRESS by hand" >&2
        exit 1
    fi
    export USBMUXD_SOCKET_ADDRESS="$gateway:27015"
fi

echo "install-ipad.sh: relay $USBMUXD_SOCKET_ADDRESS, target $target"
xtool devices
xtool install "$target"

# A launch that returns before the app is up is normal; the app then shows its
# boot overlay while the engine warms. If it dies here, the console log in
# Console.app (or `idevicesyslog`) carries the reason -- on a first run the
# usual cause is a Metal library that is missing or stamped for macOS.
xtool launch "$bundle_id"
