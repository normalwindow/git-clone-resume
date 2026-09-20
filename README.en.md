# Git Clone Resume for Windows

Resume-friendly partial cloning for GitHub and other unstable networks. The tool fetches commit/tree metadata first, then checks out files in batches. Run the same command again after an interruption to resume.

## Requirements

- Git for Windows >= 2.19
- Windows PowerShell 5.1 or PowerShell 7+
- Optional: `git config --global core.longpaths true`

## Install

Install from npm:

```powershell
npm install -g git-clone-resume
gcr https://github.com/user/repo.git
```

The package still requires Git for Windows and PowerShell. Release ZIP packages contain both `gcr` and `git-clone-resume` launchers.

## Usage

Start the fullscreen wizard without a URL, or pass a URL directly:

```bat
git-clone-resume.cmd
git-clone-resume.cmd https://github.com/user/repo.git
```

PowerShell users can call the script directly:

```powershell
.\git-clone-resume.ps1 https://github.com/user/repo.git -Ref main -OutDir D:\src\repo
.\git-clone-resume.ps1 https://github.com/user/repo.git -Include src/*,docs/* -Exclude *.bin
.\git-clone-resume.ps1 https://github.com/user/repo.git -BatchSize 64 -MaxRetries 12
.\git-clone-resume.ps1 https://github.com/user/repo.git -Verify
.\git-clone-resume.ps1 https://github.com/user/repo.git -DryRun
gcr -Version
gcr -ClearHistory
```

Use `-NoTui` in CI or when output is redirected. Use `-Tui` to force the fullscreen interface. `-Version` prints the package version. `-ClearHistory` removes `%LOCALAPPDATA%\git-clone-resume\history.json` without deleting repositories or `.git/partial-resume` state.

In the wizard recent-task list: `Enter` fills the form, `Del` removes the selected entry, `Ctrl+D` clears all history.

## Language

On the first wizard screen, select `Language` and choose Chinese or English. Press `L` in the wizard or progress panel to switch at any time. The command-line equivalent is:

```powershell
.\git-clone-resume.ps1 https://github.com/user/repo.git -Language en-US
.\git-clone-resume.ps1 https://github.com/user/repo.git -Language zh-CN
```

## Resume State

Progress is stored outside the worktree in `.git/partial-resume/`. Do not delete the target repository's `.git` directory. Completed files are skipped on subsequent runs; failed files are retried.

File contents (blobs) are fetched on purpose, in one batched request per group, instead of letting `git checkout` trigger git's implicit lazy fetch (which fetches one blob per subprocess). Each batch probes first (`git cat-file --batch-check` with `GIT_NO_LAZY_FETCH=1`, fully offline) so only the blobs that are really missing are requested, then `git checkout` is a local file write. A failing git command never means the whole group failed: only the files that did not land are fetched and retried, bisected when needed.

The tool skips submodule gitlinks. Run it separately for submodules. After checking out Git LFS files, run `git lfs pull` if actual LFS content is needed.

## Window / tab title

While a clone runs the console title is rewritten so the taskbar, Windows Terminal tabs, and the VS Code terminal list show live progress (works in TUI and `-NoTui`):

```
nature-skills  ·  42% (340/802)  ·  git-clone-resume
nature-skills  ·  42% (340/802)  ·  PAUSED  ·  git-clone-resume
nature-skills  ·  99% (799/802)  ·  FAILED 3  ·  git-clone-resume
nature-skills  ·  done (802/802)  ·  git-clone-resume
```

Phases show as `fetching metadata` / `listing files` / `scanning workspace` / `repairing index`. The previous title is restored on exit. Control it with `GCR_TITLE=1` (force, also when output is redirected) or `GCR_TITLE=0` (disable).

## Progress and download speed

The progress line (`-NoTui`) and the TUI panel both show a download speed:

```
[######################------]  80.0%  32/40  fail 0  480.5 KB  717.4 KB/s  37.5 files/s  ETA 00:01:20  dir03/file11.txt
```

- The speed is the bytes this batch actually put on disk divided by the time it needed, summed over a 20-second sliding window. It uses the same basis as the total next to it (worktree file bytes, not the compressed pack size git reports as `Receiving objects: ... 1.88 KiB`).
- When nothing in the window is newer than 20 seconds the last value is kept, so a slow or stalled batch does not flip the reading to 0.
- The TUI uses the same number and additionally shows git's own `Receiving objects: ... MiB/s` line for the running command.
- `checkpoint` log lines and the final summary add an average speed.

## Result panel colors

When a run finishes, the result panel is colored by meaning instead of a single dim block: the headline is bold (green on success, red on failure), the `Succeeded …` summary is bold green, `Failure list: …` is yellow, workspace paths are cyan, and hints stay dim. Switching to English (`-Language en-US`) now also applies to this panel and to the log summaries, with no leftover full-width punctuation.

## TUI Keys

- `Q` / `Ctrl+C`: stop after the current Git command; press again to force stop
- `P` / `Esc`: pause after the current batch
- `Space`: resume from pause
- `F`: show failed files
- `L`: switch language
- `Up` / `Down` / `j` / `k`: scroll activity
- `?` / `H`: show help
- `Enter`: close the result screen

See the Chinese guide in [README.md](README.md) for the full implementation details and release channels.
