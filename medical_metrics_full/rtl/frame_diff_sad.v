`timescale 1ns / 1ps
// Streaming SAD core for one candidate translation.
// Reference and candidate memories are synchronous: addresses are presented in
// FETCH, and the returned data are consumed one cycle later in ACC.
module frame_diff_sad #(
    parameter integer ADDR_W = 16,
    parameter integer DATA_W = 8
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 start,
    input  wire [ADDR_W-1:0]    ref_base,
    input  wire [ADDR_W-1:0]    cur_base,
    input  wire [15:0]          frame_w,
    input  wire [15:0]          roi_w,
    input  wire [15:0]          roi_h,
    output reg  [ADDR_W-1:0]    ref_addr,
    output reg  [ADDR_W-1:0]    cur_addr,
    input  wire [DATA_W-1:0]    ref_data,
    input  wire [DATA_W-1:0]    cur_data,
    output reg                  busy,
    output reg                  done,
    output reg  [31:0]          sad
);
    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] FETCH = 2'd1;
    localparam [1:0] ACC   = 2'd2;

    reg [1:0]  state;
    reg [15:0] x, y;
    reg [15:0] frame_w_r, roi_w_r, roi_h_r;
    reg [ADDR_W-1:0] ref_base_r, cur_base_r;
    reg [31:0] acc;
    wire [31:0] diff = (ref_data > cur_data)
                     ? (ref_data - cur_data)
                     : (cur_data - ref_data);

    always @(posedge clk) begin
        if (rst) begin
            state      <= IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            sad        <= 32'd0;
            acc        <= 32'd0;
            x          <= 16'd0;
            y          <= 16'd0;
            ref_addr   <= {ADDR_W{1'b0}};
            cur_addr   <= {ADDR_W{1'b0}};
            frame_w_r  <= 16'd1;
            roi_w_r    <= 16'd1;
            roi_h_r    <= 16'd1;
            ref_base_r <= {ADDR_W{1'b0}};
            cur_base_r <= {ADDR_W{1'b0}};
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        frame_w_r  <= frame_w;
                        roi_w_r    <= roi_w;
                        roi_h_r    <= roi_h;
                        ref_base_r <= ref_base;
                        cur_base_r <= cur_base;
                        x          <= 16'd0;
                        y          <= 16'd0;
                        acc        <= 32'd0;
                        ref_addr   <= ref_base;
                        cur_addr   <= cur_base;
                        busy       <= 1'b1;
                        state      <= FETCH;
                    end
                end
                FETCH: begin
                    // The synchronous RAM samples the addresses on this edge.
                    state <= ACC;
                end
                ACC: begin
                    acc <= acc + diff;
                    if (x + 16'd1 < roi_w_r) begin
                        x        <= x + 16'd1;
                        ref_addr <= ref_base_r + (y * frame_w_r) + (x + 16'd1);
                        cur_addr <= cur_base_r + (y * frame_w_r) + (x + 16'd1);
                        state    <= FETCH;
                    end else if (y + 16'd1 < roi_h_r) begin
                        x        <= 16'd0;
                        y        <= y + 16'd1;
                        ref_addr <= ref_base_r + ((y + 16'd1) * frame_w_r);
                        cur_addr <= cur_base_r + ((y + 16'd1) * frame_w_r);
                        state    <= FETCH;
                    end else begin
                        sad   <= acc + diff;
                        done  <= 1'b1;
                        busy  <= 1'b0;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
