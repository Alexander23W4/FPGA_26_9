"""Build the installed lwIP core natively; synthetic packets only, no board IO."""
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'build/tests/lwip_receive'
LWIP=(ROOT/'csrc/fpga_26/ps7_cortexa9_0/standalone_ps7_cortexa9_0/bsp/libsrc/lwip213/src/lwip-2.1.3/src')


def main():
    (OUT/'include/arch').mkdir(parents=True,exist_ok=True)
    (OUT/'include/arch/cc.h').write_text('#include <stdio.h>\n#include <stdlib.h>\n')
    (OUT/'include/xlwipconfig.h').write_text('/* Synthetic IP input; no Xilinx NIC. */\n')
    options={'NO_SYS':1,'LWIP_TIMERS':0,'LWIP_SOCKET':0,'LWIP_NETCONN':0,
        'LWIP_IPV4':1,'LWIP_IPV6':0,'LWIP_TCP':1,'LWIP_UDP':0,'LWIP_RAW':0,
        'LWIP_DHCP':0,'LWIP_DNS':0,'LWIP_AUTOIP':0,'LWIP_IGMP':0,'LWIP_ICMP':0,
        'LWIP_ARP':0,'IP_REASSEMBLY':0,'IP_FRAG':0,'LWIP_NETIF_LOOPBACK':0,
        'MEM_LIBC_MALLOC':1,'MEMP_MEM_MALLOC':1,'MEM_ALIGNMENT':8,'SYS_LIGHTWEIGHT_PROT':0,
        'TCP_WND':65535,'TCP_SND_BUF':65535,'TCP_MSS':1460,'MEMP_NUM_TCP_SEG':1024,
        'CHECKSUM_CHECK_IP':0,'CHECKSUM_CHECK_TCP':0}
    (OUT/'include/lwipopts.h').write_text(''.join('#define %s %d\n'%pair for pair in options.items()))
    sources=sorted((LWIP/'core').glob('*.c'))+sorted((LWIP/'core/ipv4').glob('*.c'))
    compiler='E:/Xilinx/Vivado/2023.2/tps/mingw/9.3.0/win64.o/nt/bin/gcc.exe'
    executable=OUT/'lwip_receive_burst.exe'
    # Upstream tcp_recved checks >65535 even with a 16-bit window type.
    command=[compiler,'-std=c11','-O2','-Wall','-Wextra','-Werror','-Wno-type-limits','-static',
             '-I'+str(OUT/'include'),'-I'+str(LWIP/'include'),
             str(ROOT/'scripts/tests/lwip_receive_burst.c'),*(str(p) for p in sources),'-o',str(executable)]
    subprocess.run(command,check=True)
    subprocess.run([str(executable)],check=True,timeout=15)


if __name__=='__main__':main()
