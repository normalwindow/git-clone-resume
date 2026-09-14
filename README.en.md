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
```

Use `-NoTui` in CI or when output is redirected. Use `-Tui` to force the fullscreen interface.

## Language

On the first wizard screen, select `Language` and choose Chinese or English. Press `L` in the wizard or progress panel to switch at any time. The command-line equivalent is:

```powershell
.\git-clone-resume.ps1 https://github.com/user/repo.git -Language en-US
.\git-clone-resume.ps1 https://github.com/user/repo.git -Language zh-CN
```

## Resume State

Progress is stored outside the worktree in `.git/partial-resume/`. Do not delete the target repository's `.git` directory. Completed files are skipped on subsequent runs; failed files are retried.

The tool skips submodule gitlinks. Run it separately for submodules. After checking out Git LFS files, run `git lfs pull` if actual LFS content is needed.

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
