# Installs the packed app, serves it a Velopack feed whose newest version is the same build packed again as 9.9.9
# (with a delta from the packed version), and checks that the app updates itself to it on its own and comes back
# listening. Uninstalls at the end.
param(
    [string] $Releases = 'dist/releases',
    [string] $App = 'dist/app',
    [string] $Feed = 'dist/feed',
    [string] $Out = 'artifacts/update'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
$api = 'http://127.0.0.1:19233'
$fake = '9.9.9'
$root = Join-Path $env:LOCALAPPDATA 'NodePrint'
$configDir = Join-Path $env:LOCALAPPDATA 'NODE Print'
$errorLog = Join-Path $configDir 'error.log'
$velopackLog = Join-Path $env:LOCALAPPDATA 'velopack\velopack_NodePrint.log'

# Velopack's manifest of what current\ holds; it is briefly gone while Update.exe swaps the folder.
function Get-InstalledVersion {
    try {
        if ((Get-Content -Raw (Join-Path $root 'current\sq.version')) -match '<version>([^<]+)</version>') { return $Matches[1] }
    } catch { }
}

function Get-Listener {
    (Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort 19233 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
}

function Get-Status {
    try { Invoke-RestMethod "$api/status" -TimeoutSec 2 } catch { $null }
}

function Remove-Install {
    Get-Process NodePrint -ErrorAction SilentlyContinue | Stop-Process -Force
    $update = Join-Path $root 'Update.exe'
    if (Test-Path $update) { Start-Process $update -ArgumentList '--silent', 'uninstall' -Wait }
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

$files = $null
try {
    Remove-Install
    New-Item -ItemType Directory -Force $configDir | Out-Null
    @{ channels = @{ label = 'NODE CI Label'; document = 'NODE CI Document' }; allowedOrigins = @(); launchAtLogin = $false } |
        ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $configDir 'config.json')
    Remove-Item $errorLog, $velopackLog -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Force $Feed | Out-Null
    Copy-Item (Join-Path $Releases "NodePrint-$env:VERSION-full.nupkg") $Feed
    vpk pack --packId NodePrint --packVersion $fake --runtime win-x64 --packDir $App --mainExe NodePrint.exe `
        --packTitle "NODE Print" --packAuthors NODE --icon windows/NodePrint.App/Assets/NodePrint.ico --outputDir $Feed
    if ($LASTEXITCODE -ne 0) { throw "vpk pack $fake failed" }
    $index = Get-Content -Raw (Join-Path $Feed 'releases.win.json') | ConvertFrom-Json
    $index.Assets | Format-Table Version, Type, FileName, Size -AutoSize | Out-String | Write-Output
    if ($index.Assets.FileName -notcontains "NodePrint-$fake-delta.nupkg") { throw "the feed has no delta to $fake" }

    $files = Start-Process python -ArgumentList '-m', 'http.server', '8098', '--bind', '127.0.0.1', '--directory', $Feed -PassThru -WindowStyle Hidden
    foreach ($try in 1..40) {
        try { Invoke-WebRequest -Uri 'http://127.0.0.1:8098/releases.win.json' -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 250 }
    }

    $setup = Start-Process (Join-Path $Releases 'NodePrint-win-Setup.exe') -ArgumentList '--silent' -Wait -PassThru
    "setup exited with $($setup.ExitCode); current\ holds $(Get-InstalledVersion)"
    if ($setup.ExitCode -ne 0 -or (Get-InstalledVersion) -ne $env:VERSION) { throw "Setup.exe --silent did not install $env:VERSION" }

    $env:NODE_PRINT_UPDATES = 'http://127.0.0.1:8098'
    $first = Start-Process (Join-Path $root 'current\NodePrint.exe') -ArgumentList '--tray' -PassThru
    $env:NODE_PRINT_UPDATES = $null
    $started = Get-Date
    "started $($first.Id) with NODE_PRINT_UPDATES"

    $deadline = $started.AddSeconds(180)
    $updated = $null
    $sawFirst = $false
    while (-not $updated -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $listener = Get-Listener
        if ($listener -eq $first.Id) { $sawFirst = $true }
        if ($first.HasExited -and $listener -and $listener -ne $first.Id -and (Get-InstalledVersion) -eq $fake -and (Get-Status)) {
            $updated = $listener
        }
    }
    if (-not $updated) {
        throw "no update to $fake within 180 s (first listened: $sawFirst, first exited: $($first.HasExited), listener: $(Get-Listener), current\ holds $(Get-InstalledVersion))"
    }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $updated"
    "updated in $([int]((Get-Date) - $started).TotalSeconds) s: pid $($first.Id) -> $updated, current\ holds $(Get-InstalledVersion)"
    "new process: $($process.CommandLine)"
    if ($process.ExecutablePath -ne (Join-Path $root 'current\NodePrint.exe')) { throw "the new version runs from $($process.ExecutablePath)" }
    if ($process.CommandLine -notmatch '--tray') { throw 'the new version was not started with --tray' }

    # The new version checks the same feed 2 s after its start and finds nothing newer than itself.
    Start-Sleep -Seconds 10
    if ((Get-Listener) -ne $updated) { throw "the app restarted again after reaching $fake" }
    $lines = @(Get-Content $errorLog -ErrorAction SilentlyContinue)
    "error.log:"; $lines
    if (-not ($lines -match "Update $fake downloaded and is being installed")) { throw 'error.log has no line for the update' }
    if (@($lines -match '^\S+ Update').Count -ne 1) { throw 'error.log has more than the one update line' }
    if (-not (Select-String -Path $velopackLog -Pattern 'Delta update download complete' -Quiet)) { throw 'the update did not come from the delta' }
    'the update came from the delta package'
}
finally {
    if ($files) { Stop-Process -Id $files.Id -ErrorAction SilentlyContinue }
    Remove-Install
    "uninstalled: $(-not (Test-Path $root))"
    if (Test-Path $velopackLog) { Copy-Item $velopackLog $Out; 'velopack log:'; Get-Content $velopackLog -Tail 80 }
    if (Test-Path $errorLog) { Copy-Item $errorLog $Out }
}
