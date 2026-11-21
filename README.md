# way — HarmonyOS 上的 xray 客户端

> **非官方鸿蒙移植，供个人学习与技术研究。如有权利或授权问题，请通过 Issues 联系维护者。**

way 是一个运行在 HarmonyOS（ArkTS + NAPI）上的 xray 客户端：内核跑在 VPN 扩展进程里，
界面用 ArkUI 写，支持订阅、节点测速、ACL4SSR 规则集、DoH DNS，以及实时的连接列表与历史。

| | |
|---|---|
| 内核 | [aimalygin/xray-rust](https://github.com/aimalygin/xray-rust) `v0.10.1`，C ABI `1.17` |
| 适配 | HarmonyOS API 26（真机 `VDE-AL10` 验证），仅 `arm64-v8a` |
| 语言 | ArkTS / C++（NAPI）/ Rust（内核，见 `kernel/`） |
| 许可证 | MPL-2.0（见 `LICENSE`、`NOTICE`） |
| 最新构建 | [Releases / v0.10.1](https://github.com/being123321/way-harmonyos/releases/tag/v0.10.1)（`way-0.10.1-unsigned.hap`，28,602,840 B，`CEE0AB02…627D8350`） |
| 应用图标 | 深色底 + 盘成 W 的公路 + U 形弧光（w + u），见 `docs/app-icon.png` |

## 功能

- **订阅 / 节点分开管理**：订阅可改名改址，拉取后按 outbound 拆成多节点；链接、JSON（含 base64 JSON）都能导入。
- **分层测速**：未连接时 TCP/UDP 探测；连接后走内核 `probe_outbound_url` 逐节点测真连接延迟，并发 4、按延迟排序。
- **规则集（ACL4SSR）**：14 个清单转成 way 的规则集 JSON，内置 / 在线更新 / 备份回滚 / 自定义四种来源，
  切换时热替换路由（`xray_core_replace_routing_policy_json`），不断线。
- **广告拦截**：BanAD + BanProgramAD（1,598 条）走 `blackhole`，可单独开关。
- **DoH DNS**：国内 `223.5.5.5` 直连 + 国外 `1.1.1.1` 经节点，HTTPS 加密查询。
- **连接面板**：`活动 / 历史` 两个标签，每行显示 `协议 + 域名:端口 + 时长 + rule_set`，可单条关闭；
  历史最多 200 条、持久化到 `filesDir/xray/conn-history.json`。
- **状态卡**：VPN 进程的内存 / CPU、实时速率、累计流量、连接数（点开连接页）、会话时长，状态灯随流量强弱变化。

## 界面

首页是状态卡（速率 / 连接数 / 时长 / 内存与 CPU）+ 可折叠的节点、规则、按需启动卡片；连接页分
`活动 / 历史` 两个标签。

![图标](docs-app-icon.png)

真机截图（含规则集、DoH、测速、连接历史）不在仓库内：里面带作者自己的节点与浏览记录，
需要的话在 Issues 里说，我单独贴几张脱敏的。

## 构建

前置：DevEco Studio（含 OpenHarmony SDK API 26）、Rust 1.96 + OHOS NDK（交叉编译
`aarch64-unknown-linux-ohos`）、Node/pnpm（hvigor）。

```bash
# 1) 内核：把 kernel/way-ohos.patch 打到 xray-rust v0.10.1 上，交叉编译出 libxray_ffi.a/.so
git clone https://github.com/aimalygin/xray-rust.git
cd xray-rust && git checkout v0.10.1
git apply /path/to/kernel/way-ohos.patch

# 2) 依赖放进 app/entry/src/main/cpp/prebuilt/arm64-v8a/
#    libxray_ffi.a + libxray_ffi.so（本仓库不包含二进制，需自行编译）

# 3) 打包 HAP
cd app
hvigorw assembleHap -p product=default -p buildMode=debug
```

产出的 HAP 未签名，需用你自己的证书与 profile 签名后安装（`hdc install`）。

## 目录

```
app/                  ArkTS 工程（entry/ 模块、NAPI 桥、VPN 扩展、页面）
kernel/               内核移植补丁（MPL-2.0 衍生，见 kernel/README.md）
tools/                ACL4SSR 清单 → way 规则集的转换脚本
docs-ARCHITECTURE.md  实现说明（分流、DNS、保活、已知限制等）
```

## 致谢与来源

- 内核：[aimalygin/xray-rust](https://github.com/aimalygin/xray-rust)（MPL-2.0）。本项目对其做的
  OHOS 适配与可观测性改动全部以补丁形式放在 `kernel/`，仍按 MPL-2.0 提供。
- 规则数据：[ACL4SSR](https://github.com/ACL4SSR/ACL4SSR) 的 14 个 Clash 清单，本项目只做格式转换，
  版权归其作者。
- 协议实现与分流策略参考 Xray-core 与 v2rayNG 的行为。

联系方式：请使用本仓库的 Issues。


