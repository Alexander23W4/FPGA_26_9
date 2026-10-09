@echo off
set PYTHON=C:\Users\13995\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe
"%PYTHON%" "%~dp0mock\mock_ps_server.py" --host 127.0.0.1
