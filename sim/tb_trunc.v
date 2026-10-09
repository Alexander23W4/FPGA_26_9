`timescale 1ns / 1ps
// ============================================================================
//  掐帧实验 (A/B 对照)
//
//  模拟 pl_ctrl_test.c 的行为: vdma_mm2s_stop() 会在帧中间掐断数据流,
//  于是那一帧的 tlast(in_last) 永远不会到来。之后 PS 重启 VDMA 送新图。
//
//  激励序列:
//    帧A: 只送 30000 个像素就【掐断】(不给 tlast)     <-- 模拟 vdma stop
//    帧B: 正常送 65536 个像素, 末尾给 tlast           <-- 换图后重启
//    帧C: 正常送 65536 个像素, 末尾给 tlast
//
//  比对: 帧B 的 denoise 输出图
//    原始逻辑(denoise_orig) => 期待【切块/拼图】
//    修复逻辑(denoise)      => 期待【正常图】
//
//  用 `define USE_ORIG 切换 (由 tcl 的 verilog_define 传)
// ============================================================================
module tb_trunc;

    localparam FRAME_PIX = 65536;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #19.841 clk = ~clk;

    reg  [7:0]  src_data  = 8'h20;
    reg         src_valid = 1'b0;
    reg         src_last  = 1'b0;
    integer     src_cnt   = 0;
    integer     phase     = 0;        // 0=帧A(掐断) 1=帧B 2=帧C 3=结束

    function [7:0] pattern;
        input integer idx;
        integer x, y;
        begin
            x = idx % 256;
            y = (idx / 256) % 256;
            if      (x < 128 && y < 128) pattern = 8'd40;
            else if (x >=128 && y < 128) pattern = 8'd90;
            else if (x < 128 && y >=128) pattern = 8'd150;
            else                         pattern = 8'd210;
            if (x < 16 && y < 16) pattern = 8'd255;
            if ((x + y) % 64 == 0) pattern = 8'd0;
        end
    endfunction

    // ---------------- denoise: A/B 切换 ----------------
    wire [7:0] dn_data;
    wire       dn_valid, dn_last, dn_ready, dn_in_ready;

`ifdef USE_ORIG
    denoise_orig u_denoise (
`else
    denoise u_denoise (
`endif
        .ap_clk(clk), .ap_rst(rst),
        .in_data(src_data), .in_valid(src_valid), .in_last(src_last),
        .in_ready(dn_in_ready),
        .out_ready(dn_ready), .out_data(dn_data), .out_valid(dn_valid), .out_last(dn_last)
    );
    assign dn_ready = 1'b1;          // 下游永远能收, 隔离出 denoise 本身的问题

    // ---------------- 采集 denoise 输出 ----------------
    reg [7:0] cap [0:FRAME_PIX-1];
    integer   cap_wr = 0;
    integer   dump_n = 0;
    reg [1023:0] fname;

    always @(posedge clk) begin
        if (!rst && dn_valid && dn_ready) begin
            if (cap_wr < FRAME_PIX) cap[cap_wr] <= dn_data;
            cap_wr <= cap_wr + 1;
        end
    end

    // 每看到一次 dn_last 就把这一帧 dump 出来
    always @(posedge clk) begin
        if (!rst && dn_valid && dn_ready && dn_last) begin
            $sformat(fname, "C:/Users/HUAWEI/Desktop/FPGA_26_9/sim/trunc_%s_%0d.hex",
`ifdef USE_ORIG
                     "orig",
`else
                     "fix",
`endif
                     dump_n);
            $writememh(fname, cap);
            $display("[TRUNC-DUMP] %0d 帧末, 该帧输出像素数=%0d", dump_n, cap_wr+1);
            dump_n <= dump_n + 1;
            cap_wr <= 0;
        end
    end

    // ---------------- 激励 ----------------
    integer gap = 0;
    reg     sending = 1'b0;

    initial begin
        rst = 1'b1;
        repeat (40) @(posedge clk);
        rst = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            src_valid <= 0; src_last <= 0; src_cnt <= 0; sending <= 0; gap <= 0; phase <= 0;
            src_data <= 8'h20;
        end else if (gap > 0) begin
            gap <= gap - 1;
            src_valid <= 1'b0;
        end else begin
            case (phase)
                0: begin  // ★ 帧A: 送 30000 个像素就掐断 (不给 tlast)
                    if (!sending) begin
                        sending <= 1'b1; src_valid <= 1'b1;
                        src_data <= pattern(src_cnt); src_last <= 1'b0;
                    end else if (dn_in_ready) begin
                        if (src_cnt == 30000) begin
                            src_valid <= 1'b0; src_last <= 1'b0;
                            sending   <= 1'b0;
                            src_cnt   <= 0;
                            phase     <= 1;
                            gap       <= 300;      // 掐断后停一会
                        end else begin
                            src_cnt  <= src_cnt + 1;
                            src_data <= pattern(src_cnt + 1);
                            src_last <= 1'b0;      // ★ 关键: 永远不给 tlast
                        end
                    end
                end
                1, 2: begin  // 帧B / 帧C: 正常整帧
                    if (!sending) begin
                        sending <= 1'b1; src_valid <= 1'b1;
                        src_data <= pattern(src_cnt);
                        src_last <= (src_cnt == FRAME_PIX-1);
                    end else if (dn_in_ready) begin
                        if (src_cnt == FRAME_PIX-1) begin
                            src_cnt  <= 0;
                            src_valid <= 1'b0;
                            src_last <= 1'b0;
                            sending  <= 1'b0;
                            phase    <= phase + 1;
                            gap      <= 2000;
                        end else begin
                            src_cnt  <= src_cnt + 1;
                            src_data <= pattern(src_cnt + 1);
                            src_last <= (src_cnt + 1 == FRAME_PIX-1);
                        end
                    end
                end
                default: src_valid <= 1'b0;
            endcase
        end
    end

    initial begin
        #(39.683 * 525 * 800 * 60);
        $display("======================================================");
        $display(" phase = %0d, dump 帧数 = %0d", phase, dump_n);
        $display("======================================================");
        $finish;
    end

endmodule
