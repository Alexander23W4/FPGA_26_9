# =============================================================================
#  ila_capture.tcl -- capture the BD ILA (u_ila_hdmi) and dump the waveform
#
#  Usage (from Git Bash):
#    /e/Xilinx/Vitis/2023.2/bin/xsct.bat \
#        "$(cygpath -w scripts/tcl/ila_capture.tcl)" "$(cygpath -w build/ila_dump)"
#
#  What it does:
#    1) connects to the local hw_server
#    2) finds every ILA in the design and prints its probe list
#       (so we can see exactly which signals are wired to debug_probe)
#    3) sets a trigger that fires when the AXI-Stream stops being accepted
#    4) arms, waits for the trigger, uploads, and dumps the probe values
#       to <outdir>/ila.csv plus a readable summary
#
#  If the trigger never fires within the timeout it still uploads whatever
#  the ILA has (it will report "no trigger").
# =============================================================================

set outdir "."
if {[llength $argv] >= 1} { set outdir [lindex $argv 0] }

file mkdir $outdir
set csv  [file join $outdir ila.csv]
set txt  [file join $outdir ila_summary.txt]

set log [open $txt w]

proc P {f s} { puts $s; puts $f $s }

P $log "============================================================"
P $log " ILA capture -- [clock format [clock seconds]]"
P $log "============================================================"

# ---------------------------------------------------------------- connect
open_hw_manager
if {[catch {
    connect_hw_server -url localhost:3121
    open_hw_target
} err]} {
    P $log "ERROR connecting to hardware: $err"
    close $log
    exit 1
}

set ilas [get_hw_ilas]
P $log "ILA cores found: [llength $ilas]"
foreach il $ilas { P $log "   $il" }

if {[llength $ilas] == 0} {
    P $log "no ILA in the design -- nothing to capture"
    close $log
    exit 0
}

# ---------------------------------------------------------------- probes
set il [lindex $ilas 0]
P $log ""
P $log "probes on $il :"
set probe_names {}
foreach p [get_hw_probes -of_objects $il] {
    set nm [get_property NAME $p]
    set wd [get_property WIDTH $p]
    lappend probe_names $nm
    P $log [format "   %-40s width=%s" $nm $wd]
}

# ---------------------------------------------------------------- trigger
# Prefer a trigger that fires when the stream stops being accepted:
#   s_axis_tready == 0   (PL stops accepting  => VDMA stalls)
# Fall back to: the ILA's raw data changing, or immediate.
set radix  HEX
set trig_done 0

proc try_trigger {log il cond} {
    if {[catch {
        reset_hw_ila $il
        set_property CONTROL.TRIGGER_POSITION 512 $il
        set_property CONTROL.DATA_DEPTH 4096 $il
        set_property TRIGGER_COMPARE_VALUE $cond [get_hw_probes -of_objects $il]
    } err]} { return 0 }
    return 1
}

foreach cand {
    {s_axis_tready == 1'b0}
    {s_axis_tvalid == 1'b1 && s_axis_tready == 1'b0}
} {
    set pr [get_hw_probes -of_objects $il -filter "NAME =~ *tready*"]
    if {[llength $pr] > 0} {
        if {[catch {
            reset_hw_ila $il
            set_property CONTROL.TRIGGER_POSITION 512 $il
            catch { set_property CONTROL.DATA_DEPTH 4096 $il }
            set_property TRIGGER_COMPARE_VALUE 1'b0 $pr
            P $log "trigger set: [get_property NAME $pr] == 0"
            set trig_done 1
        } err]} {
            P $log "trigger setup failed: $err"
        }
        break
    }
}
if {!$trig_done} { P $log "no tready probe found -- using immediate/auto trigger" }

# ---------------------------------------------------------------- arm + wait
if {[catch {
    run_hw_ila $il
    P $log "ILA armed, waiting up to 120 s for the trigger ..."
} err]} {
    P $log "run_hw_ila failed: $err"
}

set waited 0
while {$waited < 120} {
    after 1000
    incr waited
    if {[catch {set st [get_property CONTROL.CAPTURE_STATUS $il]} e]} { break }
    if {$st ne "WAITING_FOR_TRIGGER"} { break }
    if {$waited % 10 == 0} { P $log "   ... still waiting (${waited}s)" }
}
P $log "capture status: [get_property CONTROL.CAPTURE_STATUS $il]"

# ---------------------------------------------------------------- upload
if {[catch { upload_hw_ila_data $il } err]} { P $log "upload failed: $err" }

if {[catch {
    set data [current_hw_ila_data]
    write_hw_ila_data -csv_file $csv $data
    P $log "waveform written to: $csv"
} err]} { P $log "export failed: $err" }

# ---------------------------------------------------------------- readable dump
if {[catch {
    set data [current_hw_ila_data]
    set cnt 0
    foreach d [get_hw_ila_data -of_objects $il] { incr cnt }
    P $log "samples captured: $cnt"
} err]} { P $log "sample count: $err" }

close $log
puts "ILA_DONE  summary=$txt  csv=$csv"
