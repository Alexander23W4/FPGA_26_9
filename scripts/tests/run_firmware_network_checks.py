"""Run the actual C service/driver with simulated hardware and lwIP boundaries."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'build/tests/network_firmware'
HEADERS=('xparameters.h','xil_types.h','xil_io.h','xil_cache.h','xil_printf.h','xil_exception.h',
         'lwip/init.h','lwip/tcp.h','lwip/etharp.h','netif/xadapter.h')
def main():
    OUT.mkdir(parents=True,exist_ok=True)
    for name in HEADERS:
        path=OUT/'include'/name;path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text('#include "'+(ROOT/'scripts/tests/firmware_stubs.h').as_posix()+'"\n')
    compiler=Path('E:/Xilinx/Vivado/2023.2/tps/mingw/9.3.0/win64.o/nt/bin/gcc.exe')
    executable=OUT/'firmware_network_test.exe'
    command=[str(compiler),'-std=c11','-O2','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-static',
             '-I'+str(OUT/'include'),'-I'+str(ROOT/'csrc/MID_plt/src'),
             str(ROOT/'scripts/tests/firmware_network_test.c'),str(ROOT/'csrc/MID_plt/src/drv_s2mm.c'),
             str(ROOT/'csrc/MID_plt/src/crc32.c'),'-o',str(executable)]
    subprocess.run(command,check=True)
    subprocess.run([str(executable)],check=True,timeout=20)
if __name__=='__main__':main()
