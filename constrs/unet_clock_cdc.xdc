# Only first synchronizer stages; FIFO/AXI CDCs use their vendor constraints.
set_false_path -to [get_pins -quiet -hier -regexp {.*g_async[/.]enable_pipe_reg\[0\]/D}]
set_false_path -to [get_pins -quiet -hier -regexp {.*status_sync/(ack_sync|req_sync)_reg\[0\]/D}]
# Source word is held through request/ack. Three destination clocks precede
# sampling; require the 32-bit payload to arrive within one 80MHz period.
set_max_delay -datapath_only 12.500 -from [get_cells -quiet -hier -filter {NAME =~ *status_sync/data_hold_reg*}] -to [get_cells -quiet -hier -filter {NAME =~ *status_sync/data_out_reg*}]
