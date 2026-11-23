# way（xray-rust → HarmonyOS HAP）

把 [`aimalygin/xray-rust`](https://github.com/aimalygin/xray-rust)（v0.10.1，C ABI 1.17）
编译成**鸿蒙 7.0（API 26，SDK 显示名 HarmonyOS 26.0.0）**可安装的 HAP：
ArkTS UI + `VpnExtensionAbility`（type=`vpn`）+ C++ NAPI 桥 + Rust 核心静态链接。
应用名 `way`，图标为 W 字标。

## 1. 产物

| 文件 | 大小 | SHA-256 | 说明 |
|---|---|---|---|
| `dist/way-0.10.1-signed.hap` | 28,883,152 B | `F1F346DF…76DB0F1A` | 已签名（工程自带 `signing/way.*`：华为 CBG 开发者调试证书链 + debug profile，真机可装） |
| `dist/way-0.10.1-unsigned.hap` | 28,602,840 B | `CEE0AB02…627D8350` | 未签名，供 DevEco 自动签名 / 第三方安装器使用 |

- 仅 `arm64-v8a`（`libs/arm64-v8a/libentry.so` 26.6 MB，含 Rust 核心；`libc++_shared.so` 1.2 MB）。
- `targetSdkVersion` / `compatibleSdkVersion` = `26.0.0`（= 鸿蒙 7.0 / API 26）。
- 签名自检：`hap-sign-tool verify-app` 通过（`dist/verify-certchain.cer`）。
- 本机真机已装：`VDE-AL10`（API 26），`hdc install -r` 成功、`aa start` 正常。

## 2. 架构

```
┌─────────────────────────── entry 模块（HAP） ───────────────────────────┐
│ UI 进程：UIAbility + ArkUI (pages/Index|Configs|AddConfig)                │
│   · 分享链接/订阅/JSON 导入（调用 core 的离线 importer，按 outbounds 拆分）│
│   · 连接时写「全节点」config.json：每个节点一个 tag=entry id 的出站        │
│   · 测速：com.way.app.PROBE → 扩展；扩展回 PROBE_RESULT                    │
│   · startVpnExtensionAbility(want{configPath,notify,rebind})             │
│                                                                          │
│ VPN 扩展进程 com.way.app:vpn：VpnExtensionAbility XrayVpnAbility          │
│   · VpnConnection.create() → tun fd（10.7.0.1/32, fd00:7872::1/128）      │
│   · protectProcessNet() + 服务器 IP 排除路由（防环路）                    │
│   · 看门狗 / 网络变化 rebind / 常驻通知 / status.json 心跳                 │
│   · 响应 PROBE：对指定 tag 的出站做 HTTP 探针（真连接延迟）               │
│                                                                          │
│ libentry.so = NAPI 桥（cpp/xray_napi.cpp）+ 静态链接的 libxray_ffi.a       │
│   · start/stop/restart/stats/rebind/importProfile/warnings/...            │
│   · probeOutbound(url, timeoutMs, tag) → async work + Promise             │
└──────────────────────────────────────────────────────────────────────────┘
                                  │ C ABI 1.17
                        xray-ffi（Rust，TUN/socks/http inbound、VLESS/REALITY/
                        Vision、Trojan、SS2022、VMess、Hysteria2、WireGuard…）
```

数据通路：`VpnConfig.create()` 返回的 fd 交给 `xray_core_set_tun_fd(fd, RAW_IP, BORROWED)`，
包读写由核心内部线程完成（`TunFdRuntime`），ArkTS 侧不需要自己 pump 包。

## 3. 构建（可复现）

工具链（全部已在本机验证）：

| 组件 | 版本 / 路径 |
|---|---|
| DevEco Studio | 26.0.0.851（`C:\Program Files\Huawei\DevEco Studio`，SDK API 26） |
| Rust | 1.96.0，host `x86_64-pc-windows-gnu`，target `aarch64-unknown-linux-ohos` |
| MinGW-w64 | 16.2.0（Rust host 链接器） |
| OHOS NDK | SDK `openharmony/native`（clang 15 + sysroot + cmake/ninja） |
| CMake/Ninja | NDK `build-tools/cmake/bin` |

```powershell
# 1) 交叉编译 Rust 核心 → artifacts/libxray_ffi.a(.so)
..\rust-ohos.ps1

# 2) 打包 + 签名（-SkipRust 复用已有静态库）
.\build.ps1 -SkipRust
```

关键点（踩过的坑，都在脚本里固定了）：

- `-clang` 包装器是 shell 脚本，Windows 上必须直接调 `clang.exe` 并显式传
  `--target=aarch64-linux-ohos --sysroot=<ndk>/sysroot -D__MUSL__`；
- `aws-lc-sys` 通过 `OHOS_SDK_NATIVE` + NDK 的 `ohos.toolchain.cmake` 交叉编译（cmake+ninja+perl）；
- 系统 `%TEMP%` 不可写，`TMP/TEMP/TMPDIR` 必须指到工程内目录；
- host 构建脚本需要链接器 → 用 MinGW + `x86_64-pc-windows-gnu` 工具链；
- hvigor 需要真实的 `@ohos/hvigor`、`@ohos/hvigor-ohos-plugin` 包树（不能是 stub），
  且必须用 `app/node_modules/@ohos/hvigor/bin/hvigor.js` 启动。

## 4. 安装

```powershell
hdc install dist\way-0.10.1-signed.hap
```

签名说明：

- 默认用工程自带的固定签名材料（`signing/config.json` → `way.p12` / `way.cer` / `way.p7b`）：
  华为 CBG 开发者调试证书链 + `debug` profile（`bundle-name=com.way.app`，`device-ids`
  覆盖本机），`build.ps1` 每次构建后 `sign-app` + `verify-app` 自检，真机 `hdc install`
  已验证通过。
- 删掉 `signing/config.json` 时回退到 SDK 自带 `OpenHarmony.p12` 的 CA 签发链
  （`openharmony application release` → `Application CA` → `Application Root CA`，
  `-Udid` 绑定），华为设备可能不信任这条链。
- 换设备：把你的 UDID 写进 profile（`signing/way.p7b` 由 DevEco 自动签名生成时会带上
  已连接设备），或用回退路径 `.\build.ps1 -SkipRust -Udid <你的UDID>`
  （`hdc shell bm get --udid` 获取）。
- DevEco 自动签名：打开 `app/` 目录 → `File → Project Structure → Signing Configs` →
  勾选自动签名（需华为账号）→ `Build Hap(s)`，产出的 signed HAP 同样可 `hdc install`。

## 5. 节点、订阅与导入（v2rayNG 语义）

界面分三级：**主页**（状态/流量/当前节点/规则/保活/日志）→ **节点**（两个标签：
「节点」= 手动导入，「订阅」= 订阅及其节点）→ **添加节点 / 添加订阅**（导入）。

手动导入的节点和订阅**完全分开**存储与显示：

| 能力 | 说明 |
|---|---|
| 存储 | `filesDir/xray/configs.json` 每条记录带 `subId`：空 = 手动导入；否则属于该订阅。`subs.json` 存订阅（URL/名称/流量/到期/节点数） |
| 更新订阅 | 只替换 `subId` 相同的节点，手动节点原样保留；节点被重新编号时按名称保持当前选中项 |
| 删除订阅 | 连同它的节点一起删除（`removeSub` → `removeEntriesOfSub`） |
| 编辑订阅 | 「订阅」标签里可改名称、改地址并立即重新拉取；同一 URL 重复导入不会产生第二份订阅 |
| 展开订阅 | 卡片里点「N 个」展开该订阅的节点，可直接测速或选为当前节点 |
| 去重 | 节点按 config JSON 去重，订阅刷新吸收同内容的旧手动节点 |

导入逻辑对齐 v2rayNG：

| 能力 | 说明 |
|---|---|
| 多行链接 | 一次粘贴多行 `vless/vmess/ss/trojan/hysteria2/socks/http`，逐行解析 |
| base64 订阅内容 | 整段或单行 base64（URL-safe、无 padding 也接受），解码后继续展开：链接逐行、整份 JSON 走拆分，最多 3 层 |
| 订阅地址 | `订阅` 标签页填 `http(s)://`，用 v2rayNG UA 拉取后按上面规则展开 |
| 备注名 | 用链接 `#fragment`（由核心 importer 解码），无备注时回退 `TYPE n` |
| 整份 / 订阅 JSON | `JSON` 标签页或直接粘贴 `{...}`；**按 `outbounds` 拆成多节点**，见下 |
| 去重 | 同一份 config JSON 只保留一条；批量导入默认选中第一条 |
| 上限 | 单次 500 条，列表 500 条 |

### JSON 按 outbounds 拆成多节点

`splitJsonEntries()`（`common/Import.ets`）把一个 JSON 文档拆成每个代理出站一个节点：

1. 逐个看 `outbounds`：`freedom` / `blackhole` / `dns` 视为辅助出站跳过；没有
   `address/port`、`vnext`、`servers`、`peers[].endpoint`（WireGuard）可取的也跳过
   （选择器、balancer 之类）。
2. 每个真正的出站生成一份新配置：该出站排在 `outbounds[0]`（核心的默认出站，
   也是分流规则指向的 proxy），后面保留原来的 `direct`/`block`/`dns` 辅助出站。
3. `routing.rules` 里指向已不存在出站的规则（其他代理、balancerTag）被剔除，
   `routing.balancers` 清空，保证拆出来的配置仍能通过核心校验。
4. 节点名 = outbound `tag`（无 tag 时 `<PROTOCOL> n`），类型 = `protocol`（兼容
   sing-box 的 `type`），服务器地址从同一出站提取。
5. 只有一个代理出站时同样归一化（把代理提到第一位，修正 WireGuard 配置里
   `direct` 排在首位导致默认走直连的问题）。

### Hysteria2 链接的参数兼容

`hysteria2://` 的 query 参数很杂，而 Rust importer 只接受它建模的 7 个
（`sni` / `insecure` / `pinSHA256` / `fm` / `obfs` / `obfs-password` / `mport`），
遇到别的 key 会把整条链接判成 `profile contains an unsupported setting` 丢掉。
参考订阅里 4 条 hy2 带了 `upmbps=200&downmbps=1000`（客户端带宽提示）和 v2rayN 的
`allowInsecure=0`，于是 8 个节点只进来 4 个（v2rayNG 忽略未知参数，所以是 8 个）。

`sanitizeLink()`（`common/Import.ets`）现在按白名单过滤：只保留上面 7 个参数
（key 大小写不敏感、重复 key 丢弃），其余记到失败日志的 `dropped=` 里。
`security`/`alpn` 也在此列（hysteria 固定 TLS + h3，由 importer 补齐）。实测同一订阅
由 4 个节点变为 8 个，4 条 hy2 的配置分别带上了 `pinnedPeerCertSha256`（`pinSHA256`）
与 salamander 混淆（`obfs-password`）。

## 6. 测速（v2rayNG 方式）

`common/Speedtest.ets` + `xray_core_probe_outbound_url`：

| 场景 | 方式 |
|---|---|
| 已连接（`status.json` 为 `running` 且心跳 < 6 s） | **内核按出站探 HTTP**：`xray_core_probe_outbound_url(url, timeout, tag)` 让核心用该节点的出站发一次 HTTP(S) GET，量的是真正经过代理的往返（v2rayNG 的“真连接延迟”） |
| 未连接（或节点不在运行中的配置里） | TCP 握手时间；Hysteria2 / WireGuard 等 UDP 节点发 QUIC 长头包看回包 |
| 并发 | 4 个 worker（`TEST_CONCURRENCY`）；内核探针是 NAPI async work，4 个真正并行且不阻塞 ArkTS 线程 |
| 超时 | 4 秒（`TEST_TIMEOUT_MS`）硬截止，平台超时不可靠时也能返回 |
| 排序 | `sortByLatency()`：有结果的按延迟升序，超时/未测的排在后面保持原序 |
| 展示 | 行内显示 `延迟 · 方式（HTTP/TCP/UDP）`，绿色 < 500 ms、黄色 < 1.5 s、橙色更慢 |

「测速」按钮测当前标签页的全部节点；每行的「测速」只测这一条。

### 为什么探针要绕一圈（多节点配置 + 跨进程 RPC）

- `protectProcessNet()` 保护的是整个应用（含 UI 进程），UI 进程自己发的 HTTP **不经过隧道**
  （实测：8 节点一起测都是 72–172 ms，同时 `stats` 里 `up=0 down=0`、access 日志没有
  gstatic）。所以“走隧道测 HTTP”只能让**核心**去发。
- 连接时不再只写选中节点的配置：`common/TunnelConfig.ets` 把**所有节点**的代理出站塞进
  同一份 `config.json`，每个出站 tag 用它自己的 entry id，选中的节点仍然是
  `outbounds[0]`（默认路由）且原分流规则照旧生效（改 tag 时同步改了引用它的 rule）。
- 核心句柄属于 `com.way.app:vpn` 进程（扩展是独立进程，UI 进程里 `g_core == nullptr`），
  因此 UI 通过 commonEvent 走一次 RPC：`com.way.app.PROBE`
  （requestId/tag/url/timeoutMs）→ 扩展执行 NAPI `probeOutbound`（async work）→
  `com.way.app.PROBE_RESULT`（status/delayMs/failureKind/httpStatus）。
- 兜底：tag 不在运行中的配置里（老配置、或回退成单节点）或 RPC 超时，就退回直连
  TCP/UDP 探测，行内标 `TCP`/`UDP`，不会编造隧道数字。
- 多节点配置万一被核心拒（任一节点非法会让整份配置加载失败），`Index.connect()` 会在
  3 秒内检测到 `state=error` 并**自动回退**到单节点配置重连一次
  （`app.log` 里有 `multi-node config rejected, retrying with the single node`）。
- 顺带把扩展自己的存活探针（`probeLiveness`）也改成 async，8 秒的探针不再卡住每秒一次的
  `status.json` 心跳。

> 实测（本次）：8 个节点里 A-H 1284 ms、A-R 2322 ms、B-V 3434 ms、B-H 3859 ms，
> 45.66.217.56 上的 4 个显示「超时 · HTTP」——数值与扩展自己的 `probe ok 890ms`
> 同一量级，说明确实是经代理的往返，而不是本机直连。
## 7. 内置规则与规则文件更新

- 连接前把内置分流规则注入当前节点配置（不改动磁盘上的原始配置）：
  1. `localhost` + `geosite:cn` 域名 → `direct`（直接连接）
  2. 私有网段 CIDR → `direct`
  3. `geoip:cn` → `direct`
  4. 其余走节点自带出站；原有的 routing.rules 追加在最后
  - `domainStrategy` 从 `AsIs` 提升为 `IPIfNonMatch`（显式 IP 策略不动）。
- 只有 `geosite:cn` / `geoip:cn` 两个类别，避免某个精简 dat 缺类别导致整份配置加载失败；
  没有规则文件时只用 `localhost` + 私有网段（`geoText` 会显示“仅使用基础规则”）。
- 规则文件：运行时下载 `geosite.dat` + `geoip.dat`（Loyalsoldier/v2ray-rules-dat，
  GitHub → jsDelivr 两个镜像顺序回退），校验体积后原子替换到
  `filesDir/xray/geodata/`，`meta.json` 记录时间与大小。
- 自动更新：应用启动时若未下载或超过 7 天，后台静默更新；主页“规则”卡片可手动“更新”。
- 装载方式：`xray_core_set_geodata_search_dir(geodataDir)` 在 `load_config_json` 之前调用，
  由 `start/restart` 的第 5 个参数传入。

### 7.1 ACL4SSR 规则集（可选，替代上面两种分流）

`tools/acl4ssr2way.py` 把 ACL4SSR 的 Clash 清单转成 way 规则集，映射与顺序照抄
`subscription-forge`（`app.py` 的 `RULES` / `converter.py`）：

| 清单 | 目标 | 清单 | 目标 |
|---|---|---|---|
| Tencent（blackmatrix7） | direct | ChinaCompanyIp | direct |
| LocalAreaNetwork | direct | ChinaIp | direct |
| UnBan | direct | ProxyLite | proxy |
| BanAD / BanProgramAD | block | Telegram / Netflix | proxy |
| ChinaDomain / GoogleCN | direct | Microsoft / Apple | direct |

- 转换：`DOMAIN-SUFFIX → domain:`、`DOMAIN → full:`、`DOMAIN-KEYWORD → keyword:`、
  `IP-CIDR[6] → ip`；域名小写去尾点、同清单去重。当前共 **14 组 / 13,086 条
  （5,246 域名 + 7,840 IP）**，JSON ≈ 258 KB。
- 落在 `filesDir/xray/rules.json`（`common/RuleSet.ets` 校验：≤64 组、≤200k 条）。
  转换结果随包内置为 `resources/rawfile/acl4ssr-way-rules.json`，首次启动自动灌入，
  所以没网（隧道还没起来时）也能直接用。
- 加载：`Rules.ets` 在启用时**用规则集取代** gfw / bypass 两套内置清单，
  顺序就是清单顺序（先匹配先生效），仍保留：屏蔽 QUIC → 私有网段直连 → 14 条清单 →
  原配置自带规则；默认路由仍是节点，`domainStrategy=IPIfNonMatch`，DNS 分流照旧。
- 更新：主页「规则」卡片里「分流规则集 → 获取/更新」在设备上下载同样的 14 个清单
  （GitHub → jsDelivr 回退）再转换；也可以把 JSON 直接 `hdc file send` 到
  `filesDir/xray/rules.json`（见 `tools/README.md`）。
- 校验：`host-import --check-config` 用核心自己的 `parse_xray_json` 检查生成结果
  （含 `outboundTag` 悬空检查），实测 `outboundTag`s 全部有效、0 条诊断错误。
- 代价：`config.json` 增大到 ≈264 KB；规则集变化后需要重连一次（配置在连接时生成）。

**规则集与广告拦截（主页「规则」卡片）**

三个控件，按字面意思用：

| 控件 | 作用 |
|---|---|
| 分流规则集 + **更换** | 显示当前这份（来源/组数/条数/生成时间）。点「更换」弹菜单：**内置 ACL4SSR**（随包快照，不联网）/ **在线更新**（拉 ACL4SSR 最新，需联网）/ **撤销上一次**（恢复备份）/ **自定义**（粘贴自己的 JSON，见 `pages/AddRules`） |
| **使用规则集** | 开启后由规则集决定哪些直连、哪些走节点；关闭则回到内置的 GFW/绕过大陆 |
| **拦截广告** | 开启后丢弃规则集里的 block 清单（BanAD 588 + BanProgramAD 991+19，共 **1,598 条**广告域名），命中即 blackhole 断开；关闭则只做直连/代理、不再拦广告 |

- 每次切换前自动把当前那份写进单槽备份 `filesDir/xray/rules-backup.json`，
  「撤销上一次」就是和它互换（连按两次回到原状态）。
- 来源标注：`内置 / 在线更新 / 备份回滚 / 自定义 / 本地文件`（hdc 推的没有 origin）。
- 自定义格式与生成器输出一致：
  `{"name":...,"lists":[{"name","target":"direct|proxy|block","domains":["domain:","full:","keyword:"],"ip":["CIDR"]}]}`，
  规则集页有「示例」按钮可直接填入最小样例。
- 真机验证：四种来源都点过（自定义 3 组 6 条 → `config.json` 5 条规则；备份换回 ACL4SSR → 16 条；
  内置重灌 → origin=`bundled`）；「拦截广告」关掉后规则从 16 条变 14 条（两条 block 清单消失），
  再打开恢复 16 条。

**即时生效（不重连、不弹提示）**

GFW / 绕过大陆 / 全局、使用规则集、拦截广告、更换规则集都只改路由表，所以走内核的
`xray_core_replace_routing_policy_json` 热替换（`native.replaceRouting`，经
`com.way.app.RELOAD_ROUTING` 事件请扩展进程执行）：

- 出站集合固定为 `[选中节点, direct, block]`，三种模式只差路由规则；GFW 的「默认直连」
  用末尾一条 `network: tcp,udp → direct` 兜底规则表达（内核不接受没有任何匹配字段的规则），
  不再靠调整出站顺序，因此热替换不会因为出站变了而失败。
- 实测：GFW ↔ 绕过大陆 ↔ 全局 来回切，`status.json` 的 `startedAt` 一直不变（没有重启内核），
  `config.json` 的规则数按模式变化（全局 0 条 / GFW 5 条 / 绕过大陆 5 条 / 规则集 17 条）。
- 热替换被拒（例如内核里跑的是旧版单节点配置）时自动退化为 stop+start 重启。
- 切换成功不再弹 toast（卡片本身就是状态反馈）；只有失败类提示（没规则集、没备份等）保留。

**首页布局（`pages/Index.ets`）**

- 标题栏没有底色：只有 `way` 和状态两个胶囊，中间完全透出页面；顶部叠一层很淡的渐变
  （`#A60B1020 → 透明`）只为状态栏图标可读，且 `hitTestBehavior(Transparent)` 不挡滚动。
- **状态灯**：`statusColor()` 只有三种颜色——已连接 `#3DDC97`（绿）、已挂起 `#FFC857`（黄）、
  其余一律 `#FF5C7A`（红，标题显示「未连接」）。状态胶囊用同色半透明底 + 同色描边 + 同色 `shadow` 发光。
- 卡片不是盖一层雾：光被**画进卡片自己的背景**（`radialGradient`，圆心在右上角、多段衰减到 0，
  所以没有边界），节点卡也有一份更弱同款；页面右上另有一团很小的环境光垫在卡片**下面**。
- 强度跟随实时吞吐：`glowLevel()` = `0.18 + 0.82 · min(1, log10(1 + 字节每秒/512) / 2.6)`，
  空载时只有微光，满速 1.0；卡片亮度、胶囊底/描边/发光、`way` 描边一起变强变弱。
- 状态卡片首行也走 `stateTitle()`：已连接 / 已挂起 / 连接中 / 未连接（真实报错文字仍然显示）。
- 状态栏/导航栏都是透明（`statusBarColor`/`navigationBarColor = '#00000000'`，窗口背景也设透明），
  页面渐变靠 `expandSafeArea` 一直画到屏幕最顶端，所以没有状态栏色带。
- 标题栏高度用 `onAreaChange` 实测后作为滚动区顶部留白，换机型/状态栏高度变化都不用改常量。
- 三张卡都默认收起，点整行展开、再点收起（`rulesExpanded` / `nodeExpanded` / `ssidExpanded`，
  都不持久化，进页面永远是收起）：`节点 + 当前节点名 + 延迟`、`规则 + 模式名`、`按需启动 + 已加 N 条`。
- 节点卡展开就是**节点列表**（手动 + 订阅，按 store 顺序，带 VLESS/HY2 徽标和当前选中勾），
  每行带**真实 RTT**（展开自动测、4 并发、3 s 超时；绿 <300 ms / 黄 <800 ms / 橙更慢 / 红「超时」），
  顶部有「测速」可重测；点某一行直接切过去：`selectEntry` → 重建配置 → 重启一次隧道。
  延迟是**纯 TCP 往返**（扩展进程里 `protectProcessNet` 下的 socket 直连 server:port，一次握手/RST 就是 1 RTT），
  不含 DNS/TLS/代理握手/HTTP；UI 进程自己发 socket 会绕回隧道形成自环，所以这次测量放在扩展进程做（`CONNECTIONS` 事件的 `latency` op）。
  卡片里不出现「添加节点」入口，添加/订阅仍在「管理」跳过去的节点页。
- 连接卡片（第一张）：已连接状态 + `内存 x MB · CPU y%`（扩展进程每 5 个 tick 采一次
  `hidebug.getPss()` / `getCpuUsage()`，写进 `status.json` 的 `pssKb` / `cpuPercent`），
  不再显示当前节点名（按反馈去掉）。
- 每行还会带 `rule_set=<命中的规则名>`：`Rules.ets` 生成规则时就写 `ruleTag`（ACL4SSR 清单名，或
  Private / QUIC / DoH / Default），内核补齐了 `RoutingRule.rule_tag` 解析 → `matched_rule_tag()` →
  `ConnectionInfo.rule_tag` → snapshot JSON 的 `ruleTag`。地址优先显示嗅探到的域名
  （`TCP browsercfg-drcn.cloud.dbankcloud.cn:443`），没有域名时退回拨号 IP；内核这次同时补了
  `ConnectionInfo.sniffed_domain`（TCP 从 `bridge_tcp_flow` 的首包嗅探结果取、UDP 从 QUIC 嗅探的
  `route_target` 取），并把 `should_sniff_tun_tcp` 放宽成「destOverride 里配了就嗅探」，与 Xray 行为一致。
- 状态卡的「连接」数字点开是**独立页 `pages/Connections`**（内核 `xray_core_connection_snapshot_json`
  经扩展进程转发）：顶部搜索、`活动连接 N · 最多显示 100 条`，每行 `TCP/UDP + 地址:端口 + 时长 + 关闭`，
  每秒刷新，关闭走 `xray_core_close_connection`。面板上不显示节点名（按反馈去掉）。
  顶部有 `活动 N` / `历史 M` 两个标签：消失的连接（自然结束或被关闭）会写进历史，
  记录域名/IP、时长、结束时刻与 `rule_set`；最多保留 200 条，存在 `filesDir/xray/conn-history.json`，
  重启应用也还在，历史页可一键「清空」。
  地址目前是内核记录的拨号目标（多为 IP:端口），嗅探到的域名还没有从内核透出。
- 卡片样式统一柔和化：`#101827` 底 + `#07FFFFFF` 细描边 + `radius 30` 的大阴影、圆角 20~22
  （状态卡 22），不再有硬边的「巧克力板」感。
- 「HarmonyOS 代理客户端」从标题下移到页面最底部（与内核版本一起作为页脚）；标题栏只剩 `way`。
- 应用图标（`app_icon.png`，512×512，AppScope 与 entry 各一份，由 `tmp/make_way_icon.py` 生成）：
  深色底 + 一条盘成 **W** 的公路（沥青带 + 车道边线 + 中央虚线），下方一道 **U** 形弧光，
  即「w + u（吴）」；路的尽头有一点光，取「黑暗中前进的方向」之意。
- 产物文件名随之统一为 `dist/way-<version>-signed.hap` / `-unsigned.hap`。
- 颜色字符串注意：ArkUI 的 8 位十六进制是 **`#AARRGGBB`（alpha 在前）**，写成 RGBA 会变成
  完全不透明的另一种颜色（这次「白色 7% 描边」就渲染成了亮黄色）。
**DoH DNS**

「规则」卡片里的 `DoH DNS` 开关（默认开）把 DNS 换成两个 HTTPS 解析器：

| 角色 | 地址 | 走法 |
|---|---|---|
| 国内 | `https+local://223.5.5.5/dns-query`（AliDNS，`domains: geosite:cn`） | 本地直连（`https+local` 不过路由） |
| 国外 | `https://1.1.1.1/dns-query`（Cloudflare） | 经路由，默认出站=节点；GFW 模式下另有 `ip: 1.1.1.1/32, 1.0.0.1/32 → 节点` 规则兜住 |

- 两个地址都用 IP，省掉 DoH 主机名自身的解析（证书含 IP SAN），避免 bootstrap 环路。
- 与规则集共存：国内域名走国内 DoH 得到国内 CDN 地址，国外域名走国外 DoH 再经节点出口。
- DoH 属于 `dns` 段而不是路由，**开关会重建配置并重启一次内核**（不同于上面的热切换）。
- 实测：开 DoH 后 `config.json` 的 `dns.servers` 就是上面两条；浏览器打开 `baidu.com`（国内 DoH 解析、直连）
  与 `google.com`（国外 DoH 经节点）都正常；`ability.log` 无 DNS 报错。
- 校验器注意：`host-import --check-config` 在 Windows 上会因为 `geodata path escapes configured directory`
  （路径 canonicalize 的 `\\?\` 前缀差异）拒绝带 `geosite:` 的 DNS 段；把该 matcher 去掉后
  `diagnostic_errors=0 dangling_rules=0`，设备端内核按原样接受（已在跑）。

## 8. 保活策略（参考 FlClash）

| FlClash 做法 | 本 HAP 的实现 |
|---|---|
| 前台服务承载内核，Activity 退出不断线 | 内核跑在 `VpnExtensionAbility` 进程；VPN 生效期间由系统保活，UI 退出不断 |
| 前台通知显示流量 | 每秒 `notificationManager.publish` 常驻通知（可关），显示 ↑↓ 与连接数 |
| 内核崩溃自动重启 | 1 s 看门狗：`native.isRunning()` 为假即重建 core（复用同一 tun fd），连续 3 次失败才放弃并写错误状态 |
| 网络切换重连 | `NetConnection` 的 `netAvailable` / `netLost` → `native.rebind()`（Hysteria2/QUIC 载体 + WireGuard 重新发 socket，保留会话） |
| 状态持久化 / 自动连接 | 记住上次连接状态与配置，打开应用自动恢复连接 |
| 界面状态实时性 | 扩展每秒写 `status.json` 心跳；UI 每 5 s 检查，无心跳就用已保存配置拉起扩展（1/2/4/8 s 退避，最多 5 次），不是只翻开关 |

### 8.1 0.10.4 的保活与挂起

- **单条通知**：连续任务由主 Ability 申请（`ContinuousTaskRequest` + `SUBMODE_LIVE_VIEW_NOTIFICATION`），扩展把 live view 画在同一个 notification id 上；不再另发普通通知，也不再启动无窗口 Ability（它会抢前台窗口，表现为启动图卡住或最近任务里出现两张卡片）。
- **申请顺序**：先申请任务拿到 `notificationId`，再启动 VPN 并把它传进去；通知被划掉时由 `continuousTaskCancel` 监听后自动重申请，并通过 `com.way.app.TASK_ID` 把新 id 广播给扩展。
- **SSID 挂起**：命中挂起规则的 Wi-Fi 时**全停**（`stopVpn` + `stopBackgroundRunning`，不留心跳/看门狗/通知）；在挂起 Wi-Fi 上点开关只显示“已挂起”（开关为开、琥珀色），不发起连接；挂起状态下点关闭则真正关闭，不会被规则再挂起。
- **恢复**：离开挂起 Wi-Fi 时按“刚启动”走一遍——重建配置 → 申请连续任务 → 启动 VPN，使任务/通知/心跳与冷启动一致；并用 `wifiConnectionChange` 事件驱动，App 在后台（定时器被冻结）时也能恢复。
- **关闭**：滑掉后台即完整退出——停监听、释放任务、停 VPN、清挂起标记，并记 `userOff` 不再自动重连。

### 8.2 0.10.4 的心跳看门狗与连接加固

- **双进程心跳**：扩展每个 tick 重写 `status.json`（`updatedAt` 就是心跳）。UI 每秒读一次，5 s 没有新心跳即判定扩展进程丢失；随后用**已保存的 config** 再次 `startVpn`——不 `buildAndSaveTunnel`、不先 `stopVpn`，属于“拉起”而不是“重启”。连续失败按 1/2/4/8 s 退避，5 次仍失败才翻开关并释放连续任务；一旦收到心跳立即清零预算。这样不会再出现“开关先被关掉，用户再点一次”的重启路径。
- **探针 15 s**：`probeLiveness()` 从每 30 个 tick 改为每 15 个 tick，成功/失败都写 `ability.log`（`probe ok …ms` / `probe failed kind=…`），日志增长本身就是扩展的活动信号，空载时也能看出它没死。
- **live view 时间戳**：通知文本追加会话时长和 `HH:mm:ss`。空载时 `↓0 B/s ↑0 B/s` 不再是一段永远相同的内容，系统不会把“内容未变”的 publish 当成 no-op。
- **连接重试**：`connect()` 先等通知权限（有界 2.5 s）并申请连续任务（最多 3 次），再把 notification id 交给扩展；随后最多 3 次 `startVpn`，每次用 `status.json` 验证（`running`，或仍在启动且有新鲜心跳的 `starting` 都算成功），失败则 `stopVpn` + 清状态后 0.5/1 s 退避重试。这修掉了“点三次才连上”。
- **桌面卡片**：`EntryFormAbility` 不再 import `AppLog`/`Xray`，避免卡片进程为了写一行日志加载 26 MB 的 `libentry.so`；`form_config.json` 的 `displayName`/`description` 改用普通字符串，避免 `$string:` 在 profile 里被转成数字 id 后解析失败。卡片仍不出现时先看应用沙箱 `files/xray/app.log` 里的 `[card]` 行：有 `form added` 说明 form 进程和配置都正常，问题在渲染；一行都没有则是系统没有绑定 form（签名/安装问题）。
- **启动器图标**：`AppScope/resources/base/media/layered_image.json` 指向 1024×1024 的 `icon_background`/`icon_foreground`；`app.json5` 和 `module.json5` 里所有 Ability 的 `icon` 都改成 `$media:layered_image`（module 的 icon 会覆盖 app 的，必须两处一起改）。`startWindowIcon` 仍用 512 的 `app_icon`。

## 9. 已知限制（务必读）

1. 本机真机（`VDE-AL10`，API 26）已 `hdc install` 并逐项验证，截图存 `verify/`：
   `01` 节点/订阅两个标签、`02` 已连接的 HTTP 测速、`03` 未连接 TCP 探测并按延迟排序、
   `04` 粘贴 JSON 拆成 3 个节点、`05` base64 的 JSON 也拆成 2 个节点、
   `06` 订阅编辑（改名/改地址）、`07`/`08` hy2 参数修复后订阅返回 8 个节点（含 4 个 HY2）、
   `09`/`10` 逐节点内核 HTTP 真连接延迟（并发 4、按延迟排序）、`11` 行内「测速」只测该节点、
   `12` ACL4SSR 规则集离线校验报告（文本）、
   `13`~`15` 规则集自定义页 / 自定义生效 / 备份回滚，
   `16`/`17` ACL4SSR 分流实证：把默认节点换成死节点后，`baidu.com` 仍能打开（直连规则命中）、
   `google.com` 打不开（代理规则命中）、`18` 规则卡片（含「拦截广告 1598 条」）、`19`「更换」菜单、
   `20` 规则卡片（DoH DNS 行）、`21`/`22` DoH 实测：baidu 走国内 DoH 直连、google 走国外 DoH 经节点、
   `23`~`25` 新版界面：规则卡收起 / 展开 / 滚动时标题栏磨砂；
   `26`/`27` 透明状态栏 + `way`/`已连接` 胶囊（顶部 / 滚动状态）；
   `29`/`30` 状态灯：已连接绿光、未连接红光（`way` 被同色光染到）；
   `31`/`32` 同一页面空载 vs 有流量时的光强对比；
   `33`~`35` 收起后的首页 / 节点展开 / 按需启动展开；`37` 节点卡内直接切节点；
   `39` 活动连接页（含关闭一条连接），`40` 节点卡内逐节点延迟。
2. 签名：见第 4 节；OpenHarmony 调试证书在华为设备上大概率需要换成 DevEco 自动签名。
3. 仅 arm64-v8a；模拟器（x86_64）无法安装。
4. 系统重启后不会自动拉起（鸿蒙不允许第三方应用开机自启），需手动打开应用。
5. `protectProcessNet()` 是 API 22+ 能力；失败时依赖“服务器 IP 排除路由”兜底，
   若服务器用域名且解析失败，仍可能形成环路（日志里会有 `resolve … failed`）。
   它保护的是整个应用（含 UI 进程），所以 UI 自己发的 HTTP 不进隧道（实测：8 节点
   一起测都是 72–172 ms，而 `stats` 里 `up=0 down=0`）。逐节点延迟因此改成由内核探
   （第 6 节）；`status.json.probeMs` 是当前节点用同一套探测得到的值。
6. TUN 侧 DNS：配置里有 `dns` 时用核心的 `198.18.0.1` 锚点；没有时用公共 DNS 走代理。
7. 逐节点内核探测要求节点在**运行中的配置**里：节点列表变化后需要重连一次才会更新；
   老配置 / 回退成单节点配置时自动退回 TCP/UDP 探测（行内标 `TCP`/`UDP`）。
8. WireGuard 只有 UDP，没有 QUIC 回应，未连接时探测会显示“超时”，这是探测方式的
   局限而不是节点不可用。
9. 45.66.217.56 那三台（JP-R/TK-V/JP-H/TK-H）在当前网络下直连 TCP 与 UDP 都不通，
   隧道里 `probe failed kind=2`；这属于线路/服务端状态，不是导入问题（8 个节点都能
   导入、能选中、能测速）。
10. ACL4SSR 规则集：`config.json` 会涨到 ≈266 KB（13,086 条），只在**连接时**生成，
    所以改了规则集或节点列表都要重连一次；内置那份是生成时刻的快照，想追新用卡片里的
    「更新」。应用内下载走 GitHub → jsDelivr，两个都不通时会失败（此时用内置或 hdc 推送）。
11. `tools/cache/`（下载的 14 个 `.list`）和 `tools/out/`（一次性校验用配置）是生成器
    的临时目录，已在 `.gitignore` 里。

## 10. 对上游代码的改动

仅 3 处，纯可移植性修正（`crates/xray-core-rs/src/socks/tproxy/linux.rs`）：

```rust
msg.msg_controllen = mem::size_of_val(&control) as _;   // glibc: size_t / OHOS musl: socklen_t
if (header.cmsg_len as usize) < size { … }              // cmsg_len 类型宽度不同
(header.cmsg_len as usize) - size
```

TPROXY 入站需要 root，在鸿蒙上本来用不到；协议行为零改动。

## 11. 目录

```
xray-hm/
├── build.ps1                    一键：Rust 产物 → hvigor → 签名 → 校验
├── dist/                        产物 HAP
├── sign/                        profile.json / profile.p7b / 证书链 / 校验输出
├── signing/                     way.p12 / way.cer / way.p7b（固定签名材料）
├── verify/                      真机验证截图
├── tools/                       acl4ssr2way.py（ACL4SSR → way 规则集）+ 用法说明
└── app/
    ├── AppScope/app.json5
    ├── build-profile.json5      compatibleSdkVersion 26.0.0
    └── entry/
        ├── build-profile.json5  externalNativeOptions (CMake, arm64-v8a)
        ├── src/main/module.json5  EntryAbility + XrayVpnAbility(type=vpn) + 权限
        ├── src/main/ets/
        │   ├── entryability/EntryAbility.ets
        │   ├── vpnextability/XrayVpnAbility.ets
        │   ├── pages/Index.ets        主页
        │   ├── pages/Configs.ets      节点 / 订阅（两个标签，订阅可编辑）
        │   ├── pages/AddConfig.ets    链接 / 订阅 / JSON 导入
        │   ├── pages/AddRules.ets     自定义规则集（粘贴/示例/预览）
        │   └── common/
        │       ├── Xray.ets           配置/导入/状态/日志/出站探测
        │       ├── Import.ets         链接、base64、JSON 按 outbounds 拆分
        │       ├── Subscription.ets   订阅拉取与替换
        │       ├── Store.ets          configs.json / subs.json（subId 归属）
        │       ├── Speedtest.ets      v2rayNG 式测速（内核 HTTP 探针 / TCP / UDP，并发 4）
        │       ├── TunnelConfig.ets   连接时把所有节点写进一份配置（tag=entry id）
        │       ├── RuleSet.ets        ACL4SSR 规则集（读/校验/写入/内置灌入）
        │       ├── RuleSource.ets     在设备上拉取 14 个 ACL4SSR 清单并转换
        │       ├── Latency.ets        QUIC 探测
        │       ├── Rules.ets          内置分流
        │       ├── Geodata.ets        规则文件
        │       ├── Ssid.ets           按 Wi-Fi 挂起
        │       └── AppLog.ets         app.log
        ├── src/main/cpp/
        │   ├── CMakeLists.txt
        │   ├── xray_napi.cpp     NAPI 桥（12 个方法，含 async probeOutbound）
        │   ├── include/xray_ffi.h
        │   └── prebuilt/arm64-v8a/libxray_ffi.a
        └── src/main/resources/   图标/文案/颜色/页面清单
```

















































