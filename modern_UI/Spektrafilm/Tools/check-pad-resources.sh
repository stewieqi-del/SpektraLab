#!/bin/sh
# check-pad-resources.sh -- the iPad target's pre-build check.
#
# The same contract as `check-bundle-resources.sh`, for a different folder. The
# iOS target does not read `Spektrafilm/Resources/`: that tree holds the Mac
# bundle and the two differ (the Metal library is compiled for a different
# platform, and the Mac bundle carries DI LUTs the Pad only needs when it
# exports one). `engine/build.sh ipad` stages the Pad's copy into
# `SpektraPadResources/Resources/`, which the Xcode project references as a
# folder reference — so the app bundle ends up with `Resources/engine/...` and
# `EngineClient`'s bundle lookup works unchanged.
#
# As with the Mac check: this says what to run, it does not run it. A bake step
# behind an Xcode build is the thing RFC-014 removed.
#
# The dangerous case is again **stale**, not absent: nothing here can tell a
# re-baked `spektrafilm_constants.bin` from an old one. Re-run
# `engine/build.sh ipad` after changing anything under `engine/resources/`.
set -eu
root=${SRCROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
res="$root/SpektraPadResources/Resources"

missing=""
for f in spektrafilm_constants.bin spektrafilm.metallib neutral_print_filters.json print_luts.json; do
  [ -f "$res/engine/$f" ] || missing="$missing engine/$f"
done
[ -d "$res/engine/profiles" ] || missing="$missing engine/profiles/"
[ -f "$res/StockCatalog.json" ] || missing="$missing StockCatalog.json"

if [ -n "$missing" ]; then
  echo "error: the Pad's resources are incomplete under $res" >&2
  echo "error: missing:$missing" >&2
  echo "error: run \`engine/build.sh ipad\`, which compiles the iOS metallib and" >&2
  echo "error: stages the tracked \`engine/resources/\` beside it" >&2
  exit 1
fi

licences=""
for f in README.txt SpektraLab-GPL-3.0.txt Profiles-and-LUTs-CC-BY-SA-4.0.txt \
         Profiles-and-LUTs-CHANGELOG.txt metal-cpp-Apache-2.0.txt; do
  [ -f "$res/Licenses/$f" ] || licences="$licences $f"
done

if [ -n "$licences" ]; then
  echo "error: the Pad bundle is missing licence texts it is obliged to carry:$licences" >&2
  echo "error: run \`engine/build.sh ipad\`" >&2
  echo "error: (GPL-3.0 for the app and engine, CC BY-SA 4.0 for the profiles and the" >&2
  echo "error:  LUTs derived from them, Apache-2.0 for the vendored metal-cpp)" >&2
  exit 1
fi
