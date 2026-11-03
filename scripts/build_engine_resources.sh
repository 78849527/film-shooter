#!/bin/bash
# Compile the engine's Metal kernels for iOS and stage the engine's runtime
# resources into build/EngineResources, which the app ships as a folder
# reference (the engine opens it as `resources_dir`).
#
# The kernels are compiled here rather than by Xcode on purpose: the engine
# needs safe math (-fmetal-math-mode=safe, precise fp32 functions); Xcode's
# MTL_FAST_MATH would silently change its numerics, and the engine refuses to
# start on a fast-math library. See the upstream engine/build.sh.
#
#   SDK=iphonesimulator scripts/build_engine_resources.sh   # for the simulator
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
engine="$here/Engine"
out="$here/build/EngineResources"
air="$here/build/air"
IOS_MIN=${IOS_MIN:-18.0}
SDK=${SDK:-iphoneos}

if [[ "$SDK" == "iphonesimulator" ]]; then
  target_flag=(-mios-simulator-version-min="$IOS_MIN")
else
  target_flag=(-mios-version-min="$IOS_MIN")
fi

rm -rf "$out" "$air"
mkdir -p "$out" "$air"

math_flags=(-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise)
airs=()
for m in "$engine"/src/shaders/*.metal; do
  a="$air/$(basename "$m" .metal).air"
  echo "metal  $(basename "$m")  [$SDK]"
  xcrun -sdk "$SDK" metal "${math_flags[@]}" "${target_flag[@]}" \
        -I "$engine/src/shaders" -c "$m" -o "$a"
  airs+=("$a")
done
xcrun -sdk "$SDK" metallib "${airs[@]}" -o "$out/spektrafilm.metallib"

# Baked constants, spectral profiles, print LUT index.
rsync -a "$engine/resources/" "$out/"
# Product (black-and-white + CineStill) profiles go beside spektrafilm's: the
# engine opens a stock from one `profiles/` directory.
cp "$engine/resources_product/profiles/"*.json "$out/profiles/"
cp "$engine/resources_product/NOTICE.md" "$out/PRODUCT_PROFILES_NOTICE.md"

du -sh "$out"
ls -la "$out"
