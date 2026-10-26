#pragma once
#include <ap_int.h>
#include <stdint.h>
#include <hls_stream.h>
#include <ap_axi_sdata.h>
#include "model_layout_small.h"
typedef ap_axiu<8,0,0,0> axis_input_t;
typedef ap_axiu<16,0,0,0> axis_output_t;
void small_unet_ddr_core(const unsigned *weights,unsigned *features,
    hls::stream<axis_input_t>& input_r,hls::stream<axis_output_t>& output_r,
    unsigned class_map,volatile unsigned &status);
