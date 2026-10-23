`timescale 1ns / 1ps
// Frame registration with a ready/valid pixel output. Two raw-frame RAM banks
// exchange roles; no full-frame copy is required. Receive of frame N+1 overlaps
// aligned output of N, but search waits until the output RAM reader is idle.
// Relative integer offsets can accumulate into the first frame's coordinates.
module registration_top #(
    parameter integer FRAME_W=256, FRAME_H=256, ROI_W=48, ROI_H=48,
    parameter integer SEARCH_R=8, ADDR_W=16, DATA_W=8,
    parameter integer ACCUMULATE=1
)(
    input wire clk, rst,
    input wire [DATA_W-1:0] in_data,
    input wire in_valid, in_eof,
    output wire in_ready,
    output wire [DATA_W-1:0] out_data,
    output wire out_valid, out_eof,
    input wire out_ready,
    output reg signed [15:0] reg_dx, reg_dy,
    output reg [31:0] reg_sad,
    output reg reg_valid, reg_done,
    output reg [31:0] frame_count,
    output reg frame_error
);
    localparam integer FRAME_PIXELS=FRAME_W*FRAME_H;
    reg write_bank, out_bank, have_prev, frame_full, drop_frame;
    reg [ADDR_W-1:0] wr_addr;
    reg search_start, search_wait;
    wire search_done;
    wire signed [15:0] search_dx, search_dy;
    wire [31:0] search_sad;
    wire [ADDR_W-1:0] search_ref_addr, search_cur_addr;
    wire [DATA_W-1:0] bank0_data, bank1_data;
    reg signed [31:0] accumulated_x, accumulated_y, offset_x, offset_y;

    reg emitting, all_issued;
    reg [15:0] issue_x, issue_y;
    reg pending_valid, pending_zero, pending_eof;
    reg [DATA_W-1:0] fifo_data [0:3];
    reg fifo_eof [0:3];
    reg [1:0] fifo_wr, fifo_rd;
    reg [2:0] fifo_count;
    wire in_fire=in_valid && in_ready;
    wire out_fire=out_valid && out_ready;
    // Reserve space for the synchronous read already in flight as well as the
    // next read. A same-edge consumer handshake frees one credit.
    wire issue=emitting && !all_issued &&
               (({1'b0,fifo_count}+pending_valid)<4 || out_fire);
    wire issue_eof=issue_x==FRAME_W-1 && issue_y==FRAME_H-1;
    wire signed [31:0] source_x=$signed({1'b0,issue_x})+offset_x;
    wire signed [31:0] source_y=$signed({1'b0,issue_y})+offset_y;
    wire source_inside=source_x>=0 && source_x<FRAME_W && source_y>=0 && source_y<FRAME_H;
    wire [ADDR_W-1:0] source_addr=source_inside ? source_y*FRAME_W+source_x : 0;
    wire [ADDR_W-1:0] bank0_addr=search_wait ?
        (write_bank ? search_ref_addr : search_cur_addr) : source_addr;
    wire [ADDR_W-1:0] bank1_addr=search_wait ?
        (write_bank ? search_cur_addr : search_ref_addr) : source_addr;

    assign in_ready=!rst && !frame_full && !search_wait;
    assign out_valid=!rst && fifo_count!=0;
    assign out_data=fifo_data[fifo_rd];
    assign out_eof=out_valid && fifo_eof[fifo_rd];
    sync_ram #(.DEPTH(FRAME_PIXELS),.ADDR_W(ADDR_W),.DATA_W(DATA_W)) u_bank0(
        .clk(clk),.we(in_fire && !drop_frame && !write_bank),
        .waddr(wr_addr),.wdata(in_data),.raddr(bank0_addr),.rdata(bank0_data));
    sync_ram #(.DEPTH(FRAME_PIXELS),.ADDR_W(ADDR_W),.DATA_W(DATA_W)) u_bank1(
        .clk(clk),.we(in_fire && !drop_frame && write_bank),
        .waddr(wr_addr),.wdata(in_data),.raddr(bank1_addr),.rdata(bank1_data));
    registration_search #(.FRAME_W(FRAME_W),.FRAME_H(FRAME_H),
        .ROI_W(ROI_W),.ROI_H(ROI_H),.SEARCH_R(SEARCH_R),.ADDR_W(ADDR_W),.DATA_W(DATA_W)) u_search(
        .clk(clk),.rst(rst),.start(search_start),
        .ref_addr(search_ref_addr),.cur_addr(search_cur_addr),
        .ref_data(write_bank ? bank0_data : bank1_data),
        .cur_data(write_bank ? bank1_data : bank0_data),
        .busy(),.done(search_done),.best_dx(search_dx),.best_dy(search_dy),.best_sad(search_sad));

    always @(posedge clk) begin
        if (rst) begin
            write_bank<=0; out_bank<=0; have_prev<=0; frame_full<=0; drop_frame<=0;
            wr_addr<=0; search_start<=0; search_wait<=0;
            reg_dx<=0; reg_dy<=0; reg_sad<=0; reg_valid<=0; reg_done<=0;
            frame_count<=0; frame_error<=0;
            accumulated_x<=0; accumulated_y<=0; offset_x<=0; offset_y<=0;
            emitting<=0; all_issued<=0; issue_x<=0; issue_y<=0;
            pending_valid<=0; pending_zero<=0; pending_eof<=0;
            fifo_wr<=0; fifo_rd<=0; fifo_count<=0;
        end else begin
            search_start<=0; reg_done<=0;
            if (in_fire) begin
                if (drop_frame) begin
                    if (in_eof) begin drop_frame<=0; wr_addr<=0; end
                end else if (in_eof) begin
                    wr_addr<=0;
                    if (wr_addr==FRAME_PIXELS-1) begin
                        frame_full<=1; frame_count<=frame_count+1'b1;
                    end else frame_error<=1; // discard short frame, preserve reference
                end else if (wr_addr==FRAME_PIXELS-1) begin
                    frame_error<=1; drop_frame<=1; wr_addr<=0;
                end else wr_addr<=wr_addr+1'b1;
            end

            if (frame_full && !emitting && !search_wait) begin
                if (!have_prev) begin
                    // A lone image still produces a complete, unchanged output.
                    have_prev<=1; frame_full<=0; emitting<=1;
                    out_bank<=write_bank; write_bank<=!write_bank;
                    offset_x<=0; offset_y<=0; accumulated_x<=0; accumulated_y<=0;
                    issue_x<=0; issue_y<=0; all_issued<=0;
                end else begin search_start<=1; search_wait<=1; end
            end
            if (search_wait && search_done) begin
                search_wait<=0; frame_full<=0; emitting<=1;
                out_bank<=write_bank; write_bank<=!write_bank;
                reg_dx<=search_dx; reg_dy<=search_dy; reg_sad<=search_sad;
                reg_valid<=1; reg_done<=1;
                accumulated_x<=accumulated_x+search_dx;
                accumulated_y<=accumulated_y+search_dy;
                offset_x<=ACCUMULATE ? accumulated_x+search_dx : search_dx;
                offset_y<=ACCUMULATE ? accumulated_y+search_dy : search_dy;
                issue_x<=0; issue_y<=0; all_issued<=0;
            end

            pending_valid<=issue;
            if (issue) begin
                pending_zero<=!source_inside; pending_eof<=issue_eof;
                if (issue_eof) all_issued<=1;
                else if (issue_x==FRAME_W-1) begin issue_x<=0; issue_y<=issue_y+1'b1; end
                else issue_x<=issue_x+1'b1;
            end
            if (pending_valid) begin
                fifo_data[fifo_wr]<=pending_zero ? {DATA_W{1'b0}} :
                                                   (out_bank ? bank1_data : bank0_data);
                fifo_eof[fifo_wr]<=pending_eof;
                fifo_wr<=fifo_wr+1'b1;
            end
            if (out_fire) begin
                fifo_rd<=fifo_rd+1'b1;
                if (out_eof) emitting<=0;
            end
            case ({pending_valid,out_fire})
                2'b10: fifo_count<=fifo_count+1'b1;
                2'b01: fifo_count<=fifo_count-1'b1;
                default: ;
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if (FRAME_W<=0 || FRAME_H<=0 || FRAME_W>32767 || FRAME_H>32767 ||
            FRAME_PIXELS>2.0**ADDR_W)
            $fatal(1,"registration frame dimensions exceed address capacity");
    end
    // synthesis translate_on
endmodule

