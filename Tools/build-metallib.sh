#!/usr/bin/env bash
#
#  Tools/build-metallib.sh -- compile the canvas shader
#  (`Spektrafilm/Canvas/Shaders.metal`) into the `default.metallib` that
#  `Canvas/Renderer.swift` loads through
#  `device.makeDefaultLibrary(bundle: Bundle(for: Renderer.self))`.
#
#  Runs on macOS only, for the same reason `engine/build.sh ipad` does: the
#  Metal compiler ships inside Xcode as a Mach-O binary. The iPad build itself
#  is cross-compiled from WSL; only the two `.metallib` files need a Mac (or a
#  macOS CI runner). See PORT-IOS.md, "Metal".
#
#  The engine's own library is not built here -- `engine/build.sh ipad` does it
#  from `engine/src/shaders/*.metal` and stages it into
#  `SpektraPadResources/Resources/engine/spektrafilm.metallib`.
#
#      Tools/build-metallib.sh
#
#  Output: modern_UI/Spektrafilm/SpektraPadResources/default.metallib

set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$here/.." && pwd)"
source_file="$repo_root/modern_UI/Spektrafilm/Spektrafilm/Canvas/Shaders.metal"
out_dir="$repo_root/modern_UI/Spektrafilm/SpektraPadResources"
air="$out_dir/Canvas.air"
metallib="$out_dir/default.metallib"
ios_min="${SPEKTRAFILM_IOS_MIN:-17.0}"

# The Mac's app target compiles this shader with `MTL_FAST_MATH = YES`, so the
# canvas matches the desktop look only if fast math is used here too. The
# *engine* kernels are the opposite case and are compiled with safe math by
# `engine/build.sh ipad` -- that asymmetry is deliberate and documented in
# AGENTS.md ("do not drop -fmetal-math-mode=safe").
math_flags=(-fmetal-math-mode=fast -fmetal-math-fp32-functions=fast)
# `air64`, not `arm64` -- see the note in `engine/build.sh`: the Metal frontend
# in Xcode 26.6's downloadable toolchain aborts on any target triple that names
# `arm64` for iOS, and compiles the same shader when it names `air64`.
target=(-target "air64-apple-ios$ios_min")

if [ ! -f "$source_file" ]; then
    echo "build-metallib.sh: missing $source_file" >&2
    exit 1
fi

mkdir -p "$out_dir"

echo "canvas     -> $metallib"
xcrun -sdk iphoneos metal "${math_flags[@]}" "${target[@]}" -Werror -c "$source_file" -o "$air"
xcrun -sdk iphoneos metallib "$air" -o "$metallib"
rm -f "$air"

# A metallib carries the platform it was compiled for; loading a macOS one on
# an iOS device fails at `makeLibrary`, and the message does not say so. Check
# the stamp the same way `engine/build.sh` checks its own.
major="$(xcrun -sdk iphoneos metal-readobj --file-headers "$metallib" \
    | awk '/PlatformMajor:/ {print $2; exit}')"
if [ "$major" != "${ios_min%%.*}" ]; then
    echo "build-metallib.sh: ${metallib##*/} is stamped for platform $major, expected ${ios_min%%.*}" >&2
    exit 1
fi

echo "canvas     -> ${metallib#"$repo_root/"}"
