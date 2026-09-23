English documentation: [README.en.md](README.en.md).

# Git 断点续传克隆（Windows）

 启动向导时可选择语言，也可使用 `-Language en-US`；向导和克隆面板中按 `L` 可随时切换。

针对 GitHub 等网络不稳定场景：先用 **partial clone** 只拉 commit/tree 元数据，再 **按批 checkout 文件**。中断后用同一条命令再跑即可续传。

对应 Linux 参考脚本：<https://github.com/chaihahaha/git-cheatsheet> 中的 `clone_1by1.sh`。

交互式全屏 TUI（无参数启动进入向导；克隆中可暂停 / 停止，重跑同一命令续传）：

| 向导 | 克隆中 |
| --- | --- |
| ![向导主页面](snap/main.png) | ![克隆运行界面](snap/run.png) |

## 文件

| 文件 | 说明 |
| --- | --- |
| `git-clone-resume.ps1` | 主脚本，PowerShell 5.1 / 7+ |
| `git-clone-resume.tui.ps1` | 全屏 TUI（向导、进度面板、快捷键），由主脚本自动加载 |
| `git-clone-resume.cmd` | 双击或 cmd 下调用的启动器（无参数会打开 TUI 向导） |
| `snap/` | README 截图（向导主页面、克隆运行界面） |
| `bench/` | 性能基准与回归测试，不参与发布包 |

## 依赖

- [Git for Windows](https://git-scm.com/download/win) **>= 2.19**（partial clone）
- Windows PowerShell 5.1（系统自带）或 PowerShell 7+
- 建议打开 Windows 长路径：`git config --global core.longpaths true`

## 安装与短命令

发布版本会提供一个 ZIP 压缩包。解压到不会随意移动的目录后，将该目录加入用户或系统 `PATH`，即可使用短命令 `gcr`：

```bat
gcr https://github.com/user/repo.git
gcr https://github.com/user/repo.git -Ref main -OutDir D:\src\repo
```

压缩包同时包含完整命令 `git-clone-resume`。`gcr` 只是同目录启动器，不会复制或改变核心脚本；三个 PowerShell 文件需要保持在同一目录。

安装后可在 `cmd.exe`、PowerShell、Windows Terminal 和脚本/CI 中调用。CI 或重定向输出时建议显式使用 `-NoTui`。

后续发布渠道会复用 GitHub Release 中的同一 ZIP 和 SHA256 校验值：

- Scoop：执行下面的命令后直接提供 `gcr` 命令。

  ```powershell
  scoop bucket add git-clone-resume https://github.com/normalwindow/git-clone-resume
  scoop install git-clone-resume
  ```

- winget：从 0.1.1 起提供 `.exe` 启动器；manifest 已准备，提交官方仓库审核后可用于系统级安装、升级和卸载。

- npm：执行 `npm install -g git-clone-resume` 后提供 `gcr` 命令，但仍需要 Git for Windows 和 PowerShell。

卸载时只移除工具目录，不会删除任何目标仓库、`.git/partial-resume/` 状态或历史记录文件。

## 用法

交互式（推荐）：双击 `git-clone-resume.cmd`，或在终端里不带 URL 运行，会打开全屏 TUI 向导。剪贴板里如果是仓库地址会自动填入；底栏会显示当前选项的简短说明。

```bat
git-clone-resume.cmd
git-clone-resume.cmd https://github.com/user/repo.git
```

或：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\git-clone-resume.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\git-clone-resume.ps1 https://github.com/user/repo.git
```

在 Windows Terminal / 现代控制台里，带 URL 启动同样进入进度面板：百分比、下载速度、ETA、活动日志、失败列表。脚本/CI 或输出被重定向时自动退回原来的纯日志模式。

常用参数：

```powershell
# 指定目录和分支
.\git-clone-resume.ps1 https://github.com/user/repo.git -Ref main -OutDir D:\src\repo

# 只拉部分路径
.\git-clone-resume.ps1 https://github.com/user/repo.git -Include src/*,docs/* -Exclude *.bin

# 更大批次（更快，中断粒度更粗）
.\git-clone-resume.ps1 https://github.com/user/repo.git -BatchSize 64 -MaxRetries 12

# 续传时按 blob 哈希校验已存在文件
.\git-clone-resume.ps1 https://github.com/user/repo.git -Verify

# 只列出文件，不下载 blob
.\git-clone-resume.ps1 https://github.com/user/repo.git -DryRun

# 强制 / 禁用全屏 TUI
.\git-clone-resume.ps1 https://github.com/user/repo.git -Tui
.\git-clone-resume.ps1 https://github.com/user/repo.git -NoTui

# 从本机历史恢复最近一次未完成的克隆
.\git-clone-resume.ps1 -ResumeLast

# 查看版本
gcr -Version
gcr --version

# 清除本机克隆历史（不删除仓库或 .git/partial-resume 进度）
gcr -ClearHistory
```

完整帮助：`git-clone-resume.cmd -Help`

### 任务栏 / 标签页标题

克隆过程中会自动改写控制台标题，任务栏、Windows Terminal 标签页、VS Code 终端列表都能直接看到进度（TUI 与 `-NoTui` 都生效）：

```
nature-skills  ·  42% (340/802)  ·  git-clone-resume
nature-skills  ·  42% (340/802)  ·  PAUSED  ·  git-clone-resume
nature-skills  ·  99% (799/802)  ·  FAILED 3  ·  git-clone-resume
nature-skills  ·  done (802/802)  ·  git-clone-resume
```

阶段阶段会显示 `fetching metadata` / `listing files` / `scanning workspace` / `repairing index`。
脚本退出时会恢复原来的标题。需要开关时设环境变量：`GCR_TITLE=1` 强制启用（输出被重定向时也用），`GCR_TITLE=0` 禁用。

### 结束页配色

克隆结束后结果面板按语义着色，不再是一整块暗色：标题加粗（完成绿 / 失败红），`成功 802/802，失败 0，耗时 …` 为绿色加粗，`失败列表: …` 为黄色，工作区路径为青色，提示行为暗色。

### 进度与下载速度

进度行（`-NoTui`）与 TUI 面板都会显示下载速度：

```
[######################------]  80.0%  32/40  fail 0  480.5 KB  717.4 KB/s  37.5 files/s  ETA 00:01:20  dir03/file11.txt
```

- 速度 = 这一批真正落盘的字节 / 该批耗时，在 20 秒滑动窗口内统计，和左边的总量同一个口径（都是工作区文件字节，不是压缩后的传输包大小）；
- 窗口内没有新数据时保留最后一次数值，不会在慢批或卡住时跳成 0；
- TUI 里取同样口径；阶段行还会同时显示 git 自己上报的 `Receiving objects: … MiB/s`；
- 结束时汇总一行平均速度，同时出现在日志、结果面板和 `checkpoint` 行里。

### TUI 快捷键

克隆过程中（底栏会随阶段切换提示）：

| 键 | 作用 |
| --- | --- |
| `Q` / `Ctrl+C` | 当前 git 命令结束后停止；再按一次强制结束 |
| `P` / `Esc` | 当前批次结束后暂停 |
| `Space` | 从暂停恢复 |
| `F` | 切换失败文件列表 |
| `↑` `↓` / `j` `k` | 滚动活动日志 |
| `End` | 跟随最新日志 |
| `?` / `H` | 帮助 |
| `Enter` | 结束页关闭 |

向导里：`Enter` 编辑或开始，`Ctrl+S` 直接开始克隆，`Space` 切换开关，`←` `→` 改批次大小，`Tab` 最近任务，`Ctrl+V` 粘贴 URL，`Q` 退出。高亮某一选项时，底栏上一行会显示该选项的简短说明（Guide）。最近任务列表中：`Enter` 填入续传，`Del` 删除当前条目，`Ctrl+D` 清空全部历史。

`Ctrl+S` 是「开始克隆」的加速键：不管焦点在表单还是最近任务列表、甚至正在编辑某个文本框，它都能直接开始（裸 `S` 在编辑文本时会被当成输入字符，所以底栏推荐用 `Ctrl+S`）。URL 为空时会把你带回 URL 那一行并提示。

向导里还可以直接用鼠标：点某一行就选中并执行它（点 `开始克隆` 等于按 `Enter`，点开关行即切换，点文本框进入编辑），点最近任务列表的某一条即填入表单。按住 `Shift` 再点则保留终端自己的框选行为。克隆一开始就会关掉鼠标上报，所以在进度面板里拖选、复制文本一如既往；也可以用 `GCR_MOUSE=0` 完全关掉鼠标支持。

### 按键响应

按住方向键时，Windows 的自动重复每秒会发来约 30 个事件，比 PowerShell 拼一帧还快。之前是「读一个键 → 重绘一次」，于是队列里积压的事件在松手后还要继续跑完，表现就是「按一下下键，光标过一会儿还在往下走」。

现在改成**先把已经排队的按键一次性全部应用，再重绘一次**。`bench\bench-input.ps1` 用 60 个积压事件实测：

| 处理方式 | 消化整批耗时 | 重绘次数 |
| --- | --- | --- |
| 每个事件重绘一次（修改前） | 748 ms | 60 |
| 按批应用 + 单次重绘（现在） | **47 ms** | **1** |

### 键盘与鼠标是两条独立通路

这一点很关键，也是曾经踩过的坑——**鼠标出问题绝对不能连累键盘**：

- **键盘**走托管 `[Console]::ReadKey`。这条路在任何宿主里都可用，不依赖 P/Invoke，也是改动前一直在用的通路。一次读一个键，但调用方每帧会把已排队的键整批取走，所以不影响上面的批处理效果。
- **鼠标**只能走 `ReadConsoleInput`（托管 API 完全看不到鼠标），因此只用它来收集点击，并且有三重保险：
  1. 只在鼠标上报**确实已开启**时才调用；
  2. 只在 `[Console]::KeyAvailable` 为假（当前没有待处理按键）时才调用——键盘必须始终由 `ReadKey` 排空；
  3. `ReadConsoleInput` 会连键盘记录一起返回，而**被它取走的记录就没了**。所以一旦读到键盘记录，就计为故障，连续两次立刻**自动关闭鼠标支持**；任何原生调用异常也一样处理。

如果宿主拿不到控制台句柄、或鼠标上报开启失败，**点击功能自动消失，键盘完全不受影响**。`bench\check-native-input.ps1` 会在无控制台环境下验证这些性质（键盘通路不抛异常、已排队的按键不会被鼠标读取方动到、鼠标读取方故障后键盘仍能收到按键）。

遇到输入异常时可以先关掉鼠标支持对照一下：

```powershell
$env:GCR_MOUSE = "0"; .\git-clone-resume.cmd
```

`bench\check-keyboard-console.ps1` 会附着到父控制台，检查 `Enable-GcrVt` 设置的那套控制台模式下 `KeyAvailable` / `ReadKey` 是否正常（鼠标开与不开各测一次）。


历史记录写在 `%LOCALAPPDATA%\git-clone-resume\history.json`。命令行可用 `-ClearHistory` 清空，不会删除目标仓库或 `.git/partial-resume/` 进度。框线在中文控制台里若变宽，会自动改用 ASCII；也可设 `GCR_ASCII=1` 强制 ASCII。

界面语言切换（`-Language en-US` 或向导里选 English）现在对结束页也生效：`Workspace: …` / `Succeeded 802/802   failed 0   elapsed 00:00:37`，日志里的失败汇总同样会切成英文且不会残留全角标点。

## 工作原理

1. `git init` + `remote.origin.partialclonefilter=blob:none`（不直接 `git clone`，这样元数据 fetch 失败也可重试）
2. `git fetch --filter=blob:none origin <ref>` 只拉 commit / tree
3. 把 HEAD 钉在该 commit SHA 上，避免中途远端更新导致续传错位
4. `git ls-tree -r` 得到文件清单（**不用 -l**，否则 blob:none 会为了拿 size 把全部 blob 拉下来；也不用 `-z`，PowerShell 5.1 会把 NUL 截断）
5. 分批处理：先用 `git cat-file --batch-check`（带 `GIT_NO_LAZY_FETCH=1`，完全离线）探出这批里哪些 blob 本地还没有，再用 `git fetch origin <blob-oid>...` 把缺的一次性拉下来；然后 `git checkout <sha> -- file1 file2 ...`（`GIT_NO_LAZY_FETCH=1`，纯本地写文件），核对哪些没落盘，只重试这些文件（必要时二分定位）
6. 成功的路径追加写入 `.git/partial-resume/done.txt`
7. 再次运行：跳过已落盘文件。命令失败不等于整批失败，只重试真正缺的（必要时二分定位）；结束时修复 Windows 上被弄乱的 git index

> 为什么先把 blob 拉全再 checkout：在 `blob:none` 的 partial clone 上，本地还没有 blob 时，`git checkout` 每个文件都会报一次 `error: unable to read sha1 file of <path> (<oid>)` 并以 255 退出（重跑一次才会成功）。反过来先 checkout 再补拉，等于每一批都注定先失败一遍，日志里会刷满“这一组 (N 个路径) 未全部成功 …”之类的告警。先拉后写就没有这种情况：checkout 失败只代表真出了问题，日志里也只保留这一行。顺带一提，也不用让 git 自己在 checkout 里按需拉 blob：那会为每个 blob 单独起一次 fetch 子进程。

> 为什么不让 git 自己在 checkout 里按需拉 blob：在 `blob:none` 的 partial clone 上，git 会为每个缺失 blob 单独起一次 fetch 子进程，而且哪怕对象已经拿到，同一个进程仍会报 `error: unable to read sha1 file of <path> (<oid>)` 并以 255 退出；重跑一次才会成功。因此本脚本自己按批拉取 blob，再让 checkout 变成纯本地操作。

进度目录（不会进工作区）：

```
.git/partial-resume/
  meta.txt      URL / ref / 钉住的 commit
  files.tsv     待处理文件清单
  done.txt      已完成路径（追加写入）
  failed.txt    多次重试仍失败的路径
  log.txt       运行日志
```

## 比原 bash 脚本多做的事

- 目录已存在时续传，不会因为 `git clone` 到一半而从头失败
- 元数据 fetch 与 blob checkout 都有重试 / 指数退避
- blob 按需拉取自己做（`git fetch origin <oid>...`，与 git 的 lazy fetch 等价，但一次请求拉一批），不在 checkout 里一个文件一个请求地懒加载
- 命令失败不等于整批失败：只补拉 / 重试真正缺的文件，必要时二分定位，避免因一个文件重跑整批（sha1 missing / Directory not empty）
- Windows 长路径、`http.version=HTTP/1.1`、低速断开、UTF-8 路径、`index.lock` 清理
- 跳过 submodule gitlink；可用 `-Include` / `-Exclude` 过滤
- Ctrl+C 或断电后重跑同一命令即可，不需要手动改文件列表
- 交互式全屏 TUI：无参数向导、进度面板、暂停/停止、最近任务续传（`-NoTui` 可关闭）

## 注意事项

- **不要**删掉目标目录里的 `.git`，否则进度和已下 blob 都没了。
- 日志里出现 `error: unable to read sha1 file of <path> (<oid>)` 说明该 blob 本地缺失：先拉后写的流程下正常情况下不会看到它，只有对应对象在远端也已不存在（force push、仓库被裁剪等）时才会出现，这类文件会进 `failed.txt`。
- 私有仓库走本机已有的凭据即可（Git Credential Manager / `gh auth` / SSH key）。
- 子模块不会自动递归；要对子模块再执行一次本脚本。
- Git LFS 文件 checkout 后如需真正指针内容，请再执行 `git lfs pull`。
- 若 fetch 阶段就反复 `HTTP/2` / `RPC failed`，脚本已强制 `HTTP/1.1`；仍失败时检查代理、`GIT_SSL_NO_VERIFY` 不要随便开。
- 想换分支或更新到最新 commit：加 `-ForceRefetch`（会按新 SHA 补下差异文件）。

## 界面性能

TUI 的每一帧都靠 PowerShell 函数拼字符串，所以帧成本几乎完全由「每次调用要付多少函数调用开销」决定。原先有两个热点，现已修掉；下面是在 Windows PowerShell 5.1 上 `bench\bench-frame.ps1` 的实测值（120×40 面板、400 行活动日志）：

| 场景 | 修复前 | 修复后 |
| --- | --- | --- |
| 画面完全没变 | 92.9 ms | **8.5 ms** |
| 每帧多一行日志 | 86.4 ms | **7.3 ms** |
| 每一行都变（失败列表/改窗口大小） | 72.7 ms | **7.3 ms** |
| 向导界面 | 85.3 ms | **6.2 ms** |

修复前约 12 fps，低于帧率上限，所以按键和动画都会明显发滞；现在约 120–160 fps，已远高于 60 fps 的目标，真正限制重绘的是 16 ms 的节流阀而不是渲染本身。

1. **字符宽度改成查表**。原来每个字符都要调一次 `Get-GcrCharWidth`，一次调用几微秒；一行 70 字的日志要 ~1.2 ms 才量得出来，一帧 40 行光量宽度就花掉 ~67 ms（占 81 ms 预算的 83%）。现在把同样的判定预先算成一张 65536 项的 `byte[]`（`Get-GcrWidthTable`，启动时建一次约 40 ms），量宽度变成 `for` 循环里的数组下标，没有函数调用。`Format-GcrCell` 也顺手去掉重复计量：旧实现一次格式化要量三遍（自己一遍、`Truncate-GcrDisplay` 里一遍、量结果又一遍）。
2. **不再每帧重建函数**。`Push-GcrBorder` / `Push-GcrRow` / `WBorder` / `WRow` 原先定义在 `Render-GcrTui` 和 `Render-GcrTuiWizard` **内部**，PowerShell 每次调用外层函数都会重新解析并编译内层函数定义——等于每帧重建四个函数。现在它们住在脚本作用域，通过 `$script:GcrFrame` 共享当前帧，调色板也按界面变体缓存一份，不再每帧新建哈希表并调九次 `Get-GcrColor`。

`Out-GcrFrame` 本来就是按行做差分的（只重画变化的行），这部分没有改动；`bench\test-render.ps1` 会验证「画面没变时一行都不重画」。

### 回归测试

改动集中在渲染与输入热路径上，容易出「看着对、实际错位」的问题，所以配了五个测试套件：

```powershell
powershell -NoProfile -File bench\test-all.ps1
```

| 套件 | 检查内容 |
| --- | --- |
| `check-bom.ps1` | 两个脚本保留 UTF-8 BOM 且能正常解析（**Windows PowerShell 5.1 会把没有 BOM 的 .ps1 当 ANSI/GBK 读**，中文会变乱码并直接解析失败；编辑工具常会吃掉 BOM） |
| `test-widthtable.ps1` | 宽度表类型稳定、可缓存，且对全部 65536 个 BMP 码点与 `Get-GcrCharWidth` 逐一一致 |
| `test-width.ps1` | 宽/截断/填充三个函数与改动前的实现（`bench\legacy\width-reference.ps1`，从 git HEAD 冻结）在 30 个用例上结果一致，覆盖 CJK、全角、谚文、假名、组合字符、制表符、ANSI 着色、边界宽度 0–4 |
| `test-render.ps1` | 仪表盘与向导在 9 种状态 × 5 种窗口尺寸下都渲染出结构正确的整屏：行数正确、每行宽度恰好等于 `DrawW`、不碰最后一列（避免自动换行滚屏）、边框字符正确，以及帧差分（无变化零重画、改动一行只重画一行） |
| `test-wizard.ps1` | 向导按键状态机：导航（含按住方向键 / `j` `k` 到边界不回绕）、开关、批次与重试步进、行内编辑、`S` / `Ctrl+S` / `Enter` 开始、`Q` 退出确认，以及鼠标命中表与实际渲染的行一一对应（点某行确实选中该行、点开始行确实开始、点边框是空操作） |
| `check-native-input.ps1` | P/Invoke 层：`Add-Type` 能编译、三个结构体大小与全部字段偏移与 Win32 一致，且在**没有控制台**的环境下输入层不抛异常、已排队的按键不会被鼠标读取方吞掉 |

`bench\bench-frame.ps1` / `bench-profile.ps1` / `bench-startup.ps1` / `bench-input.ps1` 是可复现的性能基准，`bench\fix-bom.ps1` 可修复被编辑器吃掉 BOM 的脚本。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 全部完成或本来就已经齐 |
| 1 | 有文件最终仍失败，或中途异常；可重跑续传 |
| 2 | 参数错误 / 找不到 git |
