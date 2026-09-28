[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?\z')]
    [string]$Version,
    [ValidateRange(1, 2147483647)][int]$BuildNumber = 1,
    [ValidatePattern('\A[A-Za-z0-9_-]+\z')][string]$OutputName = 'release'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$source = Join-Path $root "build/windows/$OutputName"
$destination = Join-Path $root "build/windows/packages/$Version"
$requiredFiles = @(
    'KokoroDesktop.exe', 'Microsoft.WindowsAppRuntime.Bootstrap.dll',
    'WinUI.dll', 'WinAppSDK.dll', 'UWP.dll', 'WindowsFoundation.dll',
    'swiftCore.dll', 'Foundation.dll', 'FoundationNetworking.dll',
    'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll'
)
foreach ($name in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $name) -PathType Leaf)) {
        throw "Required distribution file missing: $name. Run build-windows.ps1 -Configuration release first."
    }
}
if (-not (Get-ChildItem -LiteralPath $source -Directory -Filter '*.resources')) { throw 'Application resources are missing.' }
if (-not (Test-Path -LiteralPath "$source/licenses" -PathType Container)) { throw 'Dependency licenses are missing.' }

# A unique staging directory prevents old debug/test files from entering the archive.
$staging = Join-Path $root ".build/windows/package-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
    Copy-Item -LiteralPath "$source/KokoroDesktop.exe" -Destination $staging
    Get-ChildItem -LiteralPath $source -File -Filter '*.dll' | Copy-Item -Destination $staging
    Get-ChildItem -LiteralPath $source -Directory -Filter '*.resources' | Copy-Item -Destination $staging -Recurse
    Copy-Item -LiteralPath "$source/licenses" -Destination $staging -Recurse
    Get-ChildItem -LiteralPath "$root/Windows/Distribution/licenses" -File | Copy-Item -Destination "$staging/licenses"
    Copy-Item -LiteralPath "$root/Windows/Distribution/README.md" -Destination $staging
    $config = Get-Content -LiteralPath "$root/Windows/projections.json" -Raw | ConvertFrom-Json
    $metadata = [ordered]@{
        version = $Version
        buildNumber = $BuildNumber
        platform = 'windows-x64'
        windowsAppSDK = $config.windowsAppSDK
    }
    $metadata | ConvertTo-Json | Set-Content -LiteralPath "$staging/version.json" -Encoding utf8NoBOM
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $archiveName = "KokoroDesktop-$Version-windows-x64.zip"
    $archive = Join-Path $destination $archiveName
    Compress-Archive -Path "$staging/*" -DestinationPath $archive -CompressionLevel Optimal -Force
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    # LF and no BOM: also readable by sha256sum on the Linux release runner.
    [IO.File]::WriteAllText("$destination/SHA256SUMS.txt", "$hash  $archiveName`n", [Text.UTF8Encoding]::new($false))
    Write-Host "Package: $archive"
} finally {
    $absolute = [IO.Path]::GetFullPath($staging)
    $boundary = [IO.Path]::GetFullPath((Join-Path $root '.build/windows')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($boundary, [StringComparison]::OrdinalIgnoreCase) -or (Get-Item -LiteralPath $absolute).LinkType) {
        throw 'Refusing to remove a staging directory outside .build/windows.'
    }
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
