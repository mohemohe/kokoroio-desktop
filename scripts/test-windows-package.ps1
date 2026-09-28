[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('\A[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?\z')]
    [string]$Version
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$directory = Join-Path $root "build/windows/packages/$Version"
$name = "KokoroDesktop-$Version-windows-x64.zip"
$path = Join-Path $directory $name
$hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
$checksum = [IO.File]::ReadAllText("$directory/SHA256SUMS.txt")
if ($checksum -cne "$hash  $name`n") { throw 'Archive checksum or checksum file format is invalid.' }
$archive = [IO.Compression.ZipFile]::OpenRead($path)
try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    foreach ($required in @('KokoroDesktop.exe', 'WinUI.dll', 'WinAppSDK.dll', 'UWP.dll', 'WindowsFoundation.dll',
        'swiftCore.dll', 'Foundation.dll', 'FoundationNetworking.dll', 'Microsoft.WindowsAppRuntime.Bootstrap.dll',
        'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'README.md', 'version.json',
        'licenses/swift-winrt.txt', 'licenses/windows-app-sdk.txt', 'licenses/swiftsoup.txt', 'licenses/swift-markdown.txt',
        'licenses/swift-runtime.txt')) {
        if ($required -notin $entries) { throw "Archive is missing $required" }
    }
    if (-not ($entries -match '\.resources/.+')) { throw 'Archive has no application resources.' }
    $unexpected = @($entries | Where-Object {
        $_ -match '(?i)\.(pdb|xctest)$' -or ($_ -match '(?i)\.exe$' -and $_ -cne 'KokoroDesktop.exe')
    })
    if ($unexpected.Count) { throw "Archive contains development binaries: $($unexpected -join ', ')" }
    $reader = [IO.StreamReader]::new($archive.GetEntry('version.json').Open())
    try { $metadata = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ($metadata.version -cne $Version -or $metadata.platform -cne 'windows-x64' -or $metadata.buildNumber -lt 1) {
        throw 'Archive version metadata is invalid.'
    }
    Write-Host "Verified $name ($($entries.Count) entries), runtime DLLs, resources, licenses, version, and SHA-256."
} finally { $archive.Dispose() }
