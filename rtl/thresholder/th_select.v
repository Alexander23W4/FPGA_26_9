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
    // Configuration/status selection. The frame buffer separately snapshots
    // the mode and threshold, so register writes never split an active frame.
    // otsu_th retains the latest completed result, including in manual mode.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            threshold <= 8'd128;        // 默认阈值
            auto_mode <= 1'b1;          // 复位后先当自动
        end else begin
            auto_mode <= ~host_mode;    // 主机说了算

            threshold <= host_mode ? host_th : otsu_th;
        end
    end
    wire _unused = &{1'b0, host_wr_en, otsu_done};
endmodule

