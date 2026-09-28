[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')][string]$Configuration = 'debug',
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$OutputName,
    [switch]$Run,
    [switch]$Test,
    [switch]$SkipGenerate
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

if (-not (Get-Command link.exe -ErrorAction SilentlyContinue)) {
    $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw 'Visual Studio C++ desktop build tools are required.' }
    $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $visualStudio) {
        $visualStudio = & $vswhere -all -latest -products '*' -property installationPath
        if ($visualStudio -and -not (Get-ChildItem "$visualStudio/VC/Tools/MSVC/*/bin/Hostx64/x64/link.exe" -ErrorAction SilentlyContinue)) { $visualStudio = $null }
    }
    if (-not $visualStudio) { throw 'Install the Desktop development with C++ workload in Visual Studio.' }
    Import-Module "$visualStudio/Common7/Tools/Microsoft.VisualStudio.DevShell.dll"
    Enter-VsDevShell -VsInstallPath $visualStudio -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
}

$swiftCommand = Get-Command swift -ErrorAction SilentlyContinue
if ($swiftCommand) { $swift = $swiftCommand.Source }
else {
    $swift = Get-ChildItem "$env:LOCALAPPDATA/Programs/Swift/Toolchains", 'C:/Library/Developer/Toolchains' -Filter swift.exe -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $swift) { throw 'Install Swift for Windows and the Visual Studio C++ desktop build tools, then reopen PowerShell.' }
$toolchainRoot = Split-Path (Split-Path (Split-Path $swift))
$toolchainVersion = (Split-Path $toolchainRoot -Leaf).Split('+')[0]
$runtimeDirectories = @(
    "$env:LOCALAPPDATA/Programs/Swift/Runtimes/$toolchainVersion/usr/bin",
    "C:/Library/Swift/Runtimes/$toolchainVersion/usr/bin"
) | Where-Object { Test-Path "$_/swiftCore.dll" }
if (-not $runtimeDirectories) { throw "Cannot find the Swift $toolchainVersion runtime DLLs. Repair the Swift installation." }

function Invoke-Swift([string[]]$SwiftArguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($swift)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $root
    # Some hosts export both PATH and Path; Swift traps on duplicate environment keys.
    $start.Environment.Clear()
    $environment = [Environment]::GetEnvironmentVariables('Process')
    foreach ($key in $environment.Keys) {
        $normalized = $key.ToUpperInvariant()
        if (-not $start.Environment.ContainsKey($normalized)) { $start.Environment[$normalized] = $environment[$key] }
    }
    $paths = @($environment.GetEnumerator() | Where-Object Key -ieq 'Path' | ForEach-Object Value)
    $paths += @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'))
    $paths += Split-Path $swift
    $swiftInstallation = Join-Path $env:LOCALAPPDATA 'Programs/Swift'
    if (-not $start.Environment['SDKROOT']) {
        $sdk = Get-ChildItem "$swiftInstallation/Platforms/$toolchainVersion", 'C:/Library/Developer/Platforms' -Filter Windows.sdk -Directory -Recurse -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
        if ($sdk) { $start.Environment['SDKROOT'] = $sdk }
    }
    $paths = @((Split-Path $swift)) + $runtimeDirectories + $paths
    $start.Environment['PATH'] = ($paths | Where-Object { $_ }) -join ';'
    foreach ($argument in $SwiftArguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    Write-Output $stdout.GetAwaiter().GetResult()
    Write-Output $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "swift $($SwiftArguments -join ' ') failed ($($process.ExitCode))." }
}

$resolvedPath = Join-Path $root 'Package.resolved'
$resolvedContents = if (Test-Path $resolvedPath) { [IO.File]::ReadAllBytes($resolvedPath) } else { $null }
try {
Invoke-Swift @('--version')
if (-not $SkipGenerate) { & "$PSScriptRoot/generate-winrt.ps1" }
if (-not (Test-Path 'Windows/Generated/WinUI/Package.swift')) { throw 'Run scripts/generate-winrt.ps1 first.' }
& "$PSScriptRoot/generate-windows-icon.ps1"
if (-not (Get-Command rc.exe -ErrorAction SilentlyContinue)) { throw 'Windows SDK resource compiler (rc.exe) is required.' }
$resourceDirectory = Join-Path $root '.build/windows/resources'
$iconResource = Join-Path $resourceDirectory 'KokoroDesktop.res'
& rc.exe /nologo /I $resourceDirectory /fo $iconResource (Join-Path $root 'Windows/Resources/KokoroDesktop.rc')
if ($LASTEXITCODE -ne 0) { throw "Windows icon resource compilation failed ($LASTEXITCODE)." }
if ($Test) { Invoke-Swift @('test', '--build-system', 'native', '--scratch-path', '.build/windows/spm', '-c', $Configuration) }
Invoke-Swift @('build', '--build-system', 'native', '--scratch-path', '.build/windows/spm', '-c', $Configuration, '--product', 'KokoroDesktop', '-Xlinker', $iconResource)

$binaryDirectory = Join-Path $root ".build/windows/spm/x86_64-unknown-windows-msvc/$Configuration"
if (-not (Test-Path "$binaryDirectory/KokoroDesktop.exe")) { throw "Expected x64 executable missing: $binaryDirectory" }
$config = Get-Content Windows/projections.json -Raw | ConvertFrom-Json
$bootstrap = Join-Path $root ".build/windows/packages/microsoft.windowsappsdk.$($config.windowsAppSDK)/runtimes/win-x64/native/Microsoft.WindowsAppRuntime.Bootstrap.dll"
Copy-Item -LiteralPath $bootstrap -Destination $binaryDirectory -Force

if (-not $OutputName) { $OutputName = $Configuration }
$destination = Join-Path $root "build/windows/$OutputName"
if (Test-Path -LiteralPath $destination) {
    $absolute = [IO.Path]::GetFullPath($destination)
    $boundary = [IO.Path]::GetFullPath((Join-Path $root 'build/windows')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase) -or (Get-Item -LiteralPath $absolute).LinkType) {
        throw 'Refusing to replace an output directory outside build/windows.'
    }
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
New-Item -ItemType Directory -Force $destination | Out-Null
Get-ChildItem $binaryDirectory -File | Where-Object Extension -in '.exe', '.dll', '.pdb' | Copy-Item -Destination $destination -Force
Get-ChildItem $binaryDirectory -Directory -Filter '*.resources' | Copy-Item -Destination $destination -Recurse -Force
# Ship Swift's runtime DLLs with the application (the App Runtime remains a prerequisite).
foreach ($directory in $runtimeDirectories | Select-Object -Unique) {
    Get-ChildItem $directory -Filter '*.dll' -ErrorAction SilentlyContinue | Copy-Item -Destination $destination -Force
}
$licenses = Join-Path $destination 'licenses'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item ".build/windows/packages/thebrowsercompany.swiftwinrt.$($config.generator)/license.txt" "$licenses/swift-winrt.txt" -Force
Copy-Item ".build/windows/packages/microsoft.windowsappsdk.$($config.windowsAppSDK)/license.txt" "$licenses/windows-app-sdk.txt" -Force
Copy-Item '.build/windows/spm/checkouts/SwiftSoup/LICENSE' "$licenses/swiftsoup.txt" -Force
Copy-Item '.build/windows/spm/checkouts/swift-markdown/LICENSE.txt' "$licenses/swift-markdown.txt" -Force
Copy-Item '.build/windows/spm/checkouts/swift-markdown/NOTICE.txt' "$licenses/swift-markdown-NOTICE.txt" -Force
Copy-Item '.build/windows/spm/checkouts/swift-cmark/COPYING' "$licenses/swift-cmark.txt" -Force
Copy-Item 'Sources/KokoroWindows/Resources/emoji-LICENSE.txt' "$licenses/emoji-data.txt" -Force
Copy-Item 'Sources/KokoroWindows/Resources/emoji-provenance.txt' "$licenses/emoji-data-provenance.txt" -Force
Write-Host "Application: $destination/KokoroDesktop.exe"
if ($Run) { Start-Process -FilePath "$destination/KokoroDesktop.exe" -WorkingDirectory $destination -WindowStyle Hidden }
} finally {
    # The platforms have different dependency graphs. Preserve the macOS lockfile;
    # Windows' external SwiftSoup dependency is pinned exactly in Package.swift.
    if ($null -ne $resolvedContents) { [IO.File]::WriteAllBytes($resolvedPath, $resolvedContents) }
}
