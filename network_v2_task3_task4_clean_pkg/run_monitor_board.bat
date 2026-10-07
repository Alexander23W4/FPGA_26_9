@echo off
if "%~1"=="" (echo Usage: run_monitor_board.bat 192.168.1.10 & exit /b 1)
set PYTHON=C:\Users\13995\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe
"%PYTHON%" "%~dp0host\monitor_network.py" --board-ip %~1
