// =============================================================================
//  pl_img_top.v —— PL 图像通路顶层 (EMMC -> DDR -> VDMA MM2S -> AXI-Stream -> 本模块)
//
//  本次改造范围(按流程图, 到 denose 入口为止):
//
//      EMMC -> DDR -> AXI VDMA MM2S ══AXI4-Stream══► pl_img_top ══8bit 像素流══► denose
//                                                          │
//                                                          └── AXI-Lite: PS 控制/状态
//
//  ★ 本模块只做"通路"这一级, denose 不在这里面 —— 像素流从顶层端口引出去,
//    由你在 BD 里接 denose。
//
//  ★ 已合并: 原来单独的 axis_rx_8b.v 已内联到本文件, 现在只有【一个模块、一个文件】,
//    没有任何子模块。
//
//  ---------------------------------------------------------------------------
//  相比旧版的改动(16bit -> 8bit, 并激活 AXI-Stream 反压):
//
//    1) 像素位宽 PIXEL_W 从 16 改成 8。图像 256x256x8bit:
//         一行 256 字节, 32bit beat = 4 字节 -> 64 拍/行, 4 个像素/拍。
//         256 行 -> 16384 拍/帧 (PS 侧可用 stat_beats/stat_frames 核对)。
//    2) AXI-Stream 反压(s_axis_tready)真正生效:
//         接 axi_vdma_0/M_AXIS_MM2S, tready 由下游 px_ready 决定,
//         VDMA 收不到 tready 就会停住 —— 这是"反压激活"的关键。
//    3) 旧版那一整条 16bit 通路(top1 / axis_rcv / axis_out / img2buf / bufback /
//       frame_buf)按说明作废, 本模块不引用它们。
//
//  ---------------------------------------------------------------------------
//  AXI-Lite 寄存器映射(和 app 侧 config/pl_cmd.h 里的地址一致):
//
//      写  +0x00 MODE_ADDR     模式 (SINGLE_MODE=1 / STREAM_MODE=2)
//      写  +0x10 CMD_REG_ADDR  控制 (REOPERATE=1), 写 1 产生一拍 pulse
//      写  +0x20 DATA_REG_ADDR 阈值等数据
//      读  +0x30 stat_beats    收到的 beat 数
//      读  +0x34 stat_pixels   发出的像素数
//      读  +0x38 stat_frames   完整帧数
//      读  +0x3C {tkeep_bad, mode, cmd_seen}
//      读  +0x40 握手实时观测 {tuser_seen, tlast_seen, tvalid_seen, px_ready,
//                             s_axis_tready, s_axis_tvalid}
// =============================================================================

`timescale 1ns / 1ps

module pl_img_top #(
    // AXI4-Stream 侧位宽。★ 配 32，和 create_zynq_project.tcl 里 VDMA 的
    //   c_m_axis_mm2s_tdata_width 一致。
    //
    //   为什么不是 64：实测在 64 位流配置下，VDMA 的 MM2S 只吐低 32 位真数据、
    //   高 32 位恒 0（端口级实测，反复复现，根因未找到）。8bit 像素 + 64 位流时
    //   那会变成"每 8 个像素里有 4 个是 0"。改成 32 位流就绕开了：
    //   不论 VDMA 内部通路是 32 还是 64 位，32 位流配置拿到的数据都是完整的。
    //
    //   一拍 = 32/8 = 4 个像素；256 字节/行 -> 64 拍/行；256 行 -> 16384 拍/帧。
    parameter integer TDATA_W  = 32,
    parameter integer PIXEL_W  = 8,      // 像素位宽: 8bit 灰度
    parameter integer H_PIXELS = 256,    // 一行像素数
    parameter integer V_PIXELS = 256,    // 一帧行数
    parameter integer CNT_W    = 32
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI:S_AXIS, ASSOCIATED_RESET rst" *)
    input  wire                    clk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    input  wire                    rst,

    // ---------------- AXI4-Lite 从端: 接 PS ----------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 9, DATA_WIDTH 32, FREQ_HZ 50000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0, READ_WRITE_MODE READ_WRITE, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, MAX_BURST_LENGTH 1, PHASE 0.0, NUM_READ_THREADS 1, NUM_WRITE_THREADS 1, RUSER_BITS_PER_BYTE 0, WUSER_BITS_PER_BYTE 0, INSERT_VIP 0" *)
    input  wire [8:0]              s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire                    s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire                    s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [31:0]             s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [3:0]              s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire                    s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire                    s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output wire [1:0]              s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output wire                    s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire                    s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [8:0]              s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire                    s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire                    s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output wire [31:0]             s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output wire [1:0]              s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output wire                    s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire                    s_axi_rready,

    // ---------------- AXI4-Stream 从端: 接 axi_vdma_0/M_AXIS_MM2S --------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXIS, TDATA_NUM_BYTES 4, TDEST_WIDTH 0, TID_WIDTH 0, TUSER_WIDTH 1, HAS_TKEEP 1, HAS_TSTRB 0, HAS_TLAST 1, FREQ_HZ 50000000, PHASE 0.0, INSERT_VIP 0" *)
    input  wire [TDATA_W-1:0]      s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire                    s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire                    s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
    input  wire                    s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
    input  wire [TDATA_W/8-1:0]    s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TUSER" *)
    input  wire                    s_axis_tuser,

    // ---------------- 8bit 像素流: 引出去接 denose ------------------------
    //   与 denose.v 端口一一对应:
    //       px_data  -> denose.in_data
    //       px_valid -> denose.in_valid
    //       px_eof   -> denose.in_last   (★ 帧尾 EOF, 不是行尾)
    //       px_ready <- denose.in_ready
    //   px_sof / px_eol 备用(接 ILA 或以后打包回 AXI-Stream 时用)。
    output wire [PIXEL_W-1:0]      px_data,
    output wire                    px_valid,
    output wire                    px_eof,      // 帧尾 EOF: 最后一行的最后一个像素
    output wire                    px_sof,      // 帧首 SOF: 每帧第一个像素
    output wire                    px_eol,      // 行尾 EOL: 每行最后一个像素
    input  wire                    px_ready,

    // ---------------- 给 PS 看的模式/控制(备用) ---------------------------
    output wire [7:0]              mode_reg,
    output wire [7:0]              cmd_reg,
    output wire                    cmd_pulse
);

    // =========================================================================
    //  一、AXI4-Stream 接收 -> 8bit 像素流   (原 axis_rx_8b 的逻辑, 已内联)
    //
    //  【协议正确性】
    //    1. s_axis_tready 只取决于下游 px_ready，【不取决于 s_axis_tvalid】
    //       —— AXI-Stream 硬性要求(否则成组合环)。
    //    2. 只在 (tvalid && tready) 同拍为 1 时才认为一个 beat 被取走。
    //    3. 一拍的 PPC 个像素没发完之前不接收下一拍，不丢像素也不重复。
    //    4. 支持下游背压: px_ready 拉低时整条流停住, 数据不丢。
    // =========================================================================
    localparam integer PPC    = TDATA_W / PIXEL_W;
    localparam integer IDX_W  = (PPC <= 2) ? 1 : $clog2(PPC);
    localparam integer KEEP_W = TDATA_W / 8;

    // 本拍最后一个像素的索引(PPC-1)。
    // ★ 不能写成 PPC[IDX_W-1:0] —— 那是对参数做位截断, PPC=4 会变成 0 而不是 3。
    localparam [IDX_W-1:0] LAST_IDX = PPC - 1;

    reg [TDATA_W-1:0] beat_q;
    reg               beat_valid_q;
    reg [IDX_W-1:0]   idx_q;        // 本拍里发到第几个像素
    reg [CNT_W-1:0]   col_q;        // 当前像素在行内的列号
    reg [CNT_W-1:0]   row_q;        // 当前行号

    reg [CNT_W-1:0]   stat_beats;
    reg [CNT_W-1:0]   stat_pixels;
    reg [CNT_W-1:0]   stat_frames;
    reg               stat_tkeep_bad;

    // 握手观测(粘滞), 只给 PS 看
    reg tvalid_seen, tlast_seen, tuser_seen;
    reg data_seen;              // s_axis_tdata 出现过非 0 (连线自检, 必须为 1)

    wire aresetn = ~rst;

    wire accept   = px_ready;                                   // 下游收得下吗
    wire px_taken = beat_valid_q && accept;

    // s_axis_tready: 没有待发拍 -> 可以收; 有待发拍但已发到本拍最后一个像素,
    // 且下游肯收 -> 同一拍就能收下一拍。只看 accept, 不看 tvalid。
    assign s_axis_tready = aresetn &&
                           ((beat_valid_q == 1'b0) ||
                            ((idx_q == LAST_IDX) && accept));

    wire load = s_axis_tvalid && s_axis_tready;

    wire last_col = (col_q == (H_PIXELS - 1));
    wire last_row = (row_q == (V_PIXELS - 1));

    assign px_data  = beat_q[idx_q * PIXEL_W +: PIXEL_W];
    assign px_valid = beat_valid_q;
    assign px_sof   = beat_valid_q && (col_q == {CNT_W{1'b0}}) && (row_q == {CNT_W{1'b0}});
    assign px_eol   = beat_valid_q && last_col;
    // ★ 帧尾 EOF: 最后一行的最后一个像素。denose 的 in_last 要的就是这个。
    //   注意它和 px_eol 不是一回事: px_eol 每行都来(256 次/帧), px_eof 每帧只来一次。
    assign px_eof   = beat_valid_q && last_col && last_row;

    always @(posedge clk) begin
        if (rst) begin
            beat_q         <= {TDATA_W{1'b0}};
            beat_valid_q   <= 1'b0;
            idx_q          <= {IDX_W{1'b0}};
            col_q          <= {CNT_W{1'b0}};
            row_q          <= {CNT_W{1'b0}};
            stat_beats     <= {CNT_W{1'b0}};
            stat_pixels    <= {CNT_W{1'b0}};
            stat_frames    <= {CNT_W{1'b0}};
            stat_tkeep_bad <= 1'b0;
            tvalid_seen    <= 1'b0;
            tlast_seen     <= 1'b0;
            tuser_seen     <= 1'b0;
            data_seen      <= 1'b0;
        end else begin
            // ---------------- 装下一拍 ----------------
            if (load) begin
                beat_q       <= s_axis_tdata;
                beat_valid_q <= 1'b1;
                idx_q        <= {IDX_W{1'b0}};
                stat_beats   <= stat_beats + {{(CNT_W-1){1'b0}}, 1'b1};

                // 连线自检: 数据线上到底有没有非 0
                if (s_axis_tdata != {TDATA_W{1'b0}}) begin
                    data_seen <= 1'b1;
                end

                // tkeep 不是全 1 => 一行字节数不是 beat 字节数的整数倍, 配置不对。
                if (s_axis_tkeep != {KEEP_W{1'b1}}) begin
                    stat_tkeep_bad <= 1'b1;
                end
            end else if (px_taken) begin
                // ---------------- 把本拍的像素一个个发出去 ----------------
                if (idx_q == LAST_IDX) begin
                    beat_valid_q <= 1'b0;
                end else begin
                    idx_q <= idx_q + {{(IDX_W-1){1'b0}}, 1'b1};
                end
            end

            // ---------------- 像素计数 / 行列边界 ----------------
            //  一行满 H_PIXELS 个像素就换行, 行满 V_PIXELS 就换帧。
            //  边界完全由计数产生, 不依赖 s_axis_tlast/tuser。
            if (px_taken) begin
                stat_pixels <= stat_pixels + {{(CNT_W-1){1'b0}}, 1'b1};

                if (last_col) begin
                    col_q <= {CNT_W{1'b0}};
                    if (last_row) begin
                        stat_frames <= stat_frames + {{(CNT_W-1){1'b0}}, 1'b1};
                        row_q       <= {CNT_W{1'b0}};
                    end else begin
                        row_q <= row_q + {{(CNT_W-1){1'b0}}, 1'b1};
                    end
                end else begin
                    col_q <= col_q + {{(CNT_W-1){1'b0}}, 1'b1};
                end
            end

            // ---------------- AXI-Stream 握手观测(粘滞) ----------------
            if (s_axis_tvalid) begin
                tvalid_seen <= 1'b1;
                if (s_axis_tlast) tlast_seen <= 1'b1;
                if (s_axis_tuser) tuser_seen <= 1'b1;
            end
        end
    end

    // =========================================================================
    //  二、AXI4-Lite 从端: 极简实现(读写各一拍完成, 无 outstanding)
    // =========================================================================
    reg        aw_hs, w_hs, bvalid_q;
    reg [8:0]  awaddr_q;
    reg [31:0] wdata_q;

    reg        rvalid_q;
    reg [8:0]  araddr_q;
    reg [31:0] rdata_q;

    assign s_axi_awready = ~aw_hs & ~bvalid_q;
    assign s_axi_wready  = ~w_hs  & ~bvalid_q;
    assign s_axi_bvalid  = bvalid_q;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = ~rvalid_q;
    assign s_axi_rvalid  = rvalid_q;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rdata   = rdata_q;

    reg [7:0]  mode_q;
    reg [7:0]  cmd_q;
    reg [7:0]  data_q;
    reg        cmd_pulse_q;

    assign mode_reg  = mode_q;
    assign cmd_reg   = cmd_q;
    assign cmd_pulse = cmd_pulse_q;

    // ---- 写通道 ----
    always @(posedge clk) begin
        if (rst) begin
            aw_hs       <= 1'b0;
            w_hs        <= 1'b0;
            bvalid_q    <= 1'b0;
            awaddr_q    <= 9'd0;
            wdata_q     <= 32'd0;
            mode_q      <= 8'd0;
            cmd_q       <= 8'd0;
            data_q      <= 8'd0;
            cmd_pulse_q <= 1'b0;
        end else begin
            cmd_pulse_q <= 1'b0;

            if (s_axi_awready && s_axi_awvalid) begin
                awaddr_q <= s_axi_awaddr;
                aw_hs    <= 1'b1;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                wdata_q  <= s_axi_wdata;
                w_hs     <= 1'b1;
            end

            // AW 和 W 都到齐 -> 落寄存器 + 回 B
            if (aw_hs && w_hs && !bvalid_q) begin
                case (awaddr_q[7:0])
                    8'h00: mode_q <= wdata_q[7:0];
                    8'h10: begin
                        cmd_q       <= wdata_q[7:0];
                        cmd_pulse_q <= 1'b1;      // 写 CMD 产生一拍 pulse
                    end
                    8'h20: data_q <= wdata_q[7:0];
                    default: ;                    // 其余地址吞掉, 不回错
                endcase
                bvalid_q <= 1'b1;
                aw_hs    <= 1'b0;
                w_hs     <= 1'b0;
            end else if (bvalid_q && s_axi_bready) begin
                bvalid_q <= 1'b0;
            end
        end
    end

    // ---- 读通道 ----
    always @(posedge clk) begin
        if (rst) begin
            rvalid_q <= 1'b0;
            araddr_q <= 9'd0;
            rdata_q  <= 32'd0;
        end else begin
            if (s_axi_arready && s_axi_arvalid) begin
                araddr_q <= s_axi_araddr;
                rvalid_q <= 1'b1;
                case (s_axi_araddr[7:0])
                    8'h00: rdata_q <= {24'd0, mode_q};
                    8'h10: rdata_q <= {24'd0, cmd_q};
                    8'h20: rdata_q <= {24'd0, data_q};
                    8'h30: rdata_q <= stat_beats;
                    8'h34: rdata_q <= stat_pixels;
                    8'h38: rdata_q <= stat_frames;
                    8'h3C: rdata_q <= {data_seen, 22'd0, (cmd_q != 8'd0),
                                       mode_q[1:0], stat_tkeep_bad, 5'd0};
                    // ★ 位定义必须和 PS 侧 pl_ctrl_test.c 的 read_pl_dbg() 对齐:
                    //     bit0=tvalid  bit1=tready  bit2=tvalid_seen  bit3=tlast_seen
                    //     bit4=tkeep_bad  bit5=tuser(实时)  bit6=tuser_seen
                    //   (旧版是 35 bit 赋给 32 位寄存器, 高位被截断, 已修正)
                    8'h40: rdata_q <= {25'd0, tuser_seen, s_axis_tuser,
                                       stat_tkeep_bad, tlast_seen, tvalid_seen,
                                       s_axis_tready, s_axis_tvalid};
                    default: rdata_q <= 32'hDEADBEEF;
                endcase
            end else if (rvalid_q && s_axi_rready) begin
                rvalid_q <= 1'b0;
            end
        end
    end

endmodule
