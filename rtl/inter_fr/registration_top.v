`timescale 1ns / 1ps
// Frame-level wrapper for ultrasound consecutive-frame registration.
// First frame is stored but produces no result.  Each later frame is searched
// against the previous frame and the result is held in reg_* until the next
// completed search.
module registration_top #(
    parameter integer FRAME_W  = 256,
    parameter integer FRAME_H  = 256,
    parameter integer ROI_W    = 48,
    parameter integer ROI_H    = 48,
    parameter integer SEARCH_R = 8,
    parameter integer ADDR_W   = 16,
    parameter integer DATA_W   = 8
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire [DATA_W-1:0]    s_axis_tdata,
    input  wire                 s_axis_tvalid,
    output wire                 s_axis_tready,
    input  wire                 s_axis_tlast,
    output reg  signed [15:0]   reg_dx,
    output reg  signed [15:0]   reg_dy,
    output reg  [31:0]          reg_sad,
    output reg                  reg_valid,
    output reg                  reg_done,
    output reg  [31:0]          frame_count
);
    localparam integer FRAME_PIXELS = FRAME_W * FRAME_H;
    localparam [2:0] ST_WRITE  = 3'd0;
    localparam [2:0] ST_COPY_R = 3'd1;
    localparam [2:0] ST_COPY_W = 3'd2;
    localparam [2:0] ST_SEARCH = 3'd3;
    localparam [2:0] ST_WAIT   = 3'd4;

    reg [2:0] state;
    reg [ADDR_W-1:0] wr_addr;
    reg [ADDR_W-1:0] copy_addr;
    reg have_prev;
    reg search_start;

    wire [ADDR_W-1:0] prev_raddr;
    wire [ADDR_W-1:0] curr_raddr;
    wire [DATA_W-1:0] prev_rdata;
    wire [DATA_W-1:0] curr_rdata;
    wire [ADDR_W-1:0] search_ref_addr;
    wire [ADDR_W-1:0] search_cur_addr;
    wire                 cur_we;
    wire [ADDR_W-1:0] curr_waddr;
    wire [DATA_W-1:0] curr_wdata;
    wire prev_we;
    wire [ADDR_W-1:0] prev_waddr;
    wire [DATA_W-1:0] prev_wdata;

    reg signed [15:0] search_dx;
    reg signed [15:0] search_dy;
    reg [31:0] search_sad;
    wire search_done;

    assign s_axis_tready = (state == ST_WRITE);
    assign curr_waddr = wr_addr;
    assign curr_wdata = s_axis_tdata;
    assign cur_we = (state == ST_WRITE) && s_axis_tvalid;
    assign prev_raddr = (state == ST_COPY_R) ? copy_addr : search_ref_addr;
    assign curr_raddr = (state == ST_COPY_R) ? copy_addr : search_cur_addr;
    assign prev_we = (state == ST_COPY_W);
    assign prev_waddr = copy_addr;
    assign prev_wdata = curr_rdata;

    sync_ram #(.DEPTH(FRAME_PIXELS), .ADDR_W(ADDR_W), .DATA_W(DATA_W)) u_prev_ram (
        .clk(clk), .we(prev_we), .waddr(prev_waddr), .wdata(prev_wdata),
        .raddr(prev_raddr), .rdata(prev_rdata)
    );

    sync_ram #(.DEPTH(FRAME_PIXELS), .ADDR_W(ADDR_W), .DATA_W(DATA_W)) u_curr_ram (
        .clk(clk), .we(cur_we), .waddr(curr_waddr), .wdata(curr_wdata),
        .raddr(curr_raddr), .rdata(curr_rdata)
    );

    registration_search #(
        .FRAME_W(FRAME_W),
        .FRAME_H(FRAME_H),
        .ROI_W(ROI_W),
        .ROI_H(ROI_H),
        .SEARCH_R(SEARCH_R),
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W)
    ) u_search (
        .clk(clk), .rst(rst), .start(search_start),
        .ref_addr(search_ref_addr), .cur_addr(search_cur_addr),
        .ref_data(prev_rdata), .cur_data(curr_rdata),
        .busy(), .done(search_done),
        .best_dx(search_dx), .best_dy(search_dy), .best_sad(search_sad)
    );

    always @(posedge clk) begin
        if (rst) begin
            state       <= ST_WRITE;
            wr_addr     <= {ADDR_W{1'b0}};
            copy_addr   <= {ADDR_W{1'b0}};
            have_prev   <= 1'b0;
            search_start<= 1'b0;
            reg_dx      <= 16'sd0;
            reg_dy      <= 16'sd0;
            reg_sad     <= 32'd0;
            reg_valid   <= 1'b0;
            reg_done    <= 1'b0;
            frame_count <= 32'd0;
        end else begin
            reg_done    <= 1'b0;
            search_start<= 1'b0;
            case (state)
                ST_WRITE: begin
                    if (s_axis_tvalid) begin
                        if (s_axis_tlast) begin
                            frame_count <= frame_count + 32'd1;
                            wr_addr <= {ADDR_W{1'b0}};
                            copy_addr <= {ADDR_W{1'b0}};
                            state <= have_prev ? ST_SEARCH : ST_COPY_R;
                        end else begin
                            wr_addr <= wr_addr + 1'b1;
                        end
                    end
                end
                ST_COPY_R: begin
                    state <= ST_COPY_W;
                end
                ST_COPY_W: begin
                    if (copy_addr == FRAME_PIXELS-1) begin
                        copy_addr <= {ADDR_W{1'b0}};
                        have_prev <= 1'b1;
                        state <= ST_WRITE;
                    end else begin
                        copy_addr <= copy_addr + 1'b1;
                        state <= ST_COPY_R;
                    end
                end
                ST_SEARCH: begin
                    search_start <= 1'b1;
                    state <= ST_WAIT;
                end
                ST_WAIT: begin
                    if (search_done) begin
                        reg_dx    <= search_dx;
                        reg_dy    <= search_dy;
                        reg_sad   <= search_sad;
                        reg_valid <= 1'b1;
                        reg_done  <= 1'b1;
                        copy_addr <= {ADDR_W{1'b0}};
                        state     <= ST_COPY_R;
                    end
                end
                default: state <= ST_WRITE;
            endcase
        end
    end
endmodule

