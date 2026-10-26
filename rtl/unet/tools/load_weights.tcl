# XSCT: load a complete prepared weight image; CPU must be halted by caller.
# Commit magic LAST so the inference core never sees partially loaded weights.
set ::unet_model_load_config [file join [file dirname [info script]] .. small_hls model_load.tcl]
proc load_unet_weights {path} {
    if {![file exists $path] || [file size $path]<64 || [file size $path]>0x4000000} {
        error "Invalid U-Net weight image: $path"
    }
    set stream [open $path rb]
    set header [read $stream 28];close $stream
    binary scan $header i7 words
    source $::unet_model_load_config
    # Program ID is unsigned; binary scan i returns a signed native integer.
    set normalized {};foreach word $words {lappend normalized [expr {$word & 0xffffffff}]}
    if {$normalized ne $::unet_expected_header} {
        error "Unexpected U-Net model header; regenerate and rebuild PL together"
    }
    puts "UNET_WEIGHTS_LOADING bytes=[file size $path] DDR=0x28000000 model=small-INT8"
    mwr 0x28000000 0
    dow -data $path 0x28000000
    mwr 0x28000000 0x554e4554
    if {[mrd -value 0x28000000]!=0x554e4554} {error "U-Net model commit failed"}
    puts "UNET_WEIGHTS_READY bytes=[file size $path] DDR=0x28000000"
}
