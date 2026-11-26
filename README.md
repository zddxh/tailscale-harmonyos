# Tailscale for HarmonyOS

Tailscale 的非官方鸿蒙原生移植项目，包含 ArkTS 界面、VPN 扩展、C++ 桥接和 Go 网络核心。安装文件为鸿蒙 `.hap` 包，当前用于开发和真机验证。

最后更新：2026-11-26。

## 当前版本

[v0.3.19-harmony.3 后台断连修复版](https://github.com/zddxh/tailscale-harmonyos/releases/tag/v0.3.19-harmony.3)。旧版真机回归确认：退到后台后 287.028 秒，系统因 `ResourceLeak:Fd Leak` 终止应用，VPN 进程当时有 20,313 个文件描述符。此次修补 OpenHarmony Go 工具链中网络接口查询未释放 socket 和 `getifaddrs` 结果的问题，并加入核心独占、状态判断和 VPN 扩展绑定的防御性改进。

新版已安装到 HarmonyOS 7 / API 26 真机。**应用持续在后台 757.335 秒（约 12 分 37 秒）后仍保持连接，VPN FD 从初始 51 降至 50 并保持稳定**；随后通过完整 MagicDNS 域名访问测试页，返回 HTTP 200。手动断开后观察 55.105 秒，保持未连接；主动重连后再次确认 TUN 与 HTTP 访问正常。这是单台设备、一次有限时长的验证，不代表无限期或所有系统条件下的长连保证。详情见 [后台修复报告](BACKGROUND-REPORT.md) 和 [验证记录](BACKGROUND-VERIFICATION.json)。

前版文件见 [版本记录](docs/RELEASES.md)。

- [下载鸿蒙安装包](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.3/tailscale-harmonyos-background-fix-signed.hap)
- [下载完整源码包（含预构建原生库）](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.3/tailscale-harmonyos-background-fix-source.zip)
- [文件 SHA256](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.3/BACKGROUND-SHA256SUMS) · [全部版本与文件](docs/RELEASES.md)

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
| `native/go_bridge/` | Go 后端、独占锁及 DNS 回归测试 |
| `third_party/tailscale/` | 固定版本及补丁后的 Tailscale 源码 |
| `native/SOURCE_LOCK.json` | 上游提交、工具链版本、资源释放补丁和校验信息 |
| `tests/` | 状态、扩展绑定、原子写入及重连控制流回归 |
| `scripts/` | 原生库构建、HAP 打包及调测脚本 |

从 Git 克隆后，先按 [本机构建说明](BUILD_LOCAL.md) 准备 DevEco Studio 和固定版本的 OpenHarmony Go 工具链，再构建原生库和 HAP。编译后的 `.so` 不纳入 Git；需要预构建库时，使用 Release 中的完整源码压缩包。

## 验证范围

后台修复版的 Go 独占锁与 DNS 专项竞争检测、`go vet`、19 条 ArkTS 控制逻辑回归、Go/C++/ArkTS 编译及 HAP 签名通过。真机后台观察覆盖约 12 分 37 秒，并验证之后的 MagicDNS / HTTP 数据通路；未覆盖数小时或数天运行。绑定和状态修复只作为防御性改进；手动断开后应保持断开，不承诺系统强制终止、强制停止或重启后仍自动保持连接。

完整 Go 测试仍有原有的 `TestClassifyPeerDevice/laptop` 失败：ThinkPad 被分类为 tablet，此次未改动该逻辑。短主机名搜索、自建 tailnet DNS 上游、实时切网和 API 23 真机兼容性仍待验证。前版 DNS 的验证范围保留在 [DNS 报告](DNS-REPORT.md) 和 [记录](DNS-VERIFICATION.json)。

启动连接后立即切到后台，防御性扩展绑定可能延后到应用再次进入前台。本次复现该场景时，绑定前的 TUN 与 HTTP 访问仍正常，返回应用后已确认绑定成功；不将此结果扩展为所有启动时序的保证。

原工程及本地整理前的 README 保存在 [历史说明快照](docs/UPSTREAM_README.md)，其中历史测试范围不代表本次执行结果。

应用基于 `flypigJ/Tailscale-OHOS`，网络核心基于 Tailscale。上游来源、许可及预构建库说明见 [第三方说明](THIRD_PARTY_NOTICES.md)。
