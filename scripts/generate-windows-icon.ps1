[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) '.build/windows/resources/KokoroDesktop.ico')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# ICO supports PNG frames. Reuse the macOS artwork byte-for-byte, including alpha.
$frames = @(
    @{ Size = 16; File = 'icon_16x16.png' },
    @{ Size = 32; File = 'icon_32x32.png' },
    @{ Size = 64; File = 'icon_32x32@2x.png' },
    @{ Size = 128; File = 'icon_128x128.png' },
    @{ Size = 256; File = 'icon_256x256.png' }
)
foreach ($frame in $frames) {
    $frame.Bytes = [IO.File]::ReadAllBytes((Join-Path $root "Resources/KokoroDesktop.iconset/$($frame.File)"))
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force (Split-Path $OutputPath -Parent) | Out-Null
$writer = [IO.BinaryWriter]::new([IO.File]::Create($OutputPath))
try {
    $writer.Write([uint16]0) # Reserved
    $writer.Write([uint16]1) # Icon
    $writer.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($frame in $frames) {
        $dimension = if ($frame.Size -eq 256) { 0 } else { $frame.Size }
        $writer.Write([byte]$dimension)
        $writer.Write([byte]$dimension)
        $writer.Write([byte]0) # True color
        $writer.Write([byte]0) # Reserved
        $writer.Write([uint16]1) # Planes
        $writer.Write([uint16]32) # RGBA
        $writer.Write([uint32]$frame.Bytes.Length)
        $writer.Write([uint32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
} finally { $writer.Dispose() }
Write-Host "Icon: $OutputPath"
