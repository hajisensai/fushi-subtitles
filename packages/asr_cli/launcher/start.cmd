@echo off
rem fushi-subs: start the server and open the web UI. Close this window to stop.
chcp 65001 >nul
cd /d "%~dp0"
"%~dp0fushi-subs.exe" serve --open
if errorlevel 1 pause
