`timescale 1ns / 1ps

module th_select (
    input  wire        clk,         // system clock
    input  wire        rst,         // reset, active high

    input  wire [7:0]  otsu_th,     // Otsu threshold from otsu_core
    input  wire        otsu_done,   // one-cycle pulse when otsu_th is ready

    input  wire        host_wr_en,  // one-cycle pulse when host writes DATA_REG

    input  wire [7:0]  host_th,     // threshold value written by host
    input  wire        host_mode,   // ★ reg_cmd[0]: 0 = auto(Otsu), 1 = manual(host_th)

    output reg  [7:0]  threshold,   // final threshold used by segmenter
    output reg         auto_mode    // 1 = auto (Otsu), 0 = manual (host)
);
    // ★ 模式完全由主机的 reg_cmd[0] 决定:
    //     host_mode = 0 -> 自动: threshold 跟随 Otsu 的输出
    //     host_mode = 1 -> 手动: threshold 用主机写进 reg_threshold 的值
    //   算法本身(threshold_seg / contour_extract)不参与, 只是拿到 threshold。
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            threshold <= 8'd128;        // 默认阈值
            auto_mode <= 1'b1;          // 复位后先当自动
        end else begin
            auto_mode <= ~host_mode;    // 主机说了算

            if (host_mode) begin   
                // 手动: 主机写 DATA_REG 时装载阈值
                if (host_wr_en) // 只有 data_reg 被修改过后, 这个才有效.  也就是说, 若cmd_reg = 1, 不改reg值, 就不更新 threhold 值
                    threshold <= host_th;
            end else begin
                // 自动: Otsu 每帧算完就更新
                if (otsu_done)
                    threshold <= otsu_th;
            end
        end
    end
endmodule

