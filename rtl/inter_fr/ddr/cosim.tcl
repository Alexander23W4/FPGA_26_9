set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. .. ..]]
open_project [file join $root build unet registration_hls]
add_files -tb [file join $here test_registration.cpp] -cflags "-std=c++14 -DREGISTRATION_RTL_COSIM"
open_solution solution
cosim_design -rtl verilog -tool xsim
puts "REGISTRATION_DDR_RTL_VERIFIED"
exit
