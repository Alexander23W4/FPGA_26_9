`timescale 1ns / 1ps

// Independent, sequential frame-store reader in the processing clock domain.
// The synchronous RAM and two-stage out_arr may finish requests already issued
// after source_ready falls. back_stream reserves FIFO capacity for those pixels.
module back_reader (
    input wire clk, input wire rst,
    input wire frame_ready_toggle, input wire write_buf_idx,
    input wire [31:0] video_mode,
    input wire packet_busy, input wire source_ready,
    output reg read_buf_idx, output wire read_lock,
    output wire [15:0] read_addr, output wire read_en,
    output wire job_start, output wire new_image_start,
    output reg pixel_valid
);
    reg frame_seen, latest_bank, have_frame, pending_image;
    reg active, busy_seen;
    reg [16:0] issued;
    reg [31:0] selected_mode;
    wire published = frame_ready_toggle != frame_seen;
    assign job_start = !rst && !active && have_frame && !published &&
                       (pending_image || video_mode != selected_mode);
    assign new_image_start = job_start && pending_image;
    // Keep the last complete bank reserved even between packets, so mode-only
    // redraws cannot race the writer. A newer published frame moves this lock.
    assign read_lock = have_frame;
    assign read_addr = issued[15:0];
    assign read_en = active && issued < 17'd65536 && source_ready;

    always @(posedge clk) begin
        if (rst) begin
            frame_seen <= 0; latest_bank <= 0; have_frame <= 0; pending_image <= 0;
            active <= 0; busy_seen <= 0; issued <= 0; read_buf_idx <= 0;
            selected_mode <= 0; pixel_valid <= 0;
        end else begin
            pixel_valid <= read_en;
            if (published) begin
                frame_seen <= frame_ready_toggle;
                latest_bank <= write_buf_idx;
                have_frame <= 1;
                pending_image <= 1;
            end
            if (job_start) begin
                read_buf_idx <= latest_bank;
                selected_mode <= video_mode;
                pending_image <= 0;
                active <= 1; busy_seen <= 0; issued <= 0;
            end
            if (read_en) issued <= issued + 1'b1;
            if (active && packet_busy) busy_seen <= 1;
            if (active && busy_seen && !packet_busy) active <= 0;
        end
    end
endmodule
