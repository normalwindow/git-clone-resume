@echo off
setlocal EnableExtensions
call "%~dp0git-clone-resume.cmd" %*
exit /b %ERRORLEVEL%