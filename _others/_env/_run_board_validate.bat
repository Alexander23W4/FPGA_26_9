@echo off
set TMP=C:\Users\HUAWEI\Desktop\FPGA_26_9\_others\_env\_tmp
if not exist "%TMP%" mkdir "%TMP%"
cd /d "%TMP%"
call "E:\Xilinx\Vivado\2023.2\bin\vivado.bat" -mode batch -nolog -nojournal -source "C:\Users\HUAWEI\Desktop\FPGA_26_9\_others\_env\_validate_board.tcl" > "%TMP%\board.log" 2>&1
echo EXITCODE=%ERRORLEVEL% >> "%TMP%\board.log"
