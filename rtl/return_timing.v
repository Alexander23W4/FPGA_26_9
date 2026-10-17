`timescale 1ns / 1ps

// Same-clock measurement: new-image return start N -> frame-store commit N+1.
// Config-only redraws do not restart the interval. Counts use processing clk;
// the host reads its frequency from CLOCK_HZ (word 0x36).
module return_timing (
    input wire clk, input wire rst,
    input wire new_image_start, input wire frame_commit,
    input wire write_blocked,
    output reg [31:0] interval_cycles,
    output reg [31:0] stall_cycles,
    output reg [31:0] sequence_id
);
    reg measuring;
    reg [31:0] ticks, started_at, blocked;
    always @(posedge clk) begin
        if (rst) begin
            measuring <= 0; ticks <= 0; started_at <= 0; blocked <= 0;
            interval_cycles <= 0; stall_cycles <= 0; sequence_id <= 0;
        end else begin
            ticks <= ticks + 1'b1;
            if (measuring && write_blocked) blocked <= blocked + 1'b1;
            if (frame_commit && measuring) begin
                interval_cycles <= ticks - started_at;
                stall_cycles <= blocked;
                sequence_id <= sequence_id + 1'b1;
                measuring <= 0;
            end
            if (new_image_start) begin
                started_at <= ticks; blocked <= 0; measuring <= 1;
            end
        end
    end
endmodule
