#include <ap_int.h>
#include <stdint.h>
#include <hls_stream.h>
#include <ap_axi_sdata.h>
#include "model_layout_fpga5.h"
typedef ap_axiu<8,1,0,0> axis_input_t;
typedef ap_axiu<8,8,0,0> axis_output_t;

// Activations are signed Q4.12 values stored as int16. Weights are symmetric
// per-output-channel int8; params store [Q20 multiplier, Q12 folded bias].
static void conv2d_q8(
    const int16_t *x0, const int16_t *x1, int16_t *y,
    const int8_t *weight_mem, const int32_t *param_mem,
    int x0_channels, int x1_channels, int out_channels,
    int height, int width, int kernel,
    int weight_offset, int param_offset, int relu,
    int8_t weight_buffer[MAX_IN_CHANNELS][9][OC_TILE],
    int32_t param_buffer[2*MAX_OUT_CHANNELS]) {
#pragma HLS INLINE off
    const int in_channels = x0_channels + x1_channels;
    for (int i = 0; i < 2*out_channels; ++i) {
#pragma HLS PIPELINE II=1
        param_buffer[i] = param_mem[param_offset + i];
    }
#pragma HLS ARRAY_PARTITION variable=weight_buffer complete dim=2
#pragma HLS ARRAY_PARTITION variable=weight_buffer complete dim=3
#pragma HLS ARRAY_PARTITION variable=param_buffer cyclic factor=OC_TILE dim=1
    const int pad = kernel / 2;
    int16_t row_buffer[3][IMG_W+2];
    ap_int<40> accum[OC_TILE][IMG_W];
#pragma HLS ARRAY_PARTITION variable=row_buffer complete dim=1
#pragma HLS ARRAY_PARTITION variable=row_buffer cyclic factor=3 dim=2
#pragma HLS ARRAY_PARTITION variable=accum complete dim=1
#pragma HLS BIND_STORAGE variable=row_buffer type=ram_2p impl=bram
#pragma HLS BIND_STORAGE variable=accum type=ram_t2p impl=bram
    for (int oc0 = 0; oc0 < out_channels; oc0 += OC_TILE) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=16
        for (int ic = 0; ic < in_channels; ++ic) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=96
            for (int ky = 0; ky < kernel; ++ky) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=3
                for (int kx = 0; kx < kernel; ++kx) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=3
                    for (int lane = 0; lane < OC_TILE; ++lane) {
#pragma HLS UNROLL
                        if (oc0 + lane < out_channels) {
                            const int wi = (((oc0 + lane) * in_channels + ic) * kernel + ky) * kernel + kx;
                            weight_buffer[ic][ky * 3 + kx][lane] = weight_mem[weight_offset + wi];
                        }
                    }
                }
            }
        }
        for (int oy = 0; oy < height; ++oy) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=256
            for (int lane = 0; lane < OC_TILE; ++lane) {
#pragma HLS UNROLL
                for (int ox = 0; ox < width; ++ox) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=256
#pragma HLS PIPELINE II=1
                    accum[lane][ox] = 0;
                }
            }
            for (int ic = 0; ic < in_channels; ++ic) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=96
                for (int ky = 0; ky < kernel; ++ky) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=3
                    const int iy = oy + ky - pad;
                    for (int ixbuf = 0; ixbuf < width + 2*pad; ++ixbuf) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=258
#pragma HLS PIPELINE II=1
                        const int ix = ixbuf - pad;
                        int16_t xv = 0;
                        if (iy >= 0 && iy < height && ix >= 0 && ix < width) {
                            if (ic < x0_channels) xv = x0[(ic*height + iy)*width + ix];
                            else xv = x1[((ic-x0_channels)*height + iy)*width + ix];
                        }
                        row_buffer[ky][ixbuf] = xv;
                    }
                }
                for (int ox = 0; ox < width; ++ox) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=256
#pragma HLS PIPELINE II=1
                    for (int lane = 0; lane < OC_TILE; ++lane) {
#pragma HLS UNROLL
                        if (oc0 + lane < out_channels) {
                            ap_int<32> dot = 0;
                            if (kernel == 1) {
                                dot = (ap_int<16>)row_buffer[0][ox] * (ap_int<8>)weight_buffer[ic][0][lane];
                            } else {
                                ap_int<24> p00=(ap_int<16>)row_buffer[0][ox+0]*(ap_int<8>)weight_buffer[ic][0][lane];
                                ap_int<24> p01=(ap_int<16>)row_buffer[0][ox+1]*(ap_int<8>)weight_buffer[ic][1][lane];
                                ap_int<24> p02=(ap_int<16>)row_buffer[0][ox+2]*(ap_int<8>)weight_buffer[ic][2][lane];
                                ap_int<24> p10=(ap_int<16>)row_buffer[1][ox+0]*(ap_int<8>)weight_buffer[ic][3][lane];
                                ap_int<24> p11=(ap_int<16>)row_buffer[1][ox+1]*(ap_int<8>)weight_buffer[ic][4][lane];
                                ap_int<24> p12=(ap_int<16>)row_buffer[1][ox+2]*(ap_int<8>)weight_buffer[ic][5][lane];
                                ap_int<24> p20=(ap_int<16>)row_buffer[2][ox+0]*(ap_int<8>)weight_buffer[ic][6][lane];
                                ap_int<24> p21=(ap_int<16>)row_buffer[2][ox+1]*(ap_int<8>)weight_buffer[ic][7][lane];
                                ap_int<24> p22=(ap_int<16>)row_buffer[2][ox+2]*(ap_int<8>)weight_buffer[ic][8][lane];
                                dot = (p00+p01+p02) + (p10+p11+p12) + (p20+p21+p22);
                            }
                            accum[lane][ox] += dot;
                        }
                    }
                }
            }
            for (int ox = 0; ox < width; ++ox) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=256
#pragma HLS PIPELINE II=1
                for (int lane = 0; lane < OC_TILE; ++lane) {
#pragma HLS UNROLL
                    if (oc0 + lane < out_channels) {
                        const int pi = 2*(oc0+lane);
                        ap_int<72> product = accum[lane][ox] * (ap_int<32>)param_buffer[pi];
                        ap_int<72> rounded;
                        if (product >= 0) rounded = (product + (1 << 19)) >> 20;
                        else rounded = -(((-product) + (1 << 19)) >> 20);
                        ap_int<48> value = rounded + (ap_int<32>)param_buffer[pi+1];
                        if (relu && value < 0) value = 0;
                        if (value > 32767) value = 32767;
                        if (value < -32768) value = -32768;
                        y[((oc0+lane)*height+oy)*width+ox] = (int16_t)value;
                    }
                }
            }
        }
    }
}
static void maxpool2_q12(const int16_t *in, int16_t *out, int channels, int h, int w) {
#pragma HLS INLINE off
    const int oh = h / 2, ow = w / 2;
    for (int c = 0; c < channels; ++c) {
        for (int y = 0; y < oh; ++y) {
            for (int x = 0; x < ow; ++x) {
#pragma HLS PIPELINE II=1
                int16_t a = in[(c*h + 2*y)*w + 2*x];
                int16_t b = in[(c*h + 2*y)*w + 2*x + 1];
                int16_t d = in[(c*h + (2*y+1))*w + 2*x];
                int16_t e = in[(c*h + (2*y+1))*w + 2*x + 1];
                int16_t m = a > b ? a : b;
                m = m > d ? m : d;
                m = m > e ? m : e;
                out[(c*oh + y)*ow + x] = m;
            }
        }
    }
}

static void upsample2_bilinear_q12(const int16_t *in, int16_t *out, int channels, int h, int w) {
#pragma HLS INLINE off
    const int oh = h * 2, ow = w * 2;
    for (int c = 0; c < channels; ++c) {
        for (int y = 0; y < oh; ++y) {
            int y0, y1, fy;
            if (y == 0) { y0 = 0; y1 = 0; fy = 0; }
            else if ((y & 1) != 0) { y0 = y/2; y1 = y0+1; fy = 1; }
            else { y0 = y/2-1; y1 = y/2; fy = 3; }
            if (y1 >= h) y1 = h-1;
            for (int x = 0; x < ow; ++x) {
#pragma HLS PIPELINE II=1
                int x0, x1, fx;
                if (x == 0) { x0 = 0; x1 = 0; fx = 0; }
                else if ((x & 1) != 0) { x0 = x/2; x1 = x0+1; fx = 1; }
                else { x0 = x/2-1; x1 = x/2; fx = 3; }
                if (x1 >= w) x1 = w-1;
                int32_t v00 = in[(c*h+y0)*w+x0];
                int32_t v01 = in[(c*h+y0)*w+x1];
                int32_t v10 = in[(c*h+y1)*w+x0];
                int32_t v11 = in[(c*h+y1)*w+x1];
                int32_t total = v00*(4-fx)*(4-fy) + v01*fx*(4-fy)
                              + v10*(4-fx)*fy + v11*fx*fy;
                out[(c*oh+y)*ow+x] = (int16_t)((total + 8) >> 4);
            }
        }
    }
}

static uint8_t argmax_label(const int16_t *logits, int pixel) {
#pragma HLS INLINE
    int16_t best = logits[pixel];
    uint8_t label = 0;
    for (int c = 1; c < 5; ++c) {
#pragma HLS UNROLL
        int16_t v = logits[c*IMG_PIXELS + pixel];
        if (v > best) { best = v; label = (uint8_t)c; }
    }
    return label;
}

static void load_label_row(const int16_t *logits, int y, uint8_t row[IMG_W]) {
#pragma HLS INLINE off
    for (int x = 0; x < IMG_W; ++x) {
#pragma HLS PIPELINE II=1
        row[x] = (y < 0 || y >= IMG_H) ? 0 : argmax_label(logits, y*IMG_W+x);
    }
}

static void stream_labels_and_contours(const int16_t *logits,
                                       hls::stream<axis_output_t> &out_stream) {
#pragma HLS INLINE off
    uint8_t rows[3][IMG_W];
#pragma HLS ARRAY_PARTITION variable=rows complete dim=1
#pragma HLS BIND_STORAGE variable=rows type=ram_2p impl=bram
    for (int x = 0; x < IMG_W; ++x) {
#pragma HLS PIPELINE II=1
        rows[2][x] = 0;
    }
    load_label_row(logits, 0, rows[0]);
    load_label_row(logits, 1, rows[1]);
    int prev = 2, cur = 0, next = 1;
    for (int y = 0; y < IMG_H; ++y) {
#pragma HLS LOOP_TRIPCOUNT min=256 max=256
        for (int x = 0; x < IMG_W; ++x) {
#pragma HLS PIPELINE II=1
            const uint8_t label = rows[cur][x];
            ap_uint<8> side = 0;
            for (int c = 1; c < 5; ++c) {
#pragma HLS UNROLL
                const bool mask = label == c;
                const uint8_t left = x > 0 ? rows[cur][x-1] : 0;
                const uint8_t right = x+1 < IMG_W ? rows[cur][x+1] : 0;
                const bool boundary = mask &&
                    (x == 0 || x == IMG_W-1 || rows[prev][x] != c ||
                     rows[next][x] != c || left != c || right != c);
                side[c-1] = mask;
                side[c+3] = boundary;
            }
            axis_output_t token;
            token.data = label;
            token.keep = -1;
            token.strb = -1;
            token.user = side;
            token.last = (y == IMG_H-1 && x == IMG_W-1);


            out_stream.write(token);
        }
        const int old_prev = prev;
        prev = cur; cur = next; next = old_prev;
        load_label_row(logits, y+2, rows[next]);
    }
}
void unet_infer(hls::stream<axis_input_t> &input_stream,
                hls::stream<axis_output_t> &output_stream,
                const int8_t weights[WEIGHT_BYTES],
                const int32_t params[PARAM_I32_COUNT],
                int16_t workspace[WS_ELEMENTS]) {
#pragma HLS INTERFACE axis port=input_stream
#pragma HLS INTERFACE axis port=output_stream
#pragma HLS INTERFACE m_axi port=weights   offset=slave bundle=gmem1 depth=WEIGHT_BYTES
#pragma HLS INTERFACE m_axi port=params    offset=slave bundle=gmem2 depth=PARAM_I32_COUNT
#pragma HLS INTERFACE m_axi port=workspace offset=slave bundle=gmem3 depth=WS_ELEMENTS
#pragma HLS INTERFACE s_axilite port=weights   bundle=control
#pragma HLS INTERFACE s_axilite port=params    bundle=control
#pragma HLS INTERFACE s_axilite port=workspace bundle=control
#pragma HLS INTERFACE s_axilite port=return    bundle=control
#pragma HLS ALLOCATION function instances=conv2d_q8 limit=1
    int8_t weight_buffer[MAX_IN_CHANNELS][9][OC_TILE];
    int32_t param_buffer[2*MAX_OUT_CHANNELS];
#pragma HLS BIND_STORAGE variable=weight_buffer type=ram_2p impl=bram
#pragma HLS BIND_STORAGE variable=param_buffer type=ram_2p impl=bram

    bool frame_end_seen = false;
    for (int p = 0; p < IMG_PIXELS; ++p) {
#pragma HLS LOOP_TRIPCOUNT min=65536 max=65536
        int32_t pixel = 0;
        if (!frame_end_seen) {
            axis_input_t token = input_stream.read();
            pixel = (int32_t)token.data;
            if (token.last) frame_end_seen = true;
        }
        workspace[WS_IN_Q+p] = (int16_t)((pixel*4096 + 127) / 255);
    }
    conv2d_q8(workspace+WS_IN_Q, 0, workspace+WS_E1A, weights, params, 1,0,8,256,256,3,W_E1A,P_E1A,1,weight_buffer,param_buffer);
    conv2d_q8(workspace+WS_E1A, 0, workspace+WS_E1B, weights, params, 8,0,8,256,256,3,W_E1B,P_E1B,1,weight_buffer,param_buffer);
    maxpool2_q12(workspace+WS_E1B, workspace+WS_POOL_A, 8,256,256);
    conv2d_q8(workspace+WS_POOL_A, 0, workspace+WS_E2A, weights, params, 8,0,16,128,128,3,W_E2A,P_E2A,1,weight_buffer,param_buffer);
    conv2d_q8(workspace+WS_E2A, 0, workspace+WS_E2B, weights, params, 16,0,16,128,128,3,W_E2B,P_E2B,1,weight_buffer,param_buffer);
    maxpool2_q12(workspace+WS_E2B, workspace+WS_POOL_B, 16,128,128);
    conv2d_q8(workspace+WS_POOL_B, 0, workspace+WS_E3A, weights, params, 16,0,32,64,64,3,W_E3A,P_E3A,1,weight_buffer,param_buffer);
    conv2d_q8(workspace+WS_E3A, 0, workspace+WS_E3B, weights, params, 32,0,32,64,64,3,W_E3B,P_E3B,1,weight_buffer,param_buffer);
    maxpool2_q12(workspace+WS_E3B, workspace+WS_POOL_C, 32,64,64);
    conv2d_q8(workspace+WS_POOL_C, 0, workspace+WS_E4A, weights, params, 32,0,64,32,32,3,W_E4A,P_E4A,1,weight_buffer,param_buffer);
    conv2d_q8(workspace+WS_E4A, 0, workspace+WS_E4B, weights, params, 64,0,64,32,32,3,W_E4B,P_E4B,1,weight_buffer,param_buffer);

    upsample2_bilinear_q12(workspace+WS_E4B, workspace+WS_UP3,64,32,32);
    conv2d_q8(workspace+WS_UP3, workspace+WS_E3B, workspace+WS_D3A, weights, params,64,32,32,64,64,3,W_D3A,P_D3A,1,weight_buffer,param_buffer);
    conv2d_q8(workspace+WS_D3A, 0, workspace+WS_D3B, weights, params,32,0,32,64,64,3,W_D3B,P_D3B,1,weight_buffer,param_buffer);

    upsample2_bilinear_q12(workspace+WS_D3B, workspace+WS_UP2,32,64,64);
    conv2d_q8(workspace+WS_UP2, workspace+WS_E2B, workspace+WS_D2A, weights, params,32,16,16,128,128,3,W_D2A,P_D2A,1,weight_buffer,param_buffer);
    conv2d_q8(workspace+WS_D2A, 0, workspace+WS_D2B, weights, params,16,0,16,128,128,3,W_D2B,P_D2B,1,weight_buffer,param_buffer);

    upsample2_bilinear_q12(workspace+WS_D2B, workspace+WS_UP1,16,128,128);
    conv2d_q8(workspace+WS_UP1, workspace+WS_E1B, workspace+WS_D1A, weights, params,16,8,8,256,256,3,W_D1A,P_D1A,1,weight_buffer,param_buffer);
    conv2d_q8(workspace+WS_D1A, 0, workspace+WS_D1B, weights, params,8,0,8,256,256,3,W_D1B,P_D1B,1,weight_buffer,param_buffer);
    conv2d_q8(workspace+WS_D1B, 0, workspace+WS_LOGITS, weights, params,8,0,5,256,256,1,W_HEAD,P_HEAD,0,weight_buffer,param_buffer);
    stream_labels_and_contours(workspace+WS_LOGITS, output_stream);
}




