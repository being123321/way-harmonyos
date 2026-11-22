# 发布记录

已发布：**https://github.com/being123321/way-harmonyos**（Public，默认分支 main，许可证 MPL-2.0）

- Release `v0.10.4`：https://github.com/being123321/way-harmonyos/releases/tag/v0.10.4
  - 附件 `way-0.10.4-unsigned.hap`，28,662,716 B，SHA256 `2A6CAA556CFFAD38BF1F7A4333898074DDA87C3C8965428298B56C238E787C9C`
  - 保活改为单条 live-view 通知（不再用无窗口 Ability 持有任务）；SSID 挂起全停、离开后按冷启动流程完整恢复（后台由 `wifiConnectionChange` 事件驱动）；挂起时开关为琥珀色，关闭即彻底退出
- Release `v0.10.3`：https://github.com/being123321/way-harmonyos/releases/tag/v0.10.3
  - 附件 `way-0.10.3-unsigned.hap`，28,656,812 B，SHA256 `BAFA58B2881AFE61468D85150BB806A72F99749DD4B5D65FCB53D4019070AFA8`
  - 默认日志 info（诊断开关可切 debug）、节点测速结果持久化且不再自动探测、QUIC 默认放行、DNS 过期缓存
- Release `v0.10.2`：https://github.com/being123321/way-harmonyos/releases/tag/v0.10.2
  - 附件 `way-0.10.2-unsigned.hap`，28,651,532 B，SHA256 `EB0AF4D194510EE948DB9A6889DEB749E84D4B9E49DF99C39A1A5CAD4DF618CB`
  - 启动不再串行解析节点域名；测速改纯 IP 目标 + UDP DNS 预解析、取消旧探针；手动清后台不重连
- Release `v0.10.1`：https://github.com/being123321/way-harmonyos/releases/tag/v0.10.1
  - 附件 `way-0.10.1-unsigned.hap`，28,602,840 B，SHA256 `CEE0AB02FD9ED8CFF70435A3DF2AEB908032E268F40E265CAEEC48D2627D8350`

## 仓库内容

```
README.md             项目介绍、构建方法、来源与声明（含指定免责声明）
NOTICE                MPL-2.0 归属：内核、补丁、ACL4SSR 数据
LICENSE               MPL-2.0 全文
kernel/               对 aimalygin/xray-rust v0.10.1 的移植补丁 + 改动说明
app/                  ArkTS 工程源码
tools/                ACL4SSR → way 规则集转换脚本
docs-ARCHITECTURE.md  实现说明
push.ps1              重新建仓/推送/挂 Release 的脚本（gitea 之外的重放用）
```

**没有**包含：`signing/`（开发者证书与私钥）、`dist/`（HAP 走 Release）、
`app/entry/src/main/cpp/prebuilt/`（151 MB 静态库，需自行编译内核）、
`local.properties`（本机 SDK 路径）、设备 UDID、真机截图（含作者节点信息）。

## 重新发布的命令

```powershell
$env:GH_CONFIG_DIR = 'D:\Backup\Documents\deepseek-harness\default-workspace\xray-rs-build\tools\gh-config'
$env:Path = 'D:\Backup\Documents\deepseek-harness\default-workspace\tools\portablegit\cmd;' + $env:Path
pwsh -File .\push.ps1
```


