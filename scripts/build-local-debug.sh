#!/bin/bash
# Rebuild ArkTS/resources using verified v0.3.19 native libraries; no signing.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deveco_home="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
plugin_home="$deveco_home/tools/hvigor/hvigor-ohos-plugin"
build_user="$project_root/.build-user"
node_bin="$deveco_home/tools/node/bin/node"

main() {
  cd "$project_root"
  test -x "$node_bin"
  if [[ ! -f "$project_root/build-profile.json5" ]]; then
    cp "$project_root/build-profile.example.json5" "$project_root/build-profile.json5"
  fi
  mkdir -p "$build_user"
  "$node_bin" -e '
    if (require(process.argv[1]).version !== "6.26.20") {
      throw new Error("This local build requires DevEco bundled Hvigor 6.26.20.");
    }
  ' "$plugin_home/package.json"

  export JAVA_HOME="$deveco_home/jbr/Contents/Home"
  export JAVA_TOOL_OPTIONS="-Duser.home=$build_user"
  export PATH="$deveco_home/tools/node/bin:$JAVA_HOME/bin:$PATH"
  export DEVECO_SDK_HOME="$deveco_home/sdk"
  export OHOS_SDK_HOME="$deveco_home/sdk"
  export HVIGOR_USER_HOME="$project_root/.hvigor-user"
  unset NODE_PATH
  export MESHARC_BUILD_USER_DIR="$build_user"

  # OHPM has no user-home option. Scope its os.homedir() to this build process
  # so initialization, audit records and cache never write into the real home.
  "$node_bin" -e '
    const buildUser = process.env.MESHARC_BUILD_USER_DIR;
    const homedir = () => buildUser;
    // OHPM audit code also interpolates homedir without calling it.
    homedir.toString = () => buildUser;
    require("node:os").homedir = homedir;
    const entry = process.argv[1];
    process.argv = [process.execPath, entry, ...process.argv.slice(2)];
    require(entry);
  ' "$deveco_home/tools/ohpm/bin/pm-cli.js" install --all --cache "$build_user/ohpm-cache"

  local native_dir="$project_root/entry/libs/arm64-v8a"
  for library in libtailscale_go.so libtailscale_ohos.so; do
    if [[ ! -f "$native_dir/$library" ]]; then
      echo "Missing verified upstream native library: $native_dir/$library" >&2
      return 1
    fi
  done
  (cd "$native_dir" && shasum -a 256 -c SHA256SUMS)

  "$node_bin" "$deveco_home/tools/hvigor/bin/hvigorw.js" --mode module \
    -p module=entry@default -p product=default -p buildMode=debug \
    -p debuggable=true assembleHap --no-daemon
  local hap="$project_root/entry/build/default/outputs/default/entry-default-unsigned.hap"
  test -f "$hap"
  echo "Unsigned HAP: $hap"
}

mkdir -p "$project_root/build-logs"
main 2>&1 | tee "$project_root/build-logs/local-debug.log"
