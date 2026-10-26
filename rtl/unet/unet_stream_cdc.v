`timescale 1ns/1ps
// Preserve data and EOF as one atomic word across the dedicated U-Net clock.
// Small distributed FIFOs keep scarce BRAM available for feature caching.
module unet_stream_cdc #(parameter integer WIDTH=9)(
    input wire s_clk,s_rst,m_clk,m_rst,
    input wire [WIDTH-1:0] s_data,input wire s_valid,output wire s_ready,
    output wire [WIDTH-1:0] m_data,output wire m_valid,input wire m_ready
);
    wire full,empty,wr_busy,rd_busy;
    assign s_ready=!s_rst&&!wr_busy&&!full;
    assign m_valid=!m_rst&&!rd_busy&&!empty;
    xpm_fifo_async #(
        .CDC_SYNC_STAGES(3),.DOUT_RESET_VALUE("0"),.ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("distributed"),.FIFO_READ_LATENCY(0),.FIFO_WRITE_DEPTH(32),
        .FULL_RESET_VALUE(0),.PROG_EMPTY_THRESH(5),.PROG_FULL_THRESH(27),
        .RD_DATA_COUNT_WIDTH(6),.READ_DATA_WIDTH(WIDTH),.READ_MODE("fwft"),
        .RELATED_CLOCKS(0),.SIM_ASSERT_CHK(1),.USE_ADV_FEATURES("0000"),
        .WAKEUP_TIME(0),.WRITE_DATA_WIDTH(WIDTH),.WR_DATA_COUNT_WIDTH(6)
    ) storage(
        .rst(s_rst),.wr_clk(s_clk),.rd_clk(m_clk),.sleep(1'b0),
        .din(s_data),.wr_en(s_valid&&s_ready),.full(full),.wr_rst_busy(wr_busy),
        .dout(m_data),.rd_en(m_valid&&m_ready),.empty(empty),.rd_rst_busy(rd_busy),
        .injectdbiterr(1'b0),.injectsbiterr(1'b0),.data_valid(),.dbiterr(),.sbiterr(),
        .overflow(),.underflow(),.prog_empty(),.prog_full(),.almost_empty(),.almost_full(),
        .rd_data_count(),.wr_data_count(),.wr_ack()
    );
endmodule
