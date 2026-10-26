"""Reproduce the active-low auxiliary-reset fault, then boot the real U-Net RTL.
Requires generated Vivado IP from an existing fpga_26 project.
"""
from pathlib import Path
import re,subprocess,shutil,struct
root=Path(__file__).resolve().parents[3]
out=root/"build/tests/unet_reset_boot"
out.mkdir(parents=True,exist_ok=True)
text=(root/"rtl/unet/unet.v").read_text()
ports=list(dict.fromkeys(re.findall(r"(input|output) wire\s*(\[[^\]]+\])?\s*(M_AXI_UNET_\w+)",text)))
decl="\n".join(f"wire {w or ''} {n};" for _,w,n in ports)
conn=",\n".join(f".{n}({n})" for _,_,n in ports)
head=list(struct.unpack("<7I",(root/"build/unet/model/weights.bin").read_bytes()[:28]))
head[0]=0x554e4554  # XSCT commits this magic after loading the blob.
tb="""`timescale 1ns/1ps
module tb_model_boot;
reg clk=0,uclk=0,rst=1,enable=0;
always #6.25 clk=~clk;
always #3.125 uclk=~uclk;
wire[31:0] status;wire ir;reg aux=0;wire urst;
system_rst_unet_0 reset_ip(.slowest_sync_clk(uclk),.ext_reset_in(rst),
 .aux_reset_in(aux),.mb_debug_sys_rst(1'b0),.dcm_locked(1'b1),.peripheral_reset(urst));
DECL
unet #(.ASYNC_CORE_CLOCK(1)) dut(.clk(clk),.unet_clk(uclk),.rst(rst),.core_arst(urst),.enable(enable),
.in_valid(1'b0),.in_data(8'd0),.in_eof(1'b0),.in_ready(ir),.out_ready(1'b1),.status(status),CONN);
reg [31:0] header[0:6];
reg rv=0;reg[31:0] rd=0;
assign M_AXI_UNET_WEIGHTS_ARREADY=!rv;
assign M_AXI_UNET_WEIGHTS_RVALID=rv;
assign M_AXI_UNET_WEIGHTS_RDATA=rd;
assign M_AXI_UNET_WEIGHTS_RLAST=1'b1;
assign M_AXI_UNET_WEIGHTS_RRESP=0;
assign M_AXI_UNET_WEIGHTS_RID=0;
assign M_AXI_UNET_FEATURES_ARREADY=1;
assign M_AXI_UNET_FEATURES_RVALID=0;
assign M_AXI_UNET_FEATURES_RLAST=0;
assign M_AXI_UNET_FEATURES_RDATA=0;
assign M_AXI_UNET_FEATURES_RRESP=0;
assign M_AXI_UNET_FEATURES_RID=0;
assign M_AXI_UNET_FEATURES_AWREADY=1;
assign M_AXI_UNET_FEATURES_WREADY=1;
assign M_AXI_UNET_FEATURES_BVALID=0;
assign M_AXI_UNET_FEATURES_BRESP=0;
assign M_AXI_UNET_FEATURES_BID=0;
integer reads=0;
always @(posedge uclk)begin
 if(rst)rv<=0;
 else begin
  if(rv&&M_AXI_UNET_WEIGHTS_RREADY)rv<=0;
  if(M_AXI_UNET_WEIGHTS_ARVALID&&M_AXI_UNET_WEIGHTS_ARREADY)begin
   rd<=header[(M_AXI_UNET_WEIGHTS_ARADDR-32'h28000000)>>2];rv<=1;reads<=reads+1;
   $display("HEADER_READ address=%h len=%d",M_AXI_UNET_WEIGHTS_ARADDR,M_AXI_UNET_WEIGHTS_ARLEN);
  end
 end
end
initial begin
HEAD
repeat(20)@(negedge clk);rst=0;
repeat(20)@(negedge clk);enable=1;
#20000;
if(urst!==1 || status!==0 || reads!=0)$fatal(1,"OLD_RESET_NOT_REPRODUCED");
$display("BUG_REPRODUCED auxiliary active-low tied 0 holds U-Net in reset");
aux=1;
wait(status==1);
$display("MODEL_BOOT_OK reads=%0d status=%h input_ready=%b",reads,status,ir);
#1000;$finish;
end
initial begin #100000;$fatal(1,"BOOT_TIMEOUT status=%h reads=%0d core_status=%h",status,reads,dut.core_status);end
endmodule
"""
tb=tb.replace("DECL",decl).replace("CONN",conn).replace("HEAD\n","\n".join(f"header[{i}]=32'h{v:08x};" for i,v in enumerate(head))+"\n")
(out/"tb_model_boot.sv").write_text(tb)
files=[root/"rtl/unet/unet.v",root/"rtl/unet/unet_status_cdc.v",root/"rtl/unet/unet_stream_cdc.v",root/"rtl/reset_sync.v",*sorted((root/"rtl/unet/small_generated").glob("*.v")),out/"tb_model_boot.sv",Path("E:/Xilinx/Vivado/2023.2/data/verilog/src/glbl.v")]
files += [root/"build/vivado/fpga_26/fpga_26.gen/sources_1/bd/system/ip/system_rst_unet_0/system_rst_unet_0_sim_netlist.v"]
files += list((root/"build/vivado/fpga_26/fpga_26.gen/sources_1/ip").glob("*/sim/*_ip.v"))
(out/"sources.prj").write_text("".join(f'sv xil_defaultlib "{p.as_posix()}"\n' for p in files))
for f in (root/"rtl/unet/small_generated").glob("*.dat"):shutil.copy2(f,out/f.name)
(out/"run.tcl").write_text("run all\nquit\n")
bin=Path("E:/Xilinx/Vivado/2023.2/bin")
commands=[("compile",[str(bin/"xvlog.bat"),"--relax","-prj","sources.prj"]),("elaborate",[str(bin/"xelab.bat"),"--relax","-L","floating_point_v7_1_16","-L","xpm","-L","unisims_ver","xil_defaultlib.tb_model_boot","xil_defaultlib.glbl","-s","boot"]),("run",[str(bin/"xsim.bat"),"boot","-tclbatch","run.tcl"])]
for name,cmd in commands:
 r=subprocess.run(cmd,cwd=out,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
 s=r.stdout.decode(errors="replace");(out/(name+".log")).write_text(s);print(name+(": OK" if r.returncode==0 else ": FAILED"),flush=True)
 if r.returncode or "Fatal:" in s or "ERROR:" in s:raise RuntimeError(s[-4000:])
 if name=="run":
  if "BUG_REPRODUCED" not in s or "MODEL_BOOT_OK reads=7" not in s:raise RuntimeError("missing boot/reset assertions")
  print("UNET_RESET_BOOT_VERIFIED: old tie-low blocks all reads; inactive tie-high releases reset and validates seven header words",flush=True)


