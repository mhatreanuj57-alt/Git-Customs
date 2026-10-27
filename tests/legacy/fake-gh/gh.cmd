@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-gh.ps1" %*
exit /b %errorlevel%
