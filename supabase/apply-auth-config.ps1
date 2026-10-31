param([switch]$Preview)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

foreach ($file in @((Join-Path $repo "..\backend\.env"), (Join-Path $PSScriptRoot ".env"))) {
    if (!(Test-Path -LiteralPath $file)) { throw "Missing env file: $file" }
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        if ($line -match '^\s*([A-Z0-9_]+)=(.*)$') {
            $name = $Matches[1]
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            if ($value) { Set-Item -Path "Env:$name" -Value $value }
        }
    }
}

if (!$env:SUPABASE_URL -or !$env:SUPABASE_AUTH_EXTERNAL_GOOGLE_CLIENT_ID -or !$env:SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET) {
    throw "Fill SUPABASE_URL in ../backend/.env and Google OAuth client ID/secret in supabase/.env first."
}

$projectRef = ([Uri]$env:SUPABASE_URL).Host.Split('.')[0]
$command = if ($Preview) { "diff" } else { "push" }
& npx --yes supabase --workdir $repo config $command --project-ref $projectRef
exit $LASTEXITCODE
