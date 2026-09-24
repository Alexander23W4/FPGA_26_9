@echo off
REM ============================================================
REM  验证 ACZ7015 PS7 Preset
REM ============================================================
set TMP=C:\Users\HUAWEI\Desktop\FPGA_26_9\_others\_env\_tmp
if not exist "%TMP%" mkdir "%TMP%"
cd /d "%TMP%"
call "E:\Xilinx\Vivado\2023.2\bin\vivado.bat" -mode batch -nolog -nojournal -source "C:\Users\HUAWEI\Desktop\FPGA_26_9\_others\_env\_validate_preset.tcl" > "%TMP%\validate.log" 2>&1
echo EXITCODE=%ERRORLEVEL% >> "%TMP%\validate.log"
