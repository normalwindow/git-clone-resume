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
    单个文件 checkout / 按需拉取 blob 失败后的最大重试次数。默认 8。

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

.PARAMETER Tui
    强制进入全屏 TUI（交互向导 + 进度面板）。

.PARAMETER NoTui
    禁用 TUI，使用原来的纯日志输出（脚本/CI 推荐）。

.PARAMETER ResumeLast
    从本机历史记录里恢复最近一次未完成（或最近一次）克隆。

.PARAMETER Version
    显示 git-clone-resume 版本后退出。

.PARAMETER ClearHistory
    清除本机克隆历史记录（%LOCALAPPDATA%\git-clone-resume\history.json）。
    不会删除目标仓库或 .git/partial-resume 进度。

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

    [switch]$Tui,

    [switch]$NoTui,

    [ValidateSet("zh-CN", "en-US")]
    [string]$Language = "zh-CN",

    [switch]$ResumeLast,

    [switch]$Version,

    [switch]$ClearHistory,

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
$script:GcrTuiWanted = $false
$script:GcrExitCode = 0
$script:GcrUserStop = $false
$script:GcrLanguage = $Language
$script:GcrVersion = $null

function Get-GcrVersion {
    if ($script:GcrVersion) { return [string]$script:GcrVersion }
    $fallback = "0.1.5"
    try {
        $root = $PSScriptRoot
        if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
        $pkg = Join-Path $root "package.json"
        if (Test-Path -LiteralPath $pkg) {
            $raw = [System.IO.File]::ReadAllText($pkg)
            if ($raw -match '"version"\s*:\s*"([^"]+)"') {
                $script:GcrVersion = [string]$Matches[1]
                return $script:GcrVersion
            }
        }
    } catch { }
    $script:GcrVersion = $fallback
    return $script:GcrVersion
}

function Show-GcrVersion {
    Write-Host ("git-clone-resume {0}" -f (Get-GcrVersion))
}

if ($Version -or $RepoUrl -eq "--version" -or $RepoUrl -eq "-version") {
    Show-GcrVersion
    exit 0
}

function Convert-GcrText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text -or $script:GcrLanguage -ne "en-US") { return $Text }
    $full = [ordered]@{
        "断点续传克隆  ·  partial clone + 按批 checkout" = "Resumable clone  ·  partial clone + batch checkout"
        "选择界面语言。可随时按 L 在中文和英文之间切换。" = "Interface language. Press L to switch between Chinese and English."
        "续传时对已有文件做 hash-object 校验，哈希不一致则重新下载。Space 开关。" = "Verify existing files with hash-object when resuming. Re-download mismatches. Space toggles."
        "浅克隆深度。留空则拉完整 commit 历史（仍然不拉 blob）。" = "Shallow clone depth. Leave empty for full commit history (blobs are still deferred)."
        "跳过匹配的路径，例如 *.bin,*.zip。可与「只含路径」同时使用。" = "Skip matching paths, such as *.bin,*.zip. Can be combined with Include paths."
        "只下载匹配的路径，逗号分隔通配符，例如 src/*,docs/*。空表示全部。" = "Download only matching paths, comma-separated patterns such as src/*,docs/*. Empty means all."
        "单文件失败后的最大重试次数。← → 调整。网络不稳时可调大。" = "Maximum retries after a single-file failure. Use Left/Right to adjust. Increase for unstable networks."
        "每批 checkout 的文件数。越大越快，中断粒度越粗。← → 调整。" = "Files checked out per batch. Larger is faster but less granular. Use Left/Right to adjust."
        "分支、标签或 commit SHA。默认远程 HEAD。" = "Branch, tag, or commit SHA. Defaults to remote HEAD."
        "远程仓库地址，支持 https、ssh、git@ 以及本地路径。Ctrl+V 从剪贴板粘贴。" = "Remote repository URL. Supports https, ssh, git@, and local paths. Ctrl+V pastes from the clipboard."
        "工作区目录。留空则用仓库名。已有 .git/partial-resume 时自动续传。" = "Workspace directory. Leave empty to use the repository name. Existing .git/partial-resume state resumes automatically."
        "强制重新 fetch 目标 ref。换分支或更新到最新 commit 时打开。Space 开关。" = "Force-fetch the target ref. Enable when changing branches or updating to the latest commit. Space toggles."
        "只列出将要处理的文件，不下载 blob。适合先看清单。Space 开关。" = "List files without downloading blobs. Useful for previewing the file list. Space toggles."
        "按上面的设置开始或继续克隆。Enter 启动。中断后重跑即可续传。" = "Start or resume with the settings above. Press Enter to begin; rerun after interruption."
        "将在当前 git 命令结束后停止。Ctrl+C 再按一次立即结束。" = "Stopping after the current git command. Press Ctrl+C again to force stop."
        "已暂停：当前批次结束后停住。Space 继续，Q 停止。" = "Paused after the current batch. Space resumes; Q stops."
        "正在拉取 commit/tree 元数据（blob:none）。文件内容会在下一步按批下载。" = "Fetching commit/tree metadata (blob:none). File contents download in batches next."
        "按批 checkout 文件。中断后重跑同一命令即可续传。" = "Check out files in batches. Rerun the same command after an interruption to resume."
        "脚本模式：加 -NoTui。强制界面：加 -Tui。" = "Script mode: add -NoTui. Force the interface: add -Tui."
        "续传：重新运行同一条命令。进度在 .git/partial-resume/" = "Resume: run the same command again. Progress is stored in .git/partial-resume/"
        "任意键关闭帮助" = "Press any key to close help"
        "当前 git 命令结束后生效；再按一次强制结束" = "takes effect after the current git command; press again to force stop"
        "当前批次结束后暂停" = "pause after the current batch"
        "从暂停恢复" = "resume from pause"
        "切换失败文件列表" = "toggle failed files"
        "滚动活动日志" = "scroll activity log"
        "跟随最新日志" = "follow latest log"
        "打开或关闭本帮助" = "toggle this help"
        "键盘" = "Keyboard"
        "仓库" = "Repository"
        "目录" = "Directory"
        "引用" = "Ref"
        "阶段" = "Phase"
        "当前" = "Current"
        "失败" = "failed"
        "批次" = "batch"
        "暂停" = "pause"
        "停止" = "stop"
        "帮助" = "help"
        "日志" = "log"
        "继续" = "resume"
        "（无。完成一次克隆后会出现在这里）" = "(None. Completed clones appear here)"
        "初始化本地仓库" = "Initialize repository"
        "快捷键说明。任意键关闭此帮助。" = "Keyboard help. Press any key to close."
        "失败文件列表。F 返回活动日志，再次运行同一命令会重试。" = "Failed files. Press F to return to the activity log; run the same command to retry."
        "初始化本地仓库并配置 partial clone（只拉元数据，不拉文件内容）。" = "Initialize the local repository and configure partial clone (metadata only, no file contents)."
        "枚举仓库文件树。不会为了拿大小去拉全部 blob。" = "List the repository file tree without downloading all blobs just to determine their sizes."
        "扫描工作区，跳过已经落盘的文件，其余进入待下载队列。" = "Scan the workspace, skip files already on disk, and queue the rest for download."
        "全部完成。工作区已可用。" = "Everything is complete. The workspace is ready."
        "出错或未完成。重新运行同一命令即可从断点继续。" = "Failed or incomplete. Run the same command to resume."
        "退出向导？未开始的克隆不会写入进度。Enter 确定，Esc 取消。" = "Quit the wizard? No progress is written before a clone starts. Enter confirms; Esc cancels."
        "正在编辑。Enter 确认，Esc 取消，Ctrl+V 粘贴。光标用 ← → Home End。" = "Editing. Enter confirms, Esc cancels, Ctrl+V pastes. Move with Left/Right, Home, or End."
        "最近任务。Enter 填入 URL/目录/分支，可直接续传未完成的克隆。" = "Recent tasks. Enter fills in the URL, directory, and branch to resume an incomplete clone."
        "清空全部历史记录？不会删除仓库或 .git/partial-resume 进度。Enter 确定，Esc 取消。" = "Clear all history? This does not delete repositories or .git/partial-resume state. Enter confirms; Esc cancels."
        "删除这条历史记录？不会删除仓库本身。Enter 确定，Esc 取消。" = "Remove this history entry? The repository itself is not deleted. Enter confirms; Esc cancels."
        "已清除全部历史记录。" = "Cleared all history."
        "已删除该历史记录。" = "Removed that history entry."
        "没有可清除的历史记录。" = "There is no history to clear."
        " Enter 填入  ·  Del 删除  ·  Ctrl+D 清空  ·  Tab 返回  ·  Q 退出" = " Enter fill in  ·  Del delete  ·  Ctrl+D clear all  ·  Tab back  ·  Q quit"
        "暂无失败文件。" = "No failed files."
        " Enter 关闭  ·  Q 退出  ·  ? 帮助" = " Enter close  ·  Q quit  ·  ? help"
        " Ctrl+C 再按一次强制结束  ·  ? 帮助" = " Ctrl+C again to force stop  ·  ? help"
        " Enter 编辑/开始  ·  Space 开关  ·  ←→ 改批次  ·  Ctrl+V 粘贴  ·  Q 退出" = " Enter edit/start  ·  Space toggle  ·  Left/Right batch  ·  Ctrl+V paste  ·  Q quit"
        " Enter 确定退出  ·  Esc 返回" = " Enter confirm quit  ·  Esc back"
        "本地目录" = "Local directory"
        "请填写仓库 URL（Ctrl+V 可从剪贴板粘贴）" = "Enter a repository URL (Ctrl+V pastes from the clipboard)"
        "Enter 编辑 · Space 开关 · Tab 最近任务 · S 开始 · Q 退出" = "Enter edit · Space toggle · Tab recent tasks · S start · Q quit"
        "git-clone-resume  交互设置" = "git-clone-resume  interactive setup"
        "直接回车使用括号里的默认值。空 URL 则退出。" = "Press Enter to use the defaults in brackets. An empty URL exits."
        '每批文件数 [$batch]' = 'Files per batch [$batch]'
        '分支/标签/commit [$defRef]' = 'Branch/tag/commit [$defRef]'
        '本地目录 [$defDir]' = 'Local directory [$defDir]'
    }
    $specific = [ordered]@{
        "断点续传克隆。Q 停止  ·  P 暂停  ·  ? 帮助" = "Resumable clone. Q stop  ·  P pause  ·  ? help"
        "初始化本地仓库并配置 partial clone（只拉元数据，不拉文件内容）。" = "Initialize the local repository and configure partial clone (metadata only, no file contents)."
        "枚举仓库文件树。不会为了拿大小去拉全部 blob。" = "List the repository file tree without downloading all blobs just to determine their sizes."
        "修复 Windows 上可能被弄乱的 git index。" = "Repair the Git index if Windows left it inconsistent."
        "出错或未完成。重新运行同一命令即可从断点继续。" = "Failed or incomplete. Run the same command to resume."
        "最近任务。Enter 填入 URL/目录/分支，可直接续传未完成的克隆。" = "Recent tasks. Enter fills in the URL, directory, and branch to resume an incomplete clone."
        "↑↓ 选择选项，Enter 编辑或开始。每个选项的说明会显示在这一行。" = "Up/Down select; Enter edits or starts. The selected option's guide appears here."
        " Enter 关闭  ·  Q 退出  ·  ? 帮助" = " Enter close  ·  Q quit  ·  ? help"
        " Ctrl+C 再按一次强制结束  ·  ? 帮助" = " Ctrl+C again to force stop  ·  ? help"
        " 最近任务  (Tab 切换  ·  Enter 填入  ·  Del 删除)" = " Recent tasks  (Tab switch  ·  Enter fill in  ·  Del delete)"
        " 最近任务  (Tab 切换  ·  Enter 填入)" = " Recent tasks  (Tab switch  ·  Enter fill in)"
        "清空全部历史记录？不会删除仓库或 .git/partial-resume 进度。Enter 确定，Esc 取消。" = "Clear all history? This does not delete repositories or .git/partial-resume state. Enter confirms; Esc cancels."
        "删除这条历史记录？不会删除仓库本身。Enter 确定，Esc 取消。" = "Remove this history entry? The repository itself is not deleted. Enter confirms; Esc cancels."
        "已清除全部历史记录。" = "Cleared all history."
        "已删除该历史记录。" = "Removed that history entry."
        "没有可清除的历史记录。" = "There is no history to clear."
        " Enter 填入  ·  Del 删除  ·  Ctrl+D 清空  ·  Tab 返回  ·  Q 退出" = " Enter fill in  ·  Del delete  ·  Ctrl+D clear all  ·  Tab back  ·  Q quit"
        " Enter 编辑/开始  ·  Space 开关  ·  ←→ 改批次  ·  Ctrl+V 粘贴  ·  Q 退出" = " Enter edit/start  ·  Space toggle  ·  Left/Right batch  ·  Ctrl+V paste  ·  Q quit"
        " Enter 确认  ·  Esc 取消  ·  Ctrl+V 粘贴" = " Enter confirm  ·  Esc cancel  ·  Ctrl+V paste"
        " Enter 确定退出  ·  Esc 返回" = " Enter confirm quit  ·  Esc back"
        "初始化仓库" = "Initialize repository"
        "拉取元数据" = "Fetch metadata"
        "枚举文件树" = "List file tree"
        "扫描已有文件" = "Scan existing files"
        "下载文件" = "Download files"
        "修复 git index" = "Repair Git index"
        "就绪" = "Ready"
        "设置" = "Setup"
        "出错" = "Error"
        "最近任务" = "Recent tasks"
        "暂无失败文件。" = "No failed files."
        "快捷键说明。任意键关闭此帮助。" = "Keyboard help. Press any key to close."
        "失败文件列表。F 返回活动日志，再次运行同一命令会重试。" = "Failed files. Press F to return to the activity log; run the same command to retry."
        "本次运行已结束。Enter 关闭界面，进度保留在 .git/partial-resume/。" = "This run has ended. Press Enter to close; progress remains in .git/partial-resume/."
        "请填写仓库 URL（Ctrl+V 可从剪贴板粘贴）" = "Enter a repository URL (Ctrl+V pastes from the clipboard)"
        "无法开始: " = "Could not start: "
        '本地目录 [$defDir]' = 'Local directory [$defDir]'
        '分支/标签/commit [$defRef]' = 'Branch/tag/commit [$defRef]'
        '每批文件数 [$batch]' = 'Files per batch [$batch]'
        "本地目录" = "Local directory"
        "分支/标签" = "Branch/tag"
        "每批文件" = "Files per batch"
        "重试次数" = "Retries"
        "只含路径" = "Include paths"
        "排除路径" = "Exclude paths"
        "浅克隆深度" = "Clone depth"
        "哈希校验" = "Hash verification"
        "强制 refetch" = "Force refetch"
        "开始克隆" = "Start clone"
        "(自动)" = "(auto)"
        "(全部)" = "(all)"
        "(无)" = "(none)"
        "(完整历史)" = "(full history)"
        "{0} 分钟前" = "{0} minutes ago"
        "{0} 小时前" = "{0} hours ago"
        "{0} 天前" = "{0} days ago"
        "全部完成。工作区已可用。" = "Everything is complete. The workspace is ready."
        "（无。完成一次克隆后会出现在这里）" = "(None. Completed clones appear here)"
        "单文件失败后的最大重试次数。← → 调整。网络不稳时可调大。" = "Maximum retries after a single-file failure. Use Left/Right to adjust. Increase for unstable networks."
        "跳过匹配的路径，例如 *.bin,*.zip。可与「只含路径」同时使用。" = "Skip matching paths, such as *.bin,*.zip. Can be combined with Include paths."
        "浅克隆深度。留空则拉完整 commit 历史（仍然不拉 blob）。" = "Shallow clone depth. Leave empty for full commit history (blobs are still deferred)."
        "选择界面语言。可随时按 L 在中文和英文之间切换。" = "Interface language. Press L to switch between Chinese and English."
        "按上面的设置开始或继续克隆。Enter 启动。中断后重跑即可续传。" = "Start or resume with the settings above. Press Enter to begin; rerun after interruption."
        "Enter 编辑 · Space 开关 · Tab 最近任务 · S 开始 · Q 退出" = "Enter edit · Space toggle · Tab recent tasks · S start · Q quit"
        "git-clone-resume  交互设置" = "git-clone-resume  interactive setup"
        "语言" = "Language"
        "英文" = "English"
        "中文" = "Chinese"
        "开" = "On"
        "关" = "Off"
    }
    $translations = @{}
    foreach ($key in $full.Keys) { $translations[$key] = [string]$full[$key] }
    foreach ($key in $specific.Keys) { $translations[$key] = [string]$specific[$key] }
    # NB: rules are applied later, all together, longest source string first.
    # Translating eagerly here let short entries win over long phrases
    # ("停止" before "已由用户停止。") and produced mixed output such as
    # "已由用户stop.Rrun the same command again to resume.".
    $pairs = @(
        @("成功 ", "Succeeded "), @("，失败 ", "  failed "), @("，耗时 ", "  elapsed "),
        @("未找到 git。请先安装 Git for Windows", "Git was not found. Install Git for Windows"),
        @("错误:", "Error:"), @("必须提供仓库 URL。", "A repository URL is required."),
        @("无法读取历史记录。", "Could not read history."),
        @("没有可恢复的历史记录。请先启动过一次克隆。", "No resumable history was found. Start a clone first."),
        @("向导失败:", "Wizard failed:"), @("无法开始克隆", "Could not start clone"),
        @("当前终端无法进入全屏 TUI，改用日志模式。Windows Terminal 下再试，或去掉 -Tui。", "This terminal cannot enter fullscreen TUI; using log mode. Try Windows Terminal or remove -Tui."),
        @("已由用户停止。", "Stopped by user."), @("再次运行同一命令即可续传。", "Run the same command again to resume."),
        @("使用 ", "Using "), @("仓库:", "Repository:"), @("目录:", "Directory:"), @("引用:", "Ref:"),
        @("语言", "Language"), @("中文", "Chinese"), @("英文", "English"),
        @("目标 commit:", "Target commit:"), @("fetch 元数据:", "Fetching metadata:"), @("枚举文件树", "Enumerating file tree"),
        @("树中条目:", "Tree entries:"), @("待处理文件:", "Pending files:"), @("工作区:", "Workspace:"),
        @("全部文件已就绪。", "All files are ready."), @("完成", "Complete"), @("克隆完成", "Clone complete"),
        @("部分文件失败", "Some files failed"), @("失败列表:", "Failure list:"), @("仍失败:", "Still failed:"),
        @("批次", "Batch"), @("失败", "failed"), @("单文件失败:", "Single-file failure:"), @("出错", "Error"),
        @("已停止", "Stopped"), @("中断后续传: ", "Resume after interruption: "), @("仓库目录:", "Repository directory:"),
        @("文件数:", "Files:"), @("清单文件:", "List file:"), @("DryRun 完成", "DryRun complete"),
        @("DryRun 结束，清单:", "DryRun finished; list:"),
        @("（blob 体积在 checkout 后统计，避免 ls-tree -l 把全部 blob 拉下来）", "(blob sizes are measured during checkout; ls-tree -l is avoided to prevent downloading all blobs)"),
        @("未下载 blob。去掉 -DryRun 后开始/继续克隆。", "No blobs were downloaded. Remove -DryRun to start or resume."),
        @("检查工作区已有文件", "Checking existing workspace files"), @("进度: 已记录", "Progress: recorded"),
        @("分 ", "Downloading in "), @(" 批下载，每批最多 ", " batches, up to "), @(" 个文件", " files each"),
        @("跳过", "Skipped"), @("个子模块（gitlink）。需要的话请在对应目录单独再跑本脚本。", " submodules (gitlinks). Run this script separately if needed.")
        ,@("断点续传克隆", "Resumable clone"), @("按批 checkout", "batch checkout"), @("刚刚", "just now"),
        @("分钟前", " minutes ago"), @("小时前", " hours ago"), @("天前", " days ago"),
        @("就绪", "Ready"), @("设置", "Setup"), @("初始化仓库", "Initialize repository"), @("拉取元数据", "Fetch metadata"),
        @("枚举文件树", "List file tree"), @("扫描已有文件", "Scan existing files"), @("下载文件", "Download files"),
        @("修复 git index", "Repair git index"), @("快捷键说明。任意键关闭此帮助。", "Keyboard help. Press any key to close."),
        @("失败文件列表。F 返回活动日志，再次运行同一命令会重试。", "Failed files. Press F to return; run the same command to retry."),
        @("本次运行已结束。Enter 关闭界面，进度保留在 .git/partial-resume/。", "This run has ended. Press Enter to close; progress remains in .git/partial-resume/."),
        @("已暂停：当前批次结束后停住。Space 继续，Q 停止。", "Paused after the current batch. Space resumes; Q stops."),
        @("全部完成。工作区已可用。", "Everything is complete. The workspace is ready."),
        @("出错或未完成。重新运行同一命令即可从断点继续。", "Failed or incomplete. Run the same command to resume."),
        @("远程仓库地址，支持 https、ssh、git@ 以及本地路径。Ctrl+V 从剪贴板粘贴。", "Remote repository URL. Supports https, ssh, git@, and local paths. Ctrl+V pastes from the clipboard."),
        @("工作区目录。留空则用仓库名。已有 .git/partial-resume 时自动续传。", "Workspace directory. Leave empty to use the repository name. Existing .git/partial-resume state resumes automatically."),
        @("选择界面语言。可随时按 L 在中文和英文之间切换。", "Interface language. Press L at any time to switch between Chinese and English."),
        @("（再次运行本脚本会重试未完成文件）", " (rerun this script to retry the unfinished files)"),
        @("，工作区已存在 ", ", already on disk "), @("，剩余 ", ", remaining "),
        @("（8 个文件）", " (8 files)"),
        @("最近任务", "Recent tasks"), @("切换", "switch"), @("填入", "fill in"), @("无。完成一次克隆后会出现在这里", "None. Completed clones appear here"),
        @("Enter 编辑/开始", "Enter edit/start"), @("Space 开关", "Space toggle"), @("改批次", "change batch"), @("粘贴", "paste"), @("退出", "quit"),
        @("按上面的设置开始或继续克隆。Enter 启动。中断后重跑即可续传。", "Start or resume with the settings above. Press Enter to begin; rerun after interruption."),
        @("请填写仓库 URL（Ctrl+V 可从剪贴板粘贴）", "Enter a repository URL (Ctrl+V pastes from the clipboard)"),
        @("语言", "Language"), @("中文", "Chinese"), @("英文", "English")
        ,@(" 仓库  ", " Repository  "), @(" 目录  ", " Directory  "), @(" 引用  ", " Ref  "), @(" 阶段  ", " Phase  "), @(" 当前  ", " Current  "),
        @("键盘", "Keyboard"), @("暂无失败文件。", "No failed files."), @("停止", "stop"), @("暂停", "pause"), @("帮助", "help"), @("日志", "log")
        ,@("仓库 URL", "Repository URL"), @("本地目录", "Local directory"), @("分支/标签", "Branch/tag"), @("每批文件", "Files per batch"),
        @("重试次数", "Retries"), @("只含路径", "Include paths"), @("排除路径", "Exclude paths"), @("浅克隆深度", "Clone depth"),
        @("哈希校验", "Hash verification"), @("强制 refetch", "Force refetch"), @("开始克隆", "Start clone"),
        @("(自动)", "(auto)"), @("(全部)", "(all)"), @("(无)", "(none)"), @("(完整历史)", "(full history)"),
        @("强制重新 fetch 目标 ref。换分支或更新到最新 commit 时打开。Space 开关。", "Force-fetch the target ref. Enable when changing branches or updating to the latest commit. Space toggles."),
        @("只列出将要处理的文件，不下载 blob。适合先看清单。Space 开关。", "List files without downloading blobs. Useful for previewing the file list. Space toggles."),
        @("按上面的设置开始或继续克隆。Enter 启动。中断后重跑即可续传。", "Start or resume with the settings above. Press Enter to begin; rerun after interruption."),
        @("Enter 编辑/开始", "Enter edit/start"), @("Space 开关", "Space toggle"), @("←→ 改批次", "Left/Right change batch"),
        @("Ctrl+V 粘贴", "Ctrl+V paste"), @("Q 退出", "Q quit"), @("Enter 确认", "Enter confirm"), @("Esc 取消", "Esc cancel"),
        @("退出向导？未开始的克隆不会写入进度。Enter 确定，Esc 取消。", "Quit the wizard? No progress is written before a clone starts. Enter confirms; Esc cancels."),
        @("↑↓ 选择选项，Enter 编辑或开始。每个选项的说明会显示在这一行。", "Up/Down select; Enter edits or starts. The selected option's guide appears here."),
        @("将在当前 git 命令结束后停止。Ctrl+C 再按一次立即结束。", "Stopping after the current git command. Press Ctrl+C again to force stop."),
        @("初始化本地仓库并配置 partial clone（只拉元数据，不拉文件内容）。", "Initialize the repository and configure partial clone (metadata only)."),
        @("正在拉取 commit/tree 元数据（blob:none）。文件内容会在下一步按批下载。", "Fetching commit/tree metadata (blob:none). File contents download in batches next."),
        @("扫描工作区，跳过已经落盘的文件，其余进入待下载队列。", "Scan the workspace, skip files already on disk, and queue the rest."),
        @("按批 checkout 文件。中断后重跑同一命令即可续传。", "Check out files in batches. Rerun the same command after an interruption to resume."),
        @("修复 Windows 上可能被弄乱的 git index。", "Repair the Git index if Windows left it inconsistent."),
        @("Q 停止  ·  P 暂停  ·  ? 帮助", "Q stop  ·  P pause  ·  ? help")
    )
    $direct = [ordered]@{
        "断点续传克隆" = "Resumable clone"
        "按批 checkout" = "batch checkout"
        "仓库 URL" = "Repository URL"
        "本地目录" = "Local directory"
        "分支/标签" = "Branch/tag"
        "每批文件" = "Files per batch"
        "重试次数" = "Retries"
        "只含路径" = "Include paths"
        "排除路径" = "Exclude paths"
        "浅克隆深度" = "Clone depth"
        "哈希校验" = "Hash verification"
        "开始克隆" = "Start clone"
        "强制重新 fetch 目标 ref。换分支或更新到最新 commit 时打开。Space 开关。" = "Force-fetch the target ref. Enable when changing branches or updating to the latest commit. Space toggles."
        "只列出将要处理的文件，不下载 blob。适合先看清单。Space 开关。" = "List files without downloading blobs. Useful for previewing the file list. Space toggles."
        "按上面的设置开始或继续克隆。Enter 启动。中断后重跑即可续传。" = "Start or resume with the settings above. Press Enter to begin; rerun after interruption."
        "Enter 编辑/开始" = "Enter edit/start"
        "Space 开关" = "Space toggle"
        "←→ 改批次" = "Left/Right change batch"
        "Ctrl+V 粘贴" = "Ctrl+V paste"
        "Q 退出" = "Q quit"
        "Language" = "Language"
    }
    # Single pass over every rule, longest source first, so a phrase is never
    # half-translated by a shorter entry it contains.
    $ruleMap = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($key in $translations.Keys) { $ruleMap[[string]$key] = [string]$translations[$key] }
    foreach ($key in $direct.Keys) { $ruleMap[[string]$key] = [string]$direct[$key] }
    $items = @($pairs)
    for ($i = 0; $i -lt $items.Count;) {
        if ($items[$i] -is [array] -and @($items[$i]).Count -ge 2) {
            $from = [string]@($items[$i])[0]
            $to = [string]@($items[$i])[1]
            $i++
        } elseif ($i + 1 -lt $items.Count) {
            $from = [string]$items[$i]
            $to = [string]$items[$i + 1]
            $i += 2
        } else {
            break
        }
        if (-not [string]::IsNullOrEmpty($from)) { $ruleMap[$from] = $to }
    }
    # A source string that ends a sentence needs a separating space on the
    # English side, otherwise the next sentence glues on (the "。" is consumed
    # by the rule itself, so the cleanup below cannot see it any more).
    foreach ($k in @($ruleMap.Keys)) {
        $ks = [string]$k
        $vs = [string]$ruleMap[$k]
        if ($ks.EndsWith("。") -and $vs -and -not $vs.EndsWith(" ")) {
            $ruleMap[$k] = $vs + " "
        }
    }
    $result = $Text
    foreach ($key in @($ruleMap.Keys | Sort-Object { $_.Length } -Descending)) {
        if (-not [string]::IsNullOrEmpty($key)) { $result = $result.Replace([string]$key, [string]$ruleMap[$key]) }
    }
    # Last pass: Chinese punctuation left over by any rule would look odd in
    # English output ("Succeeded 40/40 ，failed 0" -> ", failed 0").
    # "。" before a non-space also needs a separating space, otherwise adjacent
    # sentences glue together ("Stopped by user.Run the same command again").
    $result = [regex]::Replace($result, "。(?=\S)", ". ")
    $result = $result.Replace("。", ". ")
    $result = $result.Replace(" ，", ", ").Replace("，", ", ")
    $result = $result.Replace(" , ", ", ").Replace(" . ", ". ")
    $result = $result.Replace("（", " (").Replace("）", ")").Replace("）", ")")
    $result = $result.Replace("、", ", ")
    return $result
}

$script:GcrTuiFile = Join-Path $PSScriptRoot "git-clone-resume.tui.ps1"
if (-not $PSScriptRoot) {
    $script:GcrTuiFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "git-clone-resume.tui.ps1"
}
if (Test-Path -LiteralPath $script:GcrTuiFile) {
    . $script:GcrTuiFile
} else {
    function Test-GcrTuiActive { return $false }
    function Test-GcrTuiAvailable { return $false }
    function Test-GcrTuiQuit { return $false }
    function Test-GcrTuiForceQuit { return $false }
    function Invoke-GcrTuiTick { }
    function Write-GcrNewline { Write-Host "" }
    function Initialize-GcrTui { return $false }
    function Close-GcrTui { }
    function Set-GcrTuiPhase {
        param([string]$Name, [string]$Detail = "")
        if ($Name) { Update-GcrWindowTitle -State $Name }
    }
    function Set-GcrTuiRepo { }
    function Update-GcrTuiProgress { }
    function Add-GcrTuiLog { }
    function Add-GcrTuiFailure { }
    function Add-GcrGitOutput { }
    function Receive-GcrGitBytes { }
    function Wait-GcrTuiPaused { }
    function Show-GcrTuiResult { }
    function Save-GcrHistory { }
    function Clear-GcrHistory { return 0 }
    function Remove-GcrHistoryEntry { return $false }
}

if (-not $PSBoundParameters.ContainsKey("Language") -and (Get-Command Get-GcrLanguagePreference -ErrorAction SilentlyContinue)) {
    $savedLanguage = Get-GcrLanguagePreference
    if ($savedLanguage) { $script:GcrLanguage = $savedLanguage }
}
if ($PSBoundParameters.ContainsKey("Language") -and (Get-Command Save-GcrLanguagePreference -ErrorAction SilentlyContinue)) {
    Save-GcrLanguagePreference -Language $Language
}

function Write-Log {
    param(
        $Message,
        [string]$Level = "INFO"
    )
    if (@("INFO", "WARN", "ERROR", "OK", "STEP") -notcontains $Level) { $Level = "INFO" }
    $text = ""
    try {
        if ($null -eq $Message) { $text = "" }
        elseif ($Message -is [System.Array]) { $text = (@($Message | ForEach-Object { "$_" }) -join " ") }
        else { $text = [string]$Message }
    } catch { $text = "$Message" }
    $text = Convert-GcrText $text
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "Gray" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "OK"    { "Green" }
        "STEP"  { "Cyan" }
        default { "Gray" }
    }
    $line = "[$ts][$Level] $text"
    try {
        if (Test-GcrTuiActive) {
            Add-GcrTuiLog -Level $Level -Message $text
            Invoke-GcrTuiTick
        } else {
            Write-Host $line -ForegroundColor $color
        }
    } catch { }
    if ($script:LogFile) {
        try {
            [System.IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8NoBom)
        } catch { }
    }
}

# ---------------------------------------------------------------------------
# Window / tab title
# ---------------------------------------------------------------------------
# The taskbar, Windows Terminal tabs and the VS Code terminal list all display
# [Console]::Title. Keep it informative while a clone runs - in TUI *and* in
# -NoTui mode:  "<repo>  ·  42% (340/802)  ·  git-clone-resume".
$script:GcrTitleSaved = $false
$script:GcrTitleOriginal = $null
$script:GcrTitleCurrent = $null
$script:GcrTitleRepoName = ""
$script:GcrTitleState = ""
$script:GcrTitleEnabled = $false
try {
    $script:GcrTitleEnabled = [bool][Environment]::UserInteractive
    if ([Console]::IsOutputRedirected) { $script:GcrTitleEnabled = $false }
    $titlePreference = [string]$env:GCR_TITLE
    if ($titlePreference -eq "1") { $script:GcrTitleEnabled = $true }
    elseif ($titlePreference -eq "0") { $script:GcrTitleEnabled = $false }
} catch { $script:GcrTitleEnabled = $false }

function Set-GcrWindowTitle {
    param([string]$Text)
    if (-not $script:GcrTitleEnabled) { return }
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if (-not $script:GcrTitleSaved) {
        $script:GcrTitleSaved = $true
        try { $script:GcrTitleOriginal = [string][Console]::Title } catch { $script:GcrTitleOriginal = $null }
    }
    if ($script:GcrTitleCurrent -eq $Text) { return }
    $script:GcrTitleCurrent = $Text
    try { [Console]::Title = $Text } catch { }
}

function Restore-GcrWindowTitle {
    if (-not $script:GcrTitleSaved) { return }
    $script:GcrTitleSaved = $false
    $script:GcrTitleCurrent = $null
    if (-not $script:GcrTitleEnabled) { return }
    try {
        if ($script:GcrTitleOriginal) { [Console]::Title = $script:GcrTitleOriginal }
    } catch { }
}

# State: run | init | fetch | list | scan | download | repair | paused | done | error | stopped
# A call without -State keeps the last phase, so progress-only updates (which
# happen far more often) still render with the right label - e.g. during the
# workspace scan the title shows "scanning workspace (42/120)" instead of a
# percentage that would jump to 100% and then fall back to 0%.
function Update-GcrWindowTitle {
    param(
        [string]$State = "",
        [int]$Ok = -1,
        [int]$Total = -1,
        [int]$Fail = -1
    )
    if (-not $script:GcrTitleEnabled) { return }
    if ($State) { $script:GcrTitleState = $State }
    elseif ($script:GcrTitleState) { $State = $script:GcrTitleState }
    else { $State = "run" }
    $pct = -1
    if ($Total -gt 0 -and $Ok -ge 0) {
        $pct = [int][Math]::Floor((100.0 * $Ok) / $Total)
        if ($pct -gt 100) { $pct = 100 }
        if ($pct -lt 0) { $pct = 0 }
    }
    $counts = ""
    if ($Ok -ge 0 -and $Total -gt 0) { $counts = ("({0}/{1})" -f $Ok, $Total) }
    $progress = ""
    if ($pct -ge 0) { $progress = ("{0}% {1}" -f $pct, $counts).Trim() }
    $parts = New-Object System.Collections.Generic.List[string]
    if ($script:GcrTitleRepoName) { [void]$parts.Add([string]$script:GcrTitleRepoName) }
    switch ($State) {
        "init"    { [void]$parts.Add("starting") }
        "fetch"   { [void]$parts.Add("fetching metadata") }
        "list"    { [void]$parts.Add("listing files") }
        "scan"    { [void]$parts.Add(("scanning workspace " + $counts).Trim()) }
        "repair"  { [void]$parts.Add("repairing index") }
        "download" {
            if ($progress) { [void]$parts.Add($progress) } else { [void]$parts.Add("downloading files") }
            if ($Fail -gt 0) { [void]$parts.Add("failed " + $Fail) }
        }
        "paused"  {
            if ($progress) { [void]$parts.Add($progress) }
            [void]$parts.Add("PAUSED")
        }
        "done"    { [void]$parts.Add(("done " + $counts).Trim()) }
        "error"   {
            if ($progress) { [void]$parts.Add($progress) }
            if ($Fail -gt 0) { [void]$parts.Add("FAILED " + $Fail) } else { [void]$parts.Add("failed") }
        }
        "stopped" { [void]$parts.Add("stopped") }
        default   {
            if ($progress) { [void]$parts.Add($progress) }
            if ($Fail -gt 0) { [void]$parts.Add("failed " + $Fail) }
        }
    }
    [void]$parts.Add("git-clone-resume")
    Set-GcrWindowTitle -Text ($parts -join "  ·  ")
}

# Pick the string for the active language. Unlike the substring translation
# table (meant for TUI/wizard text), this is exact - used where a wrong or
# half-translated line would be visible, such as the result panel.
function Get-GcrText {
    param([string]$Zh, [string]$En)
    if ($script:GcrLanguage -eq "en-US" -and $En) { return $En }
    return $Zh
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
    Write-Host "  -MaxRetries <N>         Retries per file / blob fetch, default 8"
    Write-Host "  -Include a,b            Only download matching paths"
    Write-Host "  -Exclude a,b            Skip matching paths"
    Write-Host "  -Depth <N>              Optional shallow clone depth"
    Write-Host "  -Verify                 Hash-check local files on resume"
    Write-Host "  -ForceRefetch           Always fetch the target ref"
    Write-Host "  -DryRun                 List files, do not checkout blobs"
    Write-Host "  -Tui                    Force fullscreen TUI"
    Write-Host "  -NoTui                  Disable TUI (script/CI mode)"
    Write-Host "  -Language zh-CN|en-US   User interface language"
    Write-Host "  -ResumeLast             Resume the latest history entry"
    Write-Host "  -ClearHistory           Clear local clone history (not repo progress)"
    Write-Host "  -Version                Show git-clone-resume version"
    Write-Host "  -Help                   Show this help"
    Write-Host ""
    Write-Host "Interactive: run with no URL to open the TUI wizard."
    Write-Host "Resume: run the same command again. State is in .git/partial-resume/"
    Write-Host "Keys: Q stop  P pause  F failures  ? help  Ctrl+C twice to kill git"
    Write-Host ""
    Write-Host "Env: GCR_TITLE=1/0 force or disable the taskbar/tab title (default: on in a terminal)"
    Write-Host "     GCR_ASCII=1   force ASCII box drawing"
}

if ($Help) {
    Show-Usage
    exit 0
}

if ($ClearHistory) {
    if (Get-Command Clear-GcrHistory -ErrorAction SilentlyContinue) {
        $n = Clear-GcrHistory
        if ($n -gt 0) {
            Write-Host (Convert-GcrText ("已清除全部历史记录。({0})" -f $n))
        } else {
            Write-Host (Convert-GcrText "没有可清除的历史记录。")
        }
        exit 0
    }
    Write-Host (Convert-GcrText "无法读取历史记录。")
    exit 1
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
        [string]$Heartbeat,
        [hashtable]$EnvOverride
    )
    if (-not $script:GitExe) { $script:GitExe = Get-GitExePath }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:GitExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = -not $InheritConsole
    $psi.RedirectStandardInput = $true
    # Without this the writer for StandardInput inherits [Console]::InputEncoding
    # (UTF8 *with* BOM) and emits a BOM prefix as soon as it is flushed.
    try { $psi.StandardInputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
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
    if ($EnvOverride) {
        foreach ($k in $EnvOverride.Keys) {
            try { $psi.EnvironmentVariables[[string]$k] = [string]$EnvOverride[$k] } catch { }
        }
    }
    $psi.Arguments = Convert-ToGitArgumentString -GitArgs $GitArgs

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $stdout = ""
    $stderr = ""
    $script:GcrCurrentProc = $proc
    try {
        [void]$proc.Start()
        $proc.StandardInput.Close()
        $waitSlice = 16
        if (-not (Test-GcrTuiActive)) { $waitSlice = 500 }
        $waited = 0
        $hbSec = 2
        $useStream = (Test-GcrTuiActive) -and (-not $InheritConsole)
        $stdoutTask = $null
        $stderrTask = $null
        $outBuf = $null
        $errBuf = $null
        $outCarry = $null
        $errCarry = $null
        $outRead = $null
        $errRead = $null
        $stdoutSb = New-Object System.Text.StringBuilder
        $stderrSb = New-Object System.Text.StringBuilder
        if ($useStream) {
            $outBuf = New-Object byte[] 4096
            $errBuf = New-Object byte[] 4096
            $outCarry = New-Object System.Text.StringBuilder
            $errCarry = New-Object System.Text.StringBuilder
            $outRead = $proc.StandardOutput.BaseStream.ReadAsync($outBuf, 0, $outBuf.Length)
            $errRead = $proc.StandardError.BaseStream.ReadAsync($errBuf, 0, $errBuf.Length)
        } elseif (-not $InheritConsole) {
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
        }
        while (-not $proc.HasExited) {
            if ($useStream) {
                if ($null -ne $outRead -and $outRead.IsCompleted) {
                    $n = 0
                    try { $n = [int]$outRead.Result } catch { $n = 0 }
                    if ($n -gt 0) {
                        $chunk = [System.Text.Encoding]::UTF8.GetString($outBuf, 0, $n)
                        [void]$stdoutSb.Append($chunk)
                        $outRead = $proc.StandardOutput.BaseStream.ReadAsync($outBuf, 0, $outBuf.Length)
                    } else { $outRead = $null }
                }
                if ($null -ne $errRead -and $errRead.IsCompleted) {
                    $n = 0
                    try { $n = [int]$errRead.Result } catch { $n = 0 }
                    if ($n -gt 0) {
                        [void]$stderrSb.Append([System.Text.Encoding]::UTF8.GetString($errBuf, 0, $n))
                        Receive-GcrGitBytes -Buffer $errBuf -Count $n -Carry $errCarry -IsStdErr
                        $errRead = $proc.StandardError.BaseStream.ReadAsync($errBuf, 0, $errBuf.Length)
                    } else { $errRead = $null }
                }
            }
            if (-not $proc.WaitForExit($waitSlice)) {
                $waited += $waitSlice
                if ($TimeoutMs -gt 0 -and $waited -ge $TimeoutMs) {
                    try { $proc.Kill() } catch { }
                    throw "git 命令超时 (" + $TimeoutMs + "ms): git " + $psi.Arguments
                }
                if ($Heartbeat -and ($waited % ($hbSec * 1000) -lt $waitSlice)) {
                    $sec = [int]($waited / 1000)
                    if (Test-GcrTuiActive) {
                        Set-GcrTuiPhase -Detail ($Heartbeat + " ... " + $sec + "s")
                    } else {
                        Write-Host ("`r[WAIT] " + $Heartbeat + " ... " + $sec + "s    ") -NoNewline
                    }
                }
            }
            if (Test-GcrTuiActive) {
                Invoke-GcrTuiTick
                if (Test-GcrTuiForceQuit) {
                    try { $proc.Kill() } catch { }
                    $script:GcrUserStop = $true
                    throw "已由用户停止。"
                }
            }
        }
        if ($Heartbeat -and -not (Test-GcrTuiActive)) { Write-Host "" }
        if ($useStream) {
            if ($null -ne $outRead) {
                try {
                    $n = [int]$outRead.Result
                    if ($n -gt 0) { [void]$stdoutSb.Append([System.Text.Encoding]::UTF8.GetString($outBuf, 0, $n)) }
                } catch { }
            }
            if ($null -ne $errRead) {
                try {
                    $n = [int]$errRead.Result
                    if ($n -gt 0) {
                        [void]$stderrSb.Append([System.Text.Encoding]::UTF8.GetString($errBuf, 0, $n))
                        Receive-GcrGitBytes -Buffer $errBuf -Count $n -Carry $errCarry -IsStdErr
                    }
                } catch { }
            }
            if ($errCarry -and $errCarry.Length -gt 0) { Add-GcrGitOutput -Text $errCarry.ToString() }
            $stdout = $stdoutSb.ToString()
            $stderr = $stderrSb.ToString()
        } elseif (-not $InheritConsole) {
            [void]$stdoutTask.Wait()
            [void]$stderrTask.Wait()
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
        }
        if ($script:GcrUserStop) { throw "已由用户停止。" }
        $code = $proc.ExitCode
    } finally {
        $script:GcrCurrentProc = $null
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
        [int]$Retries = -1,
        [hashtable]$EnvOverride
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
            $r = Invoke-GitProcess -GitArgs $GitArgs -WorkDir $WorkDir -TimeoutMs $TimeoutMs -ExpectFail -InheritConsole:$InheritConsole -Heartbeat $Heartbeat -EnvOverride $EnvOverride
            if ($script:GcrUserStop) { throw "已由用户停止。" }
            if ($r.ExitCode -eq 0) { return $r }
            $lastError = "exit " + $r.ExitCode
            $tail = $r.StdErr
            if ([string]::IsNullOrWhiteSpace($tail)) { $tail = $r.StdOut }
            if (-not [string]::IsNullOrWhiteSpace($tail)) { $lastError = $lastError + " : " + $tail.Trim() }
        } catch {
            if ($script:GcrUserStop) { throw }
            $lastError = $_.Exception.Message
        }
        if ($attempt -ge $limit) { break }
        Write-Log (Get-GcrText ($What + " 失败 (第 " + $attempt + "/" + $limit + " 次): " + $lastError + " ；" + $delay + "s 后重试") ($What + " failed (attempt " + $attempt + "/" + $limit + "): " + $lastError + " ; retrying in " + $delay + "s")) "WARN"
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min(60, [Math]::Max(1, $delay * 2))
        Clear-StaleIndexLock -RepoRoot $WorkDir
    }
    throw (Get-GcrText ($What + " 在 " + $limit + " 次重试后仍失败: " + $lastError) ($What + " still failed after " + $limit + " attempts: " + $lastError))
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

function Get-BatchBlobOids {
    param($Batch)
    $list = New-Object System.Collections.Generic.List[string]
    $seen = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::Ordinal)
    # NB: on Windows PowerShell 5.1 `@($list)` on a List[object] holding
    # PSCustomObjects throws "parameter type mismatch", and binding such a list
    # to [string[]] silently joins the items with spaces. Always foreach.
    foreach ($e in $Batch) {
        if ($null -eq $e) { continue }
        $o = [string]$e.Blob
        if ([string]::IsNullOrWhiteSpace($o)) { continue }
        if ($seen.Add($o)) { [void]$list.Add($o) }
    }
    return ,$list
}

# Ask the promisor remote for exactly these blob oids. This mirrors git's own
# lazy fetch (promisor-remote.c: fetch_objects) but passes the ids as arguments
# instead of --stdin, so no stdin encoding can mangle them.
#   git -c fetch.negotiationAlgorithm=noop fetch <remote> --no-tags
#       --no-write-fetch-head --recurse-submodules=no --filter=blob:none <oid>...
# Result: one request per chunk instead of git's implicit one-request-per-file,
# proper retries, and a real error message when it fails.
function Invoke-BlobFetch {
    param([string]$RepoRoot, $Oids, [int]$Attempts = 3)

    $oidList = New-Object System.Collections.Generic.List[string]
    foreach ($o in $Oids) { if ($o) { [void]$oidList.Add([string]$o) } }
    if ($oidList.Count -eq 0) { return $true }
    $baseArgs = @(
        "-c", "fetch.negotiationAlgorithm=noop",
        "-c", "core.quotepath=false",
        "fetch", "origin", "--no-tags", "--no-write-fetch-head",
        "--recurse-submodules=no", "--filter=blob:none"
    )
    $limit = [Math]::Max(1, $Attempts)
    $delay = [Math]::Max(0, $RetryDelaySeconds)
    # Keep every command line far below the Windows limit (~32k chars).
    $chunkSize = 128
    $allOk = $true
    for ($start = 0; $start -lt $oidList.Count; $start += $chunkSize) {
        $take = [Math]::Min($chunkSize, $oidList.Count - $start)
        $chunk = $oidList.GetRange($start, $take)
        $gitArgs = New-Object System.Collections.Generic.List[string]
        foreach ($x in $baseArgs) { [void]$gitArgs.Add([string]$x) }
        foreach ($o in $chunk) { [void]$gitArgs.Add([string]$o) }
        $chunkOk = $false
        $last = ""
        for ($i = 1; $i -le $limit; $i++) {
            if ($script:GcrUserStop) { throw "已由用户停止。" }
            $r = Invoke-GitProcess -WorkDir $RepoRoot -ExpectFail -GitArgs $gitArgs.ToArray()
            if ($r.ExitCode -eq 0) { $chunkOk = $true; break }
            $tail = $r.StdErr
            if ([string]::IsNullOrWhiteSpace($tail)) { $tail = $r.StdOut }
            $last = "exit " + $r.ExitCode + " : " + $tail.Trim()
            if ($i -lt $limit) {
                Write-Log (Get-GcrText ("按需拉取 " + $chunk.Count + " 个 blob 失败 (第 " + $i + "/" + $limit + " 次): " + $last + " ；" + $delay + "s 后重试") ("Blob fetch for " + $chunk.Count + " blob(s) failed (attempt " + $i + "/" + $limit + "): " + $last + " ; retrying in " + $delay + "s")) "WARN"
                Start-Sleep -Seconds $delay
                $delay = [Math]::Min(60, [Math]::Max(1, $delay * 2))
                Clear-StaleIndexLock -RepoRoot $RepoRoot
            }
        }
        if (-not $chunkOk) {
            Write-Log (Get-GcrText ("按需拉取 " + $chunk.Count + " 个 blob 未成功: " + $last) ("Blob fetch for " + $chunk.Count + " blob(s) did not succeed: " + $last)) "WARN"
            $allOk = $false
        }
    }
    return $allOk
}

# Fetch the blobs these entries need: whole group first, bisected on failure so
# one unavailable object cannot poison the others.
function Prefetch-BatchBlobs {
    param([string]$RepoRoot, $Entries, [int]$Attempts = 3)

    $oids = Get-BatchBlobOids -Batch $Entries
    if ($null -eq $oids -or $oids.Count -eq 0) { return }
    $nFiles = 0
    foreach ($e in $Entries) { if ($null -ne $e) { $nFiles++ } }
    Write-Log (Get-GcrText ("按需拉取 " + $oids.Count + " 个 blob（对应 " + $nFiles + " 个路径）") ("Fetching " + $oids.Count + " blob(s) on demand for " + $nFiles + " path(s)")) "INFO"

    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue([pscustomobject]@{ Oids = $oids; Attempts = [Math]::Max(1, $Attempts) })
    $guard = 0
    while ($queue.Count -gt 0) {
        $guard++
        if ($guard -gt 512) { Write-Log (Get-GcrText "按需拉取拆分次数过多，剩下的交给 checkout 重试。" "Too many fetch splits; leaving the rest to the checkout retry.") "WARN"; break }
        $job = $queue.Dequeue()
        $jobOids = $job.Oids
        if ($null -eq $jobOids -or $jobOids.Count -eq 0) { continue }
        $ok = Invoke-BlobFetch -RepoRoot $RepoRoot -Oids $jobOids -Attempts $job.Attempts
        if ($jobOids.Count -eq 1) {
            if (-not $ok) { Write-Log (Get-GcrText ("远端拿不到该 blob（会在失败列表里重试）: " + [string]$jobOids[0]) ("The remote cannot provide this blob (it is retried via the failure list): " + [string]$jobOids[0])) "WARN" }
            continue
        }
        if ($ok) { continue }
        $half = [int][Math]::Floor($jobOids.Count / 2)
        if ($half -lt 1) { $half = 1 }
        $left = $jobOids.GetRange(0, $half)
        $right = $jobOids.GetRange($half, $jobOids.Count - $half)
        $next = [Math]::Max(1, $job.Attempts - 1)
        Write-Log (Get-GcrText ("拆半重试 " + $left.Count + " + " + $right.Count + " 个 blob") ("Retrying in halves: " + $left.Count + " + " + $right.Count + " blob(s)")) "INFO"
        $queue.Enqueue([pscustomobject]@{ Oids = $left; Attempts = $next })
        $queue.Enqueue([pscustomobject]@{ Oids = $right; Attempts = $next })
    }
}

# One raw `git checkout <sha> -- <paths>` call (no retry of its own).
# GIT_NO_LAZY_FETCH turns it into a purely local operation: the caller fetches
# the blobs it needs on purpose (Prefetch-BatchBlobs). Without that, git tries
# to fetch each missing blob by itself - one subprocess per file - and when such
# a fetch does not deliver the blob it only reports
#   error: unable to read sha1 file of <path> (<oid>)
# which is exactly the message that used to make whole batches look broken
# (and made every file fail once, before the retry finally succeeded).
function Invoke-CheckoutOnce {
    param(
        [string]$RepoRoot,
        [string]$Sha,
        $Batch,
        [int]$Retries = 1
    )
    $gitArgsList = New-Object System.Collections.Generic.List[string]
    foreach ($x in @("-c", "core.quotepath=false", "-c", "core.longpaths=true", "-c", "advice.detachedHead=false", "checkout", "--progress", $Sha, "--")) {
        [void]$gitArgsList.Add([string]$x)
    }
    $n = 0
    $firstPath = ""
    foreach ($e in $Batch) {
        if ($null -eq $e) { continue }
        if ($n -eq 0) { $firstPath = [string]$e.Path }
        [void]$gitArgsList.Add([string]$e.Path)
        $n++
    }
    if ($n -le 0) { return }
    Ensure-ParentDirectories -RepoRoot $RepoRoot -Batch $Batch
    $hb = "downloading " + $n + " file(s), e.g. " + $firstPath
    # Multi-file checkout: try once. Retrying the same big batch on Windows
    # wastes minutes (cannot create directory) and can desync the index; the
    # caller bisects instead. Single files may use the full retry budget.
    Invoke-GitRetry -What ("checkout " + $n + " files") -WorkDir $RepoRoot -Heartbeat $hb `
        -Retries ([Math]::Max(1, $Retries)) `
        -EnvOverride @{ "GIT_NO_LAZY_FETCH" = "1" } `
        -GitArgs $gitArgsList.ToArray() | Out-Null
}

# Check out a group of files and return @{ Ok = <landed>; Bad = <still missing> }.
# A failing git command does not mean the group failed: we always re-check what
# actually landed and retry only what is really missing (bisected down to single
# files), so one bad path never costs a full batch of git invocations.
function Complete-CheckoutGroup {
    param(
        [string]$RepoRoot,
        [string]$Sha,
        $Entries,
        [int]$Depth = 0
    )
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($e in $Entries) { if ($null -ne $e) { [void]$items.Add($e) } }
    if ($items.Count -eq 0) { return @{ Ok = @(); Bad = @() } }

    $ok = New-Object System.Collections.Generic.List[object]
    $bad = New-Object System.Collections.Generic.List[object]
    $single = ($items.Count -eq 1)

    # 1) local attempt. Blobs are fetched on purpose below, so a blob that is
    #    missing fails fast here instead of triggering git's lazy fetch (which
    #    fetches one blob per subprocess and then still reports
    #    "error: unable to read sha1 file of <path> (<oid>)").
    try {
        Invoke-CheckoutOnce -RepoRoot $RepoRoot -Sha $Sha -Batch $items -Retries 1
    } catch {
        if ($script:GcrUserStop) { throw }
        $msg = [string]$_.Exception.Message
        if ($single) {
            Write-Log (Get-GcrText ("单文件 checkout 失败: " + $msg) ("Single-file checkout failed: " + $msg)) "WARN"
        } else {
            # Keep one line: a cold batch reports one "unable to read sha1 file of"
            # per missing file, which is expected and noisy.
            $head = $msg
            $extra = ""
            $lines = @($msg -split "[\r\n]+" | Where-Object { $_.Trim() })
            if ($lines.Count -gt 0) { $head = [string]$lines[0] }
            if ($lines.Count -gt 1) {
                $extra = Get-GcrText (" （另有 " + ($lines.Count - 1) + " 行同类输出）") (" (plus " + ($lines.Count - 1) + " similar lines)")
            }
            # NB: keep the call in its own variable - "Get-GcrText (..) (..) + $head"
            # would let PowerShell treat "+ $head" as a separate argument.
            $prefix = Get-GcrText ("这一组 (" + $items.Count + " 个路径) 未全部成功；本地缺 blob 时属正常，下面只补缺的: ") ("This group (" + $items.Count + " path(s)) did not fully complete; normal when blobs are missing locally, fetching only what is missing: ")
            Write-Log ($prefix + $head + $extra) "INFO"
        }
    }

    # 2) trust the worktree, not the exit code
    $res = Confirm-BatchFiles -RepoRoot $RepoRoot -Batch $items
    foreach ($x in $res.Ok) { [void]$ok.Add($x) }
    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($x in $res.Bad) { [void]$missing.Add($x) }
    if ($missing.Count -eq 0) { return @{ Ok = $ok; Bad = $bad } }

    # 3) network: ask for exactly the blobs those files need (batched + retried)
    $attempts = 3
    if ($single) { $attempts = $MaxRetries }
    Prefetch-BatchBlobs -RepoRoot $RepoRoot -Entries $missing -Attempts $attempts

    # 4) retry only what did not land (single files may use the full budget)
    $tries = 1
    if ($single) { $tries = $MaxRetries }
    try {
        Invoke-CheckoutOnce -RepoRoot $RepoRoot -Sha $Sha -Batch $missing -Retries $tries
    } catch {
        if ($script:GcrUserStop) { throw }
        Write-Log (Get-GcrText ("重试 checkout 仍有失败: " + $_.Exception.Message) ("Checkout retry still failed: " + $_.Exception.Message)) "WARN"
    }

    $still = New-Object System.Collections.Generic.List[object]
    foreach ($x in $missing) {
        if (Test-FileComplete -RepoRoot $RepoRoot -Entry $x) { [void]$ok.Add($x) } else { [void]$still.Add($x) }
    }
    if ($still.Count -eq 0) { return @{ Ok = $ok; Bad = $bad } }
    if ($single -or $still.Count -eq 1 -or $Depth -ge 8) {
        # nothing left to isolate: report the survivors
        foreach ($x in $still) { [void]$bad.Add($x) }
        return @{ Ok = $ok; Bad = $bad }
    }

    # 5) still incomplete: halve to isolate the problematic path(s)
    $half = [int][Math]::Floor($still.Count / 2)
    if ($half -lt 1) { $half = 1 }
    $parts = New-Object System.Collections.Generic.List[object]
    [void]$parts.Add($still.GetRange(0, $half))
    if ($half -lt $still.Count) { [void]$parts.Add($still.GetRange($half, $still.Count - $half)) }
    foreach ($part in $parts) {
        if ($part.Count -eq 0) { continue }
        $sub = Complete-CheckoutGroup -RepoRoot $RepoRoot -Sha $Sha -Entries $part -Depth ($Depth + 1)
        foreach ($x in $sub.Ok) { [void]$ok.Add($x) }
        foreach ($x in $sub.Bad) { [void]$bad.Add($x) }
    }
    return @{ Ok = $ok; Bad = $bad }
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
    param([string]$RepoRoot, [string]$Sha, $Entries)
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
        $gitArgs = New-Object System.Collections.Generic.List[string]
        foreach ($x in @("-c", "core.quotepath=false", "add", "-f", "--")) { [void]$gitArgs.Add($x) }
        foreach ($p in $add) { [void]$gitArgs.Add($p) }
        Invoke-GitProcess -WorkDir $RepoRoot -ExpectFail -GitArgs $gitArgs.ToArray() | Out-Null
    }
    if ($needCheckout.Count -gt 0) {
        # Same rule as the download loop: make sure the blobs are local before
        # asking git to check the paths out (no slow one-by-one lazy fetch).
        if ($Entries) {
            $want = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::Ordinal)
            foreach ($p in $needCheckout) { [void]$want.Add([string]$p) }
            $fake = New-Object System.Collections.Generic.List[object]
            foreach ($e in $Entries) {
                if ($null -eq $e) { continue }
                if ($want.Contains([string]$e.Path)) {
                    [void]$fake.Add([pscustomobject]@{ Path = [string]$e.Path; Blob = [string]$e.Blob })
                }
            }
            if ($fake.Count -gt 0) { Prefetch-BatchBlobs -RepoRoot $RepoRoot -Entries $fake.ToArray() -Attempts 2 }
        }
        Write-Log ("repair index: re-checkout " + $needCheckout.Count + " missing files") "WARN"
        $gitArgs = New-Object System.Collections.Generic.List[string]
        foreach ($x in @("-c", "core.quotepath=false", "checkout", $Sha, "--")) { [void]$gitArgs.Add($x) }
        foreach ($p in $needCheckout) { [void]$gitArgs.Add($p) }
        Invoke-GitProcess -WorkDir $RepoRoot -ExpectFail -GitArgs $gitArgs.ToArray() | Out-Null
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
    Update-GcrWindowTitle -Ok $OkCount -Total $TotalCount -Fail $FailCount
    if (Test-GcrTuiActive) {
        Update-GcrTuiProgress -OkCount $OkCount -TotalCount $TotalCount -FailCount $FailCount -DoneBytes $DoneBytes -Rate $rate -Eta $eta -CurrentFile $CurrentFile
        Invoke-GcrTuiTick
    } else {
        Write-Host ("`r" + $out) -NoNewline
        Write-Progress -Activity "git-clone-resume" -Status $line -PercentComplete ([Math]::Min(100, [int]$pct))
    }
}

function Assert-GcrContinue {
    if (-not (Get-Command Test-GcrTuiActive -ErrorAction SilentlyContinue)) { return }
    if (-not (Test-GcrTuiActive)) { return }
    Invoke-GcrTuiTick
    Wait-GcrTuiPaused
    Invoke-GcrTuiTick
    if (Test-GcrTuiQuit) {
        $script:GcrUserStop = $true
        throw "已由用户停止。再次运行同一命令即可续传。"
    }
}

$script:GcrInteractive = $false
try { $script:GcrInteractive = [Environment]::UserInteractive } catch { }
if ($NoTui) {
    $script:GcrTuiWanted = $false
} elseif ($Tui) {
    $script:GcrTuiWanted = $true
} elseif ($script:GcrInteractive -and (Get-Command Test-GcrTuiAvailable -ErrorAction SilentlyContinue) -and (Test-GcrTuiAvailable)) {
    $script:GcrTuiWanted = $true
}

if ($ResumeLast) {
    if (-not (Get-Command Get-GcrHistoryLast -ErrorAction SilentlyContinue)) {
        Write-Host (Convert-GcrText "错误: 无法读取历史记录。") -ForegroundColor Red
        exit 2
    }
    $last = Get-GcrHistoryLast
    if ($null -eq $last) {
        Write-Host (Convert-GcrText "错误: 没有可恢复的历史记录。请先启动过一次克隆。") -ForegroundColor Red
        exit 2
    }
    if ([string]::IsNullOrWhiteSpace($RepoUrl) -and $last.url) { $RepoUrl = [string]$last.url }
    if ([string]::IsNullOrWhiteSpace($OutDir) -and $last.outDir) { $OutDir = [string]$last.outDir }
    if (($Ref -eq "HEAD" -or [string]::IsNullOrWhiteSpace($Ref)) -and $last.ref) { $Ref = [string]$last.ref }
}

if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    if ($NoTui -or -not $script:GcrInteractive) {
        Show-Usage
        Write-Host (Convert-GcrText "错误: 必须提供仓库 URL。") -ForegroundColor Red
        exit 2
    }
    $defaults = @{
        RepoUrl      = $RepoUrl
        OutDir       = $OutDir
        Ref          = $Ref
        BatchSize    = $BatchSize
        MaxRetries   = $MaxRetries
        Include      = $Include
        Exclude      = $Exclude
        Verify       = [bool]$Verify
        ForceRefetch = [bool]$ForceRefetch
        DryRun       = [bool]$DryRun
    }
    if ($PSBoundParameters.ContainsKey("Depth")) { $defaults["Depth"] = $Depth }
    if (-not (Get-Command Show-GcrInteractiveSetup -ErrorAction SilentlyContinue)) {
        Show-Usage
        Write-Host (Convert-GcrText "错误: 必须提供仓库 URL。") -ForegroundColor Red
        exit 2
    }
    $wiz = $null
    try {
        $wiz = Show-GcrInteractiveSetup -Defaults $defaults
        if (Get-Command ConvertFrom-GcrWizardOutput -ErrorAction SilentlyContinue) {
            $unwrapped = ConvertFrom-GcrWizardOutput $wiz
            if ($null -ne $unwrapped) { $wiz = $unwrapped }
        }
    } catch {
        if (Get-Command Close-GcrTui -ErrorAction SilentlyContinue) { Close-GcrTui }
        Write-Host ("向导失败: " + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    if ($null -eq $wiz) {
        if (Get-Command Close-GcrTui -ErrorAction SilentlyContinue) { Close-GcrTui }
        exit 0
    }
    try {
        $RepoUrl = [string]$wiz.RepoUrl
        if ($wiz.Language -eq "en-US" -or $wiz.Language -eq "zh-CN") {
            Set-GcrLanguage -Language ([string]$wiz.Language)
        }
        if ($wiz.OutDir) { $OutDir = [string]$wiz.OutDir }
        if ($wiz.Ref) { $Ref = [string]$wiz.Ref }
        if ($wiz.BatchSize) { $BatchSize = [int]$wiz.BatchSize }
        if ($wiz.MaxRetries) { $MaxRetries = [int]$wiz.MaxRetries }
        if ($null -ne $wiz.Include) { $Include = @($wiz.Include | Where-Object { $_ }) }
        if ($null -ne $wiz.Exclude) { $Exclude = @($wiz.Exclude | Where-Object { $_ }) }
        $Verify = [bool]$wiz.Verify
        $ForceRefetch = [bool]$wiz.ForceRefetch
        $DryRun = [bool]$wiz.DryRun
        if ($null -ne $wiz.Depth -and [string]$wiz.Depth -ne "") {
            $Depth = [int]$wiz.Depth
            $PSBoundParameters["Depth"] = $Depth
        }
    } catch {
        if (Test-GcrTuiActive) {
            Show-GcrTuiResult -Title "无法开始克隆" -Body @($_.Exception.Message) -Kind error
            Close-GcrTui
        } else {
            Write-Host ("无法开始克隆: " + $_.Exception.Message) -ForegroundColor Red
        }
        exit 1
    }
}

if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    if (Get-Command Close-GcrTui -ErrorAction SilentlyContinue) { Close-GcrTui }
    Show-Usage
    Write-Host (Convert-GcrText "错误: 必须提供仓库 URL。") -ForegroundColor Red
    exit 2
}

if ($script:GcrTuiWanted -and (Get-Command Initialize-GcrTui -ErrorAction SilentlyContinue)) {
    if (-not (Test-GcrTuiActive)) { [void](Initialize-GcrTui) }
    if ($Tui -and -not (Test-GcrTuiActive)) {
        Write-Host (Convert-GcrText "当前终端无法进入全屏 TUI，改用日志模式。Windows Terminal 下再试，或去掉 -Tui。") -ForegroundColor Yellow
    }
}

try {
    if (-not $OutDir) { $OutDir = Get-RepoFolderName -Url $RepoUrl }
    $repoRoot = Convert-ToFullPath -Path $OutDir
    $script:RepoRoot = $repoRoot
    # Give the taskbar a readable name right away (repo folder, not the URL).
    try { $script:GcrTitleRepoName = [string](Split-Path -Leaf $repoRoot) } catch { $script:GcrTitleRepoName = "" }
    Update-GcrWindowTitle -State "init"

    if (Test-GcrTuiActive) {
        $resumeHint = Test-Path -LiteralPath (Join-Path $repoRoot ".git\$($script:StateDirName)\meta.txt")
        Set-GcrTuiRepo -Url $RepoUrl -OutDir $repoRoot -Ref $Ref -Resume:$resumeHint
        Set-GcrTuiPhase -Name "init" -Detail ""
        if (Get-Command Save-GcrHistory -ErrorAction SilentlyContinue) {
            Save-GcrHistory -Url $RepoUrl -OutDir $repoRoot -Ref $Ref -Status "running"
        }
        Invoke-GcrTuiTick -Force
    }

    Test-GitAvailable
    $script:GitExe = Get-GitExePath

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
        Set-GcrTuiPhase -Name "fetch" -Detail ("origin " + $Ref)
        Assert-GcrContinue
        $inheritFetch = -not (Test-GcrTuiActive)
        Invoke-GitRetry -What "git fetch" -WorkDir $repoRoot -GitArgs $fetchArgs -InheritConsole:$inheritFetch | Out-Null
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
    Set-GcrTuiRepo -Commit $pinnedSha

    Write-Meta -MetaPath $metaPath -Map @{
        url      = $RepoUrl
        ref      = $Ref
        commit   = $pinnedSha
        batch    = [string]$BatchSize
        updated  = (Get-Date -Format o)
        hostname = [string]$env:COMPUTERNAME
    }

    Write-Log "枚举文件树 git ls-tree -r $pinnedSha" "STEP"
    Set-GcrTuiPhase -Name "list" -Detail $pinnedSha
    Assert-GcrContinue
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

    $okCount = 0
    $failCount = 0
    $totalCount = $filtered.Count
    $doneBytes = 0L
    $skipDownload = $false
    $resultKind = "done"
    $resultTitle = ""
    $resultBody = New-Object System.Collections.Generic.List[string]

    if ($DryRun) {
        Write-Log "DryRun 结束，清单: $listPath" "OK"
        $nshow = [Math]::Min(30, $filtered.Count)
        for ($i = 0; $i -lt $nshow; $i++) {
            $e = $filtered[$i]
            if (Test-GcrTuiActive) { Add-GcrTuiLog -Level "INFO" -Message $e.Path }
            else { Write-Host ("  " + $e.Path) }
        }
        if ($filtered.Count -gt 30) {
            $more = ("  ... 另有 {0} 个文件" -f ($filtered.Count - 30))
            if (Test-GcrTuiActive) { Add-GcrTuiLog -Level "INFO" -Message $more.Trim() }
            else { Write-Host $more }
        }
        $script:GcrExitCode = 0
        $skipDownload = $true
        $resultTitle = Get-GcrText "DryRun 完成" "DryRun complete"
        [void]$resultBody.Add((Get-GcrText "清单文件: " "List file: ") + $listPath)
        [void]$resultBody.Add((Get-GcrText "文件数: " "Files: ") + $filtered.Count)
        [void]$resultBody.Add((Get-GcrText "未下载 blob。去掉 -DryRun 后开始/继续克隆。" "No blobs were downloaded. Remove -DryRun to start or resume."))
    }

    if (-not $skipDownload) {
        Set-GcrTuiPhase -Name "scan" -Detail "检查工作区已有文件"
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
                Assert-GcrContinue
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
        Write-GcrNewline

        Write-Log (Get-GcrText ("进度: 已记录 " + $skippedDone + " ，工作区已存在 " + $skippedExist + " ，剩余 " + $pending.Count) ("Progress: recorded " + $skippedDone + ", already on disk " + $skippedExist + ", remaining " + $pending.Count)) "INFO"

        $okCount = $skippedDone + $skippedExist
        $totalCount = $filtered.Count
        foreach ($e in $filtered) {
            if ($doneSet.Contains($e.Path)) { $doneBytes += (Get-WorktreeBytes -RepoRoot $repoRoot -RelPath $e.Path) }
        }

        if ($pending.Count -eq 0) {
            Write-Log "全部文件已就绪。" "OK"
            Write-Log "工作区: $repoRoot" "OK"
            $script:GcrExitCode = 0
            $skipDownload = $true
            $resultTitle = Get-GcrText "全部文件已就绪" "All files are ready"
            [void]$resultBody.Add((Get-GcrText "工作区: " "Workspace: ") + $repoRoot)
            [void]$resultBody.Add((Get-GcrText "文件: " "Files: ") + ("{0}/{1}" -f $okCount, $totalCount))
            Update-GcrWindowTitle -State "done" -Ok $okCount -Total $totalCount
        }
    }

    if (-not $skipDownload) {
        $batches = Split-Batches -Items $pending.ToArray() -MaxCount $BatchSize -MaxChars $MaxArgChars
        Write-Log ("分 " + $batches.Count + " 批下载，每批最多 " + $BatchSize + " 个文件") "STEP"
        Set-GcrTuiPhase -Name "download" -Detail ("batch 1/" + $batches.Count)
        Assert-GcrContinue

        $started = Get-Date
        $failCount = 0
        $processedThisRun = 0
        Write-DownloadProgress -OkCount $okCount -TotalCount $totalCount -FailCount 0 -DoneBytes $doneBytes -Elapsed ([TimeSpan]::Zero) -DoneThisRun 0 -CurrentFile "starting download"

        $batchIndex = 0
        foreach ($batch in $batches) {
            Assert-GcrContinue
            $batchIndex++
            Set-GcrTuiPhase -Name "download" -Detail ("batch " + $batchIndex + "/" + $batches.Count)
            $okThis = New-Object System.Collections.Generic.List[object]
            $badThis = New-Object System.Collections.Generic.List[object]
            $preview = $batch[0].Path
            Write-DownloadProgress -OkCount $okCount -TotalCount $totalCount -FailCount $failCount -DoneBytes $doneBytes -Elapsed ((Get-Date) - $started) -DoneThisRun $processedThisRun -CurrentFile $preview

            # 先把这批缺的 blob 批量拉全（网络），再本地 checkout；
            # 失败时核对落盘结果并二分重试，不会因一个文件就废弃整批。
            $result = Complete-CheckoutGroup -RepoRoot $repoRoot -Sha $pinnedSha -Entries $batch
            foreach ($x in $result.Ok) { [void]$okThis.Add($x) }
            foreach ($x in $result.Bad) { [void]$badThis.Add($x) }

            foreach ($e in $badThis) {
                Assert-GcrContinue
                $failCount++
                Add-GcrTuiFailure -Path $e.Path
                $fullFail = Get-WorktreePath -Root $repoRoot -Rel $e.Path
                $why = Get-GcrText "blob 拿不到或 checkout 失败（工作区无此文件）" "blob unavailable or checkout failed (no file in the worktree)"
                if (Test-Path -LiteralPath $fullFail) { $why = "worktree file present but still incomplete" }
                Add-FailedPath -FailedPath $failedPath -RelPath $e.Path -Reason $why
                Write-Log ("仍失败: " + $e.Path + " (" + $why + ")") "ERROR"
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
                Write-GcrNewline
                Write-Log (("checkpoint {0}/{1} {2:N1}%  fail {3}  {4}" -f $okCount, $totalCount, $pctNow, $failCount, (Format-Bytes $doneBytes))) "INFO"
            }
        }

        Write-GcrNewline
        if (-not (Test-GcrTuiActive)) {
            Write-Progress -Activity "git-clone-resume" -Completed
        }
        Set-GcrTuiPhase -Name "repair" -Detail "git index"
        Repair-GitIndex -RepoRoot $repoRoot -Sha $pinnedSha -Entries $filtered
        $elapsed = (Get-Date) - $started
        $elapsedText = "{0:00}:{1:00}:{2:00}" -f [int]$elapsed.TotalHours, $elapsed.Minutes, $elapsed.Seconds
        Write-Log (Get-GcrText ("完成: 成功 {0}/{1} ，失败 {2} ，耗时 {3}" -f $okCount, $totalCount, $failCount, $elapsedText) ("Complete: succeeded {0}/{1}, failed {2}, elapsed {3}" -f $okCount, $totalCount, $failCount, $elapsedText)) "OK"
        Write-Log (Get-GcrText ("工作区: " + $repoRoot) ("Workspace: " + $repoRoot)) "OK"
        [void]$resultBody.Add((Get-GcrText "工作区: " "Workspace: ") + $repoRoot)
        [void]$resultBody.Add((Get-GcrText (
                    "成功 {0}/{1} ，失败 {2} ，耗时 {3}" -f $okCount, $totalCount, $failCount, $elapsedText) (
                    "Succeeded {0}/{1}   failed {2}   elapsed {3}" -f $okCount, $totalCount, $failCount, $elapsedText)))
        if ($failCount -gt 0) {
            Write-Log (Get-GcrText ("失败列表: " + $failedPath + "  （再次运行本脚本会重试未完成文件）") ("Failure list: " + $failedPath + "  (rerun this script to retry the unfinished files)")) "WARN"
            [void]$resultBody.Add((Get-GcrText "失败列表: " "Failure list: ") + $failedPath)
            [void]$resultBody.Add((Get-GcrText "再次运行同一命令会重试未完成文件。" "Run the same command again to retry the unfinished files."))
            $script:GcrExitCode = 1
            $resultKind = "error"
            $resultTitle = Get-GcrText "部分文件失败" "Some files failed"
            Update-GcrWindowTitle -State "error" -Ok $okCount -Total $totalCount -Fail $failCount
        } else {
            $script:GcrExitCode = 0
            $resultTitle = Get-GcrText "克隆完成" "Clone complete"
            Update-GcrWindowTitle -State "done" -Ok $okCount -Total $totalCount
        }
    }

    if (Get-Command Save-GcrHistory -ErrorAction SilentlyContinue) {
        $histStatus = "complete"
        if ($script:GcrExitCode -ne 0) { $histStatus = "failed" }
        if ($DryRun) { $histStatus = "dryrun" }
        Save-GcrHistory -Url $RepoUrl -OutDir $repoRoot -Ref $Ref -Commit $pinnedSha -Status $histStatus -Ok $okCount -Total $totalCount -Fail $failCount
    }
    if (Test-GcrTuiActive) {
        if (-not $resultTitle) { $resultTitle = Get-GcrText "完成" "Complete" }
        Show-GcrTuiResult -Title $resultTitle -Body $resultBody.ToArray() -Kind $resultKind
    }
}
catch {
    $err = ""
    try { $err = [string]$_.Exception.Message } catch { }
    if (-not $err) { try { $err = [string]$_ } catch { $err = "unknown error" } }
    Write-Log $err "ERROR"
    if ($_.ScriptStackTrace -and -not $script:GcrUserStop) { Write-Log ([string]$_.ScriptStackTrace) "ERROR" }
    Update-GcrWindowTitle -State $(if ($script:GcrUserStop) { "stopped" } else { "error" })
    if ($script:RepoRoot) {
        Write-Log (Get-GcrText ("中断后续传: 重新执行同一命令即可。仓库目录: " + $script:RepoRoot) ("Resume after interruption: run the same command again. Repository directory: " + $script:RepoRoot)) "WARN"
    }
    if (Get-Command Save-GcrHistory -ErrorAction SilentlyContinue -and $script:RepoRoot) {
        $st = "failed"
        if ($script:GcrUserStop) { $st = "partial" }
        Save-GcrHistory -Url $RepoUrl -OutDir $script:RepoRoot -Ref $Ref -Status $st
    }
    if (Test-GcrTuiActive) {
        $body = @($err)
        if ($script:RepoRoot) { $body += ((Get-GcrText "仓库目录: " "Repository directory: ") + $script:RepoRoot) }
        $body += (Get-GcrText "再次运行同一命令即可续传。" "Run the same command again to resume.")
        $title = $(if ($script:GcrUserStop) { Get-GcrText "已停止" "Stopped" } else { Get-GcrText "出错" "Error" })
        Show-GcrTuiResult -Title $title -Body $body -Kind "error"
    }
    $script:GcrExitCode = 1
}
finally {
    if (Get-Command Close-GcrTui -ErrorAction SilentlyContinue) { Close-GcrTui }
    Restore-GcrWindowTitle
}

exit $script:GcrExitCode

