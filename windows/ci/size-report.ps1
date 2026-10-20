# What a publish directory is made of, by component, largest files last.
param([string] $Dir = 'dist/app')
$root = (Resolve-Path $Dir).Path
$files = Get-ChildItem $root -Recurse -File
function Group-Of($file) {
    $relative = $file.FullName.Substring($root.Length + 1)
    $name = $file.Name
    if ($name -eq 'NodePrint.exe') { return 'NodePrint.exe (NativeAOT: app, .NET, Kestrel, WinRT projections)' }
    if ($name -like '*.mui' -or $relative -match '^[a-z]{2}(-[A-Za-z]+)+\\') { return 'language resources (.mui and language folders)' }
    if ($name -like '*.pri') { return 'resource indexes (.pri)' }
    if ($name -like '*.xbf' -or $name -like '*.xaml') { return 'compiled XAML' }
    if ($name -eq 'Microsoft.WindowsAppRuntime.Bootstrap.dll') { return 'Windows App SDK bootstrapper' }
    if ($name -match '^(Microsoft\.UI\.Xaml|Microsoft\.ui\.xaml|WinUIEdit|Microsoft\.UI\.Text)') { return 'WinUI (Microsoft.UI.Xaml and friends)' }
    if ($name -match '^(onnxruntime|DirectML|Microsoft\.Windows\.AI|Microsoft\.Asg|PerceptiveStreaming|Microsoft\.Windows\.Search|Microsoft\.Windows\.Widgets|Microsoft\.Windows\.Workloads)') { return 'Windows App SDK AI / ML / search / widgets' }
    if ($name -match '^(Microsoft\.|MRM|CoreMessagingXP|dcompi|dwmcorei|DwmSceneI|marshal|wuceffectsi|DWriteCore|RestartAgent|WebView2Loader)') { return 'Windows App Runtime (composition, input, windowing, MRT, DWriteCore …)' }
    if ($relative -like 'Assets\*') { return 'assets' }
    return 'other'
}
$groups = $files | Group-Object { Group-Of $_ } | ForEach-Object {
    [pscustomobject]@{ Component = $_.Name; Files = $_.Count; MB = [Math]::Round(($_.Group | Measure-Object Length -Sum).Sum / 1MB, 2) }
} | Sort-Object MB -Descending
$groups | Format-Table -AutoSize | Out-String -Width 200
"total: {0} files, {1:N2} MB" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB)
$files | Sort-Object Length -Descending | Select-Object -First 12 |
    Format-Table @{ n = 'MB'; e = { '{0:N2}' -f ($_.Length / 1MB) } }, @{ n = 'File'; e = { $_.FullName.Substring($root.Length + 1) } } -AutoSize |
    Out-String -Width 200
