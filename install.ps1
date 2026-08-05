$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$AppName = "lan-screen-stream"
$Repository = if ($env:LAN_SCREEN_STREAM_REPOSITORY) { $env:LAN_SCREEN_STREAM_REPOSITORY } else { "3d-mast/lan-screen-stream" }
$Branch = if ($env:LAN_SCREEN_STREAM_BRANCH) { $env:LAN_SCREEN_STREAM_BRANCH } else { "main" }
$NodeChannel = if ($env:LAN_SCREEN_STREAM_NODE_CHANNEL) { $env:LAN_SCREEN_STREAM_NODE_CHANNEL } else { "latest-v22.x" }
$InstallDir = if ($env:LAN_SCREEN_STREAM_HOME) { $env:LAN_SCREEN_STREAM_HOME } else { Join-Path $env:LOCALAPPDATA "LANScreenStream" }

function Write-Step([string]$Message) {
    Write-Host "[lan-screen-stream] $Message"
}

function Invoke-Curl([string[]]$Arguments) {
    & curl.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "curl.exe failed with exit code $LASTEXITCODE"
    }
}

function Get-NodeMajor([string]$NodePath) {
    try {
        return [int](& $NodePath -p "Number(process.versions.node.split('.')[0])")
    }
    catch {
        return 0
    }
}

function Install-PortableNode([string]$TempDir) {
    $Architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        "X64" { "x64" }
        "Arm64" { "arm64" }
        default { throw "Unsupported Windows architecture: $($_)" }
    }

    Write-Step "Downloading portable Node.js 22 for win-$Architecture"

    $SumsUrl = "https://nodejs.org/dist/$NodeChannel/SHASUMS256.txt"
    $SumsPath = Join-Path $TempDir "SHASUMS256.txt"
    Invoke-Curl @("-fsSL", $SumsUrl, "-o", $SumsPath)

    $Pattern = "^(?<hash>[a-f0-9]{64})\s+(?<file>node-v[^\s]+-win-$Architecture\.zip)$"
    $Match = Get-Content $SumsPath | Select-String -Pattern $Pattern | Select-Object -First 1
    if (-not $Match) {
        throw "Node.js archive for win-$Architecture was not found"
    }

    $ArchiveName = $Match.Matches[0].Groups["file"].Value
    $ExpectedHash = $Match.Matches[0].Groups["hash"].Value.ToLowerInvariant()
    $ArchivePath = Join-Path $TempDir $ArchiveName

    Invoke-Curl @("-fL", "--retry", "3", "https://nodejs.org/dist/$NodeChannel/$ArchiveName", "-o", $ArchivePath)

    $ActualHash = (Get-FileHash -Algorithm SHA256 $ArchivePath).Hash.ToLowerInvariant()
    if ($ActualHash -ne $ExpectedHash) {
        throw "Node.js SHA256 checksum mismatch"
    }

    $ExtractDir = Join-Path $TempDir "node-extract"
    Expand-Archive -Path $ArchivePath -DestinationPath $ExtractDir -Force
    $Extracted = Get-ChildItem $ExtractDir -Directory | Select-Object -First 1
    if (-not $Extracted) {
        throw "Node.js archive is empty"
    }

    $RuntimeDir = Join-Path $InstallDir ".runtime"
    if (Test-Path $RuntimeDir) {
        Remove-Item $RuntimeDir -Recurse -Force
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Move-Item $Extracted.FullName $RuntimeDir

    return (Join-Path $RuntimeDir "node.exe")
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "curl.exe was not found. Windows 10/11 or a separate curl installation is required."
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lan-screen-stream-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    Write-Step "Installing $AppName from $Repository@$Branch"

    $NodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($NodeCommand -and (Get-NodeMajor $NodeCommand.Source) -ge 20) {
        $NodeBin = $NodeCommand.Source
        Write-Step "Using installed Node.js $(& $NodeBin --version)"
    }
    else {
        $NodeBin = Install-PortableNode $TempDir
    }

    $SourceZip = Join-Path $TempDir "source.zip"
    $SourceExtract = Join-Path $TempDir "source"

    Write-Step "Downloading project sources"
    Invoke-Curl @("-fL", "--retry", "3", "https://github.com/$Repository/archive/refs/heads/$Branch.zip", "-o", $SourceZip)

    Expand-Archive -Path $SourceZip -DestinationPath $SourceExtract -Force
    $SourceRoot = Get-ChildItem $SourceExtract -Directory | Select-Object -First 1
    if (-not $SourceRoot) {
        throw "Source archive is empty"
    }
    if (-not (Test-Path (Join-Path $SourceRoot.FullName "src\server.js"))) {
        throw "src/server.js is missing from the source archive"
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    foreach ($Name in @("src", "public")) {
        $Target = Join-Path $InstallDir $Name
        if (Test-Path $Target) {
            Remove-Item $Target -Recurse -Force
        }
        Copy-Item (Join-Path $SourceRoot.FullName $Name) $Target -Recurse -Force
    }

    foreach ($Name in @("package.json", "README.md", "LICENSE", ".gitignore")) {
        $SourceFile = Join-Path $SourceRoot.FullName $Name
        if (Test-Path $SourceFile) {
            Copy-Item $SourceFile (Join-Path $InstallDir $Name) -Force
        }
    }

    & $NodeBin --check (Join-Path $InstallDir "src\server.js") | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "src/server.js syntax check failed"
    }

    & $NodeBin --check (Join-Path $InstallDir "public\app.js") | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "public/app.js syntax check failed"
    }

    $Launcher = Join-Path $InstallDir "lan-screen-stream.cmd"
    $LauncherLines = @(
        "@echo off",
        "setlocal",
        "set `"APP_DIR=%~dp0`"",
        "set `"NODE_BIN=$NodeBin`"",
        "`"%NODE_BIN%`" `"%APP_DIR%src\server.js`" %*"
    )
    Set-Content -Path $Launcher -Value $LauncherLines -Encoding Ascii

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $PathParts = @()
    if ($UserPath) {
        $PathParts = $UserPath.Split(';', [System.StringSplitOptions]::RemoveEmptyEntries)
    }

    if ($PathParts -notcontains $InstallDir) {
        $NewPath = if ($UserPath) { "$UserPath;$InstallDir" } else { $InstallDir }
        [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    }

    Write-Host ""
    Write-Host "Installation completed."
    Write-Host "Directory: $InstallDir"
    Write-Host "Start:     lan-screen-stream"
    Write-Host "Direct:    $Launcher"
    Write-Host ""
    Write-Host "Close and reopen the terminal before using the short command."
}
finally {
    if (Test-Path $TempDir) {
        Remove-Item $TempDir -Recurse -Force
    }
}
