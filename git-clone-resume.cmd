@echo off
setlocal EnableExtensions
REM Git resume clone launcher. Forwards all args to git-clone-resume.ps1
set "SCRIPT=%~dp0git-clone-resume.ps1"
if not exist "%SCRIPT%" (
  echo Cannot find git-clone-resume.ps1 next to this launcher.
  exit /b 2
)
where git >nul 2>nul
if errorlevel 1 (
  echo Git is not in PATH. Install Git for Windows: https://git-scm.com/download/win
  exit /b 2
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
