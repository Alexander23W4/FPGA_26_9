"""Reproduce the raw-API heap race with the installed, unmodified lwIP allocator."""
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'build/tests/lwip_heap'
LWIP=ROOT/'csrc/fpga_26/ps7_cortexa9_0/standalone_ps7_cortexa9_0/bsp/libsrc/lwip213/src/lwip-2.1.3/src'

def main():
    (OUT/'include/arch').mkdir(parents=True,exist_ok=True)
    (OUT/'include/arch/cc.h').write_text('''#include <stdio.h>
#include <stdlib.h>
unsigned test_protect(void);
void test_unprotect(unsigned);
void test_interrupt_point(void *);
#define SYS_ARCH_DECL_PROTECT(lev) unsigned lev
#define SYS_ARCH_PROTECT(lev) ((lev)=test_protect())
#define SYS_ARCH_UNPROTECT(lev) test_unprotect(lev)
''')
    (OUT/'include/xlwipconfig.h').write_text('/* No NIC needed. */\n')
    (OUT/'include/lwipopts.h').write_text('''#define NO_SYS 1
#define LWIP_TIMERS 0
#define SYS_LIGHTWEIGHT_PROT 1
#define MEM_ALIGNMENT 64
#define MEM_SIZE 1048576
#define LWIP_STATS 0
''')
    source=(LWIP/'core/mem.c').read_text()
    point='      if ((!mem->used) &&'
    assert source.count(point)==1
    (OUT/'mem_probe.c').write_text(source.replace(point,
        '      test_interrupt_point(mem);\n'+point))
    compiler='E:/Xilinx/Vivado/2023.2/tps/mingw/9.3.0/win64.o/nt/bin/gcc.exe'
    for protection in (0,1):
        executable=OUT/('heap_irq_%d.exe'%protection)
        subprocess.run([compiler,'-std=c11','-O2','-Wall','-Wextra','-Werror','-static',
            '-DLWIP_ALLOW_MEM_FREE_FROM_OTHER_CONTEXT=%d'%protection,
            '-I'+str(OUT/'include'),'-I'+str(LWIP/'include'),
            str(ROOT/'scripts/tests/lwip_heap_interrupt.c'),str(OUT/'mem_probe.c'),
            '-o',str(executable)],check=True)
        subprocess.run([str(executable)],check=True,timeout=5)

if __name__=='__main__':main()
