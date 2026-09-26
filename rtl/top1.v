module top1 #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 16,          // 地址位宽
    parameter DEPTH      = 65536        // 深度，必须 = 2^ADDR_WIDTH
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI:S_AXIS:M_AXIS, ASSOCIATED_RESET rst" *)
    input  wire        clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire        rst,

    // ---------------- AXI-Lite 从口：接 PS ----------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 9, DATA_WIDTH 32, FREQ_HZ 50000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 1, PHASE 0.0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
    input  wire [8:0]  awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire        awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire        awready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [31:0] wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [3:0]  wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire        wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire        wready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output wire [1:0]  bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output wire        bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire        bready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [8:0]  araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire        arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire        arready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output wire [31:0] rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output wire [1:0]  rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output wire        rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire        rready,

    // ---------------- AXI4-Stream 从口：接 axi_vdma_0/M_AXIS_MM2S ----------------
    input  wire [63:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire [7:0]  s_axis_tkeep,
    input  wire        s_axis_tuser,

    // ---------------- AXI4-Stream 主口：接 axi_vdma_0/S_AXIS_S2MM ----------------
    output wire [63:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire [7:0]  m_axis_tkeep,
    output wire        m_axis_tuser
);

    reg [7:0] mode_reg;
    reg [7:0] cmd_reg;
    reg [7:0] data_reg;

    wire __update_reg;
    wire [8:0] __update_reg_addr;
    wire [31:0] __update_data;

    axi_lite_rcv reg_io(
        .clk(clk),
        .rst(~rst),
        .awaddr(awaddr),
        .awvalid(awvalid),
        .awready(awready),
        .wdata(wdata),
        .wstrb(wstrb),
        .wvalid(wvalid),
        .wready(wready),
        .bresp(bresp),
        .bvalid(bvalid),
        .bready(bready),
        .araddr(araddr),
        .arvalid(arvalid),
        .arready(arready),
        .rdata(rdata),
        .rresp(rresp),
        .rvalid(rvalid),
        .rready(rready),
        .mode_reg(mode_reg),
        .cmd_reg(cmd_reg),
        .data_reg(data_reg),
        .__update_reg(__update_reg),
        .__update_reg_addr(__update_reg_addr),
        .__update_data(__update_data)
    );

    wire __rcvf_buf;
    reg __rcvf_buf_save;
    reg __siop;

    wire buf_en;
    wire buf_we;
    wire [ADDR_WIDTH-1:0] buf_addr;
    wire [DATA_WIDTH-1:0] buf_din;
    wire back_en;
    wire back_we;
    wire [ADDR_WIDTH-1:0] back_addr;
    wire [DATA_WIDTH-1:0] back_dout;
    wire [DATA_WIDTH-1:0] px_data;
    wire px_valid;
    wire px_ready;
    wire px_sof;
    wire px_eol;
    wire px_eof;
    wire [DATA_WIDTH-1:0] back_res_data;
    wire back_res_valid;
    wire back_res_sof;
    wire back_res_eof;

    axis_rcv u_axis_rcv (
        .aclk(clk),
        .aresetn(~rst),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tuser(s_axis_tuser),
        .px_data(px_data),
        .px_valid(px_valid),
        .px_ready(px_ready),
        .px_sof(px_sof),
        .px_eol(px_eol),
        .px_eof(px_eof),
        .stat_beats(),
        .stat_pixels(),
        .stat_frames(),
        .stat_tkeep_bad()
    );

    img2buf u_img2buf (
        .clk(clk),
        .rst(rst),
        .px_data(px_data),
        .px_valid(px_valid),
        .px_ready(px_ready),
        .px_sof(px_sof),
        .px_eol(px_eol),
        .px_eof(px_eof),

        .buf_en(buf_en),
        .buf_we(buf_we),
        .buf_addr(buf_addr),
        .buf_din(buf_din),
        .end_frame(__rcvf_buf)
    );

    frame_buf u_frame_buf (
        .clk(clk),
        .a_en(buf_en),
        .a_we(buf_we),
        .a_addr(buf_addr),
        .a_din(buf_din),
        .a_dout(),
        .b_en(back_en),
        .b_we(back_we),
        .b_addr(back_addr),
        .b_din(),
        .b_dout(back_dout)
    );

    reg __start_back;
    wire __end_back;

    // **
    bufback u_bufback (
        .clk(clk),
        .rst(rst),
        .back_en(back_en),
        .back_we(back_we),
        .back_addr(back_addr),
        .back_dout(back_dout),
        .res_data(back_res_data),
        .res_valid(back_res_valid),
        .res_sof(back_res_sof),
        .res_eof(back_res_eof),
        .__start_back(__start_back),
        .__end_back(__end_back)
    );

    axis_out u_axis_out (
        .aclk(clk),
        .aresetn(~rst),

        .res_data(back_res_data),
        .res_valid(back_res_valid),
        .res_ready(),
        .res_sof(back_res_sof),
        .res_eol(1'b0),
        .res_eof(back_res_eof),

        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tuser(m_axis_tuser),
        .stat_beats(),
        .stat_frames()
    );

    parameter MODE_ADDR = 9'h00, CMD_REG_ADDR = 9'h10, DATA_REG_ADDR = 9'h20;
    parameter SINGLE_MODE = 8'h01, STREAM_MODE = 8'h02;
    parameter REOP = 8'h01;

    localparam IDLE = 3'b000, 
               FULL_BUF = 3'b001,
               SI_OP = 3'b010,  // 发信号(siop)给图像数据通路, 图像数据通路读到siop后发起一次读ddr, 然后处理, 再通过SS2M返回给PS, 完成整个握手流程后, 数据通路返回一个信号,
               BACK = 3'b011;

    reg [2:0] state, next;

    
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state <= IDLE;
            __rcvf_buf_save <= 1'b0;
            mode_reg <= 8'h0;
            cmd_reg <= 8'h0;
            data_reg <= 8'h0;
        end else begin
            state <= next;
            if(__update_reg) begin
                case (__update_reg_addr)
                    MODE_ADDR: mode_reg <= __update_data[7:0];
                    CMD_REG_ADDR: cmd_reg <= __update_data[7:0];
                    DATA_REG_ADDR: data_reg <= __update_data[7:0]; 
                    default: 
                        ;
                endcase
            end
            if(__rcvf_buf) begin
                __rcvf_buf_save <= 1'b1;
            end
            if(state == IDLE && mode_reg == SINGLE_MODE && cmd_reg == REOP) begin
                cmd_reg <= 8'h00;           // 清空cmd, 避免循环触发状态机
                __rcvf_buf_save <= 1'b0;    // 清掉上一帧的标志, 重新等这一帧填完
            end
        end
    end

    always @(*) begin
        next = state;
        __siop = 1'b0;
        __start_back = 1'b0;

        case(state) 
            IDLE: begin
                if(mode_reg == SINGLE_MODE && cmd_reg == REOP) begin
                    next = FULL_BUF;
                end
            end
            FULL_BUF: begin
                if(__rcvf_buf_save) begin
                    next = SI_OP;
                end
            end
            SI_OP: begin
                // 现在暂时不实现算法, 直接传回buf里面的图像
                next = BACK;
            end
            BACK: begin
                __start_back = 1'b1;
                if(__end_back) begin
                    next = IDLE;
                end
            end

        endcase
    end


endmodule
