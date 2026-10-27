# Read-only JTAG presence check for the Heartcare launch gate.
# Deliberately do not reset either the PS or PL here.
if {[catch {connect} message]} {
    puts "HEARTCARE_JTAG_FAIL connect: $message"
    exit 1
}
if {[catch {targets -set -filter {name =~ "ARM*#0"}} message]} {
    puts "HEARTCARE_JTAG_FAIL APU: $message"
    puts "TARGETS: [targets]"
    exit 1
}
if {[catch {targets -set -filter {name =~ "*xc7z*"}} message]} {
    puts "HEARTCARE_JTAG_FAIL FPGA: $message"
    puts "TARGETS: [targets]"
    exit 1
}
puts "HEARTCARE_JTAG_OK"
catch {disconnect}
exit 0
