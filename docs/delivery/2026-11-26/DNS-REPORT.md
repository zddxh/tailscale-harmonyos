# 鸿蒙 Tailscale DNS 修复交付（2026-11-26）

已构建、签名并覆盖安装到当前手机，保留登录数据。用户确认测试可以使用；手机无需重新安装本目录的包。

## 修复

保留上一版 VPN 启动、心跳恢复和重连修复。此次补齐 HarmonyOS 物理网络 DNS 到 Go 核心的配置接口，使 Tailscale DNS 编译器能安装 MagicDNS 主机记录，并保留控制面的默认及分流 DNS 策略。每 5 秒检查物理网络配置变化；不硬编码公共 DNS，不修改 tailnet 管理设置。

Go 核心与 C++ 桥接均从源码重编。Tailscale 固定 v1.86.5，OpenHarmony Go 固定 1.24.5；源码包内 native/SOURCE_LOCK.json、补丁和 2142 个源文件的校验清单记录来源。构建说明见源码包 BUILD_LOCAL.md。

## 验证

- DNS 专项回归及 race 检测、go vet 通过。
- Go、C++、ArkTS、HAP 构建与签名通过；各层代码审查通过。
- 已核对 HAP 内原生库：Go/NAPI 与本次构建库经 SDK strip-all 后完全一致；C++ 运行库与 SDK 一致。
- 真机覆盖安装成功；用户确认可以使用。
- 新版安装后，测试服务于 09:19:19 收到手机 Tailscale IP 发出的 GET /check.txt?case=new-network-dns，返回 HTTP 200。测试服务已关闭。
- 未在用户接手手机后再次读取浏览器地址栏与 DNS 计数，因此不将该请求视为完整 MagicDNS 重连矩阵验证。

## 已知范围

完整 Go 测试中既有 TestClassifyPeerDevice/laptop 仍失败：ThinkPad 被原分类逻辑识别为 tablet。本次未修改该逻辑。短主机名搜索、自建 tailnet DNS 上游、实时切网及 API 23 真机兼容性未验证。

安装包为开发签名版本，仅适用于签名授权设备。源码包排除了本机签名配置、证书密码、私钥和登录状态；包含公开的上游测试资料及许可证。原生源码编译需要另行获取锁定的 Go 工具链。安装包、源码、日志的 SHA256 见 DNS-SHA256SUMS。

## 文件

- tailscale-harmonyos-dns-fix-signed.hap：已安装版本。
- tailscale-harmonyos-dns-fix-source.zip：完整应用源码、打过补丁的 Tailscale 源码、预构建库及来源记录。
- dns-fix.patch：相对上一版连接修复源码包的应用改动；Tailscale 补丁另在源码包 native/patches/。
- dns-verification.json：机器可读结果和原生库哈希。
- dns-build.log、dns-native-build.log、dns-focused-race-tests.log：构建及专项测试记录。
