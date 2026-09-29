$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
uv sync --frozen
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
uv run --no-sync uvicorn app.api:app --host 127.0.0.1 --port 8765

