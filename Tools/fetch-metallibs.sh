#!/usr/bin/env bash
#
# Fetch the two Metal libraries for the iPad port.
#
# Why this exists
# ---------------
# `metal` is a Mach-O binary, so a Windows + WSL machine cannot compile a
# metallib even though it can compile and sign everything else (see
# PORT-IOS.md). The libraries are therefore built once on a macOS runner by
# `.github/workflows/ipad-metallib.yml` and published as flat release assets,
# which are public, so this script needs no token.
#
#   default.metallib                the canvas shader  (Spektrafilm/Canvas/Shaders.metal)
#   spektrafilm.metallib            the engine kernels  (engine/src/shaders/*.metal)
#
# Both are stamped for the platform that built them; a macOS metallib will not
# load on iOS ("compiled for a different platform"), which is why the release is
# built with `-sdk iphoneos` and not reused from the Mac app.
#
# Usage
#   Tools/fetch-metallibs.sh                 # into SpektraPadResources/
#   SPEKTRAFILM_PAD_RELEASE_REPO=me/fork Tools/fetch-metallibs.sh
#
# Run `Tools/build-ipad.sh` afterwards; it refuses to package without these.

set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/.." && pwd)
out="$root/modern_UI/Spektrafilm/SpektraPadResources"

repo=${SPEKTRAFILM_PAD_RELEASE_REPO:-stewieqi-del/SpektraLab}
tag=${SPEKTRAFILM_PAD_RELEASE_TAG:-ipad-metallib}
base="https://github.com/$repo/releases/download/$tag"

dl=${SPEKTRAFILM_PAD_DOWNLOADER:-}
if [[ -z "$dl" ]]; then
  for candidate in curl wget; do
    if command -v "$candidate" >/dev/null 2>&1; then dl=$candidate; break; fi
  done
fi
[[ -n "$dl" ]] || { echo "fetch-metallibs: neither curl nor wget is installed" >&2; exit 1; }

fetch() {
  local name=$1 dest=$2 tmp
  tmp=$(mktemp)
  echo "fetch      $name"
  case "$dl" in
    curl) curl -fsSL --retry 3 -o "$tmp" "$base/$name" ;;
    *)    wget -q -O "$tmp" "$base/$name" ;;
  esac
  # A Metal library starts with the four bytes "MTLB". Checking costs nothing
  # and catches the common failure where a release exists but its asset is an
  # HTML error page — the app would otherwise install and abort at launch.
  if [[ $(head -c 4 "$tmp") != "MTLB" ]]; then
    echo "fetch-metallibs: $name is not a Metal library (no MTLB magic)" >&2
    rm -f "$tmp"
    exit 1
  fi
  mkdir -p "$(dirname -- "$dest")"
  mv "$tmp" "$dest"
  echo "ok         $dest ($(wc -c <"$dest") bytes)"
}

fetch default.metallib "$out/default.metallib"
fetch spektrafilm.metallib "$out/Resources/engine/spektrafilm.metallib"

echo
echo "Metallibs staged under $out."
echo "Next: Tools/build-ipad.sh -c debug [--sign] [--ipa]"
