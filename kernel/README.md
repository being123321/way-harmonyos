# 内核移植补丁

`way-ohos.patch` 是本项目对 [aimalygin/xray-rust](https://github.com/aimalygin/xray-rust) `v0.10.1`
的**全部**改动（`git diff` 导出，9 个文件、+137/−30）。

## 应用

```bash
git clone https://github.com/aimalygin/xray-rust.git
cd xray-rust
git checkout v0.10.1
git apply way-ohos.patch
```

## 改了什么

| 文件 | 目的 |
|---|---|
| `crates/xray-core-rs/src/runtime_log.rs` | OHOS/Android 沙盒下祖先目录只有 execute 权限，日志文件改用 `O_PATH` 打开目录 |
| `crates/xray-core-rs/src/socks/tproxy/linux.rs` | musl(OHOS) 上 `msg_controllen` 宽度不同，改为按字段类型取宽度 |
| `crates/xray-config/src/model.rs` | `RoutingRule.rule_tag` 字段 |
| `crates/xray-config/src/parser/routing.rs` | 保留 `ruleTag`（原先只校验后丢弃） |
| `crates/xray-core-rs/src/outbound/routing.rs` | `select_routed_rule()`：同步匹配返回命中的规则 |
| `crates/xray-core-rs/src/outbound.rs` | `OutboundRouter::matched_rule_tag(route, target)` |
| `crates/xray-core-rs/src/connection.rs` | `ConnectionInfo.rule_tag` / `sniffed_domain`，新增 `register_routed()` |
| `crates/xray-core-rs/src/tun.rs` | TCP/UDP 注册连接时带上命中的规则名与嗅探域名；`should_sniff_tun_tcp` 改为按 `destOverride` 嗅探（与 Xray 一致） |
| `crates/xray-ffi/src/lib.rs` | 连接快照 JSON 增加 `ruleTag`、`sniffedDomain` 字段 |

## 许可证

这些文件本身属于 xray-rust，按 **MPL-2.0** 授权；补丁同样以 MPL-2.0 提供，
修改后的源文件在应用补丁后即可获得。
