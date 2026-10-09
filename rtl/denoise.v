`timescale 1 ns / 1 ps

module denoise (
    input  wire       ap_clk,
    input  wire       ap_rst,
    input  wire [7:0] in_data,
    input  wire       in_valid,
    input  wire       in_last,
    input  wire       out_ready,
    output reg  [7:0] out_data,
    output reg        out_valid,
    output reg        out_last,
    output wire       in_ready
);

    localparam integer IMG_W = 256;
    localparam integer FRAME_PIXELS = IMG_W * IMG_W;
    localparam integer LATENCY = IMG_W + 1;
    localparam integer TAIL_START = FRAME_PIXELS - LATENCY;

    reg [7:0] pixel_buf [0:514];
    reg [7:0] tail_buf  [0:256];

    reg [9:0]  wr_ptr;
    reg [16:0] pixel_idx;
    reg [8:0]  flush_idx;
    reg        flush_active;

    assign in_ready = !flush_active && (!out_valid || out_ready);

    function [9:0] addr_back;
        input [9:0] ptr;
        input integer distance;
        integer tmp;
        begin
            tmp = ptr - distance;
            if (tmp < 0)
                tmp = tmp + 515;
            addr_back = tmp[9:0];
        end
    endfunction

    wire [9:0] r514 = addr_back(wr_ptr, 514);
    wire [9:0] r513 = addr_back(wr_ptr, 513);
    wire [9:0] r512 = addr_back(wr_ptr, 512);
    wire [9:0] r258 = addr_back(wr_ptr, 258);
    wire [9:0] r257 = addr_back(wr_ptr, 257);
    wire [9:0] r256 = addr_back(wr_ptr, 256);
    wire [9:0] r2   = addr_back(wr_ptr, 2);
    wire [9:0] r1   = addr_back(wr_ptr, 1);

    wire [15:0] center_idx = pixel_idx[15:0] - LATENCY;
    wire center_is_interior =
        center_idx[15:8] >= 8'd1 && center_idx[15:8] <= 8'd254 &&
        center_idx[7:0]  >= 8'd1 && center_idx[7:0]  <= 8'd254;

    wire [11:0] weighted_sum =
          {4'd0, pixel_buf[r514]}              // 上左 权1
        + ({4'd0, pixel_buf[r513]} << 1)       // 上中 权2
        + {4'd0, pixel_buf[r512]}              // 上右 权1
        + ({4'd0, pixel_buf[r258]} << 1)       // 中左 权2
        + ({4'd0, pixel_buf[r257]} << 2)       // 中中 权4
        + ({4'd0, pixel_buf[r256]} << 1)       // 中右 权2
        + {4'd0, pixel_buf[r2]}                // 下左 权1  ← 原来错写成 <<1
        + ({4'd0, pixel_buf[r1]} << 1)         // 下中 权2
        + {4'd0, in_data};                     // 下右 权1

    always @(posedge ap_clk) begin
        if (ap_rst) begin
            wr_ptr      <= 10'd0;
            pixel_idx   <= 17'd0;
            flush_idx   <= 9'd0;
            flush_active<= 1'b0;
            out_data    <= 8'd0;
            out_valid   <= 1'b0;
            out_last    <= 1'b0;
        end else begin
            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
                out_last  <= 1'b0;
            end

            if (flush_active) begin
                if (!out_valid || out_ready) begin
                    out_data  <= tail_buf[flush_idx];
                    out_valid <= 1'b1;
                    out_last  <= (flush_idx == 9'd256);
                    if (flush_idx == 9'd256) begin
                        flush_active <= 1'b0;
                    end else begin
                        flush_idx <= flush_idx + 1'b1;
                    end
                end
            end else if (in_valid && in_ready) begin
                if (pixel_idx >= LATENCY) begin
                    if (center_is_interior)
                        out_data <= weighted_sum[11:4];
                    else
                        out_data <= pixel_buf[r257];
                    out_valid <= 1'b1;
                    out_last  <= 1'b0;
                end

                pixel_buf[wr_ptr] <= in_data;
                if (pixel_idx >= TAIL_START && pixel_idx < FRAME_PIXELS)
                    tail_buf[pixel_idx - TAIL_START] <= in_data;

                if (wr_ptr == 10'd514)
                    wr_ptr <= 10'd0;
                else
                    wr_ptr <= wr_ptr + 1'b1;

                if (in_last) begin
                    pixel_idx <= 17'd0;
                    wr_ptr    <= 10'd0;
                    flush_idx <= 9'd0;
                    flush_active <= 1'b1;
                end else if (pixel_idx < FRAME_PIXELS) begin
                    pixel_idx <= pixel_idx + 1'b1;
                end
            end
        end
    end

endmodule
