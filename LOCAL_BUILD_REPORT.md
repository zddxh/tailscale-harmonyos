# Tailscale 鸿蒙开发版：构建与验证记录

日期：2026-11-25（Asia/Shanghai）。

## 交付状态

- 已生成 `tailscale-harmonyos-dev-unsigned.hap`，包名 `com.example.tailscaleharmony`，显示名「Tailscale 鸿蒙开发版」，`debug=true`。
- 此 HAP 尚未签名，不能直接作为已验证的可安装版本。尚未进行本设备上的应用启动、Tailscale 登录、VPN 授权或真实联网测试。
- `tailscale-harmonyos-dev-source.zip` 包含本次修改后的源码、构建脚本、原生库及校验信息，不包含个人签名、账号信息、IDE 配置或构建缓存。

## 来源与构建范围

上游：[flypigJ/Tailscale-OHOS v0.3.19-release](https://github.com/flypigJ/Tailscale-OHOS/releases/tag/v0.3.19-release)，社区客户端，不是 Tailscale 官方发布的鸿蒙客户端。

精确源码提交：`fbd14c5207e746389e54ff9f8f8593c46942adac`。已比较标签归档与该精确提交归档，所有源码文件内容一致。

ArkTS 界面、VPN 扩展和资源从源码重新编译。Go 实现的 Tailscale 1.86.5 网络核心与 C++ NAPI 桥接采用上游发布 HAP 中的 arm64 预编译库；本次没有重新编译 Go/C++，没有声称完成二进制可复现构建。

本地修改包括独立包名、开发版显示名、同步的 VPN 启停与应用排除配置、相应检查脚本，以及适配本机 SDK 的构建配置。保留上游作者标识。

## 已执行验证

- 已通过无线 HDC 读取目标设备：华为 Mate 90 Pro，型号 CMS-AL20，系统 7.0.0.115，API 26，arm64-v8a。
- 工具链：DevEco Studio 26.0.1.290、HarmonyOS SDK 26.0.1.120 Beta1、Hvigor 6.26.20。编译版本配置为 `26.0.1`，最低及目标 API 保留 23；未验证 API 23 真机。
- 独立 ArkTS/资源编译 13 项任务成功；最终 HAP 构建 33 项任务成功（27 项执行、6 项增量命中）。
- 上游 HAP 的 SHA-256 与发布记录一致；ZIP 路径及 CRC 检查通过。
- 三个原生库均为 ELF64/AArch64，依赖库完整；23 个 Go 导出名及 32 个 NAPI 属性名字节串与源码预期相符。此项为静态检查，不替代运行验证。
- 新 HAP 的 ZIP CRC、包名、调试标志、SDK 元数据及三份原生库字节一致性检查通过。
- 构建配置与包名改动经过代码审查；两处 ArkTS 包名改动经过专项审查。

## 产物摘要

未签名 HAP 大小：27,319,289 字节。

SHA-256：`69278d200363d264a04ece78982cbe38bad7dff73ce02443768f303d83958ca2`。

上游原始 HAP SHA-256：`c8c5c51817708f587e5be1a7ddb54b15b9dd396026e7a78e5ee77f4c85f96c73`。

详细机器校验记录在 `build-evidence.json`，编译日志在 `build.log`，全部交付文件的校验值在 `SHA256SUMS`。

## 下一步

1. 在 DevEco 中为 `com.example.tailscaleharmony` 配置与目标设备匹配的开发签名。不能复用另一个包名的签名 profile。
2. 生成 signed HAP 并安装到已授权设备。
3. 验证原生库加载、浏览器登录、VPN 授权、同一 Tailnet 内 IP 连通；再验证断开重连、锁屏及切网。

源码包中 `BUILD_LOCAL.md` 说明了本机未签名构建方法。上游原 README 中的真机结果属于上游自述，不代表本次已完成相同测试。
