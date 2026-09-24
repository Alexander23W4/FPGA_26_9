// Parameterized single-clock (synchronous) FIFO with first-word fall-through
// (show-ahead) read. Suitable for elastic buffering within one clock domain.
//
// Interface summary
//   wr_en / din        write side; din is captured when wr_en && !full
//   rd_en / dout       read  side; dout holds the head word; one word is removed
//                      on the clock edge where rd_en && !empty
//   full / empty / count
//
// DEPTH must be a power of two (it sizes the internal pointer wrap logic and
// the memory array). DATA_WIDTH is the word width in bits.
module sync_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int DEPTH      = 32,
    parameter int PTR_W      = $clog2(DEPTH)
) (
    input  logic clk,
    input  logic rst_n,

    // write side
    input  logic                  wr_en,
    input  logic [DATA_WIDTH-1:0] din,

    // read side
    input  logic                  rd_en,
    output logic [DATA_WIDTH-1:0] dout,

    output logic                  full,
    output logic                  empty,
    output logic [$clog2(DEPTH+1)-1:0] count
);

    // The output word is taken combinationally from the memory at the current
    // read pointer (first-word fall-through). This maps to FPGA distributed
    // RAM (async read); see top-level comment if converting to BRAM.
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    logic [PTR_W-1:0]      wr_ptr;
    logic [PTR_W-1:0]      rd_ptr;

    assign dout = mem[rd_ptr];
    assign full  = (count == DEPTH);
    assign empty = (count == 0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {PTR_W{1'b0}};
            rd_ptr <= {PTR_W{1'b0}};
            count  <= '0;
        end else begin
            case ({wr_en && !full, rd_en && !empty})
                2'b10: count <= count + 1; // write only
                2'b01: count <= count - 1; // read only
                default: ;                 // simultaneous or none
            endcase

            if (wr_en && !full) begin
                mem[wr_ptr] <= din;
                wr_ptr      <= wr_ptr + 1'b1;
            end

            if (rd_en && !empty) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end
endmodule
