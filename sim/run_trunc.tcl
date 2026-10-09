# 掐帧实验 A/B: 先跑原始逻辑(USE_ORIG), 再跑修复逻辑
set r "C:/Users/HUAWEI/Desktop/FPGA_26_9"

create_project -force sim_trunc "$r/build/sim_trunc" -part xc7z015clg485-2

add_files -norecurse [list \
    "$r/rtl/denoise.v" \
    "$r/sim/denoise_orig.v" ]

add_files -fileset sim_1 -norecurse "$r/sim/tb_trunc.v"
set_property top tb_trunc [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# ---- A: 原始逻辑 (只靠 in_last 复位) ----
puts "@@@ ============ A: ORIG ============"
set_property verilog_define {USE_ORIG} [get_filesets sim_1]
launch_simulation -mode behavioral
run all
close_sim

# ---- B: 修复逻辑 (自计数帧边界) ----
puts "@@@ ============ B: FIX ============"
set_property verilog_define {} [get_filesets sim_1]
launch_simulation -mode behavioral
run all
close_sim

puts "@@@ SIM-DONE"
