`timescale 1ns / 1ps

// One little-endian RGBA pixel per beat, from the independent frame-store reader.
// All ports belong to clk. Completion is the final AXI handshake.
module back_stream #(
    parameter integer FRAME_PIXELS = 256 * 256,
    parameter integer FIFO_DEPTH = 2048
)(
    input wire clk, input wire rst,
    input wire sof, input wire valid,
    input wire [7:0] R, input wire [7:0] G, input wire [7:0] B,
    input wire [31:0] video_mode,
    output reg [31:0] tdata,
    output reg tvalid, input wire tready,
    output wire [3:0] tkeep,
    output reg tlast, output reg tuser,
    output wire back_en, output wire busy,
    output wire source_ready,
    output reg [7:0] frame_mode,
    output reg frame_sent, output reg overflow
);
    localparam integer PTR_W = $clog2(FIFO_DEPTH);
    localparam integer PIX_W = FRAME_PIXELS < 2 ? 1 : $clog2(FRAME_PIXELS);
    localparam [2:0] IDLE=0, CAPTURE=1, PUSH_TAIL=2, DRAIN=3;
    reg [2:0] state;
    reg [PIX_W-1:0] pixel_count;

    // Synchronous BRAM FIFO plus a separate AXI output register.
    // Store {TLAST,TUSER,Alpha,B,G,R}; memory bytes are R,G,B,255.
    (* ram_style = "block" *) reg [33:0] fifo [0:FIFO_DEPTH-1];
    reg [PTR_W-1:0] write_ptr, read_ptr;
    reg [PTR_W:0] count;
    reg [33:0] pending_tail;
    wire fifo_pop = (!tvalid || tready) && count != 0;
    wire fifo_space = count < FIFO_DEPTH || fifo_pop;
    wire capture = state == CAPTURE || (state == IDLE && sof);
    wire [PIX_W-1:0] index = state == IDLE ? {PIX_W{1'b0}} : pixel_count;
    wire last_pixel = index == FRAME_PIXELS-1;
    wire [33:0] incoming = {last_pixel, (index == 0), 8'hff, B, G, R};
    wire source_write = capture && valid;
    wire fifo_push = fifo_space && (source_write || state == PUSH_TAIL);
    wire [33:0] push_data = state == PUSH_TAIL ? pending_tail : incoming;

    assign tkeep = 4'hf;
    assign back_en = state == CAPTURE;
    assign busy = state != IDLE;
    // Reserve eight slots for RAM + out_arr + capture pipeline latency. Only
    // read requests pause; already formatted pixels must still enter this FIFO.
    assign source_ready = count < FIFO_DEPTH - 8;

    // Hold the entire output tuple stable whenever TVALID && !TREADY.
    always @(posedge clk) begin
        if (rst) begin
            write_ptr <= 0; read_ptr <= 0; count <= 0;
            tdata <= 0; tvalid <= 0; tlast <= 0; tuser <= 0;
        end else begin
            if (fifo_push) begin
                fifo[write_ptr] <= push_data;
                write_ptr <= write_ptr + 1'b1;
            end
            if (fifo_pop) read_ptr <= read_ptr + 1'b1;
            case ({fifo_push, fifo_pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
            if (!tvalid || tready) begin
                tvalid <= fifo_pop;
                if (fifo_pop) {tlast, tuser, tdata} <= fifo[read_ptr];
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE; pixel_count <= 0; frame_mode <= 0;
            pending_tail <= 0; frame_sent <= 0; overflow <= 0;
        end else begin
            frame_sent <= 0;
            if (state == IDLE && sof) begin
                state <= CAPTURE;
                frame_mode <= video_mode[7:0];
                pixel_count <= 0;
                overflow <= 0;
            end
            if (source_write) begin
                if (!fifo_space) begin
                    // Defensive fault path if a producer ignores source_ready.
                    // Preserve this pixel as a terminal beat,
                    // stop capture and mark this packet short if pixels are lost.
                    // Future PS code MUST reject lengths other than FRAME_PIXELS*4.
                    // A previously asserted AXI beat is never changed or withdrawn.
                    pending_tail <= {1'b1, (index == 0), 8'hff, B, G, R};
                    overflow <= !last_pixel;
                    state <= PUSH_TAIL;
                end else if (last_pixel) begin
                    state <= DRAIN;
                end else begin
                    pixel_count <= index + 1'b1;
                end
            end
            if (state == PUSH_TAIL && fifo_space) state <= DRAIN;
            if (state == DRAIN && tvalid && tready && tlast) begin
                frame_sent <= 1;
                state <= IDLE;
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH-1)) != 0)
            $fatal(1, "back_stream: FIFO_DEPTH must be a power of two >= 2");
        if (FRAME_PIXELS < 1) $fatal(1, "back_stream: FRAME_PIXELS must be >= 1");
    end
    // synthesis translate_on
endmodule
