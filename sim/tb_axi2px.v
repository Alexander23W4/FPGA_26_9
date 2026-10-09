`timescale 1ns / 1ps
// ============================================================================
//  axi2px 掐帧验证
//
//  验证问题: VDMA 在帧中间被掐断(vdma_mm2s_stop)后, axi2px 的
//            col_q/row_q 相位会不会残留, 导致下一张图被整体旋转 => 拼图。
//
//  激励:  AXI-Stream 64bit (8 像素/拍)
//    帧A: 送 3750 拍 (=30000 像素) 就【掐断】, 不给 tlast
//        中间留一段无 TVALID 的空隙 (模拟 stop -> load -> start)
//    帧B: 完整送 8192 拍 (=65536 像素), 末尾给 tlast
//
//  观测:
//    · 帧B 的第一个像素出现在 col_q / row_q 的什么位置
//      => 若 col_q != 0 或 row_q != 0, 说明相位残留 => 图像被旋转
//    · px_sof 有没有在帧B开头出现过
//    · 把 px 流抓 256x256 出来 dump 成图, 肉眼比对
// ============================================================================
module tb_axi2px;

    localparam TDATA_W = 64;
    localparam PPC     = 8;          // 64/8 = 8 像素/拍
    localparam FRAME_PIX = 65536;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #19.841 clk = ~clk;

    reg  [TDATA_W-1:0] s_tdata  = 0;
    reg                s_tvalid = 1'b0;
    reg                s_tlast  = 1'b0;
    reg  [TDATA_W/8-1:0] s_tkeep = {TDATA_W/8{1'b1}};
    wire               s_tready;

    wire [7:0] px_data;
    wire       px_valid, px_eof, px_sof, px_eol;
    wire       px_ready;

    axi2px #(.TDATA_W(TDATA_W), .PIXEL_W(8), .H_PIXELS(256), .V_PIXELS(256)) u_dut (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
        .s_axis_tlast(s_tlast), .s_axis_tkeep(s_tkeep), .s_axis_tuser(1'b0),
        .px_data(px_data), .px_valid(px_valid), .px_eof(px_eof), .px_sof(px_sof),
        .px_eol(px_eol), .px_ready(px_ready)
    );

    // 下游一直能收
    assign px_ready = 1'b1;

    // ---------------- 图案: 4 象限 + 左上白块 + 对角斜坡 ----------------
    function [7:0] pat;
        input integer idx;
        integer x, y;
        begin
            x = idx % 256; y = (idx / 256) % 256;
            if      (x < 128 && y < 128) pat = 8'd40;
            else if (x >=128 && y < 128) pat = 8'd90;
            else if (x < 128 && y >=128) pat = 8'd150;
            else                         pat = 8'd210;
            if (x < 16 && y < 16) pat = 8'd255;
            if ((x + y) % 64 == 0) pat = 8'd0;
        end
    endfunction

    // ---------------- 统计 ----------------
    integer px_cnt = 0, eof_cnt = 0, sof_cnt = 0;
    integer first_px_col = -1, first_px_row = -1;
    integer last_px_col  = -1, last_px_row  = -1;
    // 记录每个像素到来时的 (col,row) —— 直接取 DUT 内部相位
    wire [12:0] dut_col = u_dut.col_q;
    wire [12:0] dut_row = u_dut.row_q;

    // 抓 256x256: 从"帧B 第一个像素"开始抓
    reg [7:0] cap [0:FRAME_PIX-1];
    integer   cap_wr = 0;
    reg       cap_on = 1'b0;

    integer px_seen_total = 0;
    always @(posedge clk) begin
        if (!rst && px_valid && px_ready) begin
            px_seen_total <= px_seen_total + 1;
            px_cnt <= px_cnt + 1;
            if (px_eof) eof_cnt <= eof_cnt + 1;
            if (px_sof) sof_cnt <= sof_cnt + 1;
        end
    end

    // ---------------- 激励: AXI beat 级 ----------------
    integer beat_in_frame = 0;
    integer phase = 0;      // 0=帧A(掐断) 1=空隙 2=帧B 3=完
    integer gap = 0;
    integer beat_idx = 0;
    reg [63:0] beat_data;

    task automatic make_beat(input integer base_px);
        integer k;
        begin
            beat_data = 64'd0;
            for (k = 0; k < PPC; k = k + 1)
                beat_data[k*8 +: 8] = pat(base_px + k);
        end
    endtask

    initial begin
        rst = 1'b1;
        repeat (40) @(posedge clk);
        rst = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            s_tvalid <= 1'b0; s_tlast <= 1'b0; beat_in_frame <= 0; phase <= 0; gap <= 0;
        end else begin
            case (phase)
                0: begin  // 帧A: 3750 拍 = 30000 像素, 然后掐断
                    if (!s_tvalid) begin
                        make_beat(beat_in_frame * PPC);
                        s_tdata  <= beat_data;
                        s_tvalid <= 1'b1;
                        s_tlast  <= 1'b0;              // ★ 掐断, 永不置 tlast
                    end else if (s_tready) begin
                        beat_in_frame <= beat_in_frame + 1;
                        if (beat_in_frame == 3749) begin
                            s_tvalid <= 1'b0;
                            phase    <= 1;
                            gap      <= 500;           // 模拟 stop->load->start 的空隙
                            $display("[TB] 帧A 掐断于 %0d 个像素, 此刻 axi2px 相位 col=%0d row=%0d",
                                     (beat_in_frame+1)*PPC, dut_col, dut_row);
                        end else begin
                            make_beat((beat_in_frame+1) * PPC);
                            s_tdata <= beat_data;
                        end
                    end
                end
                1: begin
                    if (gap > 0) begin gap <= gap - 1; s_tvalid <= 1'b0; end
                    else begin
                        phase <= 2;
                        beat_in_frame <= 0;
                        $display("[TB] 空隙结束, 开始送帧B; 此刻 axi2px 相位 col=%0d row=%0d",
                                 dut_col, dut_row);
                    end
                end
                2: begin  // 帧B: 完整 8192 拍, 末尾给 tlast
                    if (!s_tvalid) begin
                        if (beat_in_frame == 0) begin
                            $display("[TB] ★ 帧B 第 0 个像素到达瞬间, axi2px 相位 col=%0d row=%0d",
                                     dut_col, dut_row);
                            first_px_col = dut_col;
                            first_px_row = dut_row;
                            cap_on <= 1'b1;
                            cap_wr <= 0;
                        end
                        make_beat(beat_in_frame * PPC);
                        s_tdata  <= beat_data;
                        s_tvalid <= 1'b1;
                        s_tlast  <= (beat_in_frame == 8191);   // ★ 只在最后拍给 tlast
                    end else if (s_tready) begin
                        beat_in_frame <= beat_in_frame + 1;
                        if (beat_in_frame == 8191) begin
                            s_tvalid <= 1'b0; s_tlast <= 1'b0;
                            phase <= 3;
                            gap   <= 200;
                            $display("[TB] 帧B 完成(已给 tlast), 此刻相位 col=%0d row=%0d", dut_col, dut_row);
                        end else begin
                            make_beat((beat_in_frame+1) * PPC);
                            s_tdata <= beat_data;
                        end
                    end
                end
                3: begin  // ★ 帧C: 验证"帧尾同步后, 新一帧是否从 (0,0) 开始"
                    if (gap > 0) begin gap <= gap - 1; s_tvalid <= 1'b0; end
                    else if (!s_tvalid) begin
                        if (beat_in_frame == 0) begin
                            $display("[TB] ★★★ 帧C 第 0 个像素到达瞬间, 相位 col=%0d row=%0d",
                                     dut_col, dut_row);
                            last_px_col = dut_col;
                            last_px_row = dut_row;
                        end
                        make_beat(beat_in_frame * PPC);
                        s_tdata  <= beat_data;
                        s_tvalid <= 1'b1;
                        s_tlast  <= (beat_in_frame == 8191);
                    end else if (s_tready) begin
                        beat_in_frame <= beat_in_frame + 1;
                        if (beat_in_frame == 8191) begin
                            s_tvalid <= 1'b0; s_tlast <= 1'b0; phase <= 4;
                        end else begin
                            make_beat((beat_in_frame+1) * PPC);
                            s_tdata <= beat_data;
                        end
                    end
                end
                default: s_tvalid <= 1'b0;
            endcase
        end
    end

    // 抓图
    always @(posedge clk) begin
        if (!rst && cap_on && px_valid && px_ready) begin
            if (cap_wr < FRAME_PIX) cap[cap_wr] <= px_data;
            cap_wr <= cap_wr + 1;
        end
    end

    reg [1023:0] fn;
    initial begin
        #(39.683 * 525 * 800 * 40);
        $sformat(fn, "C:/Users/HUAWEI/Desktop/FPGA_26_9/sim/axi2px_frameB.hex");
        $writememh(fn, cap);
        $display("======================================================");
        $display(" 帧A 掐断在 30000 像素");
        $display(" 帧B 第 0 个像素到达时相位: col_q = %0d   row_q = %0d", first_px_col, first_px_row);
        $display("    => 非 0 说明相位残留, 新图会整体旋转 => 拼图");
        $display(" ★ 帧C 第 0 个像素到达时相位: col_q = %0d   row_q = %0d", last_px_col, last_px_row);
        if (last_px_col == 0 && last_px_row == 0)
            $display("    => ★★★ 归零了! 帧尾同步生效, 新一帧从 (0,0) 开始 ✓✓✓");
        else
            $display("    => ✗ 仍未归零, 帧尾同步没起作用");
        $display(" px_sof 次数 = %0d", sof_cnt);
        $display(" px_eof 次数 = %0d", eof_cnt);
        $display(" 抓图写入 sim/axi2px_frameB.hex, 共 %0d 像素", cap_wr);
        $display("======================================================");
        $finish;
    end

endmodule
