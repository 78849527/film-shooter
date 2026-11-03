#!/bin/bash
# Compile every engine translation unit for iOS arm64 on its own, in parallel.
# Fast feedback on the C++ side without building the whole app.
set -uo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IOS_MIN=${IOS_MIN:-18.0}
obj="$here/build/engine-obj"
log="$here/build/engine-logs"
mkdir -p "$obj" "$log"

compile() {
  local f="$1" name
  name=$(basename "$f" .cpp)
  if xcrun -sdk iphoneos clang++ -arch arm64 -miphoneos-version-min="$IOS_MIN" -std=c++20 -O1 \
      -Wall -Wno-unused-parameter \
      -I "$here/Engine/include" -I "$here/Engine/src" -I "$here/Engine/src/core" \
      -I "$here/Engine/third_party/metal-cpp" -c "$f" -o "$obj/$name.o" > "$log/$name.log" 2>&1; then
    echo "ok   $name"
  else
    echo "FAIL $name"; cat "$log/$name.log"; return 1
  fi
}

pids=()
for f in "$here"/Engine/src/core/*.cpp "$here"/Engine/src/gpu/*.cpp "$here"/Engine/src/pipeline/*.cpp; do
  compile "$f" &
  pids+=($!)
  while (( $(jobs -rp | wc -l) >= 6 )); do sleep 0.2; done
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
if (( fail )); then echo "engine failed to compile for iOS"; exit 1; fi
echo "engine compiles for iOS arm64"
