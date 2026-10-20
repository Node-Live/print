# Two "Microsoft Print to PDF" queues on file ports, so jobs land as PDFs the CI can read back.
$ErrorActionPreference = 'Stop'
Set-Service Spooler -StartupType Automatic
Start-Service Spooler
if (-not (Get-PrinterDriver -Name 'Microsoft Print To PDF' -ErrorAction SilentlyContinue)) {
    Enable-WindowsOptionalFeature -Online -FeatureName Printing-PrintToPDFServices-Features -All -NoRestart | Out-Null
}
New-Item -ItemType Directory -Force C:\nodeprint-ci | Out-Null
foreach ($name in 'Label', 'Document') {
    $port = "C:\nodeprint-ci\$($name.ToLowerInvariant()).pdf"
    Add-PrinterPort -Name $port
    Add-Printer -Name "NODE CI $name" -DriverName 'Microsoft Print To PDF' -PortName $port
}
Get-Printer | Format-Table Name, DriverName, PortName -AutoSize
