# Starts the published app against the CI queues, takes screenshots, prints through the local API and checks the
# pages that come out.
param(
    [string] $App = 'dist/app/NodePrint.exe',
    [string] $Out = 'artifacts/run'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
$api = 'http://127.0.0.1:19233'

$configDir = Join-Path $env:LOCALAPPDATA 'NODE Print'
New-Item -ItemType Directory -Force $configDir | Out-Null
@{
    channels = @{ label = 'NODE CI Label'; document = 'NODE CI Document' }
    allowedOrigins = @()
    launchAtLogin = $false
} | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $configDir 'config.json')

$process = Start-Process $App -PassThru
$status = $null
$deadline = (Get-Date).AddSeconds(90)
while (-not $status -and (Get-Date) -lt $deadline -and -not $process.HasExited) {
    Start-Sleep -Milliseconds 500
    try { $status = Invoke-RestMethod "$api/status" -TimeoutSec 2 } catch { }
}
if (-not $status) {
    Get-WinEvent -LogName Application -MaxEvents 20 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -in 'Application Error', '.NET Runtime', 'Windows Error Reporting' } |
        Format-List TimeCreated, ProviderName, Message
    throw "The app did not answer on $api (exited: $($process.HasExited))"
}
$status | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Out 'status.json')
Invoke-RestMethod "$api/printers" | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Out 'printers.json')
Get-Content (Join-Path $Out 'status.json')

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Screen {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT rect, int size);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(int flags, int dx, int dy, int data, IntPtr extra);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
}
'@
function Save-Screen([int] $left, [int] $top, [int] $width, [int] $height, [string] $path) {
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($left, $top, 0, 0, $bitmap.Size)
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
}
$window = [Screen]::FindWindow($null, 'NODE Print')
if ($window -eq [IntPtr]::Zero) { throw 'No NODE Print window' }
[Screen]::SetForegroundWindow($window) | Out-Null
Start-Sleep -Seconds 3
$rect = New-Object Screen+RECT
[Screen]::DwmGetWindowAttribute($window, 9, [ref] $rect, 16) | Out-Null
$width = $rect.Right - $rect.Left; $height = $rect.Bottom - $rect.Top
"window $($rect.Left),$($rect.Top) ${width}x${height} at $([Screen]::GetDpiForWindow($window)) dpi"
Save-Screen $rect.Left $rect.Top $width $height (Join-Path $Out 'main-window.png')
Save-Screen ($rect.Left - 40) ($rect.Top - 40) ($width + 80) ($height + 80) (Join-Path $Out 'main-window-frame.png')

# The label card's centre: 20 + 240 across, 92 + 30 down, in window DIPs.
$scale = [Screen]::GetDpiForWindow($window) / 96
[Screen]::SetCursorPos($rect.Left + [int](260 * $scale), $rect.Top + [int](122 * $scale)) | Out-Null
Start-Sleep -Milliseconds 300
[Screen]::mouse_event(0x2, 0, 0, 0, [IntPtr]::Zero); [Screen]::mouse_event(0x4, 0, 0, 0, [IntPtr]::Zero)
Start-Sleep -Seconds 2
Save-Screen $rect.Left $rect.Top $width ([Math]::Min($height + 300, 768 - $rect.Top)) (Join-Path $Out 'printer-list.png')
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')

function Get-PdfPages([string] $path) {
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::Latin1)
    $boxes = [regex]::Matches($text, '/MediaBox\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]')
    $boxes | ForEach-Object { '{0}x{1}' -f [Math]::Round([double]$_.Groups[3].Value - [double]$_.Groups[1].Value), [Math]::Round([double]$_.Groups[4].Value - [double]$_.Groups[2].Value) }
}
function Invoke-Print([string] $channel, [string] $file, [string] $output, [string[]] $expected) {
    Remove-Item $output -ErrorAction SilentlyContinue
    $response = Invoke-WebRequest -Method Post -Uri "$api/print?channel=$channel&title=CI%20$channel" -ContentType 'application/pdf' -InFile $file -SkipHttpErrorCheck
    "$channel -> $($response.StatusCode) $($response.Content)"
    if ($response.StatusCode -ne 200) { throw "print $channel failed" }
    $deadline = (Get-Date).AddSeconds(60)
    $pages = $null
    while (-not $pages -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try { $stream = [IO.File]::Open($output, 'Open', 'Read', 'None'); $stream.Dispose(); $pages = @(Get-PdfPages $output) } catch { }
    }
    Copy-Item $output (Join-Path $Out "app-$channel.pdf")
    "$channel pages: $($pages -join ', ') (expected $($expected -join ', '))"
    if (($pages -join ',') -ne ($expected -join ',')) { throw "$channel came out as $($pages -join ', ')" }
}
Invoke-Print 'label' 'testdata/zpl/border-4x6-203.pdf' 'C:\nodeprint-ci\label.pdf' @('288x432')
Invoke-Print 'document' 'windows/NodePrint.Printing.Tests/Fixtures/letter-mixed.pdf' 'C:\nodeprint-ci\document.pdf' @('612x792', '792x612')

$bad = Invoke-WebRequest -Method Post -Uri "$api/print?channel=nope" -ContentType 'application/pdf' -InFile 'testdata/zpl/border-4x6-203.pdf' -SkipHttpErrorCheck
"bad channel -> $($bad.StatusCode) $($bad.Content)"
if ($bad.StatusCode -ne 400) { throw 'BAD_CHANNEL not returned' }
$preflight = Invoke-WebRequest -Method Options -Uri "$api/print?channel=label" -Headers @{ Origin = 'https://nrp.node.live'; 'Access-Control-Request-Method' = 'POST'; 'Access-Control-Request-Private-Network' = 'true' } -SkipHttpErrorCheck
"preflight -> $($preflight.StatusCode) $($preflight.Headers['Access-Control-Allow-Origin']) $($preflight.Headers['Access-Control-Allow-Private-Network'])"
if ($preflight.StatusCode -ne 204) { throw 'preflight failed' }

Stop-Process -Id $process.Id
