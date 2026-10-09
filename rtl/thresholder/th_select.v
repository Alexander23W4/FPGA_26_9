`timescale 1ns / 1ps

module th_select (
    input  wire        clk,         // system clock
    input  wire        rst,         // reset, active high
    input  wire [7:0]  otsu_th,     // Otsu threshold from otsu_core
    input  wire        otsu_done,   // one-cycle pulse when otsu_th is ready
    input  wire        host_wr_en,  // one-cycle pulse when host writes DATA_REG
    input  wire [7:0]  host_th,     // threshold value written by host
    output reg  [7:0]  threshold,   // final threshold used by segmenter
    output reg         auto_mode    // 1 = auto (Otsu), 0 = manual (host)
);
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            threshold <= 8'd128;    // default threshold
            auto_mode <= 1'b1;      // start in auto mode
        end else begin
            // Auto load Otsu result only when still in auto mode
            if (otsu_done && auto_mode)
                threshold <= otsu_th;

            // Host writes threshold -> switch to manual mode
            if (host_wr_en) begin
                threshold <= host_th;
                auto_mode <= 1'b0;
            end
        end
    end
endmodule

