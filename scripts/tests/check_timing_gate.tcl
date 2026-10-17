set root [file normalize [file join [file dirname [info script]] ../..]]
set out [file join $root build tests processing_clock]
source [file join $root scripts tcl processing_clock.tcl]
open_checkpoint [file join $out routed_80MHz.dcp]
verify_implemented_timing [file join $out gate_80MHz.rpt]
close_design
open_checkpoint [file join $out placed_100MHz.dcp]
if {![catch {verify_implemented_timing [file join $out gate_100MHz.rpt]} reason]} {
    error "Timing gate accepted known failing 100MHz candidate"
}
if {[string first "!!!TIMING_FAILED!!!" $reason] < 0} {error $reason}
puts "TIMING_GATE_OK: accepts routed 80MHz; rejects known failing 100MHz"
close_design
