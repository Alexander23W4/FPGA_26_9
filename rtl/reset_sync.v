`timescale 1ns / 1ps

// Common asynchronous assertion, separate synchronous release in every domain.
module reset_sync(input wire clk, input wire arst, output wire rst);
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [2:0] release_pipe = 3'b111;
    always @(posedge clk or posedge arst)
        if (arst) release_pipe <= 3'b111;
        else release_pipe <= {release_pipe[1:0], 1'b0};
    assign rst = release_pipe[2];
endmodule
