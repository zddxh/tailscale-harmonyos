# 版本与交付文件

最后更新：2026-11-26。源码主分支对应当前 DNS 修复版；每次交付的原始安装包、源码压缩包、日志和校验文件保存在 GitHub Releases。

## v0.3.19-harmony.2 — DNS 修复版

发布日期：2026-11-26。[打开 Release](https://github.com/zddxh/tailscale-harmonyos/releases/tag/v0.3.19-harmony.2)。

| 文件 | 用途 |
| --- | --- |
| [tailscale-harmonyos-dns-fix-signed.hap](https://github.com/zddxh/tailscale-harmonyos/releases/download/v0.3.19-harmony.2/tailscale-harmonyos-dns-fix-signed.hap) | 当前手机已安装版本 |
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
