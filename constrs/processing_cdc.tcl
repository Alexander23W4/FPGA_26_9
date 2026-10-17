# Synchronizer first stages only. Do not false-path subsequent settling stages
# or place whole clock domains in asynchronous groups: that would hide bugs and
# override the bounded bundled-data paths below.
foreach cell [get_cells -quiet -hier -filter {ASYNC_REG == TRUE}] {
    set name [get_property NAME $cell]
    if {[regexp {/(req_sync|ack_sync|idle_sync|run_sync)_reg\[0\]$} $name]} {
        set_false_path -to [get_pins $cell/D]
    }
    if {[regexp {/release_pipe_reg\[[0-2]\]$} $name]} {
        set pins [get_pins -quiet -of_objects $cell -filter {REF_PIN_NAME == CLR || REF_PIN_NAME == PRE}]
        if {[llength $pins]} {set_false_path -to $pins}
    }
}
# Payloads are held until acknowledged; the request takes at least two/three
# destination clocks. Bound data propagation to one destination cycle.
foreach spec {
    {*u_display_cfg_cdc/mode_hold_reg* *u_display_cfg_cdc/mode_out_reg*}
    {*u_display_cfg_cdc/alpha_hold_reg* *u_display_cfg_cdc/alpha_out_reg*}
    {*u_hdl_out/display_buf_idx_reg* *u_display_frame_cdc/frame_bank_reg*}
} {
    lassign $spec source target
    set from [get_cells -quiet -hier -filter "NAME =~ $source"]
    set to [get_cells -quiet -hier -filter "NAME =~ $target"]
    if {![llength $from] || ![llength $to]} {continue}
    set clock [get_clocks -quiet -of_objects [get_pins -of_objects $to -filter {REF_PIN_NAME == C}]]
    if {[llength $clock] != 1} {error "CDC payload has no unique destination clock: $target"}
    set_max_delay -datapath_only [get_property PERIOD $clock] -from $from -to $to
}
