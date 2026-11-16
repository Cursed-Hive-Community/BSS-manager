@echo off
rem Opens the BSS Manager window (Windows asks for administrator rights).
rem Arguments are passed through, e.g. BSS-Manager.bat -Action Menu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BSS-Manager.ps1" %*
