# Creates (once) and pushes the way repo, then attaches the unsigned HAP to a
# release. Needs an authenticated gh CLI:
#   tools\gh\bin\gh.exe auth login          # browser/device flow
#   or: $env:GH_TOKEN = 'ghp_...' ; .\push.ps1
[CmdletBinding()]
param(
    [string]$Repo = 'way-harmonyos',
    [string]$Gh,
    [string]$Hap = (Join-Path $PSScriptRoot '..\xray-hm\dist\way-0.10.1-unsigned.hap'),
    [string]$Tag = 'v0.10.1'
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path $PSScriptRoot

if (-not $Gh) {
    $candidates = @(
        (Join-Path (Split-Path (Split-Path $root -Parent) -Parent) 'tools\gh\bin\gh.exe'),
        "$env:ProgramFiles\GitHub CLI\gh.exe",
        (Get-Command gh -ErrorAction SilentlyContinue).Source
    ) | Where-Object { $_ -and (Test-Path $_) }
    if (-not $candidates) { throw 'gh CLI not found: install GitHub CLI or pass -Gh <path>' }
    $Gh = @($candidates)[0]
}

& $Gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "gh is not authenticated. Run: `"$Gh`" auth login   (or set `$env:GH_TOKEN)"
}

$owner = (& $Gh api user --jq .login 2>$null).Trim()
if (-not $owner) { throw 'Could not read the GitHub account for this token' }
Write-Output "account: $owner"

Push-Location $root
try {
    $hasRemote = (git remote) -contains 'origin'
    if (-not $hasRemote) {
        & $Gh repo create $Repo --public --source . --remote origin --push 2>&1 | ForEach-Object { $_ }
        if ($LASTEXITCODE -ne 0) { throw 'gh repo create failed' }
    } else {
        git push -u origin main 2>&1 | ForEach-Object { $_ }
        if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
    }

    $existing = & $Gh release view $Tag --repo "$owner/$Repo" --json tagName 2>$null
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $Hap) {
            & $Gh release create $Tag $Hap --repo "$owner/$Repo" `
                --title "way 0.10.1" `
                --notes "首个公开构建。未签名 HAP（arm64-v8a / API 26），需自行签名后安装。

- 内核 aimalygin/xray-rust v0.10.1 + kernel/way-ohos.patch
- 连接列表显示 rule_set 与嗅探域名，活动/历史分页
- 订阅按 outbound 拆分、分层测速、ACL4SSR 规则集热切换、广告拦截、DoH DNS

非官方鸿蒙移植，供个人学习与技术研究。如有权利或授权问题，请通过 Issues 联系维护者。" 2>&1 | ForEach-Object { $_ }
        } else {
            Write-Output "release skipped: $Hap not found"
        }
    } else {
        Write-Output "release $Tag already exists"
    }

    Write-Output ''
    Write-Output "repo:    https://github.com/$owner/$Repo"
    Write-Output "release: https://github.com/$owner/$Repo/releases/tag/$Tag"
} finally {
    Pop-Location
}
