
`timescale 1ns / 1ps

// ============================================================
// AXI-Lite interface
// 封装寄存器读写接口
// ============================================================
interface axi_lite_if;

    logic [31:0] awaddr;
    logic        awvalid;
    logic        awready;

    logic [31:0] wdata;
    logic [3:0]  wstrb;
    logic        wvalid;
    logic        wready;

    logic [1:0]  bresp;
    logic        bvalid;
    logic        bready;

    logic [31:0] araddr;
    logic        arvalid;
    logic        arready;

    logic [31:0] rdata;
    logic [1:0]  rresp;
    logic        rvalid;
    logic        rready;

endinterface


// ============================================================
// AXI-Stream interface
// 封装输入/输出像素流
// ============================================================
interface axis_if;

    logic [7:0] tdata;
    logic       tvalid;
    logic       tready;
    logic       tlast;

    // 输出侧的图像处理标志
    logic       tmask;
    logic       tcontour;

endinterface


// ============================================================
// Testbench
// ============================================================
module tb_thr_ctrl;

    timeunit 1ns;
    timeprecision 1ps;

    localparam time CLK_PERIOD = 39.682ns;
    localparam int  FRAME_PIXELS = 256 * 256;
    localparam int  TIMEOUT_CYCLES = 200_000;

    logic clk   = 0;
    logic rst_n = 0;

    always #(CLK_PERIOD / 2) clk = ~clk;

    axi_lite_if axil();
    axis_if     s_axis();
    axis_if     m_axis();

    logic [7:0] threshold_out;
    logic       auto_mode_out;
    logic       frame_done_out;

    int unsigned contour_cnt = 0;
    int unsigned mask_cnt    = 0;
    logic        clear_counts = 0;

    // ========================================================
    // DUT: 被测 RTL
    // ========================================================
    top_threshold_demo u_dut (
        .clk   (clk),
        .rst_n (rst_n),

        .s_axi_awaddr  (axil.awaddr),
        .s_axi_awvalid (axil.awvalid),
        .s_axi_awready (axil.awready),

        .s_axi_wdata   (axil.wdata),
        .s_axi_wstrb   (axil.wstrb),
        .s_axi_wvalid  (axil.wvalid),
        .s_axi_wready  (axil.wready),

        .s_axi_bresp   (axil.bresp),
        .s_axi_bvalid  (axil.bvalid),
        .s_axi_bready  (axil.bready),

        .s_axi_araddr  (axil.araddr),
        .s_axi_arvalid (axil.arvalid),
        .s_axi_arready (axil.arready),

        .s_axi_rdata   (axil.rdata),
        .s_axi_rresp   (axil.rresp),
        .s_axi_rvalid  (axil.rvalid),
        .s_axi_rready  (axil.rready),

        .s_axis_tdata  (s_axis.tdata),
        .s_axis_tvalid (s_axis.tvalid),
        .s_axis_tready (s_axis.tready),
        .s_axis_tlast  (s_axis.tlast),

        .m_axis_tdata    (m_axis.tdata),
        .m_axis_tvalid   (m_axis.tvalid),
        .m_axis_tready   (m_axis.tready),
        .m_axis_tlast    (m_axis.tlast),
        .m_axis_tmask    (m_axis.tmask),
        .m_axis_tcontour (m_axis.tcontour),

        .threshold_out (threshold_out),
        .auto_mode_out (auto_mode_out),
        .frame_done_out(frame_done_out)
    );

    // Testbench 始终接收输出流
    assign m_axis.tready = 1'b1;

    // AXI-Lite 控制默认值
    initial begin
        axil.awaddr  = '0;
        axil.awvalid = 0;
        axil.wdata   = '0;
        axil.wstrb   = 4'hF;
        axil.wvalid  = 0;
        axil.bready  = 1;

        axil.araddr  = '0;
        axil.arvalid = 0;
        axil.rready  = 1;

        s_axis.tdata  = '0;
        s_axis.tvalid = 0;
        s_axis.tlast  = 0;
    end

    // ========================================================
    // Monitor: 统计实际完成握手的输出像素
    // ========================================================
    always_ff @(posedge clk) begin
        if (!rst_n || clear_counts) begin
            contour_cnt <= 0;
            mask_cnt    <= 0;
        end
        else if (m_axis.tvalid && m_axis.tready) begin
            if (m_axis.tcontour)
                contour_cnt <= contour_cnt + 1;

            if (m_axis.tmask)
                mask_cnt <= mask_cnt + 1;
        end
    end

    // ========================================================
    // Driver 1: AXI-Lite 寄存器写
    //
    // AW 和 W 通道分别握手，不假设它们同周期完成。
    // 在下降沿驱动，在上升沿采样，减少 testbench race。
    // ========================================================
    task automatic axi_write(
        input logic [7:0]  offset,
        input logic [31:0] value
    );
        bit aw_done;
        bit w_done;
        int unsigned cycles;

        begin
            aw_done = 0;
            w_done  = 0;
            cycles  = 0;

            @(negedge clk);
            axil.awaddr  = {24'b0, offset};
            axil.wdata   = value;
            axil.awvalid = 1;
            axil.wvalid  = 1;

            while (!(aw_done && w_done)) begin
                @(posedge clk);

                if (!aw_done && axil.awready)
                    aw_done = 1;

                if (!w_done && axil.wready)
                    w_done = 1;

                cycles++;

                if (cycles >= TIMEOUT_CYCLES)
                    $fatal(1,
                        "AXI write timeout: offset=%h value=%0d",
                        offset, value);
            end

            @(negedge clk);
            axil.awvalid = 0;
            axil.wvalid  = 0;

            // 等待写响应
            cycles = 0;

            do begin
                @(posedge clk);
                cycles++;

                if (cycles >= TIMEOUT_CYCLES)
                    $fatal(1,
                        "AXI B response timeout: offset=%h",
                        offset);

            end while (axil.bvalid !== 1'b1);

            $display(
                "[%0t] AXI WRITE offset=0x%02h value=%0d",
                $time, offset, value
            );
        end
    endtask


    // ========================================================
    // Driver 2: 发送一帧 256x256 灰度像素
    //
    // 仅在 tvalid && tready 时推进到下一个像素。
    // tlast 在最后一个像素上拉高。
    // ========================================================
    task automatic send_frame(input logic [7:0] gray);
        int i;
        int unsigned cycles;

        begin
            $display(
                "[%0t] Start frame, gray=%0d",
                $time, gray
            );

            for (i = 0; i < FRAME_PIXELS; i++) begin
                @(negedge clk);

                s_axis.tdata  = gray;
                s_axis.tvalid = 1;
                s_axis.tlast  = (i == FRAME_PIXELS - 1);

                cycles = 0;

                do begin
                    @(posedge clk);
                    cycles++;

                    if (cycles >= TIMEOUT_CYCLES)
                        $fatal(1,
                            "AXIS input timeout at pixel %0d", i);

                end while (s_axis.tready !== 1'b1);
            end

            @(negedge clk);
            s_axis.tvalid = 0;
            s_axis.tlast  = 0;

            $display(
                "[%0t] Input frame accepted, gray=%0d",
                $time, gray
            );
        end
    endtask


    // ========================================================
    // Checker 1: 检查模式和手动阈值
    //
    // 依据原 TB 的约定：
    // auto_mode_out=1 表示自动模式。
    // ========================================================
    task automatic check_mode(
        input logic       expected_auto,
        input logic [7:0] expected_threshold,
        input bit         check_threshold
    );
        begin
            repeat (2) @(posedge clk);

            if (auto_mode_out !== expected_auto)
                $fatal(1,
                    "Mode mismatch: expected auto=%b, got %b",
                    expected_auto, auto_mode_out);

            if (check_threshold &&
                threshold_out !== expected_threshold)
                $fatal(1,
                    "Threshold mismatch: expected=%0d, got=%0d",
                    expected_threshold, threshold_out);

            $display(
                "[%0t] CHECK PASS: auto=%b threshold=%0d",
                $time, auto_mode_out, threshold_out
            );
        end
    endtask


    // ========================================================
    // Checker 2: 等待一帧处理完成，带超时保护
    // ========================================================
    task automatic wait_frame_done;
        int unsigned cycles;

        begin
            cycles = 0;

            while (frame_done_out !== 1'b1) begin
                @(posedge clk);
                cycles++;

                if (cycles >= TIMEOUT_CYCLES)
                    $fatal(1,
                        "Timeout waiting for frame_done_out");
            end

            $display("[%0t] Frame processing completed", $time);
        end
    endtask


    // ========================================================
    // 统计控制
    // ========================================================
    task automatic reset_counts;
        begin
            @(negedge clk);
            clear_counts = 1;

            @(negedge clk);
            clear_counts = 0;
        end
    endtask


    task automatic report_frame(input string label);
        begin
            $display(
                "%s: mask=%0d contour=%0d auto=%b threshold=%0d",
                label,
                mask_cnt,
                contour_cnt,
                auto_mode_out,
                threshold_out
            );
        end
    endtask


    // ========================================================
    // Test sequence
    // ========================================================
    initial begin : test_sequence

        $display("======================================");
        $display(" tb_thr_ctrl SystemVerilog Testbench");
        $display("======================================");

        // Reset
        repeat (20) @(negedge clk);
        rst_n = 1;

        repeat (2) @(negedge clk);

        // ----------------------------------------------------
        // T1: 自动模式下写入手动阈值 90
        // ----------------------------------------------------
        $display("\n==== T1: Write threshold=90 ====");

        axi_write(8'h08, 32'd90);

        reset_counts();
        send_frame(8'h80);
        wait_frame_done();
        report_frame("T1");

        // ----------------------------------------------------
        // T1-check: 切换到手动模式，验证之前的阈值仍保留
        // ----------------------------------------------------
        axi_write(8'h04, 32'd1);
        check_mode(1'b0, 8'd90, 1'b1);

        // ----------------------------------------------------
        // T2: 手动模式，阈值 60
        // ----------------------------------------------------
        $display("\n==== T2: Manual threshold=60 ====");

        axi_write(8'h08, 32'd60);
        axi_write(8'h04, 32'd1);
        check_mode(1'b0, 8'd60, 1'b1);

        reset_counts();
        send_frame(8'hC0);
        wait_frame_done();
        report_frame("T2");

        // ----------------------------------------------------
        // T3: 自动模式
        // ----------------------------------------------------
        $display("\n==== T3: Automatic mode ====");

        axi_write(8'h04, 32'd0);
        check_mode(1'b1, 8'd0, 1'b0);

        reset_counts();
        send_frame(8'h20);
        wait_frame_done();
        report_frame("T3");

        // ----------------------------------------------------
        // T4: 手动模式，阈值 200
        // ----------------------------------------------------
        $display("\n==== T4: Manual threshold=200 ====");

        axi_write(8'h04, 32'd1);
        axi_write(8'h08, 32'd200);
        check_mode(1'b0, 8'd200, 1'b1);

        reset_counts();
        send_frame(8'h40);
        wait_frame_done();
        report_frame("T4");

        $display("\n======================================");
        $display(" ALL TESTS COMPLETED");
        $display("======================================");

        $finish;
    end

endmodule
