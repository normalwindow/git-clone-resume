# End-to-end test using the RELEASE-PACKAGED scripts.
#
# Tests the artifact users actually get: builds the same ZIP the release workflow
# builds, extracts it, and runs a clone + resume from that extracted copy. This
# catches packaging problems (missing file, lost BOM, wrong launcher target) that
# testing the working tree cannot.
#
#   powershell -NoProfile -File bench\test-packaged-e2e.ps1
#
# Native commands here write progress and warnings to stderr (git over file://
# emits "filtering not recognized by server", which is harmless), and PowerShell
# surfaces native stderr as error records. This script therefore does NOT stop on
# errors; it asserts on exit codes and resulting files instead.
$ErrorActionPreference = "Continue"

$root = Split-Path -Parent $PSScriptRoot
$stage = Join-Path $env:TEMP ("gcr-packaged-e2e-" + [guid]::NewGuid().ToString("N"))
$fail = 0
function Step { param([string]$T) Write-Host $T }
function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = "")
    if ($Ok) { Write-Host ("  ok   {0}" -f $What) }
    else { Write-Host ("  FAIL {0}  {1}" -f $What, $Detail); $script:fail++ }
}

try {
    # --- build the release package ------------------------------------------
    # The workflow's own build logic (version/tag check, file list, BOM survival)
    # is verified separately by verify-release-package.ps1. This suite builds the
    # same zip and then exercises it, so the two remain independent steps.
    $pkg = Join-Path $stage "pkg"
    New-Item -ItemType Directory -Force -Path $pkg | Out-Null

    $package = Get-Content -Raw -LiteralPath (Join-Path $root "package.json") | ConvertFrom-Json
    $version = $package.version
    $packageName = "git-clone-resume-$version"
    $packageDir = Join-Path $pkg $packageName
    $zipPath = Join-Path $pkg "$packageName.zip"
    New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe /optimize+ "/out:$(Join-Path $packageDir 'gcr.exe')" (Join-Path $root 'gcr.launcher.cs') | Out-Null
    foreach ($file in @('README.md', 'README.en.md', 'package.json', 'gcr.cmd', 'git-clone-resume.cmd',
            'git-clone-resume.ps1', 'git-clone-resume.tui.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination $packageDir
    }
    Compress-Archive -Path (Join-Path $packageDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $install = Join-Path $stage "installed"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $install

    $ghcr = Join-Path $install "git-clone-resume.ps1"
    $gcrCmd = Join-Path $install "gcr.cmd"
    $gcrExe = Join-Path $install "gcr.exe"
    Check "packaged git-clone-resume.ps1 present" (Test-Path -LiteralPath $ghcr)
    Check "packaged gcr.cmd present" (Test-Path -LiteralPath $gcrCmd)
    Check "packaged gcr.exe present" (Test-Path -LiteralPath $gcrExe)

    # --- build a source repo to clone ---------------------------------------
    $src = Join-Path $stage "source"
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    git -C $src init -q 2>&1 | Out-Null
    git -C $src config user.email "t@example.com"
    git -C $src config user.name "Tester"
    $dirs = @("src/core", "docs/zh-CN", "assets")
    foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path (Join-Path $src $d) | Out-Null }
    for ($i = 0; $i -lt 60; $i++) {
        $d = $dirs[$i % $dirs.Count]
        $name = if ($i % 3 -eq 0) { "实现文件-{0:d3}.txt" -f $i } else { "file-{0:d3}.txt" -f $i }
        [System.IO.File]::WriteAllText((Join-Path $src "$d\$name"), ("content {0}`n" -f $i), (New-Object System.Text.UTF8Encoding($false)))
    }
    [System.IO.File]::WriteAllText((Join-Path $src ".gitattributes"), "* -text`n", (New-Object System.Text.UTF8Encoding($false)))
    git -C $src add -A 2>&1 | Out-Null
    git -C $src -c commit.gpgsign=false commit -q -m "initial" 2>&1 | Out-Null
    $url = "file:///" + ($src -replace '\\', '/')

    $env:GIT_CONFIG_COUNT = "1"; $env:GIT_CONFIG_KEY_0 = "core.autocrlf"; $env:GIT_CONFIG_VALUE_0 = "false"

    # --- clone via the packaged launcher (gcr.cmd -> ps1) -------------------
    $dst1 = Join-Path $stage "clone-cmd"
    Step ""
    Step "clone through the packaged gcr.cmd launcher:"
    $out1 = & cmd /c "`"$gcrCmd`" `"$url`" -OutDir `"$dst1`" -NoTui" 2>&1
    $code1 = $LASTEXITCODE
    $doneLine = @($out1 | Select-String -Pattern 'Complete|完成' | Select-Object -Last 1)
    Check "gcr.cmd clone exited 0" ($code1 -eq 0) "exit=$code1"
    Check "gcr.cmd reported completion" ($doneLine.Count -gt 0) ($out1 | Select-Object -Last 3 | Out-String)
    $n1 = @(Get-ChildItem -Recurse -File $dst1 | Where-Object { $_.FullName -notmatch '\\\.git\\' }).Count
    Check "gcr.cmd cloned 61 files" ($n1 -eq 61) "got $n1"

    # --- clone via gcr.exe --------------------------------------------------
    $dst2 = Join-Path $stage "clone-exe"
    Step ""
    Step "clone through the packaged gcr.exe launcher:"
    $out2 = & $gcrExe $url -OutDir $dst2 -NoTui 2>&1
    $code2 = $LASTEXITCODE
    Check "gcr.exe clone exited 0" ($code2 -eq 0) "exit=$code2"
    $n2 = @(Get-ChildItem -Recurse -File $dst2 | Where-Object { $_.FullName -notmatch '\\\.git\\' }).Count
    Check "gcr.exe cloned 61 files" ($n2 -eq 61) "got $n2"

    # --- resume from the packaged copy --------------------------------------
    Step ""
    Step "resume through the packaged copy:"
    $victims = Get-ChildItem -Recurse -File $dst1 | Where-Object { $_.FullName -notmatch '\\\.git\\' } | Select-Object -First 20
    foreach ($v in $victims) { Remove-Item -LiteralPath $v.FullName -Force }
    $out3 = & cmd /c "`"$gcrCmd`" `"$url`" -OutDir `"$dst1`" -NoTui" 2>&1
    $code3 = $LASTEXITCODE
    Check "resume exited 0" ($code3 -eq 0) "exit=$code3"
    $n3 = @(Get-ChildItem -Recurse -File $dst1 | Where-Object { $_.FullName -notmatch '\\\.git\\' }).Count
    Check "resume restored all 61 files" ($n3 -eq 61) "got $n3"

    # --- content integrity --------------------------------------------------
    $bad = 0
    foreach ($f in (Get-ChildItem -Recurse -File $src | Where-Object { $_.FullName -notmatch '\\\.git\\' })) {
        $rel = $f.FullName.Substring($src.Length + 1)
        $tgt = Join-Path $dst1 $rel
        if (-not (Test-Path -LiteralPath $tgt)) { $bad++; continue }
        if ((Get-FileHash $f.FullName).Hash -ne (Get-FileHash $tgt).Hash) { $bad++ }
    }
    Check "cloned content matches source byte-for-byte" ($bad -eq 0) "$bad mismatches"

    # --- version reported by the packaged script ----------------------------
    Step ""
    Step "packaged script metadata:"
    $verOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $ghcr -Version 2>&1
    Check "packaged script reports $version" (@($verOut) -join " " -match [regex]::Escape($version)) ($verOut | Out-String)

    Step ""
    if ($fail -gt 0) { Write-Host "$fail check(s) FAILED" -ForegroundColor Red; exit 1 }
    Write-Host "Packaged end-to-end PASSED" -ForegroundColor Green
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}
