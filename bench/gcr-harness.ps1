# Shared setup for the TUI benchmarks.
#
#     . .\bench\gcr-harness.ps1
#     Initialize-GcrTuiState
#
# Loads the real functions out of .tui.ps1 and .ps1, then defines the
# script-scoped variables the real scripts declare at their top level.

. (Join-Path $PSScriptRoot "load-gcr.ps1")

$gcrRoot = Split-Path -Parent $PSScriptRoot
. (Get-GcrFunctionBlock -Paths @(
        (Join-Path $gcrRoot "git-clone-resume.tui.ps1"),
        (Join-Path $gcrRoot "git-clone-resume.ps1")
    )).Block

# --- Script state normally declared at the top level of the real scripts -----
$script:GcrTui = $null
$script:GcrEsc = [char]27
$script:GcrReset = "$([char]27)[0m"
$script:GcrCurrentProc = $null
$script:GcrOrigOutMode = $null
$script:GcrOrigInMode = $null
$script:GcrOrigTitle = $null
$script:GcrOrigCursor = $true
$script:GcrOrigTreatCtrlC = $false
$script:GcrNativeReady = $false

$script:GcrLanguage = "zh-CN"
$script:GcrStateDirName = "partial-resume"
$script:GcrRepoRoot = $null
$script:GcrLogFile = $null
$script:GcrGitExe = $null
$script:GcrProgressOpen = $false
$script:GcrExitCode = 0
$script:GcrUserStop = $false
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Top-level script variables the real .tui.ps1 declares at file scope, which the
# AST loader deliberately does not execute.
$script:GcrWidthTable = $null
$script:GcrAnsiRegex = [char]27 + '\[[0-9;?]*[ -/]*[@-~]'
$script:GcrFramePalettes = @{}
# Input layer: the decoded-event queue and the click hit-map.
$script:GcrPendingInput = New-Object System.Collections.Generic.List[object]
$script:GcrMouseHit = $null
$script:GcrMouseReady = $false
$script:GcrMouseFaults = 0
$script:GcrInputBuf = $null

# The real TUI builds the width table during Initialize-GcrTui; the benchmarks
# must not include its one-off construction cost in per-frame timings.
[void](Get-GcrWidthTable)

# Window-title helpers: disabled, so the benchmarks never touch [Console]::Title.
$script:GcrTitleSaved = $false
$script:GcrTitleOriginal = $null
$script:GcrTitleCurrent = $null
$script:GcrTitleRepoName = ""
$script:GcrTitleState = ""
$script:GcrTitleEnabled = $false

# Download-speed meter.
$script:GcrSpeedWindowSec = 20
$script:GcrSpeedSamples = $null
$script:GcrSpeedValue = 0.0
