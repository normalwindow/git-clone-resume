# Local dry run of .github/workflows/release.yml's build step.
#
# Reproduces exactly what the workflow does - version/tag consistency check,
# gcr.exe compilation, file staging, ZIP + SHA256 - so a tag push is not the
# first time this code runs. Writes into a temp directory and cleans up.
#
#   powershell -NoProfile -File bench\verify-release-package.ps1
#   powershell -NoProfile -File bench\verify-release-package.ps1 -TagVersion 0.1.7
param([string]$TagVersion)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

# Default to the working tree's version, which is what the tag must match.
$package = Get-Content -Raw -LiteralPath (Join-Path $root "package.json") | ConvertFrom-Json
$fileVersion = $package.version
if (-not $TagVersion) { $TagVersion = $fileVersion }

Write-Host "workflow check: tag=$TagVersion package.json=$fileVersion"
if ($TagVersion -ne $fileVersion) {
    # Exactly the workflow's failure mode.
    throw "Tag version $TagVersion does not match package.json $fileVersion"
}
Write-Host "  OK   tag matches package.json" -ForegroundColor Green

$stage = Join-Path $env:TEMP ("gcr-release-dryrun-" + [guid]::NewGuid().ToString("N"))
$packageName = "git-clone-resume-$fileVersion"
$packageDir = Join-Path $stage $packageName
$zipPath = Join-Path $stage "$packageName.zip"
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null

try {
    # --- gcr.exe, compiled the same way the workflow does -------------------
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) {
        throw "csc.exe not found at $compiler (the workflow assumes it exists on windows-latest)"
    }
    $launcherSource = Join-Path $root 'gcr.launcher.cs'
    $launcherPath = Join-Path $packageDir 'gcr.exe'
    & $compiler /nologo /target:exe /optimize+ "/out:$launcherPath" $launcherSource | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not compile gcr.exe (csc exit $LASTEXITCODE)" }
    Write-Host ("  OK   gcr.exe compiled ({0} bytes)" -f (Get-Item $launcherPath).Length) -ForegroundColor Green

    # --- staged files -------------------------------------------------------
    $files = @(
        'README.md',
        'README.en.md',
        'package.json',
        'gcr.cmd',
        'git-clone-resume.cmd',
        'git-clone-resume.ps1',
        'git-clone-resume.tui.ps1'
    )
    foreach ($file in $files) {
        $from = Join-Path $root $file
        if (-not (Test-Path -LiteralPath $from)) { throw "missing file for packaging: $file" }
        Copy-Item -LiteralPath $from -Destination $packageDir
    }
    Write-Host ("  OK   staged {0} files" -f $files.Count) -ForegroundColor Green

    # --- zip + checksum -----------------------------------------------------
    Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
    "$hash  $(Split-Path -Leaf $zipPath)" | Set-Content -Encoding ascii "$zipPath.sha256"
    Write-Host ("  OK   {0} ({1} bytes)" -f (Split-Path -Leaf $zipPath), (Get-Item $zipPath).Length) -ForegroundColor Green
    Write-Host ("  OK   sha256 {0}" -f $hash) -ForegroundColor Green

    # --- sanity: the zip really is installable ------------------------------
    $extract = Join-Path $stage "extracted"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extract
    $got = @(Get-ChildItem -File $extract | ForEach-Object { $_.Name } | Sort-Object)
    $want = @($files + 'gcr.exe' | Sort-Object)
    $missing = @($want | Where-Object { $got -notcontains $_ })
    if ($missing.Count -gt 0) { throw ("zip is missing: " + ($missing -join ", ")) }
    Write-Host ("  OK   zip contains all {0} expected entries" -f $want.Count) -ForegroundColor Green

    # The launcher needs the script beside it with the same name it looks for.
    if ($got -notcontains 'git-clone-resume.ps1') { throw "launcher's script target missing from zip" }
    Write-Host "  OK   gcr.exe has git-clone-resume.ps1 beside it" -ForegroundColor Green

    # --- the scripts inside the zip must still parse (BOM survived zipping) --
    foreach ($script in @('git-clone-resume.ps1', 'git-clone-resume.tui.ps1')) {
        $p = Join-Path $extract $script
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
        if (-not $hasBom) { throw "$script lost its UTF-8 BOM inside the zip" }
        if ($errors.Count -gt 0) { throw "$script has $($errors.Count) parse errors inside the zip" }
        Write-Host ("  OK   {0} keeps BOM and parses from the zip" -f $script) -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "Release package dry run PASSED. The tag push should produce these artifacts:" -ForegroundColor Green
    Write-Host ("  {0}.zip" -f $packageName)
    Write-Host ("  {0}.zip.sha256" -f $packageName)
    exit 0
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}
