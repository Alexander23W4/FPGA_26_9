`timescale 1ns / 1ps

// 覆盖两个 bank 的独立写入、pclk 域一拍读取及 bank 选择。
module tb_double_buf;
    reg        clk  = 1'b0;
    reg        pclk = 1'b0;
    reg        write_en = 1'b0;
    reg        read_buf_idx = 1'b0;
    reg        write_buf_idx = 1'b0;
    reg [15:0] read_addr = 16'd0;
    reg [15:0] write_addr = 16'd0;
    reg [7:0]  write_data = 8'd0;
    wire [7:0] read_data;

    double_buf dut (
        .clk          (clk),
        .pclk         (pclk),
        .write_en     (write_en),
        .read_buf_idx (read_buf_idx),
        .write_buf_idx(write_buf_idx),
        .read_addr    (read_addr),
        .write_addr   (write_addr),
        .read_data    (read_data),
        .write_data   (write_data)
    );

    always #5 clk  = ~clk;
    always #7 pclk = ~pclk;

    task write_pixel;
        input bank;
        input [15:0] addr;
        input [7:0] data;
        begin
            @(negedge clk);
            write_buf_idx = bank;
            write_addr    = addr;
            write_data    = data;
            write_en      = 1'b1;
            @(posedge clk);
            #1 write_en = 1'b0;
        end
    endtask

    task expect_pixel;
        input bank;
        input [15:0] addr;
        input [7:0] expected;
        begin
            @(negedge pclk);
            read_buf_idx = bank;
            read_addr    = addr;
            @(posedge pclk);
            #1;
            if (read_data !== expected) begin
                $fatal(1, "[FAIL] bank=%0d addr=%0d: got 0x%02h, expected 0x%02h",
                       bank, addr, read_data, expected);
            end
        end
    endtask

    initial begin
        write_pixel(1'b0, 16'd3,  8'hA5);
        write_pixel(1'b1, 16'd3,  8'h5A);
        write_pixel(1'b0, 16'd99, 8'h3C);
        write_pixel(1'b1, 16'd99, 8'hC3);

        expect_pixel(1'b0, 16'd3,  8'hA5);
        expect_pixel(1'b1, 16'd3,  8'h5A);
        expect_pixel(1'b0, 16'd99, 8'h3C);
        expect_pixel(1'b1, 16'd99, 8'hC3);

        $display("[PASS] tb_double_buf");
        $finish;
    end

    initial begin
        #5000;
        $fatal(1, "[FAIL] tb_double_buf timeout");
    end
endmodule
