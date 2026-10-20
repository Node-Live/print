# Starts the published app against the CI queues, takes screenshots, prints through the local API (bytes and URL
# forms) and checks what comes out.
param(
    [string] $App = 'dist/app/NodePrint.exe',
    [string] $Out = 'artifacts/run'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out | Out-Null
$api = 'http://127.0.0.1:19233'
$configDir = Join-Path $env:LOCALAPPDATA 'NODE Print'
New-Item -ItemType Directory -Force $configDir | Out-Null
$failures = [System.Collections.Generic.List[string]]::new()

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Screen {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT rect, int size);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(int flags, int dx, int dy, int data, IntPtr extra);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);
    delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, System.Text.StringBuilder text, int max);
    public static IntPtr Find(uint pid) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hwnd, data) => {
            uint owner; GetWindowThreadProcessId(hwnd, out owner);
            var title = new System.Text.StringBuilder(64); GetWindowText(hwnd, title, 64);
            if (owner == pid && title.ToString() == "NODE Print") { found = hwnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
    public static RECT Bounds(IntPtr hwnd) { RECT r; DwmGetWindowAttribute(hwnd, 9, out r, 16); return r; }
}
'@

function Write-Config($label, $document) {
    @{ channels = @{ label = $label; document = $document }; allowedOrigins = @(); launchAtLogin = $false } |
        ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $configDir 'config.json')
}

function Wait-Api($process, [int] $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        try { return Invoke-RestMethod "$api/status" -TimeoutSec 2 } catch { Start-Sleep -Milliseconds 500 }
    }
    return $null
}

function Find-Window($process) {
    for ($i = 0; $i -lt 40; $i++) {
        $window = [Screen]::Find([uint32]$process.Id)
        if ($window -ne [IntPtr]::Zero) { return $window }
        Start-Sleep -Milliseconds 250
    }
    throw "No NODE Print window for process $($process.Id)"
}

function Save-Screen([int] $left, [int] $top, [int] $width, [int] $height, [string] $name) {
    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($left, $top, 0, 0, $bitmap.Size)
    $bitmap.Save((Join-Path $Out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
}

function Save-Window($window, [string] $name, [int] $below = 0) {
    [Screen]::SetForegroundWindow($window) | Out-Null
    Start-Sleep -Seconds 3
    $rect = [Screen]::Bounds($window)
    $height = [Math]::Min($rect.Bottom - $rect.Top + $below, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height - $rect.Top)
    if ($rect.Right -le $rect.Left -or $height -le 0) { $failures.Add("$name`: no window bounds ($($rect.Left),$($rect.Top),$($rect.Right),$($rect.Bottom))"); return }
    Save-Screen $rect.Left $rect.Top ($rect.Right - $rect.Left) $height $name
    "$name`: $($rect.Right - $rect.Left)x$($rect.Bottom - $rect.Top) at $([Screen]::GetDpiForWindow($window)) dpi"
}

# A point in DIPs from the client area's top-left, inside the window's 1px frame.
function Get-Point($window, [double] $x, [double] $y) {
    $rect = [Screen]::Bounds($window)
    $scale = [Screen]::GetDpiForWindow($window) / 96
    return @(($rect.Left + 1 + [int]($x * $scale)), ($rect.Top + 1 + [int]($y * $scale)))
}

function Invoke-Click($window, [double] $x, [double] $y) {
    $point = Get-Point $window $x $y
    [Screen]::SetCursorPos($point[0], $point[1]) | Out-Null
    Start-Sleep -Milliseconds 300
    [Screen]::mouse_event(0x2, 0, 0, 0, [IntPtr]::Zero); [Screen]::mouse_event(0x4, 0, 0, 0, [IntPtr]::Zero)
}

function Start-App {
    Start-Process $App -PassThru
}

function Get-PdfPages([string] $path) {
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::Latin1)
    [regex]::Matches($text, '/MediaBox\s*\[\s*([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*\]') | ForEach-Object {
        '{0}x{1}' -f [Math]::Round([double]$_.Groups[3].Value - [double]$_.Groups[1].Value),
            [Math]::Round([double]$_.Groups[4].Value - [double]$_.Groups[2].Value)
    }
}

function Invoke-Print([string] $channel, [string] $file, [string] $type, [string] $output, [string[]] $expected) {
    Remove-Item $output -ErrorAction SilentlyContinue
    $uri = "$api/print?channel=$channel&title=CI+$channel"
    $response = if ($type -eq 'url') {
        Invoke-WebRequest -Method Post -Uri $uri -ContentType 'application/json' -Body (@{ url = $file } | ConvertTo-Json) -SkipHttpErrorCheck
    } else {
        Invoke-WebRequest -Method Post -Uri $uri -ContentType $type -InFile $file -SkipHttpErrorCheck
    }
    "$channel $type -> $($response.StatusCode) $($response.Content)"
    if ($response.StatusCode -ne 200) { $failures.Add("print $channel $type answered $($response.StatusCode)"); return }
    $deadline = (Get-Date).AddSeconds(60)
    $pages = $null
    while (-not $pages -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try { $stream = [IO.File]::Open($output, 'Open', 'Read', 'None'); $stream.Dispose(); $pages = @(Get-PdfPages $output) } catch { }
    }
    $name = "app-$channel-$type-$([IO.Path]::GetFileNameWithoutExtension($file))".Replace('/', '-')
    if (Test-Path $output) { Copy-Item $output (Join-Path $Out "$name.pdf") }
    "$name pages: $($pages -join ', ') (expected $($expected -join ', '))"
    if (($pages -join ',') -ne ($expected -join ',')) { $failures.Add("$name came out as $($pages -join ', ')") }
}

# The designed window against the CI queues.
Write-Config 'NODE CI Label' 'NODE CI Document'
$process = Start-App
$status = Wait-Api $process 90
if (-not $status) {
    Get-Content (Join-Path $configDir 'error.log') -ErrorAction SilentlyContinue
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    Save-Screen 0 0 $bounds.Width $bounds.Height 'desktop'
    throw "The app did not answer on $api (exited: $($process.HasExited))"
}
$status | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Out 'status.json')
Invoke-RestMethod "$api/printers" | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Out 'printers.json')
$window = Find-Window $process
Save-Window $window 'design-main-window'
$rect = [Screen]::Bounds($window)
Save-Screen ($rect.Left - 40) ($rect.Top - 40) ($rect.Right - $rect.Left + 80) ($rect.Bottom - $rect.Top + 80) 'design-main-window-frame'
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Save-Screen 0 0 $bounds.Width $bounds.Height 'desktop'
foreach ($point in @(@(100, 20, 'drag strip'), @(497, 16, 'close button'), @(260, 122, 'label card'))) {
    $p = Get-Point $window $point[0] $point[1]
    "hit test at $($point[2]): $([Screen]::SendMessage($window, 0x84, [IntPtr]::Zero, [IntPtr](($p[1] -shl 16) -bor $p[0])))"
}
Invoke-Click $window 260 122
Start-Sleep -Seconds 3
Save-Window $window 'design-printer-list' 260
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')
Get-Content (Join-Path $configDir 'error.log') -ErrorAction SilentlyContinue

Invoke-Print 'label' 'testdata/zpl/border-4x6-203.pdf' 'application/pdf' 'C:\nodeprint-ci\label.pdf' @('288x432')
Invoke-Print 'label' 'windows/NodePrint.Printing.Tests/Fixtures/label-landscape.png' 'image/png' 'C:\nodeprint-ci\label.pdf' @('288x432')
Invoke-Print 'document' 'windows/NodePrint.Printing.Tests/Fixtures/letter-mixed.pdf' 'application/pdf' 'C:\nodeprint-ci\document.pdf' @('612x792', '792x612')

# The URL form: the app downloads the label itself, here from a file server on the loopback.
$files = Start-Process python -ArgumentList '-m', 'http.server', '8099', '--bind', '127.0.0.1', '--directory', 'testdata/zpl' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
Invoke-Print 'label' 'http://127.0.0.1:8099/border-4x6-203.pdf' 'url' 'C:\nodeprint-ci\label.pdf' @('288x432')
$missing = Invoke-WebRequest -Method Post -Uri "$api/print?channel=label" -ContentType 'application/json' -Body '{"url":"http://127.0.0.1:8099/missing.pdf"}' -SkipHttpErrorCheck
"missing url -> $($missing.StatusCode) $($missing.Content)"
if ($missing.StatusCode -ne 502) { $failures.Add('FETCH_FAILED not returned') }
Stop-Process -Id $files.Id

$bad = Invoke-WebRequest -Method Post -Uri "$api/print?channel=nope" -ContentType 'application/pdf' -InFile 'testdata/zpl/border-4x6-203.pdf' -SkipHttpErrorCheck
"bad channel -> $($bad.StatusCode) $($bad.Content)"
if ($bad.StatusCode -ne 400) { $failures.Add('BAD_CHANNEL not returned') }
$foreign = Invoke-WebRequest -Method Post -Uri "$api/print?channel=label" -Headers @{ Origin = 'https://evil.example.com' } -ContentType 'application/pdf' -InFile 'testdata/zpl/border-4x6-203.pdf' -SkipHttpErrorCheck
"foreign origin -> $($foreign.StatusCode) $($foreign.Content)"
if ($foreign.StatusCode -ne 403) { $failures.Add('FORBIDDEN_ORIGIN not returned') }
$preflight = Invoke-WebRequest -Method Options -Uri "$api/anything" -Headers @{ Origin = 'https://nrp.node.live'; 'Access-Control-Request-Method' = 'POST'; 'Access-Control-Request-Private-Network' = 'true' } -SkipHttpErrorCheck
"preflight -> $($preflight.StatusCode) $($preflight.Headers['Access-Control-Allow-Origin']) $($preflight.Headers['Access-Control-Allow-Private-Network'])"
if ($preflight.StatusCode -ne 204) { $failures.Add('preflight failed') }

# A second launch hands over to the running copy and exits.
$second = Start-App
if ($second.WaitForExit(20000)) { "second instance exited with $($second.ExitCode); first still running: $(-not $process.HasExited)" }
else { $failures.Add('a second instance kept running'); Stop-Process -Id $second.Id }
$run = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'NODE Print' -ErrorAction SilentlyContinue
"launch at login entry with launchAtLogin=false: $($null -ne $run)"
if ($run) { $failures.Add('Run key written although launchAtLogin is false') }
Stop-Process -Id $process.Id

# The other card states: a network printer, a printer that is gone, nothing chosen.
foreach ($state in @(@('states-network', 'NODE CI Network', 'NODE CI Document'), @('states-missing', 'Gone Printer', $null))) {
    Write-Config $state[1] $state[2]
    $process = Start-App
    if (Wait-Api $process 30) { Save-Window (Find-Window $process) "design-$($state[0])" }
    else { $failures.Add("$($state[0]) did not start") }
    Stop-Process -Id $process.Id
    Start-Sleep -Seconds 1
}

# Something else holds the port: the window says so, and the app takes the port once it is free.
Write-Config 'NODE CI Label' 'NODE CI Document'
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 19233)
$listener.Start()
$process = Start-App
$window = Find-Window $process
Start-Sleep -Seconds 3
Save-Window $window 'design-port-in-use'
$listener.Stop()
if (Wait-Api $process 20) { 'took the port once it was free' } else { $failures.Add('never took the freed port') }
Stop-Process -Id $process.Id

Get-Content (Join-Path $configDir 'error.log') -ErrorAction SilentlyContinue
if ($failures.Count -gt 0) { throw ($failures -join '; ') }
