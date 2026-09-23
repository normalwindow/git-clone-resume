# Per-operation profiling of Render-GcrTui: times the whole frame and each
# helper the renderer leans on, so the bottleneck is identified by measurement
# rather than by inspection.
$ErrorActionPreference = "Continue"
$out = New-Object System.Collections.Generic.List[string]
function Say { param([string]$T) [void]$out.Add($T) }
Say "[p] start"

. (Join-Path $PSScriptRoot "gcr-harness.ps1")
Say "[p] harness ok"
Initialize-GcrTuiState
Say "[p] state ok"

$script:NullStream = New-Object System.IO.MemoryStream
$script:NullWriter = New-Object System.IO.StreamWriter($script:NullStream, (New-Object System.Text.UTF8Encoding $false))
$script:NullWriter.AutoFlush = $false
[Console]::SetOut($script:NullWriter)

$script:BenchW = 120
$script:BenchH = 40
function Get-GcrTuiSize { return @{ W = $script:BenchW; H = $script:BenchH; DrawW = [Math]::Max(20, $script:BenchW - 1) } }
function Sync-GcrConsoleBuffer { }
function Test-GcrTuiActive { return ($null -ne $script:GcrTui -and [bool]$script:GcrTui.Active) }
function Test-GcrTuiAvailable { return $true }
function Test-GcrTuiForceQuit { return $false }
function Sync-GcrTuiWindowTitle { }
function Set-GcrTuiTabProgress { param($Percent, $State) }

function Fill-GcrBenchLog {
    param([int]$Count = 400)
    $script:GcrTui.Logs.Clear()
    $dirs = @("src/core", "docs/zh-CN", "third_party/vendor", "assets/images", "tests/integration")
    for ($i = 0; $i -lt $Count; $i++) {
        $p = "{0}/module-{1:d3}/瀹炵幇鏂囦欢-{2:d4}.ps1" -f $dirs[$i % $dirs.Count], ($i % 97), $i
        [void]$script:GcrTui.Logs.Add(@{
                T = (Get-Date).AddSeconds(-1 * ($Count - $i))
                L = @("INFO", "WARN", "OK", "STEP")[$i % 4]
                M = ("checkout ok  " + $p)
            })
    }
}

Fill-GcrBenchLog
$script:GcrTui.Active = $true
$script:GcrTui.Screen = "dash"
$script:GcrTui.Phase = "download"
$script:GcrTui.Total = 802
$script:GcrTui.Ok = 340
$script:GcrTui.Fail = 3
$script:GcrTui.Bytes = 1288490188
$script:GcrTui.Speed = 1258291.0
$script:GcrTui.Rate = 42.5
$script:GcrTui.Eta = "00:01:20"
$script:GcrTui.CurrentFile = "src/core/module-042/瀹炵幇鏂囦欢-0042.ps1"
$script:GcrTui.GitPercent = -1
$script:GcrTui.LastFrame = @()
$script:GcrTui.LastFrameW = 0
$script:GcrTui.LastFrameH = 0

function Time-Gcr {
    param([string]$Name, [int]$Iters, [scriptblock]$Body)
    & $Body | Out-Null
    $s = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Iters; $i++) { & $Body | Out-Null }
    $s.Stop()
    [pscustomobject]@{
        Name      = $Name
        Calls     = $Iters
        TotalMs   = [Math]::Round($s.Elapsed.TotalMilliseconds, 2)
        PerCallUs = [Math]::Round(($s.Elapsed.TotalMilliseconds * 1000.0) / $Iters, 2)
    }
}

Say "=== Whole-frame cost ==="
Render-GcrTui | Out-Null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt 20; $i++) { Render-GcrTui | Out-Null }
$sw.Stop()
$fullMs = $sw.Elapsed.TotalMilliseconds / 20
Say ("Render-GcrTui : {0:N2} ms/frame  ({1:N1} fps)" -f $fullMs, (1000.0 / $fullMs))

$text = " 12:34:56 checkout ok  src/core/module-042/瀹炵幇鏂囦欢-0042.ps1"
$rows = 40
$r = @()
$r += Time-Gcr "Get-GcrDisplayWidth" ($rows * 20) { Get-GcrDisplayWidth $text }
$r += Time-Gcr "Truncate-GcrDisplay" ($rows * 20) { Truncate-GcrDisplay $text 100 }
$r += Time-Gcr "Format-GcrCell"      ($rows * 20) { Format-GcrCell $text 100 }
$r += Time-Gcr "Get-GcrCharWidth"    ($rows * 20) { foreach ($ch in $text.ToCharArray()) { Get-GcrCharWidth $ch } }
$r += Time-Gcr "Get-GcrColor"        ($rows * 20) { Get-GcrColor "cyan" }
$r += Time-Gcr "Get-GcrLevelColor"   ($rows * 20) { Get-GcrLevelColor "INFO" }
$r += Time-Gcr "Convert-GcrText"     ($rows * 20) { Convert-GcrText $text }
$r += Time-Gcr "New-GcrBar"          ($rows * 20) { New-GcrBar -Width 107 -Ratio 0.42 -Tick 1 }

Say ""
Say "=== Per-call costs ==="
$r | Format-Table -AutoSize | Out-String | Write-Host

$per = @{}
foreach ($x in $r) { $per[$x.Name] = $x.PerCallUs }

Say "=== Extrapolated per-frame cost (40 rows) ==="
Say ("40 x Get-GcrCharWidth-loop  = {0,8:N2} ms" -f (40 * $per["Get-GcrCharWidth"] / 1000))
Say ("40 x Format-GcrCell         = {0,8:N2} ms" -f (40 * $per["Format-GcrCell"] / 1000))
Say ("40 x Get-GcrLevelColor      = {0,8:N2} ms" -f (40 * $per["Get-GcrLevelColor"] / 1000))
Say ("40 x Convert-GcrText        = {0,8:N2} ms" -f (40 * $per["Convert-GcrText"] / 1000))
Say (" 6 x Get-GcrColor           = {0,8:N2} ms" -f (6 * $per["Get-GcrColor"] / 1000))
Say ("measured frame total        = {0,8:N2} ms" -f $fullMs)

$out | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'profile-results.txt') -Encoding UTF8

