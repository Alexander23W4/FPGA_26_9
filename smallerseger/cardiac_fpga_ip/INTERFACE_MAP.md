# Cardiac U-Net FPGA stream interface

Target device: `xc7z015clg485-2`. Pixel size remains 256 x 256, one 8-bit grayscale pixel per accepted input beat.

## External stream interface

| Signal | Direction | Meaning |
|---|---|---|
| `clk` | input | External 20 MHz clock |
| `rst` | input | Active-high reset |
| `in_valid` / `in_ready` | in / out | Input AXI-Stream handshake; a pixel is consumed when both are high |
| `in_data[7:0]` | input | Grayscale pixel; frame is 65,536 pixels in raster order |
| `in_eof` | input | End-of-frame marker (AXI TLAST) |
| `out_valid` / `out_ready` | out / in | Output handshake; result beat advances when both are high |
| `out_data[7:0]` | output | Predicted class id, 0 background and 1-4 chambers |
| `out_eof` | output | End-of-frame marker (AXI TLAST) |
| `LA_mask`, `RA_mask`, `LV_mask`, `RV_mask` | output | Per-pixel one-hot chamber masks in output TUSER[3:0] |
| `LA_ctr`, `RA_ctr`, `LV_ctr`, `RV_ctr` | output | Per-pixel 4-connected contour flags in output TUSER[7:4] |

## Memory-mapped connections

The HLS IP additionally has AXI master interfaces for runtime weights, quantization parameters, and workspace, plus an AXI-Lite control/status interface. The Vivado block design routes these through the Zynq PS/DDR. The workspace is about 11.94 MiB, so this design uses external DDR; it is not a standalone fabric-only accelerator.

## Framing notes

Input and output use ready/valid backpressure. Input is expected to contain exactly 256 x 256 pixels. The HLS implementation pads remaining pixels with zero if TLAST is asserted early; use one frame per invocation. Output class byte and mask/contour sideband are aligned beat-by-beat.

## Current validation boundary

Block-design validation, HLS packaging, and Vivado synthesis are software-tool checks. No FPGA board bitstream, timing closure after place-and-route, or live hardware inference has been validated yet.
