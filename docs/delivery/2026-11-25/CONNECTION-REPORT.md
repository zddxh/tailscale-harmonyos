# 鸿蒙 Tailscale 连接修复记录

日期：2026-11-25，Asia/Shanghai。

## 当前结果

已在华为 Mate 90 Pro（CMS-AL20，HarmonyOS 7.0.0.115，API 26）覆盖安装签名调试版，保留原有登录。已验证自动连接、断开后重连，以及普通浏览器通过 Tailscale IP 从电脑读取测试文件。HTTP 服务端确认请求来自手机的 Tailscale IP，返回 HTTP 200；这是实际应用数据传输验证。

MagicDNS 完整域名访问测试未通过，原因尚未确定。当前请使用设备的 Tailscale IP 访问服务。本次未验证不同外网、蜂窝网络切换、长期锁屏、出口节点和子网路由。

## 故障与修复

- 登录和地址分配已完成时，原生网络核心仍可能停留在 `Starting`。旧界面拒绝启动 VPN，却把具体失败原因覆盖成“未连接”。现通过已有的、有超时限制的 peer 探测尝试建立传输路径，再重新检查核心状态；未放宽登录或 Running 检查。
- VPN 启动和可选诊断期间缺少持续心跳：peer 探测最长 10 秒，界面却在 5 秒后认定状态过期。现在启动阶段持续发送心跳，Running 后先启动状态更新，再进行可选诊断。
- 延长扩展恢复与重启阶段的有界等待，以涵盖原生核心恢复网络偏好的时间。
- 异步启动异常、失败清理、重试、过期状态和启动中被停止均有明确处理。缺少新心跳的连接尝试会结束并允许重试，避免一直转圈。
- 恢复失败时不再建立只有文档网段路由的无效 TUN。

## 验证范围

- ArkTS 编译、打包和签名构建成功，33 项构建任务通过。
- TypeScript/ArkTS 专项审查和一般代码审查已执行。
- 已安装 HAP 的包名为 `com.example.tailscaleharmony`，保留既有开发签名和登录数据。
- 独立启动连接和断开重连均观察到“已连接”及扩展 TUN 创建成功；两次扩展日志显示启动至 TUN 创建约 18–19 秒。
- 浏览器访问 Tailscale IP 的 HTTP 测试多次返回 200，含重连后复测。
- HDC shell 的 ping 在同一时间仍可失败，因此不把调试 shell 的结果当作普通应用 VPN 连通性的结论。
- 超时及取消边界处理经过编译和代码审查；没有对所有异常路径做真机故障注入测试。

## 交付内容

- `tailscale-harmonyos-connection-fix-signed.hap`：本设备开发签名安装包。开发签名不等同于面向任意设备的正式发布签名。
- `tailscale-harmonyos-connection-fix-source.zip`：更新后的完整开发源码包，不包含个人签名材料。
- `connection-fix.patch`：相对于本次接手版本的两份 ArkTS 文件差异。
- `build.log`、`verification.json`、`SHA256SUMS`：构建记录、验证摘要与文件校验值。

工程继续基于社区项目 flypigJ/Tailscale-OHOS 的 `v0.3.19-release`（源码提交 `fbd14c5207e746389e54ff9f8f8593c46942adac`）。Go/Tailscale 1.86.5 与 C++ 桥接仍使用上一轮已校验的上游原生库，本次没有重编或替换原生库；不宣称原生二进制可复现构建。
