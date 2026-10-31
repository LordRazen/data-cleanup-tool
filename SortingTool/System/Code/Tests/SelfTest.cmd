@echo off
rem Runs the self test of the SortingTool in a temporary folder.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0SelfTest.ps1"
pause
