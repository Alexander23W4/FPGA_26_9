@echo off
if "%~1"=="" (echo Usage: run_image_sender.bat image.png 192.168.1.10 & exit /b 1)
set PYTHON=C:\Users\13995\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe
"%PYTHON%" "%~dp0pc\image_sender.py" --image %~1 --host %~2
