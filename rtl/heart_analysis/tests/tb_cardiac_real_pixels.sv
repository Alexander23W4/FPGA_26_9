`timescale 1ns/1ps
module tb_cardiac_real_pixels;
    reg clk=0,rst=1,in_valid=0,out_ready=0;
    always #5 clk=~clk;
    reg [3:0] mask_memory[0:65535];
    reg [127:0] reference[0:255];
    reg [3:0] offered=0;
    reg eof=0;
    wire in_ready,out_valid,out_eof;
    wire [3:0] out_masks;
    wire [127:0] ed,es;
    integer frames,fd,count=0,pairs=0,cycles=0,received=0,sent=0;
    reg [4:0] expected[$];
    string mask_dir,input_path,output_path;
    medical_accel_top dut(.clk(clk),.rst(rst),.in_data(8'd0),
        .in_valid(in_valid),.in_ready(in_ready),.in_eof(eof),
        .in_LA_mask(offered[0]),.in_RA_mask(offered[1]),.in_LV_mask(offered[2]),.in_RV_mask(offered[3]),
        .in_LA_ctr(1'b0),.in_RA_ctr(1'b0),.in_LV_ctr(1'b0),.in_RV_ctr(1'b0),
        .out_ready(out_ready),.out_valid(out_valid),.out_eof(out_eof),
        .out_LA_mask(out_masks[0]),.out_RA_mask(out_masks[1]),.out_LV_mask(out_masks[2]),.out_RV_mask(out_masks[3]),
        .VOLUME_LA(),.VOLUME_RA(),.VOLUME_LV(),.VOLUME_RV(),.VOLUME_SEQ(),.VOLUME_STATUS());
    // Legacy phase oracle is test-only; production phase detection now runs in PS.
    wire reference_update;
    ed_es_tracker reference_tracker(.clk(clk),.rst(rst),.frame_valid(dut.frame_valid),
        .frame_good(dut.frame_good),.volumes_x100(dut.frame_volumes),
        .ed_values(ed),.es_values(es),.result_valid(),.result_updated(reference_update),
        .ed_frame_id(),.es_frame_id(),.frame_id());
    always @(negedge clk)out_ready=!rst && cycles%8192<8187;
    always @(posedge clk)begin
        cycles++;
        if(!rst)begin
            if(in_valid && in_ready)begin expected.push_back({eof,offered});sent++;end
            if(out_valid && out_ready)begin
                reg [4:0] value;
                if(expected.size()==0)$fatal(1,"unexpected real mask output");
                value=expected.pop_front();
                if({out_eof,out_masks}!==value)$fatal(1,"real mask/EOF damaged under backpressure");
                received++;
            end
            if(dut.frame_valid)begin
                if(!dut.frame_good || count>=frames || dut.frame_volumes!==reference[count])
                    $fatal(1,"real mask geometry mismatch frame %0d got=%h expected=%h",count,dut.frame_volumes,reference[count]);
                count++;
            end
            if(reference_update)begin
                $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",reference_tracker.ed_frame_id,reference_tracker.es_frame_id,
                    ed[31:0],es[31:0],ed[63:32],es[63:32],ed[95:64],es[95:64],ed[127:96],es[127:96]);
                pairs++;
            end
        end
    end
    initial begin
        if(!$value$plusargs("FRAMES=%d",frames) || frames<1 || frames>256)$fatal(1,"FRAMES required");
        if(!$value$plusargs("MASK_DIR=%s",mask_dir) || !$value$plusargs("INPUT=%s",input_path) ||
           !$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"data paths required");
        $readmemh(input_path,reference,0,frames-1);
        fd=$fopen(output_path,"w");if(!fd)$fatal(1,"cannot open real-pixel result");
        $fdisplay(fd,"ed_frame,es_frame,EDV_LA,ESV_LA,EDV_RA,ESV_RA,EDV_LV,ESV_LV,EDV_RV,ESV_RV");
        repeat(4)@(negedge clk);rst=0;
        for(int f=0;f<frames;f++)begin
            $readmemh($sformatf("%s/frame_%03d.hex",mask_dir,f),mask_memory);
            for(int i=0;i<65536;i++)begin
                @(negedge clk);in_valid=1;eof=i==65535;offered=mask_memory[i];
                do @(posedge clk);while(!in_ready);
            end
            @(negedge clk);in_valid=0;eof=0;
        end
        wait(received==frames*65536 && count==frames);
        repeat(12)@(negedge clk);$fclose(fd);
        if(sent!=received || expected.size()!=0)$fatal(1,"real pixel count mismatch");
        $display("[PASS] real pixel stream: %0d frames / %0d pixels match reference exactly; %0d phase pairs",count,sent,pairs);$finish;
    end
    initial begin #200000000;$fatal(1,"real pixel stream timeout");end
endmodule
