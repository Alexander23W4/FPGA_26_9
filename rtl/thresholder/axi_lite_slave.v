`timescale 1ns / 1ps

// Register numbers match config/pl_cmd.h. AXI carries BYTE addresses:
// MODE=0x00, CMD=0x04, VIDEO=0x08, STATUS=0x0c,
// DATA=0x80, AREA=0x84, MASK_TRANSP=0x88, BACK_RECEIVE=0xc0 (number << 2).
module axi_lite_slave (
    input wire s_axi_aclk, input wire s_axi_aresetn,
    input wire [31:0] s_axi_awaddr, input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [31:0] s_axi_wdata, input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid, output wire s_axi_wready,
    output reg [1:0] s_axi_bresp, output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [31:0] s_axi_araddr, input wire s_axi_arvalid,
    output wire s_axi_arready,
    output reg [31:0] s_axi_rdata, output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid, input wire s_axi_rready,

    output reg [31:0] reg_mode, output reg [31:0] reg_cmd,
    output reg [7:0] reg_threshold, output reg host_wr_en,
    input wire [31:0] status_in,
    output reg [31:0] reg_video_mode,
    input wire [16:0] lesion_pixels,
    output reg [31:0] reg_mask_transparency,
    output reg reg_back_receive,
    input wire back_receive_ready
);
    localparam [6:0] ADDR_MODE = 7'h00, ADDR_CMD = 7'h01,
        ADDR_VIDEO_MODE = 7'h02, ADDR_STATUS = 7'h03,
        ADDR_DATA = 7'h20, ADDR_AREA_DATA = 7'h21,
        ADDR_MASK_TRANSP = 7'h22, ADDR_BACK_RECEIVE = 7'h30;

    reg aw_pending, w_pending;
    reg [31:0] aw_saved, w_saved;
    reg [3:0] strb_saved;
    wire aw_take = s_axi_awvalid && s_axi_awready;
    wire w_take = s_axi_wvalid && s_axi_wready;
    wire [31:0] write_addr = aw_pending ? aw_saved : s_axi_awaddr;
    wire [31:0] write_data = w_pending ? w_saved : s_axi_wdata;
    wire [3:0] write_strb = w_pending ? strb_saved : s_axi_wstrb;
    wire ack_write = write_addr[1:0] == 0 && write_addr[8:2] == ADDR_BACK_RECEIVE &&
                     write_strb[0] && write_data[0];
    // Retain AW/W while the previous ACK crosses clock domains. A second ACK
    // must wait instead of overwriting the outstanding event.
    wire write_commit = !s_axi_bvalid && (aw_pending || aw_take) && (w_pending || w_take) &&
                        (!ack_write || back_receive_ready);

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

    wire [31:0] next_alpha = merge_bytes(reg_mask_transparency, write_data, write_strb);

    // AW and W can arrive in either order. Retain each until paired.
    assign s_axi_awready = !aw_pending && !s_axi_bvalid;
    assign s_axi_wready = !w_pending && !s_axi_bvalid;
    assign s_axi_arready = !s_axi_rvalid;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            aw_pending <= 0; w_pending <= 0;
            aw_saved <= 0; w_saved <= 0; strb_saved <= 0;
            s_axi_bvalid <= 0; s_axi_bresp <= 0;
            reg_mode <= 0; reg_cmd <= 0; reg_threshold <= 0;
            reg_video_mode <= 0; reg_mask_transparency <= 32'd45;
            host_wr_en <= 0;
            reg_back_receive <= 0;
        end else begin
            host_wr_en <= 0;
            reg_back_receive <= 0;
            if (aw_take) begin aw_saved <= s_axi_awaddr; aw_pending <= 1; end
            if (w_take) begin
                w_saved <= s_axi_wdata; strb_saved <= s_axi_wstrb; w_pending <= 1;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (write_commit) begin
                aw_pending <= 0; w_pending <= 0;
                s_axi_bvalid <= 1; s_axi_bresp <= 2'b00;
                if (write_addr[1:0] != 2'b00) s_axi_bresp <= 2'b10;
                else begin
                    case (write_addr[8:2])
                        ADDR_MODE: reg_mode <= merge_bytes(reg_mode, write_data, write_strb);
                        ADDR_CMD: reg_cmd <= merge_bytes(reg_cmd, write_data, write_strb);
                        ADDR_VIDEO_MODE: reg_video_mode <= merge_bytes(reg_video_mode, write_data, write_strb);
                        ADDR_DATA: if (write_strb[0]) begin
                            reg_threshold <= write_data[7:0]; host_wr_en <= 1;
                        end
                        ADDR_MASK_TRANSP: reg_mask_transparency <= next_alpha > 100 ? 32'd100 : next_alpha;
                        // W1P: exactly one source-clock pulse per accepted write.
                        ADDR_BACK_RECEIVE: if (write_strb[0] && write_data[0]) reg_back_receive <= 1;
                        default: s_axi_bresp <= 2'b10;
                    endcase
                end
            end
        end
    end

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 0; s_axi_rdata <= 0; s_axi_rresp <= 0;
        end else begin
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1; s_axi_rresp <= 2'b00; s_axi_rdata <= 0;
                if (s_axi_araddr[1:0] != 2'b00) s_axi_rresp <= 2'b10;
                else begin
                    case (s_axi_araddr[8:2])
                        ADDR_MODE: s_axi_rdata <= reg_mode;
                        ADDR_CMD: s_axi_rdata <= reg_cmd;
                        ADDR_VIDEO_MODE: s_axi_rdata <= reg_video_mode;
                        ADDR_STATUS: s_axi_rdata <= status_in;
                        ADDR_DATA: s_axi_rdata <= {24'd0, reg_threshold};
                        ADDR_AREA_DATA: s_axi_rdata <= {15'd0, lesion_pixels};
                        ADDR_MASK_TRANSP: s_axi_rdata <= reg_mask_transparency;
                        ADDR_BACK_RECEIVE: s_axi_rdata <= 0; // action register, no stored level
                        default: s_axi_rresp <= 2'b10;
                    endcase
                end
            end
        end
    end
endmodule
