@echo off
rem Starts the SortingTool without a console window.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0System\Code\Main.ps1"
