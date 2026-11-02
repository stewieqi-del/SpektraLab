#!/bin/bash
# build.sh -- the C++ render engine, its Metal library, and the test drivers.
#
#   engine/build.sh            everything
#   engine/build.sh lib        the static library + the metallib
#   engine/build.sh dylib      the shared library the ctypes parity harness loads
#   engine/build.sh tests      the setup/schema dump drivers
#   engine/build.sh metallib   just the kernels
#   engine/build.sh ipad       the same kernels for iPadOS + the Pad bundle's resources
#
# bash, and arrays throughout, because the repository path contains a space
# ("Summer 2026") and every unquoted expansion of a path list is a build that
# works on the author's other checkout and not on this one.
#
# Two flags below are load-bearing and must not be dropped (RFC-014 §5.1 trap 1):
#
#   -fmetal-math-mode=safe
#   -fmetal-math-fp32-functions=precise
#
# Metal's offline compiler defaults to fast math, and `MTLCompileOptions`
# defaults to `MathModeFast` (measured on Xcode 26.6: `mathMode` reads 2).
# MLX -- the reference the kernels were held to float32 epsilon against --
# compiles `MathModeSafe`. Under fast math `exp` and fma contraction drift by
# up to 1.1e-5, which is past the float32 bar and silent.
#
# Setting them here is necessary but not sufficient, because a build flag is
# exactly the kind of guard that stops being checked. `spk_math_probe` in
# `shaders/probe.metal` computes `a*b - a*b`, which is *zero* under fast math
# and the fma error term under safe math, and `spk_engine_create` asserts it.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out="$here/build"
mkdir -p "$out"

CXX=${CXX:-clang++}
cxxflags=(-std=c++20 -O2 -Wall -Wextra)
includes=(-I"$here/include" -I"$here/src" -I"$here/src/core" -I"$here/third_party/metal-cpp")
# CoreText/CoreGraphics: RFC-032 §27 rasterises the edge print and the date in the
# engine. Accelerate: the mask's blur (vImage).
frameworks=(-framework Metal -framework Foundation -framework QuartzCore -framework CoreText -framework CoreGraphics -framework Accelerate)
math_flags=(-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise)
# The app's floor is macOS 15 (LSMinimumSystemVersion, MACOSX_DEPLOYMENT_TARGET
# in gen-project.py). Without this the metal compiler targets the *host* OS, and
# a metallib stamped for a newer macOS than the user's does not load -- the app
# opens and cannot render. `check_metallib_target` below fails the build if the
# stamp drifts.
MACOS_MIN=15.0
target_flags=(-mmacos-version-min="$MACOS_MIN")

sources=()
collect_sources() {
  sources=()
  local f
  # nullglob, so a directory that does not exist yet (src/gpu before the GPU
  # layer landed) contributes nothing rather than contributing the literal
  # pattern -- and so the `-f` test that would otherwise trip `set -e` on the
  # loop's last iteration is not needed at all.
  shopt -s nullglob
  for f in "$here"/src/core/*.cpp "$here"/src/gpu/*.cpp "$here"/src/pipeline/*.cpp; do
    sources+=("$f")
  done
  shopt -u nullglob
  if [[ ${#sources[@]} -eq 0 ]]; then
    echo "build.sh: no C++ sources found under $here/src" >&2
    exit 1
  fi
}

# **The metallib build is byte-reproducible**, checked 2026-09-20 by the peer
# session building the same sources three times: `014600ec...` each time. That
# makes a hash a valid provenance check — "does this artifact match that tag"
# is answerable rather than inferable, and a bundle built from a tree that has
# moved since its commit can be shown to be one. Worth keeping: the build does
# not stamp a UUID or a timestamp, and this comment is the only record of it.
check_metallib_target() {
  local major
  major=$(xcrun -sdk macosx metal-readobj --file-headers "$1" | awk '/PlatformMajor:/ {print $2; exit}')
  if [[ "$major" != "${MACOS_MIN%%.*}" ]]; then
    echo "build.sh: $1 targets macOS $major, not $MACOS_MIN -- it would not load on older Macs" >&2
    exit 1
  fi
}

build_metallib() {
  local airs=() m air
  shopt -s nullglob
  for m in "$here"/src/shaders/*.metal; do
    air="$out/$(basename "$m" .metal).air"
    xcrun -sdk macosx metal "${math_flags[@]}" "${target_flags[@]}" -Werror -c "$m" -o "$air"
    airs+=("$air")
  done
  shopt -u nullglob
  if [[ ${#airs[@]} -eq 0 ]]; then echo "no shaders yet"; return 0; fi
  xcrun -sdk macosx metallib "${airs[@]}" -o "$out/spektrafilm.metallib"
  check_metallib_target "$out/spektrafilm.metallib"
  cp "$out/spektrafilm.metallib" "$here/resources/spektrafilm.metallib"
  echo "metallib   -> $here/resources/spektrafilm.metallib"
}

objects=()
build_objects() {
  collect_sources
  objects=()
  local src obj
  for src in "${sources[@]}"; do
    obj="$out/$(basename "$src" .cpp).o"
    "$CXX" "${cxxflags[@]}" "${includes[@]}" -c "$src" -o "$obj"
    objects+=("$obj")
  done
}

build_lib() {
  build_objects
  ar rcs "$out/libspektrafilm_engine.a" "${objects[@]}"
  echo "static lib -> $out/libspektrafilm_engine.a"
}

build_dylib() {
  build_objects
  "$CXX" -dynamiclib -install_name @rpath/libspektrafilm_engine.dylib \
    "${objects[@]}" "${frameworks[@]}" -o "$out/libspektrafilm_engine.dylib"
  echo "dylib      -> $out/libspektrafilm_engine.dylib"
}

build_tests() {
  collect_sources
  local driver
  for driver in dump_setup dump_json gpu_smoke; do
    [[ -f "$here/tests/$driver.cpp" ]] || continue
    "$CXX" "${cxxflags[@]}" "${includes[@]}" -I"$here/tests" \
      "$here/tests/$driver.cpp" "${sources[@]}" "${frameworks[@]}" -o "$out/$driver"
    echo "driver     -> $out/$driver"
  done
}

# Sync the baked resources into the app's own Resources folder, which
# `Tools/gen-project.py` already ships as a folder reference -- so the engine's
# constants, profiles and metallib end up in the bundle without the project
# generator having to know about any of them.
#
# The metallib is copied rather than compiled by Xcode on purpose. The app
# target sets `MTL_FAST_MATH = YES` for its own canvas shader, and inheriting
# that for the engine's kernels is exactly RFC-014 §5.1 trap 1. Building it
# here keeps the math flags in one place, next to the reason for them.
bundle_resources() {
  local app="$here/../modern_UI/Spektrafilm/Spektrafilm/Resources/engine"
  if [[ ! -f "$here/resources/spektrafilm_constants.bin" ]]; then
    # `engine/resources/` is *tracked* in this repository, so this means the
    # checkout is damaged -- not that anything needs baking. Re-baking needs the
    # Python reference tree, which is deliberately not here; see README,
    # "Rebaking the engine resources".
    echo "build.sh: engine/resources is missing, and it is a tracked directory." >&2
    echo "    Restore it:  git checkout -- engine/resources" >&2
    exit 1
  fi
  mkdir -p "$app"
  rsync -a --delete "$here/resources/" "$app/"
  # The product's own profiles (black and white; `resources_product/NOTICE.md`)
  # go in beside spektrafilm's, because the engine opens a stock from one
  # `profiles/` directory. They are not spektrafilm's and the notice travels
  # with them. The app lists them only where `FeatureFlags.blackAndWhite` is on.
  if [[ -d "$here/resources_product/profiles" ]]; then
    cp "$here/resources_product/profiles/"*.json "$app/profiles/"
    cp "$here/resources_product/NOTICE.md" "$app/PRODUCT_PROFILES_NOTICE.md"
  fi
  local size
  size=$(du -sh "$app" | cut -f1)
  echo "bundle     -> $app ($size)"
}

# ---- iPadOS -------------------------------------------------------------
#
# The Pad target compiles the same C++ through `Tools/gen-ipad-project.py`, so
# nothing here produces a library for it: the two things it needs that the Mac
# does not are a metallib stamped for the iOS deployment target -- a macOS
# metallib does not load there, and the failure is at `newLibraryWithURL` at
# launch rather than at build time -- and its own resource folder, because the
# app that ships it is a different bundle with a different `Resources/`.
#
# The floor is iPadOS 17 for `@Observable` (`Tools/gen-ipad-project.py` says so
# too). The Pad has no long tail of older devices to carry, so the floor is the
# Swift runtime the shared model is written against.
IOS_MIN=17.0
ios_target=(-target "arm64-apple-ios$IOS_MIN")

check_ios_metallib_target() {
  local major
  major=$(xcrun -sdk iphoneos metal-readobj --file-headers "$1" | awk '/PlatformMajor:/ {print $2; exit}')
  if [[ "$major" != "${IOS_MIN%%.*}" ]]; then
    echo "build.sh: $1 targets iOS $major, not $IOS_MIN -- it would not load on older iPads" >&2
    exit 1
  fi
}

build_metallib_ios() {
  local airs=() m air
  mkdir -p "$out/ios"
  shopt -s nullglob
  for m in "$here"/src/shaders/*.metal; do
    air="$out/ios/$(basename "$m" .metal).air"
    xcrun -sdk iphoneos metal "${math_flags[@]}" "${ios_target[@]}" -Werror -c "$m" -o "$air"
    airs+=("$air")
  done
  shopt -u nullglob
  if [[ ${#airs[@]} -eq 0 ]]; then echo "no shaders yet"; return 0; fi
  xcrun -sdk iphoneos metallib "${airs[@]}" -o "$out/ios/spektrafilm.metallib"
  check_ios_metallib_target "$out/ios/spektrafilm.metallib"
  echo "metallib   -> $out/ios/spektrafilm.metallib (iOS $IOS_MIN)"
}

# Stage everything the engine opens at run time, plus the three resources the
# *app* reads from its own bundle. The macOS target gets those by shipping
# `Spektrafilm/Resources/` as a folder reference; the Pad cannot reference that
# folder without also dragging in the whole Mac app, so they are copied here and
# the Pad's folder reference is the parent.
#
# The layout is the part to keep right: the folder reference is named
# `Resources` and is copied to the bundle root, so `Bundle.main` answers
# `Resources/engine/spektrafilm_constants.bin` -- the same path
# `EngineClient.defaultResources()` looks for, and the same one the Mac gets
# under `Contents/Resources`.
pad_bundle_resources() {
  local pad="$here/../modern_UI/Spektrafilm/SpektraPadResources/Resources"
  local app="$pad/engine"
  if [[ ! -f "$here/resources/spektrafilm_constants.bin" ]]; then
    echo "build.sh: engine/resources is missing, and it is a tracked directory." >&2
    echo "    Restore it:  git checkout -- engine/resources" >&2
    exit 1
  fi
  mkdir -p "$app" "$pad"
  # The macOS metallib is excluded rather than overwritten after the copy: a
  # checkout that has also run `bundle` leaves one here, and an iPad app
  # carrying it would fail at load with a platform mismatch that looks like a
  # corrupt resource.
  rsync -a --delete --exclude 'spektrafilm.metallib' "$here/resources/" "$app/"
  cp "$out/ios/spektrafilm.metallib" "$app/spektrafilm.metallib"
  if [[ -d "$here/resources_product/profiles" ]]; then
    cp "$here/resources_product/profiles/"*.json "$app/profiles/"
    cp "$here/resources_product/NOTICE.md" "$app/PRODUCT_PROFILES_NOTICE.md"
  fi
  local src="$here/../modern_UI/Spektrafilm/Spektrafilm/Resources"
  cp "$src/StockCatalog.json" "$pad/"
  rsync -a --delete "$src/FilmCovers/" "$pad/FilmCovers/"
  rsync -a --delete "$src/Licenses/" "$pad/Licenses/"
  # The two DI-view `.cube` files travel beside an exported Digital
  # Intermediate (`CineonLUT.copyBeside`). Leaving them out would make DI export
  # fail on the Pad only -- the kind of difference nobody finds until they use
  # it, on the device, with no Mac to compare against.
  rsync -a --delete "$src/DI/" "$pad/DI/"
  local size
  size=$(du -sh "$pad" | cut -f1)
  echo "pad bundle -> $pad ($size)"
}

ipad() { build_metallib_ios; pad_bundle_resources; }

case "${1:-all}" in
  metallib) build_metallib ;;
  lib)      build_metallib; build_lib ;;
  dylib)    build_metallib; build_dylib ;;
  tests)    build_tests ;;
  bundle)   build_metallib; bundle_resources ;;
  ipad)     ipad ;;
  all)      build_metallib; build_lib; build_dylib; build_tests; bundle_resources ;;
  *) echo "usage: build.sh [all|lib|dylib|tests|metallib|bundle|ipad]" >&2; exit 2 ;;
esac
