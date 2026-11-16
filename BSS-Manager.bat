@echo off
rem Opens the BSS Manager menu (Windows asks for administrator rights).
rem Arguments are passed through, e.g. BSS-Manager.bat -Action Start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0BSS-Manager.ps1" %*
