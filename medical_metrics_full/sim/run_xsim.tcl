# Run from the package root:
#   vivado -mode batch -source sim/run_xsim.tcl
# The script stops on the first failing elaboration/run.
set root [file normalize [pwd]]
set rtl  "$root/rtl"
set sim  "$root/sim"

xvlog "$rtl/sync_ram.v" "$rtl/frame_diff_sad.v" "$rtl/registration_search.v" "$rtl/registration_top.v" \
      "$rtl/area_counter.v" "$rtl/long_axis_extent.v" "$rtl/div_u64_u64.v" "$rtl/volume_calc.v" \
      "$rtl/strain_calc.v" "$rtl/ed_es_tracker.v" "$rtl/medical_axi_lite.v" "$rtl/medical_accel_top.v" \
      "$rtl/bilinear_interp.v" \
"$sim/tb_registration_top.v" "$sim/tb_volume_calc.v" "$sim/tb_area_axis.v" "$sim/tb_medical_axi_lite.v" \
      "$sim/tb_bilinear_interp.v"

foreach tb {tb_registration_top tb_volume_calc tb_area_axis tb_medical_axi_lite tb_bilinear_interp} {
    puts "===== $tb ====="
    xelab $tb -s $tb
    xsim $tb -R
}
