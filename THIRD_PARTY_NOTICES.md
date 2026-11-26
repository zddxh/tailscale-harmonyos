# 上游来源与许可证记录

本仓库是社区项目的鸿蒙开发版延续，不是 Tailscale 官方客户端发布仓库。

| 组成 | 上游与固定版本 | 许可证记录 |
| --- | --- | --- |
| ArkTS 应用、VPN 扩展、原始 Go/C++ 桥接 | [flypigJ/Tailscale-OHOS](https://github.com/flypigJ/Tailscale-OHOS)，`v0.3.19-release`，提交 `fbd14c5207e746389e54ff9f8f8593c46942adac` | 上游 `package.json` 声明 `BSD-3-Clause`；该提交归档没有独立 LICENSE 文件，本仓库保留原声明。 |
| UI 与 VPN 扩展的绑定思路及相关逻辑 | 同一上游的 [PR #22](https://github.com/flypigJ/Tailscale-OHOS/pull/22)，主线提交 [`5defb85198373370ecf83d22e7fc113f4f44ec42`](https://github.com/flypigJ/Tailscale-OHOS/commit/5defb85198373370ecf83d22e7fc113f4f44ec42) | 在本版中适配移植，并保留来源注释；应用整体基线未随之升级。 |
| Tailscale Go 核心 | [tailscale/tailscale](https://github.com/tailscale/tailscale)，`v1.86.5`，提交 `db392aed39630023f969e1961fcbced785d09358` | 原文保留于 [third_party/tailscale/LICENSE](third_party/tailscale/LICENSE)，其内部第三方许可证一并保留。 |
| OpenHarmony Go 编译工具链 | [openharmony-sig/ohos_golang_go](https://gitcode.com/openharmony-sig/ohos_golang_go.git)，Go 1.24.5，提交 `302a5306b6fad2f47196360b82561d1db1f954cf` | 工具链不随仓库分发，构建时从上游获取。 |
| C++ 运行库 | DevEco Studio 所带 HarmonyOS SDK 的 `libc++_shared.so` | 已构建安装包和原始完整源码 ZIP 中保留运行所需二进制，Git 源码树不存放该二进制。 |

本次补丁及源文件哈希见 [native/SOURCE_LOCK.json](native/SOURCE_LOCK.json)。这里的来源说明不替代各上游的许可证原文。

v0.3.19-harmony.3 对上述固定版 OpenHarmony Go 工具链增加本地资源释放补丁：[ohos-go-1.24.5-interface-resources.patch](native/patches/ohos-go-1.24.5-interface-resources.patch)。补丁关闭网络接口查询创建的 socket，并释放成功获取的 `getifaddrs` 结果；不是上游版本号升级。最终补丁 SHA256 为 `12175a19cf14336534885b49296485c7e8a1fcff06c18b92bdb00901903cb857`，记录于 `SOURCE_LOCK.json`；构建过程校验修补后的源文件。工具链本体仍不随仓库分发。
