set r "C:/Users/HUAWEI/Desktop/FPGA_26_9"
create_project -force sim_a2p "$r/build/sim_a2p" -part xc7z015clg485-2
add_files -norecurse "$r/rtl/axi2px.v"
add_files -fileset sim_1 -norecurse "$r/sim/tb_axi2px.v"
set_property top tb_axi2px [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation -mode behavioral
run all
close_sim
puts "@@@ SIM-DONE"
