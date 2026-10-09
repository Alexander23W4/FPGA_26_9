`timescale 1ns / 1ps
// ============================================================================
//  bank 握手验证 (小实验, 秒级)
//
//  不变量(防撕裂): 只要 hdl_out 正在写(en=1), 读端读的 bank 就不能 == 写 bank
//                  一旦 wr_idx == rd_idx 且 wr_en=1 => 读端正被覆盖 => 撕裂/拼图
//
//  被测: 真实的 hdl_out.v / hdmi_out.v / double_buf.v
//        握手胶合与 top1.v 完全一致 (clk 和 pclk 同频, 与 BD 一致)
// ============================================================================
module tb_bank_handshake;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #19.841 clk = ~clk;          // 25.2 MHz (clk == pclk, 和 BD 一致)

    // ---------------- hdl_out (写端) ----------------
    wire        wr_idx;
    wire [15:0] wr_addr;
    wire [7:0]  wr_data;
    wire        wr_en;
    wire        hdl_ready;
    wire        done_accept;
    wire [18:0] hdl_dbg;

    reg  [7:0]  hdl_data  = 8'hA5;
    reg         hdl_valid = 1'b0;
    reg         hdl_eof   = 1'b0;

    // ---------------- hdmi_out (读端) ----------------
    wire        rd_idx;
    wire [15:0] rd_addr;
    wire        hm0d, hm1d;
    wire [7:0]  vr, vg, vb;
    wire        hs, vs, de;
    wire [37:0] hdmi_dbg;

    // ---------------- 握手胶合 (照抄 top1.v) ----------------
    reg [2:0] d0s, d1s;
    always @(posedge clk) begin
        if (rst) begin d0s <= 3'd0; d1s <= 3'd0; end
        else begin
            d0s <= {d0s[1:0], hm0d};
            d1s <= {d1s[1:0], hm1d};
        end
    end
    wire hdmi_0_done_c = d0s[2] & ~d0s[1];
    wire hdmi_1_done_c = d1s[2] & ~d1s[1];

    reg accept_tgl;
    always @(posedge clk) begin
        if (rst)              accept_tgl <= 1'b0;
        else if (done_accept) accept_tgl <= ~accept_tgl;
    end
    reg [2:0] accept_tgl_s;
    always @(posedge clk) begin
        if (rst) accept_tgl_s <= 3'd0;
        else     accept_tgl_s <= {accept_tgl_s[1:0], accept_tgl};
    end

    hdl_out u_hdl_out (
        .clk(clk), .rst(rst),
        .hdl_data(hdl_data), .hdl_valid(hdl_valid), .hdl_eof(hdl_eof),
        .hdl_ready(hdl_ready),
        .buf_idx(wr_idx), .buf_addr(wr_addr), .buf_data(wr_data), .en(wr_en),
        // ★ 必须接【电平】(与修好的 top1.v 一致), 不能接边沿脉冲
        .hdmi_0_done(d0s[2]), .hdmi_1_done(d1s[2]),
        .done_accept(done_accept),
        .dbg_status(hdl_dbg)
    );

    double_buf u_double_buf (
        .clk(clk), .pclk(clk),
        .write_en(wr_en), .read_buf_idx(rd_idx), .write_buf_idx(wr_idx),
        .read_addr(rd_addr), .write_addr(wr_addr),
        .read_data(), .write_data(wr_data)
    );

    // 写端 bank 打一拍送读端 (与 top1.v 一致)
    reg write_idx_sync;
    always @(posedge clk) begin
        if (rst) write_idx_sync <= 1'b0;
        else     write_idx_sync <= wr_idx;
    end

    hdmi_out u_hdmi_out (
        .pclk(clk), .rst(rst),
        .buf_idx(rd_idx), .buf_addr(rd_addr), .buf_data(8'h5A),
        .vid_r(vr), .vid_g(vg), .vid_b(vb),
        .vid_hs(hs), .vid_vs(vs), .vid_de(de),
        .hdmi_0_done(hm0d), .hdmi_1_done(hm1d),
        .done_accept(accept_tgl_s[2]),      // ★ 翻转电平(仅启动放行)
        .write_idx_sync(write_idx_sync),    // ★ 读端读写端的另一块
        .dbg_status(hdmi_dbg)
    );

    // ---------------- 激励: 连续送 65536 像素/帧 ----------------
    integer sent = 0;
    integer frames = 0;
    initial begin
        rst = 1'b1;
        repeat (20) @(posedge clk);
        rst = 1'b0;
    end

    always @(posedge clk) begin
        if (rst) begin
            hdl_valid <= 1'b0;
            hdl_eof   <= 1'b0;
            sent      <= 0;
        end else begin
            hdl_valid <= hdl_ready;
            if (hdl_ready) begin
                hdl_eof <= (sent == 65535);
                if (sent == 65535) begin
                    sent   <= 0;
                    frames <= frames + 1;
                end else begin
                    sent <= sent + 1;
                end
            end
        end
    end

    // ---------------- 不变量检查 ----------------
    //  只在【读端真正在显示时】才算违规: hdmi_out 处于 BUF(state=1) 才有撕裂
    //  可能。启动阶段读端在 IDLE(输出黑屏), 此时写 bank 与读 bank 相同不算问题。
    //  hdmi_dbg = {state, buf_idx_save, hcnt, vcnt, counter}, 共 38 位, state 是最高位。
    integer viol = 0;
    always @(posedge clk) begin
        if (!rst && wr_en && (wr_idx === rd_idx) && hdmi_dbg[37]) begin
            viol = viol + 1;
            if (viol <= 5)
                $display("[VIOLATION] t=%0t wr_en=1 wr_idx=%b rd_idx=%b  <== 读正在写的 bank",
                         $time, wr_idx, rd_idx);
        end
    end

    initial begin
        #(39.683 * 525 * 800 * 12);        // 约 12 帧的显示时间
        $display("======================================================");
        $display(" 完成的写入帧数 = %0d", frames);
        $display(" 违规次数(写 bank == 读 bank 且正在写) = %0d", viol);
        $display(" --- 状态 ---");
        $display(" hdl_out  dbg = %b  (eof_mismatch,state,wr_bank,wr_addr)", hdl_dbg);
        $display(" hdmi_out dbg = %b  (state,rd_bank,hcnt,vcnt,rd_addr)", hdmi_dbg);
        $display(" hdl_ready=%b  wr_en=%b  wr_idx=%b  rd_idx=%b", hdl_ready, wr_en, wr_idx, rd_idx);
        $display(" done_accept=%b  accept_lvl=%b  hm0d=%b  hm1d=%b",
                 done_accept, accept_tgl_s[2], hm0d, hm1d);
        if (viol == 0) $display(" 结果:  PASS  ✓ 无撕裂风险");
        else           $display(" 结果:  FAIL  ✗ 存在撕裂风险");
        $display("======================================================");
        $finish;
    end

endmodule
