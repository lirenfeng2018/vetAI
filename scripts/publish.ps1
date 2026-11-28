<#
.SYNOPSIS
One-command publish for a Quarto blog: render, safe commit, resilient push, deployment verification.
#>
param(
    [string]$ProjectDir = 'F:\myblog\vetAI',
    [string]$Message = '',
    [string]$Remote = 'origin',
    [string]$Branch = 'main',
    [string]$OutputDir = 'docs',
    [int]$ProxyPort = 1080,
    [string]$ProxyHost = '127.0.0.1',
    [string]$ProxyScheme = 'socks5h',
    [int]$PushRetries = 3,
    [string[]]$Exclude = @('.workbuddy', '.codebuddy', '.obsidian', '.claudian'),
    [string[]]$BlockedPaths = @('.obsidian/', '.claudian/', '.workbuddy/', '.codebuddy/', '.env', 'credentials', 'secrets/'),
    [string]$RepoUrl = 'https://github.com/lirenfeng2018/vetAI',
    [string]$SiteUrl = 'https://myvetai.pages.dev/',
    [string]$CloudflareProject = 'myvetai',
    [string]$DeployHook = '',
    [string]$VerifyPath = 'posts.xml',
    [int]$DeployWaitSeconds = 90,
    [switch]$SkipRender,
    [switch]$SkipDeployCheck
)

$ErrorActionPreference = 'Stop'
$env:GIT_TERMINAL_PROMPT = '0'
$env:PYTHONIOENCODING = 'utf-8'

if (-not (Test-Path -LiteralPath $ProjectDir -PathType Container)) {
    throw "项目目录不存在：$ProjectDir"
}
Set-Location -LiteralPath $ProjectDir

if ([string]::IsNullOrWhiteSpace($DeployHook) -and -not [string]::IsNullOrWhiteSpace($env:CF_PAGES_DEPLOY_HOOK)) {
    $DeployHook = $env:CF_PAGES_DEPLOY_HOOK
}
if ([string]::IsNullOrWhiteSpace($DeployHook)) {
    $hookFile = Join-Path $env:USERPROFILE '.codebuddy\vetai-deploy-hook.txt'
    if (Test-Path -LiteralPath $hookFile) {
        $DeployHook = ([System.IO.File]::ReadAllText($hookFile)).Trim()
    }
}

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Assert-LastExit([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "$What 失败（exit code $LASTEXITCODE），发布已中止。" }
}
function Test-TcpPort([int]$Port) {
    if ($Port -le 0) { return $false }
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect($ProxyHost, $Port, $null, $null)
        return $async.AsyncWaitHandle.WaitOne(250)
    } catch { return $false }
    finally { $client.Close() }
}
function Get-ProxyOptions {
    $ports = @($ProxyPort) + @(7890, 10809, 7897, 10808, 1080)
    foreach ($p in ($ports | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
        if (Test-TcpPort $p) { "${ProxyScheme}://${ProxyHost}:$p" }
    }
}
function Get-NormalizedHash([string]$Path) {
    $text = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
}

if ($SkipRender) {
    Write-Step '1/5 跳过 quarto render'
} else {
    Write-Step '1/5 quarto render'
    & quarto render
    Assert-LastExit 'quarto render'
}

Write-Step '2/5 git add（自动跳过被 .gitignore 忽略的目录）'
$pathspecs = @('.')
foreach ($item in $Exclude) {
    & git check-ignore -q -- $item 2>$null
    if ($LASTEXITCODE -ne 0) { $pathspecs += ":(exclude)$item" }
}
& git add -A -- $pathspecs
Assert-LastExit 'git add'

Write-Step '3/5 git commit'
& git diff --cached --quiet
$hasChanges = ($LASTEXITCODE -ne 0)
if ($hasChanges) {
    if ([string]::IsNullOrWhiteSpace($Message)) { $Message = 'Update blog: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    & git commit -m $Message
    Assert-LastExit 'git commit'
    Write-Host "已提交：$Message"
} else {
    Write-Host '没有文件变更，跳过提交。'
}

& git rev-parse --verify "$Remote/$Branch" 2>$null
if ($LASTEXITCODE -eq 0) {
    $pending = & git diff --name-only "$Remote/$Branch..HEAD"
    $bad = @()
    foreach ($f in $pending) {
        foreach ($b in $BlockedPaths) { if ($f -like "*$b*") { $bad += $f; break } }
    }
    if ($bad.Count -gt 0) {
        throw "待推送提交包含禁止发布的文件（会触发 GitHub Push Protection）：`n$($bad -join "`n")`n请按 references/workflow.md 清理历史后再发布。"
    }
}

Write-Step "4/5 git push $Remote $Branch"
& curl.exe -s -o NUL --max-time 4 https://github.com 2>$null
$directOk = ($LASTEXITCODE -eq 0)
$modes = @()
if ($directOk) { $modes += 'direct' }
foreach ($proxy in @(Get-ProxyOptions)) { $modes += $proxy }
if (-not $directOk) { $modes += 'direct' }
$modes = @($modes | Select-Object -Unique)
if ($modes.Count -eq 0) { $modes = @('direct') }
$attempts = @()
for ($i = 0; $i -lt $PushRetries; $i++) { $attempts += $modes[$i % $modes.Count] }

$pushOk = $false
$lastOpts = @()
foreach ($mode in $attempts) {
    $opts = @('-c', 'http.lowSpeedLimit=1', '-c', 'http.lowSpeedTime=15')
    if ($mode -ne 'direct') { $opts += @('-c', "http.proxy=$mode") }
    Write-Host "尝试推送：$mode"
    & git @opts push $Remote $Branch
    if ($LASTEXITCODE -eq 0) { $pushOk = $true; $lastOpts = $opts; break }
    Start-Sleep -Seconds 2
}
if (-not $pushOk) {
    throw "git push 失败（已重试 $($attempts.Count) 次）。若为 non-fast-forward，先执行 git pull --rebase $Remote $Branch；若为网络错误，请开启本地代理或稍后重试。"
}

Write-Step '5/5 验证远端与线上部署'
$ls = & git @lastOpts ls-remote $Remote "refs/heads/$Branch"
Assert-LastExit 'git ls-remote'
$remoteHash = ((($ls | Select-Object -First 1) -split "`t")[0]).Trim()
$localHash = ((& git rev-parse HEAD) | Out-String).Trim()
if ($remoteHash -ne $localHash) { throw "远端 $Branch ($remoteHash) 与本地 HEAD ($localHash) 不一致。" }
Write-Host "远端已更新到 $remoteHash"

if (-not [string]::IsNullOrWhiteSpace($DeployHook)) {
    & curl.exe -s -X POST --max-time 20 --ssl-no-revoke -o NUL $DeployHook 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host '已触发 Cloudflare Deploy Hook' }
    else { Write-Warning 'Deploy Hook 调用失败，继续依赖 Git 自动部署。' }
}

if ($SkipDeployCheck) {
    Write-Host '已跳过线上部署校验（-SkipDeployCheck）。'
} else {
    $localFile = Join-Path $ProjectDir (Join-Path $OutputDir $VerifyPath)
    $verifyUrl = $SiteUrl.TrimEnd('/') + '/' + $VerifyPath.TrimStart('/')
    if (-not (Test-Path -LiteralPath $localFile)) {
        Write-Warning "验证文件不存在：$localFile，跳过线上校验。"
    } else {
        & git diff --quiet HEAD~1 HEAD -- "$OutputDir/$VerifyPath" 2>$null
        $markerChanged = ($LASTEXITCODE -ne 0)
        $localHash = Get-NormalizedHash $localFile
        $deployed = $false
        $deadline = (Get-Date).AddSeconds($DeployWaitSeconds)
        do {
            $tmp = Join-Path $env:TEMP ("vetai-verify-" + [guid]::NewGuid().ToString('N') + '.tmp')
            & curl.exe -sS -L --max-time 15 -o $tmp "$verifyUrl?v=$localHash" 2>$null
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp)) {
                $onlineHash = Get-NormalizedHash $tmp
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                if ($onlineHash -eq $localHash) { $deployed = $true; break }
            }
            Start-Sleep -Seconds 10
        } while ((Get-Date) -lt $deadline)

        if ($deployed -and $markerChanged) {
            Write-Host "线上已同步：$verifyUrl" -ForegroundColor Green
        } elseif ($deployed) {
            Write-Host "站点可访问：$verifyUrl" -ForegroundColor Green
            Write-Host "本次未改动 $VerifyPath，无法据此证明新部署；请在 Cloudflare Dashboard 确认最新部署。" -ForegroundColor Yellow
        } else {
            Write-Warning "线上 $VerifyPath 与本地不一致：Cloudflare Pages 可能尚未部署或 Git 连接已断开。请检查 https://dash.cloudflare.com/ -> Workers & Pages -> $CloudflareProject -> Deployments"
        }
    }
}

Write-Host "`n发布完成。" -ForegroundColor Green
Write-Host "GitHub: $RepoUrl"
Write-Host "站点: $SiteUrl"
