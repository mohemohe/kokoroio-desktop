[CmdletBinding()]
param(
    [string]$Python = 'python',
    [ValidateSet('debug', 'release')][string]$Configuration = 'debug',
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$OutputName,
    [switch]$EmptyChannels,
    [switch]$Performance,
    [switch]$NoRealtime
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputName) { $OutputName = $Configuration }
$executable = Join-Path $root "build/windows/$OutputName/KokoroDesktop.exe"
if (-not (Test-Path $executable)) { throw 'Build the Windows app first.' }
$connection = [Net.Sockets.TcpClient]::new()
try {
    $connection.Connect('127.0.0.1', 8765)
    throw 'Port 8765 is already in use. Stop that server before running the isolated smoke test.'
} catch [Net.Sockets.SocketException] {
    # Expected: this test must own the fixture server.
} finally { $connection.Dispose() }
$logs = Join-Path $root '.build/windows'
$fixtureArguments = @("`"$PSScriptRoot/mock-server.py`"", '--channel-tree', '--legacy-images', '--split-image-responses')
$appArguments = @('--smoke-test')
if ($Performance) {
    $appArguments += '--smoke-performance'
    $fixtureArguments += '--fragment-websockets'
}
if ($NoRealtime) {
    if (-not $Performance) { throw 'NoRealtime is only supported with Performance.' }
    $appArguments += '--smoke-no-realtime'
}
$scenarioSuffix = ''
if ($EmptyChannels) {
    $fixtureArguments += '--empty-channels'
    $appArguments += '--smoke-empty'
    $scenarioSuffix = '-empty'
}
if ($Performance) {
    if ($EmptyChannels) { throw 'Performance and EmptyChannels are separate scenarios.' }
    $scenarioSuffix = if ($NoRealtime) { '-performance-no-realtime' } else { '-performance' }
}
$appLog = "$logs/smoke$scenarioSuffix.log"
$appErrorLog = "$logs/smoke$scenarioSuffix-errors.log"
$fixture = Start-Process -FilePath $Python -ArgumentList $fixtureArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput "$logs/fixture$scenarioSuffix.log" -RedirectStandardError "$logs/fixture$scenarioSuffix-errors.log"
try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if ($fixture.HasExited) { throw 'Fixture server exited before startup.' }
        try {
            Invoke-RestMethod 'http://127.0.0.1:8765/api/v1/profiles/me' -Headers @{'X-Access-Token'='test-token'} | Out-Null
            $ready = $true
            break
        } catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ready) { throw 'Fixture server did not become ready.' }
    $app = Start-Process -FilePath $executable -ArgumentList $appArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $appLog -RedirectStandardError $appErrorLog
    if (-not $app.WaitForExit(75000)) { $app.Kill(); throw 'Windows smoke test timed out.' }
    Get-Content $appLog
    if ($app.ExitCode -ne 0) {
        Get-Content $appErrorLog
        throw "Windows smoke test failed ($($app.ExitCode))."
    }
    if ($Performance) {
        if (-not $NoRealtime) {
            $state = Invoke-RestMethod 'http://127.0.0.1:8765/test/state' -Headers @{'X-Access-Token'='test-token'}
            if (@($state.records | Where-Object type -eq 'websocket_open').Count -lt 2) { throw 'Reconnect was not exercised.' }
            if (-not @($state.records | Where-Object type -eq 'fragmented_websocket_message').Count) { throw 'Fragmented WebSocket messages were not exercised.' }
        }
        return
    }
    $state = Invoke-RestMethod 'http://127.0.0.1:8765/test/state' -Headers @{'X-Access-Token'='test-token'}
    $requests = @($state.image_requests)
    foreach ($request in $requests) {
        if ($request.has_access_token -or $request.has_authorization -or $request.has_cookie) {
            throw "Media request included authentication: $($request.path)"
        }
    }
    $requestedPaths = @($requests | ForEach-Object path)
    foreach ($path in $state.media_expectations.required_images) {
        if ($path -notin $requestedPaths) { throw "Expected media was never requested: $path" }
    }
    foreach ($path in $state.media_expectations.forbidden_images) {
        if ($path -in $requestedPaths) { throw "Sensitive or deleted media loaded without a reveal: $path" }
    }
    if ($EmptyChannels) {
        if (@($state.memberships).Count -ne 0) { throw 'Empty-channel scenario unexpectedly returned memberships.' }
        if ($requests.Count -ne 0) { throw 'Empty-channel scenario unexpectedly requested media.' }
        Write-Host 'Windows empty-channel smoke test passed (no memberships, no media requests).'
    } else {
        if (-not @($state.records | Where-Object type -eq 'split_image_response').Count) {
            throw 'The fixture did not exercise split Hotwire WebSocket responses.'
        }
        Write-Host 'Windows media smoke test passed (avatars, thumbnails, embed cards, sensitive/deleted media gates, no credentials).'
    }
} finally {
    if (-not $fixture.HasExited) { Stop-Process -Id $fixture.Id }
}
