# Read-only budget audit of an optimized checkpoint. HDL-instantiated ILA cores
# cannot be removed from a DCP with delete_debug_core; migration removes them
# in the BD before synthesis instead. This audit reports expected capacity,
# not a replacement for implementation DRC of the newly synthesized design.
set repo [file normalize [file join [file dirname [info script]] .. ..]]
set checkpoint [file join $repo build vivado fpga_26 fpga_26.runs impl_1 system_wrapper_opt.dcp]
if {[llength $argv]} {set checkpoint [lindex $argv 0]}
set out [file join $repo build tests bram_budget]
file mkdir $out
open_checkpoint $checkpoint
set report [file join $out hierarchical_utilization.rpt]
report_utilization -hierarchical -file $report
puts [exec python -I [file join $repo scripts tests check_bram_budget.py] --report $report]
close_design
exit
