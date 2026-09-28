[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$config = Get-Content (Join-Path $root 'Windows/projections.json') -Raw | ConvertFrom-Json
$cache = Join-Path $root '.build/windows/packages'
$output = Join-Path $root '.build/windows/projections'
$generated = Join-Path $root 'Windows/Generated'
# Only remove these two generated directories, after checking their absolute paths.
foreach ($directory in @($output, $generated)) {
    $absolute = [IO.Path]::GetFullPath($directory)
    $boundary = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase)) { throw 'Generated output is outside the repository.' }
    if (Test-Path -LiteralPath $absolute) {
        if ((Get-Item -LiteralPath $absolute).LinkType) { throw 'Generated output must not be a symbolic link.' }
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
New-Item -ItemType Directory -Force $cache, $output | Out-Null

function Restore-Package([string]$id, [string]$version) {
    $destination = Join-Path $cache "$id.$version"
    if (-not (Test-Path $destination)) {
        $archive = "$destination.zip"
        Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$id/$version/$id.$version.nupkg" -OutFile $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $destination
    }
    return $destination
}

$generator = Restore-Package 'thebrowsercompany.swiftwinrt' $config.generator
$appSDK = Restore-Package 'microsoft.windowsappsdk' $config.windowsAppSDK
$contracts = Restore-Package 'microsoft.windows.sdk.contracts' $config.windowsSDKContracts
$webView = Restore-Package 'microsoft.web.webview2' $config.webView2
$arguments = @('-output', $output)
foreach ($type in $config.include) { $arguments += @('-include', $type) }
# Select one metadata version per namespace; do not scan all SDK directories (duplicates).
$metadata = @(Get-ChildItem "$appSDK/lib/uap10.0" -Filter '*.winmd')
$metadata += @(Get-ChildItem "$appSDK/lib/uap10.0.18362" -Filter '*.winmd')
$metadata += @(Get-ChildItem "$contracts/ref/netstandard2.0" -Filter '*.winmd')
$metadata += Get-Item "$webView/lib/Microsoft.Web.WebView2.Core.winmd"
foreach ($file in $metadata) { $arguments += @('-input', $file.FullName) }
& "$generator/bin/swiftwinrt.exe" @arguments
if ($LASTEXITCODE -ne 0) { throw "swift-winrt failed ($LASTEXITCODE)." }

# Separate packages are intentional: dependencies on targets in one package are
# linked statically by SPM, even if those targets also have dynamic products. That
# duplicates WinRT type identities and can overflow the Windows DLL export limit.
$modules = [ordered]@{
    CWinRT = @()
    WindowsFoundation = @('CWinRT')
    UWP = @('CWinRT', 'WindowsFoundation')
    WinAppSDK = @('CWinRT', 'WindowsFoundation', 'UWP')
    WinUI = @('CWinRT', 'WindowsFoundation', 'UWP', 'WinAppSDK')
}
foreach ($module in $modules.Keys) {
    $directory = Join-Path $root "Windows/Generated/$module"
    $sources = Join-Path $directory "Sources/$module"
    New-Item -ItemType Directory -Force $sources | Out-Null
    Copy-Item "$output/Sources/$module/*" -Destination $sources -Recurse -Force
    $dependencies = ($modules[$module] | ForEach-Object { '.package(path: "../' + $_ + '")' }) -join ', '
    $targets = ($modules[$module] | ForEach-Object { '.product(name: "' + $_ + '", package: "' + $_ + '")' }) -join ', '
    $kind = if ($module -eq 'CWinRT') { '.static' } else { '.dynamic' }
    $headers = if ($module -eq 'CWinRT') { ', publicHeadersPath: "include"' } else { '' }
    @"
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "$module",
    products: [.library(name: "$module", type: $kind, targets: ["$module"])],
    dependencies: [$dependencies],
    targets: [.target(name: "$module", dependencies: [$targets]$headers)],
    swiftLanguageModes: [.v5]
)
"@ | Set-Content (Join-Path $directory 'Package.swift') -Encoding utf8
}
Write-Host 'Generated WinRT packages in Windows/Generated'
