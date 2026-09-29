# Registers this checkout; an existing, different configuration is never overwritten.
$ErrorActionPreference = 'Stop'
$projectDirectory = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$uvCommand = (Get-Command uv -ErrorAction Stop).Source
$serverArguments = @('--directory', $projectDirectory, 'run', '--frozen', '--no-sync', 'python', '-m', 'app.mcp_server')
if (-not (Test-Path -LiteralPath (Join-Path $projectDirectory '.venv'))) {
    throw 'Install the locked dependencies first: uv sync --frozen'
}
$configuredServers = codex mcp list --json
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the existing Codex MCP configuration.' }
$existing = @($configuredServers | ConvertFrom-Json) | Where-Object name -eq 'swe-workspace'
if ($existing) {
    $sameArguments = ($existing.transport.args | ConvertTo-Json -Compress) -ceq ($serverArguments | ConvertTo-Json -Compress)
    $envKeys = @($existing.transport.env.PSObject.Properties | Where-Object Name | Select-Object -ExpandProperty Name)
    if ($existing.transport.type -ne 'stdio' -or $existing.transport.command -ne $uvCommand -or -not $sameArguments -or $envKeys.Count -gt 0 -or -not $existing.enabled) {
        throw 'A different or disabled swe-workspace configuration exists. Inspect it with codex mcp get swe-workspace; nothing was changed.'
    }
    Write-Output 'swe-workspace is already registered for this checkout.'
    exit 0
}
codex mcp add swe-workspace -- $uvCommand @serverArguments
if ($LASTEXITCODE -ne 0) { throw 'Codex MCP registration failed.' }
