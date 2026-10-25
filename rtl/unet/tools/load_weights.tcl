# XSCT: load a complete prepared weight image; CPU must be halted by caller.
# Commit magic LAST so the inference core never sees partially loaded weights.
proc load_unet_weights {path} {
    if {![file exists $path] || [file size $path]<64 || [file size $path]>0x4000000} {
        error "Invalid U-Net weight image: $path"
    }
    set stream [open $path rb]
    set header [read $stream 28];close $stream
    binary scan $header i7 words
    if {[lindex $words 0]!=0 || [lindex $words 1]!=1 || [lindex $words 2]!=78 ||
        [lindex $words 4]!=16 || [lindex $words 5]!=256} {
        error "Unexpected U-Net model header; regenerate and rebuild PL together"
    }
    mwr 0x28000000 0
    dow -data $path 0x28000000
    mwr 0x28000000 0x554e4554
    if {[mrd -value 0x28000000]!=0x554e4554} {error "U-Net model commit failed"}
    puts "UNET_WEIGHTS_READY bytes=[file size $path] DDR=0x28000000"
}
