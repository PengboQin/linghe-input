# Read-only environment check. Does not install tools, register TSF, open ports,
# change the input source, or collect machine/user/network names.
[CmdletBinding()]
param([string]$OutputPath = (Join-Path (Get-Location) 'PrivateInput-preflight.json'))
$ErrorActionPreference = 'Stop'
$os = Get-CimInstance Win32_OperatingSystem
try { $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant() }
catch {
    $nativeArchitecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $nativeArchitecture) { $nativeArchitecture = $env:PROCESSOR_ARCHITECTURE }
    $architecture = switch ($nativeArchitecture) { 'AMD64' { 'x64' } 'ARM64' { 'arm64' } default { $nativeArchitecture.ToLowerInvariant() } }
}
$tools = [ordered]@{}
foreach ($tool in @('cl.exe', 'cmake.exe', 'ninja.exe', 'ssh.exe')) {
    $tools[$tool] = [bool](Get-Command $tool -ErrorAction SilentlyContinue)
}
$vsVersions = @()
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $vswhere) {
    $json = & $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json
    if ($LASTEXITCODE -ne 0) { throw 'Visual Studio discovery failed' }
    $vsVersions = @($json | ConvertFrom-Json | ForEach-Object { $_.installationVersion })
}
$sdkVersions = @()
$sdkKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots' -ErrorAction SilentlyContinue
if ($sdkKey -and $sdkKey.KitsRoot10) {
    $includeRoot = Join-Path $sdkKey.KitsRoot10 'Include'
    if (Test-Path -LiteralPath $includeRoot) {
        $sdkVersions = @(Get-ChildItem -LiteralPath $includeRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\msctf.h') } | ForEach-Object { $_.Name })
    }
}
$sshd = Get-Service sshd -ErrorAction SilentlyContinue
$report = [ordered]@{
    schemaVersion = 1
    osVersion = [string]$os.Version
    osBuild = [int]$os.BuildNumber
    architecture = $architecture
    windows11X64 = ([int]$os.BuildNumber -ge 22000 -and $architecture -eq 'x64' -and [int]$os.ProductType -eq 1)
    memoryGiB = [math]::Round((Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory / 1GB, 1)
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    toolsOnPath = $tools
    visualCppInstallations = $vsVersions
    windowsSdkVersionsWithTsfHeaders = $sdkVersions
    sshServicePresent = [bool]$sshd
    sshServiceRunning = [bool]($sshd -and $sshd.Status -eq 'Running')
    nonSystemSession = ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0)
    interactiveEnvironment = [Environment]::UserInteractive
    # Neither flag is proof of a visible, foreground input session.
    tsfDesktopAcceptancePerformed = $false
    registeredOrInstalled = $false
}
$encoded = $report | ConvertTo-Json -Depth 5
# A newly named report avoids replacing unrelated files.
$stream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
try {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($encoded)
    $stream.Write($bytes, 0, $bytes.Length)
} finally { $stream.Dispose() }
$encoded
