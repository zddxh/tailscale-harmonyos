# 版本与交付文件

最后更新：2026-11-26。当前版本为后台断连修复版；各版本的安装包、完整源码压缩包及验证材料见 GitHub Releases。

## v0.3.19-harmony.3 — 后台断连修复版

已完成构建、签名、真机覆盖安装及 757.335 秒应用后台观察，连接与 FD 数量稳定，随后 MagicDNS / HTTP 访问成功；手动断开后保持停止 55.105 秒，主动重连及再次 HTTP 访问也通过。当前版本号 `0.3.19-harmony.3`，versionCode `3190017`。[Release 页面](https://github.com/zddxh/tailscale-harmonyos/releases/tag/v0.3.19-harmony.3)与附件如下。

| 文件 | 用途 |
| --- | --- |
| [tailscale-harmonyos-background-fix-signed.hap](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.3/tailscale-harmonyos-background-fix-signed.hap) | 后台断连修复版开发签名安装包 |
| [tailscale-harmonyos-background-fix-source.zip](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.3/tailscale-harmonyos-background-fix-source.zip) | 完整交付源码，含预构建原生库及工具链补丁 |
| [BACKGROUND-REPORT.md](../BACKGROUND-REPORT.md) | 根因、修复范围与验证边界 |
| [BACKGROUND-VERIFICATION.json](../BACKGROUND-VERIFICATION.json) | 脱敏的机器可读验证记录 |
| [BACKGROUND-SHA256SUMS](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.3/BACKGROUND-SHA256SUMS) | 外置文件校验清单，含完整源码 ZIP 的 SHA256 |

旧版后台回归在 287.028 秒触发系统 `ResourceLeak:Fd Leak`，VPN 进程 FD 数为 20,313。此版针对 OpenHarmony Go 网络接口查询的 socket / `getifaddrs` 资源释放缺口；独占锁、状态原子写入和扩展绑定提供额外保护。19 条 ArkTS 控制逻辑回归、Go 专项 race / vet 及构建签名已通过。真机结果限于本次约 12 分 37 秒的应用后台观察，不代表数小时或数天的验证。手动断开后必须保持断开，不承诺强制停止或设备重启后自动连接。

启动连接后立即切到后台，防御性扩展绑定可能等待再次进入前台；本次该场景下 HTTP 仍正常，返回应用后绑定成功。完整边界见本版报告。

## v0.3.19-harmony.2 — DNS 修复版

发布日期：2026-11-26。[打开 Release](https://github.com/zddxh/tailscale-harmonyos/releases/tag/v0.3.19-harmony.2)。

| 文件 | 用途 |
| --- | --- |
| [tailscale-harmonyos-dns-fix-signed.hap](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/tailscale-harmonyos-dns-fix-signed.hap) | DNS 修复版开发签名安装包 |
| [tailscale-harmonyos-dns-fix-source.zip](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/tailscale-harmonyos-dns-fix-source.zip) | 完整交付源码，含预构建原生库 |
| [DNS-REPORT.md](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/DNS-REPORT.md) | 修复、验证结果及已知范围 |
| [dns-verification.json](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/dns-verification.json) | 机器可读验证记录 |
| [dns-fix.patch](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/dns-fix.patch) | 相对前一版的应用改动 |
| [dns-build.log](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/dns-build.log) | ArkTS/HAP 构建日志 |
| [dns-native-build.log](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/dns-native-build.log) | Go/C++ 构建日志 |
| [dns-focused-race-tests.log](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/dns-focused-race-tests.log) | DNS 专项竞争检测记录 |
| [DNS-SHA256SUMS](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/DNS-SHA256SUMS) | 本版交付文件 SHA256 |

DNS 专项、构建和代码审查通过；设备使用者确认测试可用。完整 MagicDNS/重连矩阵、短主机名搜索、自建 tailnet DNS 上游及实时切网的验证边界，以本版报告为准。

## v0.3.19-harmony.1 — 连接修复版

交付日期：2026-11-25。[打开 Release](https://github.com/zddxh/tailscale-harmonyos/releases/tag/v0.3.19-harmony.1)。

| 文件 | 用途 |
| --- | --- |
| [tailscale-harmonyos-connection-fix-signed.hap](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.1/tailscale-harmonyos-connection-fix-signed.hap) | 前一版签名安装包 |
| [tailscale-harmonyos-connection-fix-source.zip](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.1/tailscale-harmonyos-connection-fix-source.zip) | 前一版完整源码包 |
| [CONNECTION-REPORT.md](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.1/CONNECTION-REPORT.md) | 连接修复交付报告 |
| [verification.json](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.1/verification.json) | 验证记录 |
| [connection-fix.patch](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.1/connection-fix.patch) | 连接修复补丁 |
| [build.log](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.1/build.log) | 构建日志 |
| [SHA256SUMS](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.1/SHA256SUMS) | 本版交付文件 SHA256 |

该版本保留用于回溯。其连接修复已纳入当前 DNS 修复版。

## 使用说明

下载后可对照对应版本的 SHA256 文件校验完整性。GitHub 自动生成的 Source code 压缩包反映标签指向的 Git 源码；带 `tailscale-harmonyos-…-source.zip` 名称的附件才是保留原生预构建库的原始交付源码包。

本仓库及 Release 已公开，可直接下载附件。所有 HAP 均为开发签名版本，安装范围仍受签名授权设备限制。
