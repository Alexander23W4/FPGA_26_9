`timescale 1ns / 1ps
// AXI4-Lite register slice for the medical accelerator.
//
// The address map deliberately continues the teammate repository's WORD-index
// convention used by rtl/thresholder/axi_lite_slave.v and pl_cmd.h:
//   byte address = BASE + (WORD_INDEX << 2)
// Existing registers occupy 0x00..0x36; this block uses 0x40..0x4F.
// For a second AXI-Lite slave, BASE is normally 0x44010000.
module medical_axi_lite (
    input  wire        clk,
    input  wire        rst,
    input  wire [8:0]  awaddr,
    input  wire        awvalid,
    output wire        awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output wire        wready,
    output reg  [1:0]  bresp,
    output reg         bvalid,
    input  wire        bready,
    input  wire [8:0]  araddr,
    input  wire        arvalid,
    output wire        arready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp,
    output reg         rvalid,
    input  wire        rready,

    output reg  [31:0] ctrl_out,
    input  wire [31:0] med_status,
    input  wire signed [15:0] reg_dx,
    input  wire signed [15:0] reg_dy,
    input  wire [31:0] reg_sad,
    input  wire [23:0] area_px,
    input  wire [15:0] length_px,
    input  wire [63:0] edv_q16,
    input  wire [63:0] esv_q16,
    input  wire signed [63:0] strain_q16,
    input  wire [31:0] ed_frame,
    input  wire [31:0] es_frame,
    input  wire [31:0] frame_id
);
    localparam [6:0] ADDR_MED_CTRL  = 7'h40;
    localparam [6:0] ADDR_MED_STATUS= 7'h41;
    localparam [6:0] ADDR_DX        = 7'h42;
    localparam [6:0] ADDR_DY        = 7'h43;
    localparam [6:0] ADDR_SAD       = 7'h44;
    localparam [6:0] ADDR_AREA      = 7'h45;
    localparam [6:0] ADDR_LENGTH    = 7'h46;
    localparam [6:0] ADDR_EDV_LO    = 7'h47;
    localparam [6:0] ADDR_EDV_HI    = 7'h48;
    localparam [6:0] ADDR_ESV_LO    = 7'h49;
    localparam [6:0] ADDR_ESV_HI    = 7'h4A;
    localparam [6:0] ADDR_STRAIN_LO = 7'h4B;
    localparam [6:0] ADDR_STRAIN_HI = 7'h4C;
    localparam [6:0] ADDR_ED_FRAME  = 7'h4D;
    localparam [6:0] ADDR_ES_FRAME  = 7'h4E;
    localparam [6:0] ADDR_FRAME_ID  = 7'h4F;

    reg aw_pending, w_pending;
    reg [31:0] aw_saved, w_saved;
    reg [3:0] strb_saved;

    wire aw_take = awvalid && awready;
    wire w_take  = wvalid && wready;
    wire [31:0] write_addr = aw_pending ? aw_saved : {23'd0, awaddr};
    wire [31:0] write_data = w_pending ? w_saved : wdata;
    wire [3:0]  write_strb = w_pending ? strb_saved : wstrb;
    wire write_commit = !bvalid && (aw_pending || aw_take) && (w_pending || w_take);

    function [31:0] merge_bytes;
        input [31:0] previous, data;
        input [3:0] strb;
        integer lane;
        begin
            merge_bytes = previous;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (strb[lane]) merge_bytes[lane*8 +: 8] = data[lane*8 +: 8];
        end
    endfunction

    assign awready = !aw_pending && !bvalid;
    assign wready  = !w_pending && !bvalid;
    assign arready = !rvalid;

    always @(posedge clk) begin
        if (rst) begin
            aw_pending <= 1'b0;
            w_pending  <= 1'b0;
            aw_saved   <= 32'd0;
            w_saved    <= 32'd0;
            strb_saved <= 4'd0;
            bresp      <= 2'b00;
            bvalid     <= 1'b0;
            ctrl_out   <= 32'd0;
        end else begin
            if (aw_take) begin aw_saved <= {23'd0, awaddr}; aw_pending <= 1'b1; end
            if (w_take) begin w_saved <= wdata; strb_saved <= wstrb; w_pending <= 1'b1; end
            if (bvalid && bready) bvalid <= 1'b0;
            if (write_commit) begin
                aw_pending <= 1'b0;
                w_pending  <= 1'b0;
                bvalid     <= 1'b1;
                bresp      <= 2'b00;
                if (write_addr[1:0] != 2'b00) begin
                    bresp <= 2'b10;
                end else begin
                    case (write_addr[8:2])
                        ADDR_MED_CTRL: ctrl_out <= merge_bytes(ctrl_out, write_data, write_strb);
                        default: bresp <= 2'b10;
                    endcase
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            rdata  <= 32'd0;
            rresp  <= 2'b00;
            rvalid <= 1'b0;
        end else begin
            if (rvalid && rready) rvalid <= 1'b0;
            if (arvalid && arready) begin
                rvalid <= 1'b1;
                rresp  <= 2'b00;
                rdata  <= 32'd0;
                if (araddr[1:0] != 2'b00) begin
                    rresp <= 2'b10;
                end else begin
                    case (araddr[8:2])
                        ADDR_MED_CTRL:   rdata <= ctrl_out;
                        ADDR_MED_STATUS: rdata <= med_status;
                        ADDR_DX:         rdata <= {{16{reg_dx[15]}}, reg_dx};
                        ADDR_DY:         rdata <= {{16{reg_dy[15]}}, reg_dy};
                        ADDR_SAD:        rdata <= reg_sad;
                        ADDR_AREA:       rdata <= {8'd0, area_px};
                        ADDR_LENGTH:     rdata <= {16'd0, length_px};
                        ADDR_EDV_LO:     rdata <= edv_q16[31:0];
                        ADDR_EDV_HI:     rdata <= edv_q16[63:32];
                        ADDR_ESV_LO:     rdata <= esv_q16[31:0];
                        ADDR_ESV_HI:     rdata <= esv_q16[63:32];
                        ADDR_STRAIN_LO:  rdata <= strain_q16[31:0];
                        ADDR_STRAIN_HI:  rdata <= strain_q16[63:32];
                        ADDR_ED_FRAME:   rdata <= ed_frame;
                        ADDR_ES_FRAME:   rdata <= es_frame;
                        ADDR_FRAME_ID:   rdata <= frame_id;
                        default: rresp <= 2'b10;
                    endcase
                end
            end
        end
    end
endmodule


