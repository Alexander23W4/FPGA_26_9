//============================================================
// axi_lite_slave.v  AXI4-Lite slave for host control
// Address map:
//   0x00 : MODE_REG
//   0x04 : CMD_REG
//   0x08 : DATA_REG (threshold)
//   0x0C : STATUS_REG
//============================================================
`timescale 1ns / 1ps

module axi_lite_slave (
    input  wire        s_axi_aclk,   // AXI clock
    input  wire        s_axi_aresetn,// AXI reset, active low
    // Write address channel
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,// combinational ready
    // Write data channel
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready, // combinational ready
    // Write response channel
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    // Read address channel
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,// combinational ready
    // Read data channel
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,
    // User registers
    output reg  [31:0] reg_mode,
    output reg  [31:0] reg_cmd,
    output reg  [7:0]  reg_threshold,
    output reg         host_wr_en,
    input  wire [31:0] status_in
);
    localparam ADDR_MODE   = 8'h00;
    localparam ADDR_CMD    = 8'h04;
    localparam ADDR_DATA   = 8'h08;
    localparam ADDR_STATUS = 8'h0C;

    // Combinational ready: accept when no pending response
    assign s_axi_awready = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_wready  = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_arready = s_axi_arvalid && !s_axi_rvalid;

    // ---- Write channel ----
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            reg_mode      <= 32'd0;
            reg_cmd       <= 32'd0;
            reg_threshold <= 8'd0;
            host_wr_en    <= 1'b0;   // 默认自动模式
        end else begin
            host_wr_en <= 1'b0;

            if (s_axi_awready && s_axi_wready && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
                case (s_axi_awaddr[7:0])   // 这里写入reg
                    ADDR_MODE: reg_mode      <= s_axi_wdata;
                    ADDR_CMD:  reg_cmd       <= s_axi_wdata;
                    ADDR_DATA: begin   // 这里写入 data, 不判断 cmd, 任何情况下写0x08寄存器都能够写入 threshold
                        reg_threshold <= s_axi_wdata[7:0];
                        host_wr_en    <= 1'b1;
                    end
                    default: ;
                endcase
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ---- Read channel ----
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
            s_axi_rresp  <= 2'b00;
        end else begin
            if (s_axi_arready && !s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= 2'b00;
                case (s_axi_araddr[7:0])
                    ADDR_MODE:   s_axi_rdata <= reg_mode;
                    ADDR_CMD:    s_axi_rdata <= reg_cmd;
                    ADDR_DATA:   s_axi_rdata <= {24'd0, reg_threshold};
                    ADDR_STATUS: s_axi_rdata <= status_in;
                    default:     s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end
endmodule