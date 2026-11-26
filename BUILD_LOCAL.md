# 本机鸿蒙调试构建

工程基于 Tailscale-OHOS `v0.3.19-release`。本版同时从源码构建 ArkTS、C++ NAPI 桥接和 Tailscale v1.86.5 Go 核心。源码包包含打过补丁的 `third_party/tailscale`；来源、补丁及校验清单见 `native/SOURCE_LOCK.json`。

本次工具链为 macOS DevEco Studio 26.0.1.290，捆绑 Hvigor 6.26.20、HarmonyOS API 26 Beta1 SDK。`compileSdkVersion` 必须为 `26.0.1`，以匹配本机 IDE；最低及目标 API 保留 23。API 23 的实际设备兼容性仍需另行验证；当前目标设备为 API 26。

## 准备 Go 工具链

必须使用 OpenHarmony SIG 的 Go 1.24.5 移植版。工具链源码固定于 `302a5306b6fad2f47196360b82561d1db1f954cf`，不随应用源码包分发：

```sh
git clone https://gitcode.com/openharmony-sig/ohos_golang_go.git third_party/ohos-go
git -C third_party/ohos-go checkout 302a5306b6fad2f47196360b82561d1db1f954cf
git -C third_party/ohos-go apply ../../native/patches/ohos-go-1.24.5-interface-resources.patch
```

上述补丁必须应用：该版本鸿蒙 `net` 标准库在枚举网络接口时未释放临时 socket 和 `getifaddrs` 链表，持续运行会触发系统的 FD 泄漏保护并结束应用。补丁保留原接口行为，并覆盖成功获取资源后遇到错误的清理路径。若工具链已构建，可在其源码目录应用补丁后直接重新构建应用；Go 会根据标准库源码变化更新编译缓存。原生构建脚本校验两个修复后源文件的精确 SHA256，缺少补丁时拒绝构建。外部工具链路径同样需要应用此补丁。

在工具链 `src` 目录运行 `./make.bash`，将 `GOROOT_BOOTSTRAP` 指向已安装的 Go。本机使用 Homebrew Go 1.26.1 引导构建。设置 `GOCACHE` 和 `GOPATH` 到工程下的缓存目录，避免写入实际用户主目录。

## 构建原生库和 HAP

```sh
# 已在其他位置构建工具链时指定 OHOS_GO_ROOT。
OHOS_GO_ROOT=/absolute/path/to/ohos-go ./scripts/build-native-local.sh
./scripts/build-local-debug.sh
```

脚本使用 DevEco 自带 Node、Java、Hvigor wrapper，支持用 `DEVECO_STUDIO_HOME` 指定其 `Contents` 目录。Hvigor 配置使用 IDE 内置插件，脚本校验版本为 6.26.20，避免下载另一份引擎。OHPM 配置、缓存与 Java 用户目录位于 `.build-user/`，Hvigor 缓存位于 `.hvigor-user/`。不安装全局工具，不修改 SDK。

原生脚本校验工具链提交及 Tailscale 源文件清单，使用 SDK clang/CMake/Ninja 构建 Go 和 C++ 库；两阶段成功后才更新打包目录及 `SHA256SUMS`。`libc++_shared.so` 来自当前 SDK。Go 缓存位于 `.build-native/`；可通过 `OHOS_GOMODCACHE` 复用模块缓存。网络需要时可设置 `GOPROXY=https://goproxy.cn,https://proxy.golang.org,direct`，依赖仍按 `go.sum` 校验。HAP 脚本在打包前重新校验全部原生库。

源码包只含 `build-profile.example.json5`，不含本机开发签名、密码和证书。脚本在缺少 `build-profile.json5` 时复制示例配置；商用鸿蒙手机安装需要在 DevEco 中配置该设备的开发签名。本机已配置签名，但未将其打包。

构建日志为 `build-logs/local-debug.log`，输出目录为 `entry/build/default/outputs/default/`。未签名包为 `entry-default-unsigned.hap`；配置有效签名时另有 `entry-default-signed.hap`。

## DNS 与后台连接回归验证

Go 主机测试同样使用上述 OpenHarmony Go 工具链：依赖引用其专有的 `runtime.IsOpenharmony`，普通 Go 无法编译。在仓库根目录设置工具链及工程缓存目录，然后运行主机测试（不要设置 `GOOS=openharmony`）：

```sh
export GOROOT=/absolute/path/to/ohos-go
export PATH="$GOROOT/bin:$PATH"
export GOCACHE="$PWD/.build-native/host-go-cache"
export GOPATH="$PWD/.build-native/gopath"
export GOMODCACHE="$PWD/.build-native/gomodcache"
export GOENV=off GOTOOLCHAIN=local GOWORK=off
unset GOOS GOARCH
cd native/go_bridge
go test -race -run 'Test(BackendOwnership|ParseBaseDNS|HarmonyDNS|BaseDNSStaging)' -v .
go vet ./...
```

后台生命周期与绑定回归测试位于 `tests/`，使用 DevEco 自带 TypeScript 编译器在 Node 中加载平台替身进行验证，运行 `node --test tests/*.test.mjs`。真实系统绑定兼容性、后台资源占用和持续连通仍须通过签名 HAP 真机验证。

完整测试中已知的 `TestClassifyPeerDevice/laptop` 将 ThinkPad 识别成 tablet，属于此次修复前的分类逻辑，尚未修复。DNS 配置测试不等于自建 tailnet DNS 服务器端到端可用；仍须用普通手机应用验证完整域名、IP、公共域名和断开重连。详细真机结果见交付报告。
