#!/bin/bash
# Compile every engine translation unit for iOS arm64 on its own, in parallel.
# Fast feedback on the C++ side without building the whole app.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IOS_MIN=${IOS_MIN:-18.0}
obj="$here/build/engine-obj"
mkdir -p "$obj"
export IOS_MIN obj here
ls "$here"/Engine/src/core/*.cpp "$here"/Engine/src/gpu/*.cpp "$here"/Engine/src/pipeline/*.cpp \
 | xargs -P 6 -I{} bash -c '
    f="{}"; o="$obj/$(basename "$f" .cpp).o"
    xcrun -sdk iphoneos clang++ -arch arm64 -miphoneos-version-min=$IOS_MIN -std=c++20 -O1 \
      -Wall -Wno-unused-parameter \
      -I "$here/Engine/include" -I "$here/Engine/src" -I "$here/Engine/src/core" \
      -I "$here/Engine/third_party/metal-cpp" -c "$f" -o "$o" \
      && echo "ok   $(basename "$f")" || { echo "FAIL $(basename "$f")"; exit 255; }'
echo "engine compiles for iOS arm64"
