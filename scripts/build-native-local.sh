#!/bin/bash
# Rebuild the pinned Go engine and its matching NAPI bridge before packaging.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deveco_home="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
native_sdk="$deveco_home/sdk/default/openharmony/native"
go_root="${OHOS_GO_ROOT:-$project_root/third_party/ohos-go}"
build_dir="$project_root/.build-native"
dist_dir="$project_root/native/go_bridge/dist/arm64-v8a"
lib_dir="$project_root/entry/libs/arm64-v8a"

test -x "$go_root/bin/go"
test -f "$project_root/third_party/tailscale/go.mod"
test "$(git -C "$go_root" rev-parse HEAD)" = 302a5306b6fad2f47196360b82561d1db1f954cf
test "$(head -n 1 "$go_root/VERSION")" = go1.24.5
mkdir -p "$build_dir" "$dist_dir" "$lib_dir" "$project_root/build-logs"
(
  cd "$project_root/third_party/tailscale"
  shasum -a 256 -c "$project_root/native/tailscale-v1.86.5-patched.sha256" > "$project_root/build-logs/vendor-checksums.log"
)

export GOROOT="$go_root"
export PATH="$go_root/bin:$PATH"
export GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1
export GOTOOLCHAIN=local GOENV=off GOWORK=off GOFLAGS= GOEXPERIMENT=
export GOCACHE="$build_dir/go-cache" GOPATH="$build_dir/gopath"
export GOMODCACHE="${OHOS_GOMODCACHE:-$build_dir/gomodcache}"
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
# Go's CC parser only removes quotes at the start of an argument.
export CC="\"$native_sdk/llvm/bin/clang\" --target=aarch64-linux-ohos \"--sysroot=$native_sdk/sysroot\" -D__MUSL__ -fstack-protector-strong"
export CXX="\"$native_sdk/llvm/bin/clang++\" --target=aarch64-linux-ohos \"--sysroot=$native_sdk/sysroot\" -D__MUSL__ -fstack-protector-strong"

(
  cd "$project_root/native/go_bridge"
  go build -p 2 -mod=readonly -buildmode=c-shared -trimpath -buildvcs=false \
    -ldflags='-extldflags=-Wl,-soname,libtailscale_go.so,--build-id=sha1,-z,relro,-z,now,-z,noexecstack -X tailscale.com/version.longStamp=1.86.5 -X tailscale.com/version.shortStamp=1.86.5' \
    -o "$dist_dir/libtailscale_go.so" .
)

cmake_bin="$native_sdk/build-tools/cmake/bin/cmake"
"$cmake_bin" -S "$project_root/entry/src/main/cpp" -B "$build_dir/cpp" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$native_sdk/build-tools/cmake/bin/ninja" \
  -DCMAKE_TOOLCHAIN_FILE="$native_sdk/build/cmake/ohos.toolchain.cmake" \
  -DOHOS_ARCH=arm64-v8a -DOHOS_STL=c++_shared -DCMAKE_BUILD_TYPE=Release -DCMAKE_SKIP_RPATH=TRUE
"$cmake_bin" --build "$build_dir/cpp" --parallel 2

# Publish only after both stages succeed; the checksum file is written last.
cp "$dist_dir/libtailscale_go.so" "$lib_dir/libtailscale_go.so"
cp "$build_dir/cpp/libtailscale_ohos.so" "$lib_dir/libtailscale_ohos.so"
cp "$native_sdk/llvm/lib/aarch64-linux-ohos/libc++_shared.so" "$lib_dir/libc++_shared.so"
(
  cd "$lib_dir"
  shasum -a 256 libc++_shared.so libtailscale_go.so libtailscale_ohos.so > SHA256SUMS.next
  mv SHA256SUMS.next SHA256SUMS
)
echo "Native libraries rebuilt from source. Run scripts/build-local-debug.sh to assemble the HAP."
