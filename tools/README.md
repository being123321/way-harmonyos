# tools — ACL4SSR → way 规则集

`acl4ssr2way.py`：把 [ACL4SSR/ACL4SSR](https://github.com/ACL4SSR/ACL4SSR) 的 Clash
规则清单转成 way 能直接吃的规则集（`app/entry/src/main/resources/rawfile/acl4ssr-way-rules.json`，
首次启动时复制到 `filesDir/xray/rules.json`）。

清单与目标分组的映射、顺序都照抄
`subscription-forge`（`C:\Users\Administrator\Documents\Codex\2026-10-17\https-github-com-acl4ssr-acl4ssr-https`
里的 `app.py` / `converter.py`）：

| 清单 | way 目标 |
|---|---|
| Tencent（blackmatrix7/ios_rule_script） | direct |
| LocalAreaNetwork、UnBan | direct |
| BanAD、BanProgramAD | block |
| ChinaDomain、GoogleCN | direct |
| Telegram、Netflix | proxy |
| Microsoft、Apple | direct（源码 selector 默认 DIRECT） |
| ChinaCompanyIp、ChinaIp | direct |
| ProxyLite | proxy |

顺序即优先级：way 按这个顺序生成 14 条 Xray 路由规则，先匹配先生效。

## 用法

```powershell
# 拉取 + 转换（GitHub 失败自动换 jsDelivr），写进 HAP 的 rawfile
python tools\acl4ssr2way.py

# 复用已下载的 .list（tools/cache/），不联网
python tools\acl4ssr2way.py --cache-dir tools\cache

# 从本地目录读 <name>.list（离线复现）
python tools\acl4ssr2way.py --from-dir D:\lists

# 只打印，不落盘；或写到别的路径
python tools\acl4ssr2way.py --stdout
python tools\acl4ssr2way.py --out out\way-rules.json
```

输出统计示例（2026-11-21）：

```
lists=14 rules=13086 domains=5246 ip=7840 skipped={}
```

- `DOMAIN-SUFFIX → domain:`、`DOMAIN → full:`、`DOMAIN-KEYWORD → keyword:`、
  `IP-CIDR/IP-CIDR6 → ip`；`PROCESS-NAME`/`URL-REGEX` 之类 Xray 没有对应项，会被统计到
  `skipped`（当前 14 个清单里没有这类行）。
- 域名统一小写、去掉尾部点；同一清单内去重。
- 与源码 `converter.convert_rules()` 对拍：源码存在的每条规则都在本输出里
  （源码会剪掉被父域名覆盖的冗余项，本输出保留，行为一致）。

## 校验

```powershell
# 用核心自己的解析器检查一份由规则集生成的 config（0 错误 / 0 悬空 outboundTag 才算过）
..\host-import\target\release\host-import.exe --check-config config.json
```

`host-import --check-config` 除了跑 `xray_config::parse_xray_json`（核心加载配置的同一
条代码路径），还会检查 `routing.rules[].outboundTag` 是否都指向存在的出站。

## 刷新方式

1. 应用内：主页 → 规则 → 「分流规则集」→ 获取/更新（`RuleSource.ets` 在设备上下载同样的
   14 个清单并转换，GitHub 不通时走 jsDelivr）。
2. 离线推送：把生成的 JSON 放到设备
   `filesDir/xray/rules.json`（例如
   `hdc file send tools\out\way-rules.json /data/app/el2/100/base/com.way.app/haps/entry/files/xray/rules.json`），
   回到应用切到「使用规则集」即可。
3. 随包更新：重新跑本脚本写 rawfile，再 `build.ps1 -SkipRust`。
