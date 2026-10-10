`timescale 1ns / 1ps
// ============================================================================
//  tb_thr_ctrl —— 阈值寄存器 / 模式切换 的功能验证
//
//  验证三件事：
//    ① 0x08 (reg_threshold) 在任何情况下都能写进去
//    ② 0x04 = 1  -> th_select 用手动阈值 (reg_threshold)
//    ③ 0x04 = 0  -> th_select 恢复自动阈值 (Otsu)
//
//  看波形时重点看：
//    reg_cmd / reg_threshold / host_wr_en / auto_mode / threshold / otsu_th / otsu_done
//  打印里直接给出每帧的轮廓像素数，四个数应该不一样。
// ============================================================================
module tb_thr_ctrl;

    reg clk = 0;
    reg rst = 1;
    always #19.841 clk = ~clk;              // 25.2 MHz

    // ---------------- AXI-Lite 接口 (模拟 PS) ----------------
    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, arvalid = 0;
    reg         bready = 1, rready = 1;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata;
    wire [1:0]  bresp, rresp;

    // ---------------- 像素流 (模拟 VDMA 送来的 8bit 灰度) ----------------
    reg  [7:0]  pix = 8'h80;
    reg         pvalid = 0, plast = 0;
    wire        pready;
    wire [7:0]  mdata;
    wire        mvalid, mlast, mtcontour, mtmask;
    wire [7:0]  thr_out;
    wire        auto_out, fdone;

    top_threshold_demo u_dut (
        .clk(clk), .rst_n(~rst),
        .s_axi_awaddr (awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata  (wdata),  .s_axi_wstrb  (4'hF),    .s_axi_wvalid (wvalid), .s_axi_wready(wready),
        .s_axi_bresp  (bresp),  .s_axi_bvalid (bvalid),  .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata  (rdata),  .s_axi_rresp  (rresp),   .s_axi_rvalid (rvalid), .s_axi_rready(rready),
        .s_axis_tdata (pix),    .s_axis_tvalid(pvalid),  .s_axis_tready(pready), .s_axis_tlast(plast),
        .m_axis_tdata (mdata),  .m_axis_tvalid(mvalid),  .m_axis_tready(1'b1),
        .m_axis_tlast (mlast),  .m_axis_tmask (mtmask),  .m_axis_tcontour(mtcontour),
        .threshold_out(thr_out), .auto_mode_out(auto_out), .frame_done_out(fdone)
    );

    // ---- 一次 AXI-Lite 写: off = 寄存器偏移 (0x04 / 0x08), val = 数据 ----
    // axi_wr
    task axi_wr(input [7:0] off, input [31:0] val);
        begin
            @(posedge clk);
            awaddr <= {24'd0, off};  awvalid <= 1'b1;
            wdata  <= val;           wvalid  <= 1'b1;
            @(posedge clk);
            awvalid <= 1'b0; wvalid <= 1'b0;
            while (bvalid !== 1'b1) @(posedge clk);   // 等写响应
            @(posedge clk);
            $display("[%0t] AXI-WR off=0x%02X val=%0d", $time, off, val);
        end
    endtask

    // ---- 送一整帧: 65536 个像素 ----
    task frame(input [7:0] g);
        integer i;
        begin
            for (i = 0; i < 65536; i = i + 1) begin
                pix    <= g;
                pvalid <= 1'b1;
                plast  <= (i == 65535);
                @(posedge clk);
                while (pready !== 1'b1) @(posedge clk);
            end
            pvalid <= 1'b0; plast <= 1'b0;
            @(posedge clk);
            $display("[%0t] frame done (gray=%0d)", $time, g);
        end
    endtask

    // ---- 统计一帧里的轮廓像素个数 (直接打印, 不用数波形) ----
    integer contour_cnt = 0;
    integer mask_cnt    = 0;
    always @(posedge clk) if (mtcontour) contour_cnt <= contour_cnt + 1;
    always @(posedge clk) if (mtmask)    mask_cnt    <= mask_cnt + 1;

    initial begin: sequence
        rst = 1'b1;
        repeat (20) @(posedge clk);
        rst = 1'b0;

        // ===== T1: 只写 0x08, 还没写过 0x04 => 验证 0x08 任何时候都能写进去 =====
        $display("==== T1: 只写 0x08=90, 不写 0x04 ====");

        axi_wr(8'h08, 32'd90);
        contour_cnt = 0; mask_cnt = 0; frame(8'h80);

        $display("     mask=%0d  contour=%0d   (auto_mode=%b threshold=%0d)",
                 mask_cnt, contour_cnt, auto_out, thr_out);

        // ===== T2: 0x04=1 手动, 0x08=60 =====
        $display("==== T2: 0x04=1 (手动) + 0x08=60 ====");
        // axi_wr(8'h08, 32'd60);
        axi_wr(8'h04, 32'd1);
        contour_cnt = 0; mask_cnt = 0; frame(8'hC0);
        $display("     mask=%0d  contour=%0d   (auto_mode=%b threshold=%0d)",
                 mask_cnt, contour_cnt, auto_out, thr_out);

        // ===== T3: 0x04=0 自动 =====
        $display("==== T3: 0x04=0 (自动) ====");
        axi_wr(8'h04, 32'd0);
        contour_cnt = 0; mask_cnt = 0; frame(8'h20);
        $display("     mask=%0d  contour=%0d   (auto_mode=%b threshold=%0d)",
                 mask_cnt, contour_cnt, auto_out, thr_out);

        // ===== T4: 回手动, 0x08=200 =====
        $display("==== T4: 0x04=1 + 0x08=200 ====");
        axi_wr(8'h04, 32'd1);
        axi_wr(8'h08, 32'd200);
        contour_cnt = 0; mask_cnt = 0; frame(8'h40);
        $display("     mask=%0d  contour=%0d   (auto_mode=%b threshold=%0d)",
                 mask_cnt, contour_cnt, auto_out, thr_out);

        #2000;
        $display("==== SIM DONE ====");
        $finish;
    end

endmodule


