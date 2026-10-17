# Only synchronizer first stages. Subsequent settling stages remain timed.
set_false_path -to [get_pins -quiet -hier -regexp {.*u_(display_cfg_cdc|display_frame_cdc|hdmi_enable_cdc)/(req_sync|ack_sync|idle_sync|run_sync)_reg\[0\]/D}]
set_false_path -to [get_pins -quiet -hier -regexp {.*/release_pipe_reg\[[0-2]\]/(CLR|PRE)}]

# Bundled payloads remain held until acknowledged. Request takes at least two
# destination clocks; data must arrive within one 25.2-MHz destination period.
# Do not use clock groups or broad false paths, which would override this bound.
set_max_delay -datapath_only 39.680 -from [get_cells -quiet -hier -filter {NAME =~ *u_display_cfg_cdc/mode_hold_reg*}] -to [get_cells -quiet -hier -filter {NAME =~ *u_display_cfg_cdc/mode_out_reg*}]
set_max_delay -datapath_only 39.680 -from [get_cells -quiet -hier -filter {NAME =~ *u_display_cfg_cdc/alpha_hold_reg*}] -to [get_cells -quiet -hier -filter {NAME =~ *u_display_cfg_cdc/alpha_out_reg*}]
set_max_delay -datapath_only 39.680 -from [get_cells -quiet -hier -filter {NAME =~ *u_hdl_out/display_buf_idx_reg*}] -to [get_cells -quiet -hier -filter {NAME =~ *u_display_frame_cdc/frame_bank_reg*}]
