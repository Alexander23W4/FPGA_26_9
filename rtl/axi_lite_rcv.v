module axi_lite_rcv #(
    parameter ADDR_WIDTH = 9,
    parameter DATA_WIDTH = 32
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET rst" *)
    input  wire                  clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                  rst,


    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 9, DATA_WIDTH 32, FREQ_HZ 50000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 1, PHASE 0.0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
    input  wire [ADDR_WIDTH-1:0] awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire                  awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output reg                   awready,


    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [DATA_WIDTH-1:0] wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [DATA_WIDTH/8-1:0] wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire                  wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output reg                   wready,


    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output reg  [1:0]            bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output reg                   bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire                  bready,


    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [ADDR_WIDTH-1:0] araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire                  arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output reg                   arready,


    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output reg  [DATA_WIDTH-1:0] rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output reg  [1:0]            rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output reg                   rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire                  rready,

    input [7:0] mode_reg,
    input [7:0] cmd_reg,
    input [7:0] data_reg,

    output reg        __update_reg,
    output reg [8:0]  __update_reg_addr,
    output reg [31:0] __update_data
);

    reg [31:0] rdata_save;


    parameter MODE_ADDR = 9'h00, CMD_REG_ADDR = 9'h10, DATA_REG_ADDR = 9'h20;

    localparam IDLE = 3'b000, R = 3'b010, AW = 3'b011, W = 3'b100, B = 3'b101;

    reg [2:0] state, next;

    always @(posedge clk or negedge rst) begin
        if(!rst) begin
            state <= IDLE;
            rdata_save <= 32'h0;
            __update_reg_addr <= 9'h0;
            __update_data <= 32'h0;

        end else begin
            state <= next;
            if(state == IDLE && arvalid) begin
                case(araddr) 
                    MODE_ADDR: rdata_save <= {{24{1'b0}}, mode_reg};
                    CMD_REG_ADDR: rdata_save <= {{24{1'b0}}, cmd_reg};
                    DATA_REG_ADDR: rdata_save <= {{24{1'b0}}, data_reg};
                    default: rdata_save <= 32'h0;
                endcase
            end 
            if(state == IDLE && awvalid) begin
                __update_reg_addr <= awaddr;
            end
            if(state == W && wvalid) begin
                __update_data <= wdata;
            end         
        end
    end

// 这里由于考虑到ps不可能同时发送读请求和写请求, 所以读写共用一个状态机
    always @(*) begin
        next = state;
        rdata = rdata_save;
        rresp = 2'b00;
        rvalid = 1'b0;

        awready = 1'b0;
        wready = 1'b0;
        arready = 1'b0;
        bresp = 2'b00;
        bvalid = 1'b0;

        __update_reg = 1'b0;

        case(state) 
            IDLE: begin
                if(arvalid) begin
                    arready = 1'b1;
                    next = R;
                end
                else if(awvalid) begin
                    awready = 1'b1;
                    next = W;
                end
            end
            R: begin
                rvalid = 1'b1;
                if(rready) begin
                    next = IDLE;
                end
            end
            W: begin
                if(wvalid) begin
                    wready = 1'b1;
                    next = B;
                end
            end
            B: begin
                bvalid = 1'b1;
                if(bready) begin
                    __update_reg = 1'b1;

                    next = IDLE;
                end
            end
        endcase
    end


endmodule
