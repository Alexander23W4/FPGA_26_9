`timescale 1ns / 1ps

// Cache one denoised frame, calculate its own Otsu threshold, then replay it.
// Hold mode/threshold for the entire replay, and wait for contour output EOF
// before accepting the next frame. RAM has a synchronous read port for BRAM.
module otsu_frame_buffer (
    input wire clk, input wire rst,
    input wire [7:0] s_data, input wire s_valid, output wire s_ready, input wire s_last,
    output reg [7:0] m_data, output reg m_valid, input wire m_ready, output reg m_last,
    input wire host_mode, input wire [7:0] host_threshold,
    input wire output_frame_done,
    output reg [7:0] frame_threshold, output reg frame_auto,
    output wire frame_busy,
    output wire [7:0] auto_threshold, output wire auto_done
);
    localparam [2:0] CAPTURE=0, WAIT_THRESHOLD=1, PRIME=2, REPLAY=3, DRAIN=4;
    reg [2:0] state;
    (* ram_style = "block" *) reg [7:0] pixels [0:65535];
    reg [16:0] write_count, frame_length, next_read;
    reg [7:0] manual_threshold;
    wire otsu_ready;
    wire take_input = s_valid && s_ready;
    wire read_enable = state == PRIME ||
        (state == REPLAY && m_valid && m_ready && !m_last);
    wire [15:0] read_address = state == PRIME ? 16'd0 : next_read[15:0];

    assign s_ready = state == CAPTURE && otsu_ready && write_count < 17'd65536;
    assign frame_busy = state != CAPTURE || write_count != 0;

    otsu_core u_otsu (
        .clk(clk), .rst(rst), .pix_in(s_data), .valid_in(s_valid),
        .en(s_ready), .frame_done(s_last), .otsu_th(auto_threshold),
        .otsu_done(auto_done), .ready(otsu_ready)
    );

    // No RAM reset: every address read belongs to this frame's accepted input.
    always @(posedge clk) begin
        if (take_input) pixels[write_count[15:0]] <= s_data;
        if (read_enable) m_data <= pixels[read_address];
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= CAPTURE; write_count <= 0; frame_length <= 0; next_read <= 0;
            manual_threshold <= 0; frame_threshold <= 128; frame_auto <= 1;
            m_valid <= 0; m_last <= 0;
        end else begin
            case (state)
                CAPTURE: if (take_input) begin
                    if (write_count == 0) begin
                        frame_auto <= !host_mode;
                        manual_threshold <= host_threshold;
                        if (host_mode) frame_threshold <= host_threshold;
                    end
                    write_count <= write_count + 1'b1;
                    if (s_last) begin
                        frame_length <= write_count + 1'b1;
                        state <= WAIT_THRESHOLD;
                    end
                end
                WAIT_THRESHOLD: if (auto_done) begin
                    frame_threshold <= frame_auto ? auto_threshold : manual_threshold;
                    state <= PRIME;
                end
                PRIME: begin
                    m_valid <= 1;
                    m_last <= frame_length == 1;
                    next_read <= 1;
                    state <= REPLAY;
                end
                REPLAY: if (m_ready) begin
                    if (m_last) begin
                        m_valid <= 0; m_last <= 0;
                        state <= DRAIN;
                    end else begin
                        m_last <= next_read == frame_length - 1'b1;
                        next_read <= next_read + 1'b1;
                    end
                end
                DRAIN: if (output_frame_done) begin
                    write_count <= 0;
                    state <= CAPTURE;
                end
                default: begin state <= CAPTURE; write_count <= 0; m_valid <= 0; end
            endcase
        end
    end
endmodule
