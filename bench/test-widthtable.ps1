# Tests the width-table API: type stability, caching, and lookup correctness.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "load-gcr.ps1")
. (Get-GcrFunctionBlock -Paths @((Split-Path -Parent $PSScriptRoot) + "\git-clone-resume.tui.ps1")).Block

function Say { param([string]$T) Write-Host $T }

$script:GcrWidthTable = $null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$t1 = Get-GcrWidthTable
$sw.Stop()
Say ("1st call: {0:N1} ms  type={1}  len={2}" -f $sw.Elapsed.TotalMilliseconds, $t1.GetType().FullName, $t1.Length)

$sw.Restart()
$t2 = Get-GcrWidthTable
$sw.Stop()
Say ("2nd call: {0:N3} ms  type={1}  len={2}" -f $sw.Elapsed.TotalMilliseconds, $t2.GetType().FullName, $t2.Length)

$sw.Restart()
$t3 = Get-GcrWidthTable
$sw.Stop()
Say ("3rd call: {0:N3} ms  type={1}" -f $sw.Elapsed.TotalMilliseconds, $t3.GetType().FullName)

Say ("same reference: {0}" -f [object]::ReferenceEquals($t1, $t3))
Say ("script var type: {0}" -f $script:GcrWidthTable.GetType().FullName)

# The table must classify exactly as Get-GcrCharWidth does.
$bad = 0
for ($code = 0; $code -lt 65536; $code++) {
    $expect = Get-GcrCharWidth -Ch ([char]$code)
    $got = $t1[$code]
    if ($got -ne $expect) {
        if ($bad -lt 5) { Say ("  MISMATCH U+{0:X4}: table={1} func={2}" -f $code, $got, $expect) }
        $bad++
    }
}
Say ("table vs Get-GcrCharWidth: {0} mismatches over 65536 code points" -f $bad)

# Representative widths.
foreach ($s in @("abc", "中文", "a中b", "abcde")) {
    Say ("  width('{0}') = {1}" -f $s, (Get-GcrPlainWidth $s))
}
