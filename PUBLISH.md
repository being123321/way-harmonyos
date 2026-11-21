# 发布说明（本地已完成，只差推送）

本目录已经是一个可以直接推送的 Git 仓库：`git log` 有一条完整提交，`git ls-files` 99 个文件、约 6.5 MB。

## 为什么还没到 GitHub

这台机器上没有可用的 GitHub 凭据：`git`（portablegit）没有 `user.name/email`、没有
`~/.git-credentials`，`gh` CLI 也未安装，环境里 `GH_TOKEN` / `GITHUB_TOKEN` 都是空的。
推送需要你的账号授权，任何替代方式都不该由我代填。

## 之一：用 gh 登录（推荐）

```powershell
winget install --id GitHub.cli          # 或者下载 GitHub CLI 安装包
gh auth login                            # 选 HTTPS → 浏览器授权
gh repo create way --public --source . --remote origin --push
```

## 之二：用 Personal Access Token

```powershell
$env:GH_TOKEN = 'ghp_...'    # 只需 repo 权限
git remote add origin https://github.com/<你的账号>/way.git
git push -u origin main
```

## 之三：你自己在网页上建仓库再推

```powershell
git remote add origin https://github.com/<你的账号>/way.git
git branch -M main
git push -u origin main
```

## 推送后还要做的一步：挂 Release

未签名 HAP 没有进仓库（`.gitignore` 排除了 `*.hap`），需要作为 Release 资产上传：

```powershell
gh release create v0.10.1 "..\xray-hm\dist\way-0.10.1-unsigned.hap" `
  --title "way 0.10.1" `
  --notes "首个公开构建。未签名 HAP，需自行签名后安装。"
```

或在网页 `Releases → Draft a new release` 手动上传
`..\xray-hm\dist\way-0.10.1-unsigned.hap`（28,602,840 B，SHA256
`CEE0AB02FD9ED8CFF70435A3DF2AEB908032E268F40E265CAEEC48D2627D8350`）。

## 仓库里有什么

```
README.md             项目介绍、构建方法、来源与声明（含指定免责声明）
NOTICE                MPL-2.0 归属：内核、补丁、ACL4SSR 数据
LICENSE               MPL-2.0 全文
kernel/               对 aimalygin/xray-rust v0.10.1 的移植补丁 + 改动说明
app/                  ArkTS 工程源码（不含构建产物、签名材料、二进制）
tools/                ACL4SSR → way 规则集转换脚本
verify/               50 张真机验证截图
docs-ARCHITECTURE.md  实现说明
```

**没有**包含：`signing/`（开发者证书与私钥）、`dist/`（HAP 走 Release）、
`app/entry/src/main/cpp/prebuilt/`（151 MB 静态库，需自行编译内核）、
`local.properties`（本机 SDK 路径）、设备 UDID。
