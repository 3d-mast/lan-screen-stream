$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$AppName = "lan-screen-stream"
$Repository = if ($env:LAN_SCREEN_STREAM_REPOSITORY) { $env:LAN_SCREEN_STREAM_REPOSITORY } else { "3d-mast/lan-screen-stream" }
$Branch = if ($env:LAN_SCREEN_STREAM_BRANCH) { $env:LAN_SCREEN_STREAM_BRANCH } else { "main" }
$NodeChannel = if ($env:LAN_SCREEN_STREAM_NODE_CHANNEL) { $env:LAN_SCREEN_STREAM_NODE_CHANNEL } else { "latest-v22.x" }
$InstallDir = if ($env:LAN_SCREEN_STREAM_HOME) { $env:LAN_SCREEN_STREAM_HOME } else { Join-Path $env:LOCALAPPDATA "LANScreenStream" }

function Write-Step([string]$Message) {
    Write-Host $Message
}

function Get-NodeMajor([string]$NodePath) {
    try {
        return [int](& $NodePath -p 'Number(process.versions.node.split(".")[0])')
    }
    catch {
        return 0
    }
}

function Install-PortableNode([string]$TempDir) {
    $Architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        "X64" { "x64" }
        "Arm64" { "arm64" }
        default { throw "Архитектура Windows не поддерживается: $($_)" }
    }

    Write-Step "Скачиваю переносимый Node.js 22 для win-$Architecture..."
    $SumsUrl = "https://nodejs.org/dist/$NodeChannel/SHASUMS256.txt"
    $SumsPath = Join-Path $TempDir "SHASUMS256.txt"
    curl.exe -fsSL $SumsUrl -o $SumsPath
    if ($LASTEXITCODE -ne 0) { throw "Не удалось скачать SHASUMS256.txt" }

    $Pattern = "^(?<hash>[a-f0-9]{64})\s+(?<file>node-v[^\s]+-win-$Architecture\.zip)$"
    $Match = Get-Content $SumsPath | Select-String -Pattern $Pattern | Select-Object -First 1
    if (-not $Match) { throw "Не найден архив Node.js для win-$Architecture" }

    $ArchiveName = $Match.Matches[0].Groups["file"].Value
    $ExpectedHash = $Match.Matches[0].Groups["hash"].Value.ToLowerInvariant()
    $ArchivePath = Join-Path $TempDir $ArchiveName

    curl.exe -fL --retry 3 "https://nodejs.org/dist/$NodeChannel/$ArchiveName" -o $ArchivePath
    if ($LASTEXITCODE -ne 0) { throw "Не удалось скачать Node.js" }

    $ActualHash = (Get-FileHash -Algorithm SHA256 $ArchivePath).Hash.ToLowerInvariant()
    if ($ActualHash -ne $ExpectedHash) { throw "Контрольная сумма Node.js не совпала" }

    $ExtractDir = Join-Path $TempDir "node-extract"
    Expand-Archive -Path $ArchivePath -DestinationPath $ExtractDir -Force
    $Extracted = Get-ChildItem $ExtractDir -Directory | Select-Object -First 1
    if (-not $Extracted) { throw "Архив Node.js пуст" }

    $RuntimeDir = Join-Path $InstallDir ".runtime"
    if (Test-Path $RuntimeDir) { Remove-Item $RuntimeDir -Recurse -Force }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Move-Item $Extracted.FullName $RuntimeDir

    return (Join-Path $RuntimeDir "node.exe")
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "curl.exe не найден. Нужна Windows 10/11 или установленный curl."
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lan-screen-stream-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    Write-Step "Установка $AppName из $Repository@$Branch"

    $NodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($NodeCommand -and (Get-NodeMajor $NodeCommand.Source) -ge 20) {
        $NodeBin = $NodeCommand.Source
        Write-Step "Использую установленный $(& $NodeBin --version)."
    }
    else {
        $NodeBin = Install-PortableNode $TempDir
    }

    $SourceZip = Join-Path $TempDir "source.zip"
    $SourceExtract = Join-Path $TempDir "source"
    Write-Step "Скачиваю исходники проекта..."
    curl.exe -fL --retry 3 "https://github.com/$Repository/archive/refs/heads/$Branch.zip" -o $SourceZip
    if ($LASTEXITCODE -ne 0) { throw "Не удалось скачать исходники" }

    Expand-Archive -Path $SourceZip -DestinationPath $SourceExtract -Force
    $SourceRoot = Get-ChildItem $SourceExtract -Directory | Select-Object -First 1
    if (-not $SourceRoot) { throw "Архив исходников пуст" }
    if (-not (Test-Path (Join-Path $SourceRoot.FullName "src\server.js"))) { throw "В архиве нет src/server.js" }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    foreach ($Name in @("src", "public")) {
        $Target = Join-Path $InstallDir $Name
        if (Test-Path $Target) { Remove-Item $Target -Recurse -Force }
        Copy-Item (Join-Path $SourceRoot.FullName $Name) $Target -Recurse -Force
    }
    foreach ($Name in @("package.json", "README.md", "LICENSE", ".gitignore")) {
        Copy-Item (Join-Path $SourceRoot.FullName $Name) (Join-Path $InstallDir $Name) -Force
    }

    $Launcher = Join-Path $InstallDir "lan-screen-stream.cmd"
    $LauncherContent = @'
@echo off
set "APP_DIR=%~dp0"
if exist "%APP_DIR%.runtime\node.exe" (
  "%APP_DIR%.runtime\node.exe" "%APP_DIR%src\server.js" %*
) else (
  node "%APP_DIR%src\server.js" %*
)
'@
    Set-Content -Path $Launcher -Value $LauncherContent -Encoding Ascii

    & $NodeBin --check (Join-Path $InstallDir "src\server.js") | Out-Null
    & $NodeBin --check (Join-Path $InstallDir "public\app.js") | Out-Null

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $PathParts = @()
    if ($UserPath) { $PathParts = $UserPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries) }
    if ($PathParts -notcontains $InstallDir) {
        $NewPath = if ($UserPath) { "$UserPath;$InstallDir" } else { $InstallDir }
        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
        $env:Path = "$env:Path;$InstallDir"
    }

    Write-Host ""
    Write-Host "Готово."
    Write-Host "Каталог: $InstallDir"
    Write-Host "Запуск:  lan-screen-stream"
    Write-Host "Прямой запуск: $Launcher"
    Write-Host ""
    Write-Host "В уже открытой старой консоли команда может появиться только после перезапуска окна."
}
finally {
    if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force }
}
