# bank 握手小实验: 秒级仿真, 检查防撕裂不变量
# 用法(Git Bash):
#   E:/Xilinx/Vivado/2023.2/bin/vivado.bat -mode batch -source sim/run_bank_ab.tcl
set r "C:/Users/HUAWEI/Desktop/FPGA_26_9"

create_project -force sim_bank "$r/build/sim_bank" -part xc7z015clg485-2

# RTL 进 sources_1
add_files -norecurse [list \
    "$r/rtl/hdl_out.v" \
    "$r/rtl/hdmi_out.v" \
    "$r/rtl/double_buf.v" ]

# 测试台进 sim_1 (!), 顶层也设在 sim_1
add_files -fileset sim_1 -norecurse "$r/sim/tb_bank_handshake.v"
set_property top tb_bank_handshake [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_simulation -mode behavioral
run all
close_sim
puts "@@@ SIM-DONE"
