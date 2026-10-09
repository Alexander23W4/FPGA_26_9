# 完整链路诊断: denoise -> thresholder -> hdl_out -> double_buf -> hdmi_out
# 用法(Git Bash):
#   E:/Xilinx/Vivado/2023.2/bin/vivado.bat -mode batch -source sim/run_full_chain.tcl
set r "C:/Users/HUAWEI/Desktop/FPGA_26_9"

create_project -force sim_full "$r/build/sim_full" -part xc7z015clg485-2

add_files -norecurse [list \
    "$r/rtl/hdl_out.v" \
    "$r/rtl/hdmi_out.v" \
    "$r/rtl/double_buf.v" \
    "$r/rtl/denoise.v" \
    "$r/rtl/thresholder/top_threshold_demo.v" \
    "$r/rtl/thresholder/axi_lite_slave.v" \
    "$r/rtl/thresholder/otsu_core.v" \
    "$r/rtl/thresholder/th_select.v" \
    "$r/rtl/thresholder/threshold_seg.v" \
    "$r/rtl/thresholder/contour_extract.v" ]

add_files -fileset sim_1 -norecurse "$r/sim/tb_full_chain.v"
set_property top tb_full_chain [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_simulation -mode behavioral
run all
close_sim
puts "@@@ SIM-DONE"
