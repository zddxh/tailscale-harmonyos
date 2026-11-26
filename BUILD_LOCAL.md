# 本机鸿蒙调试构建

此工程基于 Tailscale-OHOS `v0.3.19-release`。ArkTS 界面、VPN 扩展及资源从源码编译；Go 网络核心与 C++ NAPI 桥接使用该发布版 HAP 中提取的 arm64 预编译库，不属于 Go/C++ 源码重编。

本次工具链为 macOS DevEco Studio 26.0.1.290，捆绑 Hvigor 6.26.20、HarmonyOS API 26 Beta1 SDK。`compileSdkVersion` 必须为 `26.0.1`，以匹配本机 IDE；最低及目标 API 保留 23。API 23 的实际设备兼容性仍需另行验证；当前目标设备为 API 26。

```sh
./scripts/build-local-debug.sh
```

脚本使用 DevEco 自带 Node、Java、Hvigor wrapper，支持用 `DEVECO_STUDIO_HOME` 指定其 `Contents` 目录。Hvigor 配置使用 IDE 内置插件，脚本校验版本为 6.26.20，避免下载另一份引擎。OHPM 配置、缓存与 Java 用户目录位于 `.build-user/`，Hvigor 缓存位于 `.hvigor-user/`。不安装全局工具，不修改 SDK。

构建前，`entry/libs/arm64-v8a/` 必须具有经完整上游 HAP 校验后提取的库及相对文件名格式的 `SHA256SUMS`；脚本每次重新校验这些库。缺少依赖或校验失败会停止构建。

完整日志：`build-logs/local-debug.log`。未签名 HAP：`entry/build/default/outputs/default/entry-default-unsigned.hap`。此配置不含签名材料；安装到商用鸿蒙设备前还需有效的设备开发签名。编译成功不代表 VPN、登录、休眠或切网验证完成。


## 2026-11-25 连接修复

已更新启动心跳、Starting 阶段单次 peer 探测、失败清理、重试和取消超时。Go/C++ 库保持不变。源码包不含开发签名；本次 signed HAP 使用本机已有设备开发签名，覆盖安装保留登录。真机范围见 CONNECTION-REPORT.md。
