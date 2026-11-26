# Tailscale for HarmonyOS

Tailscale 的非官方鸿蒙原生移植项目，包含 ArkTS 界面、VPN 扩展、C++ 桥接和 Go 网络核心。安装文件为鸿蒙 `.hap` 包，当前用于开发和真机验证。

最后更新：2026-11-26。

## 当前版本

[v0.3.19-harmony.2](https://github.com/zddxh/tailscale-harmonyos/releases/tag/v0.3.19-harmony.2) 已覆盖安装到 HarmonyOS 7 / API 26 手机，设备使用者确认测试可用。本版保留连接启动、心跳恢复及重连修复，并补齐物理网络 DNS 配置到 Tailscale 核心的传递。

- [下载鸿蒙安装包](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/tailscale-harmonyos-dns-fix-signed.hap)
- [下载完整源码包（含预构建原生库）](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/tailscale-harmonyos-dns-fix-source.zip)
- [修复与验证说明](DNS-REPORT.md) · [全部版本与文件](docs/RELEASES.md)

安装包采用设备开发签名，仅适用于签名授权设备。其他设备需自行配置开发签名并构建。仓库和源码压缩包不含私有签名材料、密码或设备登录状态。

## 源码与构建

```text
ArkTS UI / VpnExtensionAbility
  → C++ Node-API 桥接
  → OpenHarmony arm64 Go 共享库
  → Tailscale v1.86.5
  → HarmonyOS VPN TUN
```

| 路径 | 内容 |
| --- | --- |
| `entry/src/main/ets/` | 界面、物理 DNS 监测和 VPN 扩展 |
| `entry/src/main/cpp/` | C++ NAPI 桥接 |
| `native/go_bridge/` | Go 后端及 DNS 回归测试 |
| `third_party/tailscale/` | 固定版本及补丁后的 Tailscale 源码 |
| `native/SOURCE_LOCK.json` | 上游提交、工具链版本和校验信息 |
| `scripts/` | 原生库构建、HAP 打包及调测脚本 |

从 Git 克隆后，先按 [本机构建说明](BUILD_LOCAL.md) 准备 DevEco Studio 和固定版本的 OpenHarmony Go 工具链，再构建原生库和 HAP。编译后的 `.so` 不纳入 Git；需要预构建库时，使用 Release 中的完整源码压缩包。

## 验证范围

DNS 专项回归、竞争检测、`go vet`、Go/C++/ArkTS 编译、HAP 签名及代码审查均通过。新版已安装，使用者确认可用；完整 MagicDNS 浏览器访问与重连矩阵未独立执行完毕。短主机名搜索、自建 tailnet DNS 上游、实时切网和 API 23 真机兼容性仍待验证。

完整 Go 测试仍有原有的 `TestClassifyPeerDevice/laptop` 失败：ThinkPad 被分类为 tablet，此次未改动该逻辑。详情见 [验证说明](DNS-REPORT.md) 和 [机器可读记录](DNS-VERIFICATION.json)。

原工程及本地整理前的 README 保存在 [历史说明快照](docs/UPSTREAM_README.md)，其中历史测试范围不代表本次执行结果。

应用基于 `flypigJ/Tailscale-OHOS`，网络核心基于 Tailscale。上游来源、许可及预构建库说明见 [第三方说明](THIRD_PARTY_NOTICES.md)。
