param(
    [string]$Message = ""
)

$ErrorActionPreference = 'Stop'
$env:GIT_TERMINAL_PROMPT = '0'
Set-Location (Join-Path $PSScriptRoot '..')

function Write-Step([string]$Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Assert-LastExit([string]$What) {
    if ($LASTEXITCODE -ne 0) {
        throw "$What 失败（exit code $LASTEXITCODE），发布已中止。"
    }
}

function Test-LocalProxy([int]$Port = 1080) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        return $async.AsyncWaitHandle.WaitOne(300)
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

Write-Step '1/4 quarto render'
& quarto render
Assert-LastExit 'quarto render'

Write-Step '2/4 git add（排除 .workbuddy/）'
& git add -A -- . ':(exclude).workbuddy'
Assert-LastExit 'git add'

Write-Step '3/4 git commit'
& git diff --cached --quiet
$hasChanges = ($LASTEXITCODE -ne 0)
if ($hasChanges) {
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = 'Update blog: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
    }
    & git commit -m $Message
    Assert-LastExit 'git commit'
    Write-Host "已提交：$Message"
} else {
    Write-Host '没有文件变更，跳过提交。'
}

Write-Step '4/4 git push origin main'
$gitOpts = @()
& curl.exe -s -o NUL --max-time 4 https://github.com 2>$null
$directOk = ($LASTEXITCODE -eq 0)
if (-not $directOk -and (Test-LocalProxy)) {
    $gitOpts += @('-c', 'http.proxy=socks5h://127.0.0.1:1080')
    Write-Host 'GitHub 直连不可用，改用本机 SOCKS5 代理 127.0.0.1:1080' -ForegroundColor Yellow
}
$gitOpts += @('-c', 'http.lowSpeedLimit=1', '-c', 'http.lowSpeedTime=20')
& git @gitOpts push origin main
if ($LASTEXITCODE -ne 0) {
    throw 'git push 失败。若提示 non-fast-forward，请先执行 git pull --rebase origin main；若为网络错误，请确认代理已开启。'
}

Write-Host "`n发布完成。" -ForegroundColor Green
Write-Host 'GitHub: https://github.com/lirenfeng2018/vetAI'
Write-Host 'Cloudflare Pages 会在 push 后自动部署 docs/，通常 1-2 分钟生效。'
Write-Host '站点: https://myvetai.pages.dev/'
Write-Host '部署记录: https://dash.cloudflare.com/ -> Workers & Pages -> myvetai'
