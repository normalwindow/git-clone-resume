#Requires -Version 5.1
<#
.SYNOPSIS
    Git 仓库 Windows 断点续传克隆（partial clone + 按批 checkout）。

.DESCRIPTION
    针对 GitHub 等不稳定网络：先只拉 commit/tree 元数据（--filter=blob:none），
    再分批把工作区文件 checkout 下来。中断后用同一命令重跑即可续传。

    进度保存在仓库 .git/partial-resume/ 下，不污染工作区。
    已成功落盘且大小（可选哈希）匹配的文件会自动跳过。

.PARAMETER RepoUrl
    仓库地址。支持 https / ssh / git@ 以及本地路径。

.PARAMETER OutDir
    本地目录。默认取 URL 最后一段（去掉 .git）。

.PARAMETER Ref
    分支、标签或 commit。默认远程 HEAD。

.PARAMETER BatchSize
    每批最多 checkout 的文件数。越大越快，中断粒度越粗。默认 32。

.PARAMETER MaxArgChars
    单次 git 命令行参数最大字符数，避免超过 Windows 限制。默认 6000。

.PARAMETER MaxRetries
    单个批次/文件失败后的最大重试次数。默认 8。

.PARAMETER RetryDelaySeconds
    首次重试等待秒数，之后指数退避（封顶 60 秒）。默认 2。

.PARAMETER Include
    只下载匹配这些通配符的路径（相对仓库根，支持 * 和 ?）。可重复。

.PARAMETER Exclude
    排除匹配这些通配符的路径。可重复。

.PARAMETER Depth
    可选浅克隆深度。不指定则拉完整 commit 历史（仍不拉 blob）。

.PARAMETER Verify
    续传时对已存在文件做 hash-object 校验，哈希不一致则重下。

.PARAMETER ForceRefetch
    强制重新 fetch 目标 ref（默认仅在本地还没有该 commit 时 fetch）。

.PARAMETER DryRun
    只列出将要处理的文件，不 checkout。

.EXAMPLE
    .\git-clone-resume.ps1 https://github.com/chaihahaha/git-cheatsheet.git

.EXAMPLE
    .\git-clone-resume.ps1 https://github.com/user/repo.git -Ref main -OutDir D:\src\repo -BatchSize 64

.EXAMPLE
    .\git-clone-resume.ps1 https://github.com/user/repo.git -Include src/* -Exclude *.bin
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$RepoUrl,

    [string]$OutDir,

    [string]$Ref = "HEAD",

    [ValidateRange(1, 5000)]
    [int]$BatchSize = 32,

    [ValidateRange(512, 30000)]
    [int]$MaxArgChars = 6000,

    [ValidateRange(1, 100)]
    [int]$MaxRetries = 8,

    [ValidateRange(0, 600)]
    [int]$RetryDelaySeconds = 2,

    [string[]]$Include,

    [string[]]$Exclude,

    [ValidateRange(1, 1000000)]
    [int]$Depth,

    [switch]$Verify,

    [switch]$ForceRefetch,

    [switch]$DryRun,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try { $null = cmd /c "chcp 65001 >NUL" } catch { }
try {
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8
if (-not $env:LC_ALL) { $env:LC_ALL = "C.UTF-8" }
if (-not $env:LANG)   { $env:LANG   = "C.UTF-8" }
if (-not $env:GIT_HTTP_LOW_SPEED_LIMIT) { $env:GIT_HTTP_LOW_SPEED_LIMIT = "1024" }
if (-not $env:GIT_HTTP_LOW_SPEED_TIME)  { $env:GIT_HTTP_LOW_SPEED_TIME  = "60" }
$env:GIT_FLUSH = "1"

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:RepoRoot = $null
$script:LogFile = $null
$script:GitExe = $null
$script:StateDirName = "partial-resume"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "OK", "STEP")]
        [string]$Level = "INFO"
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "Gray" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "OK"    { "Green" }
        "STEP"  { "Cyan" }
    }
    $line = "[$ts][$Level] $Message"
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) {
        try {
            [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8NoBom)
        } catch { }
    }
}

function Show-Usage {
    Write-Host "Git resume clone for Windows / PowerShell 5.1+"
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  .\git-clone-resume.ps1 <repo-url> [options]"
    Write-Host "  git-clone-resume.cmd <repo-url> [options]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -OutDir <dir>           Local directory (default: from URL)"
    Write-Host "  -Ref <branch/tag/sha>   Default: remote HEAD"
    Write-Host "  -BatchSize <N>          Files per batch, default 32"
    Write-Host "  -MaxRetries <N>         Retries per failed batch/file, default 8"
    Write-Host "  -Include a,b            Only download matching paths"
    Write-Host "  -Exclude a,b            Skip matching paths"
    Write-Host "  -Depth <N>              Optional shallow clone depth"
    Write-Host "  -Verify                 Hash-check local files on resume"
    Write-Host "  -ForceRefetch           Always fetch the target ref"
    Write-Host "  -DryRun                 List files, do not checkout blobs"
    Write-Host "  -Help                   Show this help"
    Write-Host ""
    Write-Host "Resume: run the same command again. State is in .git/partial-resume/"
}

if ($Help -or [string]::IsNullOrWhiteSpace($RepoUrl)) {
    Show-Usage
    if ($Help) { exit 0 }
    Write-Host "错误: 必须提供仓库 URL。" -ForegroundColor Red
    exit 2
}

function Get-RepoFolderName {
    param([string]$Url)
    $s = $Url.Trim().TrimEnd([char]47, [char]92)
    if ($s.Length -ge 4 -and $s.EndsWith(".git", [System.StringComparison]::OrdinalIgnoreCase)) {
        $s = $s.Substring(0, $s.Length - 4)
    }
    $s = $s.Replace([char]92, [char]47)
    $i = $s.LastIndexOf([char]47)
    if ($i -ge 0) { $s = $s.Substring($i + 1) }
    $colon = $s.LastIndexOf([char]58)
    if ($colon -ge 0) { $s = $s.Substring($colon + 1) }
    if ([string]::IsNullOrWhiteSpace($s)) { return "repo" }
    return $s
}

function Convert-ToFullPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Get-WorktreePath {
    param([string]$Root, [string]$Rel)
    $acc = $Root
    foreach ($p in ($Rel -split "[\\/]")) {
        if ([string]::IsNullOrEmpty($p) -or $p -eq ".") { continue }
        $acc = Join-Path $acc $p
    }
    return $acc
}

function Test-GitAvailable {
    try {
        $null = Get-Command git -ErrorAction Stop
    } catch {
        throw "未找到 git。请先安装 Git for Windows: https://git-scm.com/download/win"
    }
    $verText = (& git --version 2>$null | Out-String).Trim()
    Write-Log "使用 $verText" "INFO"
    if ($verText -match "git version (\d+)\.(\d+)") {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 19)) {
            Write-Log "partial clone 需要 Git >= 2.19，当前: $verText 。将继续尝试，失败请升级 Git。" "WARN"
        }
    }
}

function Get-GitExePath {
    $cmd = Get-Command git -ErrorAction Stop
    if ($cmd.Source) { return $cmd.Source }
    if ($cmd.Path) { return $cmd.Path }
    return "git"
}

function Convert-ToGitArgumentString {
    param([string[]]$GitArgs)
    $quoted = New-Object System.Text.StringBuilder
    foreach ($a in $GitArgs) {
        if ($null -eq $a) { continue }
        if ($quoted.Length -gt 0) { [void]$quoted.Append(" ") }
        $needsQuote = ($a -match "\s") -or ($a -match '"') -or ($a.Length -eq 0)
        if ($needsQuote) {
            $escaped = $a.Replace([string][char]34, [string][char]92 + [string][char]34)
            [void]$quoted.Append('"').Append($escaped).Append('"')
        } else {
            [void]$quoted.Append($a)
        }
    }
    return $quoted.ToString()
}

function Invoke-GitProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [string]$WorkDir,
        [int]$TimeoutMs = 0,
        [switch]$ExpectFail,
        [switch]$InheritConsole,
        [string]$Heartbeat
    )
    if (-not $script:GitExe) { $script:GitExe = Get-GitExePath }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:GitExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = -not $InheritConsole
    $psi.RedirectStandardInput = $true
    if ($InheritConsole) {
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false
    } else {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    $psi.Arguments = Convert-ToGitArgumentString -GitArgs $GitArgs

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $stdout = ""
    $stderr = ""
    try {
        [void]$proc.Start()
        $proc.StandardInput.Close()
        if (-not $InheritConsole) {
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
        }
        $waitSlice = 500
        $waited = 0
        $hbSec = 2
        while (-not $proc.HasExited) {
            if (-not $proc.WaitForExit($waitSlice)) {
                $waited += $waitSlice
                if ($TimeoutMs -gt 0 -and $waited -ge $TimeoutMs) {
                    try { $proc.Kill() } catch { }
                    throw "git 命令超时 (" + $TimeoutMs + "ms): git " + $psi.Arguments
                }
                if ($Heartbeat -and ($waited % ($hbSec * 1000) -lt $waitSlice)) {
                    $sec = [int]($waited / 1000)
                    Write-Host ("`r[WAIT] " + $Heartbeat + " ... " + $sec + "s    ") -NoNewline
                }
            }
        }
        if ($Heartbeat) { Write-Host "" }
        if (-not $InheritConsole) {
            [void]$stdoutTask.Wait()
            [void]$stderrTask.Wait()
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
        }
        $code = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }

    if ($null -eq $stdout) { $stdout = "" }
    if ($null -eq $stderr) { $stderr = "" }

    if (-not $ExpectFail -and $code -ne 0) {
        $err = $stderr
        if ([string]::IsNullOrWhiteSpace($err)) { $err = $stdout }
        $msg = "git 失败 (exit $code): git " + $psi.Arguments
        if (-not [string]::IsNullOrWhiteSpace($err)) { $msg = $msg + [Environment]::NewLine + $err.Trim() }
        throw $msg
    }
    return [pscustomobject]@{
        ExitCode = $code
        StdOut   = $stdout
        StdErr   = $stderr
        Args     = $GitArgs
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [string]$WorkDir
    )
    $r = Invoke-GitProcess -GitArgs $GitArgs -WorkDir $WorkDir
    return $r.StdOut
}

function Clear-StaleIndexLock {
    param([string]$RepoRoot)
    if (-not $RepoRoot) { return }
    $lock = Join-Path $RepoRoot ".git\index.lock"
    if (Test-Path -LiteralPath $lock) {
        $age = (Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime
        if ($age.TotalMinutes -ge 2) {
            Write-Log ("删除过期 index.lock (" + [int]$age.TotalMinutes + " 分钟)") "WARN"
            Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log ("检测到 index.lock (" + [int]$age.TotalSeconds + "s)。若确认没有其它 git 进程，请手动删除: " + $lock) "WARN"
        }
    }
}

function Invoke-GitRetry {
    param(
        [Parameter(Mandatory = $true)][string[]]$GitArgs,
        [string]$WorkDir,
        [string]$What,
        [int]$TimeoutMs = 0,
        [switch]$InheritConsole,
        [string]$Heartbeat,
        [int]$Retries = -1
    )
    $attempt = 0
    $delay = [Math]::Max(0, $RetryDelaySeconds)
    $lastError = $null
    $limit = $MaxRetries
    if ($Retries -ge 0) { $limit = $Retries }
    $limit = [Math]::Max(1, $limit)
    while ($attempt -lt $limit) {
        $attempt++
        try {
            $r = Invoke-GitProcess -GitArgs $GitArgs -WorkDir $WorkDir -TimeoutMs $TimeoutMs -ExpectFail -InheritConsole:$InheritConsole -Heartbeat $Heartbeat
            if ($r.ExitCode -eq 0) { return $r }
            $lastError = "exit " + $r.ExitCode
            $tail = $r.StdErr
            if ([string]::IsNullOrWhiteSpace($tail)) { $tail = $r.StdOut }
            if (-not [string]::IsNullOrWhiteSpace($tail)) { $lastError = $lastError + " : " + $tail.Trim() }
        } catch {
            $lastError = $_.Exception.Message
        }
        if ($attempt -ge $limit) { break }
        Write-Log ($What + " 失败 (第 " + $attempt + "/" + $limit + " 次): " + $lastError + " ；" + $delay + "s 后重试") "WARN"
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min(60, [Math]::Max(1, $delay * 2))
        Clear-StaleIndexLock -RepoRoot $WorkDir
    }
    throw ($What + " 在 " + $limit + " 次重试后仍失败: " + $lastError)
}

function Save-TextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function Read-Meta {
    param([string]$MetaPath)
    $map = @{}
    if (-not (Test-Path -LiteralPath $MetaPath)) { return $map }
    foreach ($line in [System.IO.File]::ReadAllLines($MetaPath, $script:Utf8NoBom)) {
        $eq = $line.IndexOf("=")
        if ($eq -lt 1) { continue }
        if ($line.StartsWith("#")) { continue }
        $k = $line.Substring(0, $eq).Trim()
        $v = $line.Substring($eq + 1)
        $map[$k] = $v
    }
    return $map
}

function Write-Meta {
    param([string]$MetaPath, [hashtable]$Map)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("# git-clone-resume state")
    foreach ($k in ($Map.Keys | Sort-Object)) {
        [void]$sb.AppendLine($k + "=" + $Map[$k])
    }
    Save-TextFile -Path $MetaPath -Content $sb.ToString()
}

function Test-WildcardMatch {
    param([string]$Path, [string[]]$Patterns)
    if (-not $Patterns -or @($Patterns).Count -eq 0) { return $false }
    $norm = $Path.Replace("\", "/")
    foreach ($p in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $pat = $p.Trim().Replace("\", "/")
        if ($norm -like $pat) { return $true }
        $prefix = $pat.TrimEnd("/")
        if ($prefix -and $norm -like ($prefix + "/*")) { return $true }
    }
    return $false
}

function Initialize-PartialRepo {
    param([string]$RepoRoot, [string]$Url)
    $gitDir = Join-Path $RepoRoot ".git"
    if (-not (Test-Path -LiteralPath $gitDir)) {
        if (-not (Test-Path -LiteralPath $RepoRoot)) {
            New-Item -ItemType Directory -Path $RepoRoot -Force | Out-Null
        }
        Write-Log "git init $RepoRoot" "STEP"
        Invoke-GitRetry -What "git init" -WorkDir $RepoRoot -GitArgs @("init") | Out-Null
    }

    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "core.longpaths", "true") | Out-Null
    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "core.quotepath", "false") | Out-Null
    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "core.precomposeunicode", "true") | Out-Null
    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "i18n.logOutputEncoding", "utf-8") | Out-Null
    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "gc.auto", "0") | Out-Null
    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "http.version", "HTTP/1.1") | Out-Null
    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "http.postBuffer", "524288000") | Out-Null
    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "http.lowSpeedLimit", "1024") | Out-Null
    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "http.lowSpeedTime", "60") | Out-Null

    $existingRemote = ""
    $remoteProbe = Invoke-GitProcess -WorkDir $RepoRoot -ExpectFail -GitArgs @("remote", "get-url", "origin")
    if ($remoteProbe.ExitCode -eq 0) { $existingRemote = $remoteProbe.StdOut.Trim() }

    if ([string]::IsNullOrWhiteSpace($existingRemote)) {
        Invoke-Git -WorkDir $RepoRoot -GitArgs @("remote", "add", "origin", $Url) | Out-Null
    } else {
        $a = $existingRemote.Trim().TrimEnd("/")
        $b = $Url.Trim().TrimEnd("/")
        if ($a -ne $b -and ($a + ".git") -ne $b -and $a -ne ($b + ".git")) {
            Write-Log "已有 origin=$existingRemote ，与本次 URL 不同，改为 $Url" "WARN"
            Invoke-Git -WorkDir $RepoRoot -GitArgs @("remote", "set-url", "origin", $Url) | Out-Null
        }
    }

    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "remote.origin.promisor", "true") | Out-Null
    Invoke-Git -WorkDir $RepoRoot -GitArgs @("config", "remote.origin.partialclonefilter", "blob:none") | Out-Null
}

function Set-DetachedHead {
    param([string]$RepoRoot, [string]$Sha)
    $headFile = Join-Path $RepoRoot ".git\HEAD"
    Save-TextFile -Path $headFile -Content ($Sha + [Environment]::NewLine)
}

function Get-TreeEntries {
    param([string]$RepoRoot, [string]$Sha)
    # Write git stdout to a file as raw bytes. Capturing via StreamReader in PS 5.1
    # can collapse the whole tree into one fake path.
    # Do NOT use -l (blob:none would fetch every blob for sizes) or -z (NUL truncation).
    $gitDir = Join-Path $RepoRoot ".git"
    $stateDir = Join-Path $gitDir $script:StateDirName
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $outFile = Join-Path $stateDir "ls-tree.raw"
    $errFile = Join-Path $stateDir "ls-tree.err"
    if (Test-Path -LiteralPath $outFile) { Remove-Item -LiteralPath $outFile -Force }
    if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force }
    if (-not $script:GitExe) { $script:GitExe = Get-GitExePath }

    $arg = "-c core.quotepath=false ls-tree -r " + $Sha
    $p = Start-Process -FilePath $script:GitExe -WorkingDirectory $RepoRoot `
        -ArgumentList $arg `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -Wait -NoNewWindow -PassThru
    if ($p.ExitCode -ne 0) {
        $err = ""
        if (Test-Path -LiteralPath $errFile) {
            $err = [System.IO.File]::ReadAllText($errFile, $script:Utf8NoBom)
        }
        throw ("ls-tree failed (exit " + $p.ExitCode + "): " + $err.Trim())
    }

    $entries = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $outFile)) { return ,$entries }
    $bytes = [System.IO.File]::ReadAllBytes($outFile)
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return ,$entries }
    $raw = [System.Text.Encoding]::UTF8.GetString($bytes)

    foreach ($rec in $raw.Split(@([char]10), [System.StringSplitOptions]::None)) {
        $rec = $rec.TrimEnd([char]13, [char]0)
        if ([string]::IsNullOrWhiteSpace($rec)) { continue }
        $tab = $rec.IndexOf([char]9)
        if ($tab -lt 0) { continue }
        $metaBits = $rec.Substring(0, $tab)
        $path = $rec.Substring($tab + 1).TrimEnd()
        $bits = @($metaBits -split "\s+", 3)
        if ($bits.Count -lt 3) { continue }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        [void]$entries.Add([pscustomobject]@{
            Mode = $bits[0]
            Type = $bits[1]
            Blob = $bits[2]
            Size = 0L
            Path = $path
        })
    }
    Write-Log ("ls-tree bytes=" + $bytes.Length + " files=" + $entries.Count) "INFO"
    return ,$entries
}

function Get-LocalBlobHash {
    param([string]$RepoRoot, [string]$RelPath)
    $full = Get-WorktreePath -Root $RepoRoot -Rel $RelPath
    if (-not (Test-Path -LiteralPath $full)) { return $null }
    $r = Invoke-GitProcess -WorkDir $RepoRoot -ExpectFail -GitArgs @("hash-object", "--path", $RelPath, "--", $RelPath)
    if ($r.ExitCode -eq 0) { return $r.StdOut.Trim() }
    return $null
}

function Test-FileComplete {
    param(
        [string]$RepoRoot,
        $Entry,
        [switch]$HashVerify
    )
    $full = Get-WorktreePath -Root $RepoRoot -Rel $Entry.Path
    if (-not (Test-Path -LiteralPath $full)) { return $false }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { return $false }

    if ($HashVerify) {
        $h = Get-LocalBlobHash -RepoRoot $RepoRoot -RelPath $Entry.Path
        return ($h -eq $Entry.Blob)
    }
    # Do not compare raw byte length to ls-tree size: core.autocrlf on Windows
    # makes working-tree files larger than the blob.
    return $true
}

function Split-Batches {
    param(
        [object[]]$Items,
        [int]$MaxCount,
        [int]$MaxChars
    )
    $batches = New-Object System.Collections.Generic.List[object]
    $cur = New-Object System.Collections.Generic.List[object]
    $chars = 0
    foreach ($it in $Items) {
        $add = $it.Path.Length + 3
        if ($cur.Count -gt 0 -and (($cur.Count -ge $MaxCount) -or ($chars + $add -gt $MaxChars))) {
            [void]$batches.Add((New-BatchCopy -Items $cur))
            $cur = New-Object System.Collections.Generic.List[object]
            $chars = 0
        }
        [void]$cur.Add($it)
        $chars += $add
    }
    if ($cur.Count -gt 0) {
        [void]$batches.Add((New-BatchCopy -Items $cur))
    }
    return ,$batches
}

function New-BatchCopy {
    param($Items)
    $copy = New-Object System.Collections.Generic.List[object]
    foreach ($it in $Items) { [void]$copy.Add($it) }
    return ,$copy
}

function Format-Bytes {
    param([int64]$n)
    if ($n -lt 1024) { return "$n B" }
    if ($n -lt 1MB) { return ("{0:N1} KB" -f ($n / 1KB)) }
    if ($n -lt 1GB) { return ("{0:N1} MB" -f ($n / 1MB)) }
    return ("{0:N2} GB" -f ($n / 1GB))
}

function Add-DonePaths {
    param([string]$DonePath, [string[]]$Paths)
    if (-not $Paths -or @($Paths).Count -eq 0) { return }
    $text = (@($Paths) -join [Environment]::NewLine) + [Environment]::NewLine
    [System.IO.File]::AppendAllText($DonePath, $text, $script:Utf8NoBom)
}

function Add-FailedPath {
    param([string]$FailedPath, [string]$RelPath, [string]$Reason)
    $safe = $Reason -replace "[\r\n]+", " "
    $line = (Get-Date -Format o) + [char]9 + $RelPath + [char]9 + $safe + [Environment]::NewLine
    [System.IO.File]::AppendAllText($FailedPath, $line, $script:Utf8NoBom)
}

function Load-DoneSet {
    param([string]$DonePath)
    $set = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::Ordinal)
    if (Test-Path -LiteralPath $DonePath) {
        foreach ($line in [System.IO.File]::ReadAllLines($DonePath, $script:Utf8NoBom)) {
            $p = $line.Trim()
            if ($p) { [void]$set.Add($p) }
        }
    }
    # unary comma: stop PowerShell from enumerating the HashSet (empty => $null)
    return ,$set
}

function Invoke-CheckoutBatch {
    param(
        [string]$RepoRoot,
        [string]$Sha,
        $Batch
    )
    $gitArgsList = New-Object System.Collections.Generic.List[string]
    foreach ($x in @("-c", "core.quotepath=false", "-c", "core.longpaths=true", "-c", "advice.detachedHead=false", "checkout", "--progress", $Sha, "--")) {
        [void]$gitArgsList.Add([string]$x)
    }
    $n = 0
    foreach ($e in $Batch) {
        [void]$gitArgsList.Add([string]$e.Path)
        $n++
    }
    if ($n -le 0) { return }
    Ensure-ParentDirectories -RepoRoot $RepoRoot -Batch $Batch
    $first = [string]$Batch[0].Path
    $hb = "downloading " + $n + " file(s), e.g. " + $first
    # Multi-file checkout: try once. Retrying the same 64-file batch on Windows
    # wastes minutes (sha1 missing + cannot create directory) and can desync the index.
    $tries = 1
    if ($n -eq 1) { $tries = $MaxRetries }
    Invoke-GitRetry -What ("checkout " + $n + " files") -WorkDir $RepoRoot -Heartbeat $hb -Retries $tries -GitArgs $gitArgsList.ToArray() | Out-Null
}

function Ensure-ParentDirectories {
    param([string]$RepoRoot, $Batch)
    $seen = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $Batch) {
        $rel = [string]$e.Path
        $slash = $rel.LastIndexOf([char]47)
        if ($slash -lt 1) { continue }
        $parentRel = $rel.Substring(0, $slash)
        if (-not $seen.Add($parentRel)) { continue }
        $full = Get-WorktreePath -Root $RepoRoot -Rel $parentRel
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            Write-Log ("parent path is a file, removing so a directory can be created: " + $parentRel) "WARN"
            Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath $full)) {
            New-Item -ItemType Directory -Path $full -Force | Out-Null
        }
    }
}

function Confirm-BatchFiles {
    param(
        [string]$RepoRoot,
        $Batch,
        [switch]$HashVerify
    )
    $ok = New-Object System.Collections.Generic.List[object]
    $bad = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Batch) {
        if (Test-FileComplete -RepoRoot $RepoRoot -Entry $e -HashVerify:$HashVerify) {
            [void]$ok.Add($e)
        } else {
            [void]$bad.Add($e)
        }
    }
    return @{ Ok = $ok; Bad = $bad }
}

function Repair-GitIndex {
    param([string]$RepoRoot, [string]$Sha)
    # Failed multi-path checkout on Windows can drop index entries while leaving
    # the files on disk (status: D + ??). Re-add existing files; re-checkout missing ones.
    $porcelain = Invoke-GitProcess -WorkDir $RepoRoot -ExpectFail -GitArgs @(
        "-c", "core.quotepath=false", "status", "--porcelain", "-uall"
    )
    if ($porcelain.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($porcelain.StdOut)) { return }
    $add = New-Object System.Collections.Generic.List[string]
    $needCheckout = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($porcelain.StdOut -split [char]10)) {
        $line = $line.TrimEnd([char]13)
        if ($line.Length -lt 4) { continue }
        $code = $line.Substring(0, 2)
        $path = $line.Substring(3).Trim()
        if ($path.StartsWith(".git/")) { continue }
        $full = Get-WorktreePath -Root $RepoRoot -Rel $path
        $exists = Test-Path -LiteralPath $full -PathType Leaf
        if ($code -eq "D " -or $code -eq " D" -or $code -eq "??") {
            if ($exists) { [void]$add.Add($path) } else { [void]$needCheckout.Add($path) }
        }
    }
    if ($add.Count -gt 0) {
        Write-Log ("repair index: git add " + $add.Count + " files that exist on disk") "WARN"
        $args = New-Object System.Collections.Generic.List[string]
        foreach ($x in @("-c", "core.quotepath=false", "add", "-f", "--")) { [void]$args.Add($x) }
        foreach ($p in $add) { [void]$args.Add($p) }
        Invoke-GitProcess -WorkDir $RepoRoot -ExpectFail -GitArgs $args.ToArray() | Out-Null
    }
    if ($needCheckout.Count -gt 0) {
        Write-Log ("repair index: re-checkout " + $needCheckout.Count + " missing files") "WARN"
        $args = New-Object System.Collections.Generic.List[string]
        foreach ($x in @("-c", "core.quotepath=false", "checkout", $Sha, "--")) { [void]$args.Add($x) }
        foreach ($p in $needCheckout) { [void]$args.Add($p) }
        Invoke-GitProcess -WorkDir $RepoRoot -ExpectFail -GitArgs $args.ToArray() | Out-Null
    }
}

function Format-Eta {
    param([TimeSpan]$Elapsed, [int]$DoneThisRun, [int]$Remain)
    if ($Elapsed.TotalSeconds -lt 1 -or $DoneThisRun -le 0 -or $Remain -le 0) { return "--:--:--" }
    $rate = $DoneThisRun / $Elapsed.TotalSeconds
    if ($rate -le 0) { return "--:--:--" }
    $sec = [Math]::Min(864000, $Remain / $rate)
    $ts = [TimeSpan]::FromSeconds($sec)
    return ("{0:00}:{1:00}:{2:00}" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds)
}

function Get-WorktreeBytes {
    param([string]$RepoRoot, [string]$RelPath)
    $full = Get-WorktreePath -Root $RepoRoot -Rel $RelPath
    if (-not (Test-Path -LiteralPath $full)) { return 0L }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if (-not $item -or $item.PSIsContainer) { return 0L }
    return [int64]$item.Length
}

function Write-DownloadProgress {
    param(
        [int]$OkCount,
        [int]$TotalCount,
        [int]$FailCount,
        [int64]$DoneBytes,
        [TimeSpan]$Elapsed,
        [int]$DoneThisRun,
        [string]$CurrentFile,
        [int]$BarWidth = 28
    )
    $pct = 0.0
    if ($TotalCount -gt 0) { $pct = 100.0 * $OkCount / $TotalCount }
    $filled = 0
    if ($TotalCount -gt 0) {
        $filled = [int][Math]::Round($BarWidth * $OkCount / $TotalCount)
        if ($filled -gt $BarWidth) { $filled = $BarWidth }
    }
    $empty = $BarWidth - $filled
    $bar = ("#" * $filled) + ("-" * $empty)
    $remain = $TotalCount - $OkCount - $FailCount
    $eta = Format-Eta -Elapsed $Elapsed -DoneThisRun $DoneThisRun -Remain $remain
    $rate = 0.0
    if ($Elapsed.TotalSeconds -gt 0.5 -and $DoneThisRun -gt 0) {
        $rate = $DoneThisRun / $Elapsed.TotalSeconds
    }
    $name = [string]$CurrentFile
    if ($name.Length -gt 48) { $name = "..." + $name.Substring($name.Length - 45) }
    $line = ("[{0}] {1,5:N1}%  {2}/{3}  fail {4}  {5}  {6:N1} files/s  ETA {7}  {8}" -f @(
        $bar, $pct, $OkCount, $TotalCount, $FailCount, (Format-Bytes $DoneBytes), $rate, $eta, $name
    ))
    $width = 120
    try {
        $w = [int]$Host.UI.RawUI.WindowSize.Width
        if ($w -gt 20) { $width = $w - 1 }
    } catch { }
    $out = $line
    if ($out.Length -lt $width) { $out = $out.PadRight($width) }
    elseif ($out.Length -gt $width) { $out = $out.Substring(0, $width) }
    Write-Host ("`r" + $out) -NoNewline
    Write-Progress -Activity "git-clone-resume" -Status $line -PercentComplete ([Math]::Min(100, [int]$pct))
}

try {
    Test-GitAvailable
    $script:GitExe = Get-GitExePath

    if (-not $OutDir) { $OutDir = Get-RepoFolderName -Url $RepoUrl }
    $repoRoot = Convert-ToFullPath -Path $OutDir
    $script:RepoRoot = $repoRoot

    Write-Log "仓库: $RepoUrl" "STEP"
    Write-Log "目录: $repoRoot" "INFO"
    Write-Log "引用: $Ref" "INFO"

    if (-not (Test-Path -LiteralPath $repoRoot)) {
        New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    }
    Initialize-PartialRepo -RepoRoot $repoRoot -Url $RepoUrl

    $gitDir = Join-Path $repoRoot ".git"
    $stateDir = Join-Path $gitDir $script:StateDirName
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $metaPath   = Join-Path $stateDir "meta.txt"
    $listPath   = Join-Path $stateDir "files.tsv"
    $donePath   = Join-Path $stateDir "done.txt"
    $failedPath = Join-Path $stateDir "failed.txt"
    $script:LogFile = Join-Path $stateDir "log.txt"

    Clear-StaleIndexLock -RepoRoot $repoRoot

    $fetchArgs = @(
        "-c", "http.version=HTTP/1.1",
        "fetch", "--filter=blob:none", "--progress", "--no-recurse-submodules"
    )
    if ($PSBoundParameters.ContainsKey("Depth")) {
        $fetchArgs += @("--depth", [string]$Depth)
    }
    $fetchArgs += @("origin", $Ref)

    $needFetch = $true
    $pinnedSha = $null
    $meta = Read-Meta -MetaPath $metaPath
    if (-not $ForceRefetch -and $meta.ContainsKey("commit") -and $meta["ref"] -eq $Ref) {
        $trySha = $meta["commit"]
        $chk = Invoke-GitProcess -WorkDir $repoRoot -ExpectFail -GitArgs @("cat-file", "-t", $trySha)
        if ($chk.ExitCode -eq 0 -and $chk.StdOut.Trim() -eq "commit") {
            $needFetch = $false
            $pinnedSha = $trySha
            $short = $trySha.Substring(0, [Math]::Min(12, $trySha.Length))
            Write-Log "本地已有 commit $short ，跳过 fetch（需要更新请加 -ForceRefetch）" "OK"
        }
    }

    if ($needFetch) {
        Write-Log "fetch 元数据: git fetch --filter=blob:none origin $Ref" "STEP"
        Invoke-GitRetry -What "git fetch" -WorkDir $repoRoot -GitArgs $fetchArgs -InheritConsole | Out-Null
        $rev = Invoke-GitRetry -What "rev-parse FETCH_HEAD" -WorkDir $repoRoot -GitArgs @("rev-parse", "FETCH_HEAD")
        $pinnedSha = $rev.StdOut.Trim()
        if ([string]::IsNullOrWhiteSpace($pinnedSha)) {
            throw "无法解析 FETCH_HEAD，fetch 可能失败。"
        }
    }

    $type = (Invoke-Git -WorkDir $repoRoot -GitArgs @("cat-file", "-t", $pinnedSha)).Trim()
    if ($type -ne "commit") {
        throw "目标 $Ref 解析为 $type ($pinnedSha)，需要 commit。"
    }
    Set-DetachedHead -RepoRoot $repoRoot -Sha $pinnedSha
    Write-Log "目标 commit: $pinnedSha" "OK"

    Write-Meta -MetaPath $metaPath -Map @{
        url      = $RepoUrl
        ref      = $Ref
        commit   = $pinnedSha
        batch    = [string]$BatchSize
        updated  = (Get-Date -Format o)
        hostname = [string]$env:COMPUTERNAME
    }

    Write-Log "枚举文件树 git ls-tree -r $pinnedSha" "STEP"
    $all = Get-TreeEntries -RepoRoot $repoRoot -Sha $pinnedSha
    if ($null -eq $all) { $all = New-Object System.Collections.Generic.List[object] }
    Write-Log ("树中条目: " + $all.Count) "INFO"

    $skippedSubmodule = 0
    $filtered = New-Object System.Collections.Generic.List[object]
    $includeArr = @($Include | Where-Object { $_ })
    $excludeArr = @($Exclude | Where-Object { $_ })
    foreach ($e in $all) {
        if ($e.Type -eq "commit" -or $e.Mode -eq "160000") {
            $skippedSubmodule++
            continue
        }
        if ($e.Type -ne "blob") { continue }
        if ($includeArr.Count -gt 0 -and -not (Test-WildcardMatch -Path $e.Path -Patterns $includeArr)) { continue }
        if ($excludeArr.Count -gt 0 -and (Test-WildcardMatch -Path $e.Path -Patterns $excludeArr)) { continue }
        [void]$filtered.Add($e)
    }
    if ($skippedSubmodule -gt 0) {
        Write-Log "跳过 $skippedSubmodule 个子模块（gitlink）。需要的话请在对应目录单独再跑本脚本。" "WARN"
    }

    Write-Log ("待处理文件: " + $filtered.Count + " （blob 体积在 checkout 后统计，避免 ls-tree -l 把全部 blob 拉下来）") "INFO"

    $tsv = New-Object System.Text.StringBuilder
    [void]$tsv.AppendLine("mode" + [char]9 + "type" + [char]9 + "blob" + [char]9 + "size" + [char]9 + "path")
    foreach ($e in $filtered) {
        [void]$tsv.AppendLine($e.Mode + [char]9 + $e.Type + [char]9 + $e.Blob + [char]9 + $e.Size + [char]9 + $e.Path)
    }
    Save-TextFile -Path $listPath -Content $tsv.ToString()

    if ($DryRun) {
        Write-Log "DryRun 结束，清单: $listPath" "OK"
        $nshow = [Math]::Min(30, $filtered.Count)
        for ($i = 0; $i -lt $nshow; $i++) {
            $e = $filtered[$i]
            Write-Host ("  " + $e.Path)
        }
        if ($filtered.Count -gt 30) {
            Write-Host ("  ... 另有 {0} 个文件" -f ($filtered.Count - 30))
        }
        exit 0
    }

    $doneSet = Load-DoneSet -DonePath $donePath
    $pending = New-Object System.Collections.Generic.List[object]
    $skippedDone = 0
    $skippedExist = 0
    $reverify = [bool]$Verify
    $scanTotal = $filtered.Count
    $scanIndex = 0
    $scanStarted = Get-Date

    foreach ($e in $filtered) {
        $scanIndex++
        if (($scanIndex % 200) -eq 0 -or $scanIndex -eq $scanTotal) {
            Write-DownloadProgress -OkCount $scanIndex -TotalCount $scanTotal -FailCount 0 -DoneBytes 0L -Elapsed ((Get-Date) - $scanStarted) -DoneThisRun $scanIndex -CurrentFile ("scan " + $e.Path)
        }
        $complete = Test-FileComplete -RepoRoot $repoRoot -Entry $e -HashVerify:$reverify
        if ($complete) {
            if ($doneSet.Contains($e.Path)) {
                $skippedDone++
            } else {
                [void]$doneSet.Add($e.Path)
                Add-DonePaths -DonePath $donePath -Paths @($e.Path)
                $skippedExist++
            }
            continue
        }
        if ($doneSet.Contains($e.Path)) {
            [void]$doneSet.Remove($e.Path)
        }
        [void]$pending.Add($e)
    }
    Write-Host ""

    Write-Log ("进度: 已记录 " + $skippedDone + " ，工作区已存在 " + $skippedExist + " ，剩余 " + $pending.Count) "INFO"

    if ($pending.Count -eq 0) {
        Write-Log "全部文件已就绪。" "OK"
        Write-Log "工作区: $repoRoot" "OK"
        exit 0
    }

    $batches = Split-Batches -Items $pending.ToArray() -MaxCount $BatchSize -MaxChars $MaxArgChars
    Write-Log ("分 " + $batches.Count + " 批下载，每批最多 " + $BatchSize + " 个文件") "STEP"

    $started = Get-Date
    $okCount = $skippedDone + $skippedExist
    $failCount = 0
    $doneBytes = 0L
    foreach ($e in $filtered) {
        if ($doneSet.Contains($e.Path)) { $doneBytes += (Get-WorktreeBytes -RepoRoot $repoRoot -RelPath $e.Path) }
    }
    $totalCount = $filtered.Count
    $processedThisRun = 0
    Write-DownloadProgress -OkCount $okCount -TotalCount $totalCount -FailCount 0 -DoneBytes $doneBytes -Elapsed ([TimeSpan]::Zero) -DoneThisRun 0 -CurrentFile "starting download"

    $batchIndex = 0
    foreach ($batch in $batches) {
        $batchIndex++
        $okThis = New-Object System.Collections.Generic.List[object]
        $badThis = New-Object System.Collections.Generic.List[object]
        $preview = $batch[0].Path
        Write-DownloadProgress -OkCount $okCount -TotalCount $totalCount -FailCount $failCount -DoneBytes $doneBytes -Elapsed ((Get-Date) - $started) -DoneThisRun $processedThisRun -CurrentFile $preview

        try {
            Invoke-CheckoutBatch -RepoRoot $repoRoot -Sha $pinnedSha -Batch $batch
            $result = Confirm-BatchFiles -RepoRoot $repoRoot -Batch $batch
            foreach ($x in $result.Ok) { [void]$okThis.Add($x) }
            foreach ($x in $result.Bad) { [void]$badThis.Add($x) }
        } catch {
            $nBatch = @($batch).Count
            if ($nBatch -gt 1) {
                Write-Log ("批次 " + $batchIndex + "/" + $batches.Count + " 失败（" + $nBatch + " 个文件），立即拆成单文件，不再整批重试: " + $_.Exception.Message) "WARN"
            } else {
                Write-Log ("单文件失败: " + $_.Exception.Message) "WARN"
            }
            foreach ($x in $batch) { [void]$badThis.Add($x) }
        }

        $retry = New-Object System.Collections.Generic.List[object]
        foreach ($e in $badThis) { [void]$retry.Add($e) }
        foreach ($e in $retry) {
            $oneOk = $false
            $one = New-Object System.Collections.Generic.List[object]
            [void]$one.Add($e)
            try {
                Invoke-CheckoutBatch -RepoRoot $repoRoot -Sha $pinnedSha -Batch $one
                if (Test-FileComplete -RepoRoot $repoRoot -Entry $e) { $oneOk = $true }
            } catch {
                Add-FailedPath -FailedPath $failedPath -RelPath $e.Path -Reason $_.Exception.Message
            }
            if ($oneOk) {
                [void]$okThis.Add($e)
            } else {
                $failCount++
                $fullFail = Get-WorktreePath -Root $repoRoot -Rel $e.Path
                $why = "no worktree file"
                if (Test-Path -LiteralPath $fullFail) { $why = "worktree file present but still incomplete" }
                Write-Log ("仍失败: " + $e.Path + " (" + $why + ")") "ERROR"
            }
        }

        $okPaths = New-Object System.Collections.Generic.List[string]
        foreach ($x in $okThis) { [void]$okPaths.Add([string]$x.Path) }
        if ($okPaths.Count -gt 0) {
            Add-DonePaths -DonePath $donePath -Paths $okPaths.ToArray()
            foreach ($p in $okPaths) { [void]$doneSet.Add($p) }
        }

        $processedThisRun += $okThis.Count
        $okCount += $okThis.Count
        foreach ($e in $okThis) { $doneBytes += (Get-WorktreeBytes -RepoRoot $repoRoot -RelPath $e.Path) }

        $lastName = $batch[$batch.Count - 1].Path
        Write-DownloadProgress -OkCount $okCount -TotalCount $totalCount -FailCount $failCount -DoneBytes $doneBytes -Elapsed ((Get-Date) - $started) -DoneThisRun $processedThisRun -CurrentFile $lastName
        if (($batchIndex % 20) -eq 0 -or $okCount -eq $totalCount) {
            $pctNow = 0.0
            if ($totalCount -gt 0) { $pctNow = 100.0 * $okCount / $totalCount }
            Write-Host ""
            Write-Log (("checkpoint {0}/{1} {2:N1}%  fail {3}  {4}" -f $okCount, $totalCount, $pctNow, $failCount, (Format-Bytes $doneBytes))) "INFO"
        }
    }

    Write-Host ""
    Write-Progress -Activity "git-clone-resume" -Completed
    Repair-GitIndex -RepoRoot $repoRoot -Sha $pinnedSha
    $elapsed = (Get-Date) - $started
    $elapsedText = "{0:00}:{1:00}:{2:00}" -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
    Write-Log ("完成: 成功 {0}/{1} ，失败 {2} ，耗时 {3}" -f $okCount, $totalCount, $failCount, $elapsedText) "OK"
    Write-Log "工作区: $repoRoot" "OK"
    if ($failCount -gt 0) {
        Write-Log "失败列表: $failedPath  （再次运行本脚本会重试未完成文件）" "WARN"
        exit 1
    }
    exit 0
}
catch {
    $err = $_.Exception.Message
    Write-Log $err "ERROR"
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace "ERROR" }
    if ($script:RepoRoot) {
        Write-Log ("中断后续传: 重新执行同一命令即可。仓库目录: " + $script:RepoRoot) "WARN"
    }
    exit 1
}

