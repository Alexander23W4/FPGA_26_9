`timescale 1ns/1ps
module tb_cardiac_real_phases;
    reg clk=0,rst=1,frame_valid=0;
    always #5 clk=~clk;
    reg [127:0] values=0;
    reg [127:0] reference[0:255];
    wire [127:0] ed,es;
    wire valid,updated;
    wire [31:0] ed_id,es_id,frame_id;
    integer count,fd,pairs=0;
    string input_path,output_path;
    ed_es_tracker dut(.clk(clk),.rst(rst),.frame_valid(frame_valid),.frame_good(1'b1),
        .volumes_x100(values),.ed_values(ed),.es_values(es),.result_valid(valid),
        .result_updated(updated),.ed_frame_id(ed_id),.es_frame_id(es_id),.frame_id(frame_id));
    always @(posedge clk)if(!rst && updated)begin
        if(ed_id>=count || es_id>=count || ed_id>=es_id)$fatal(1,"invalid ED/ES indices");
        for(int c=0;c<4;c++)begin
            if(ed[c*32+:32]!==reference[ed_id][c*32+:32] ||
               es[c*32+:32]!==reference[es_id][c*32+:32])$fatal(1,"phase snapshot mismatches selected real frame");
        end
        $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",ed_id,es_id,
            ed[31:0],es[31:0],ed[63:32],es[63:32],ed[95:64],es[95:64],ed[127:96],es[127:96]);
        pairs++;
    end
    initial begin
        if(!$value$plusargs("FRAMES=%d",count) || count<1 || count>256)$fatal(1,"FRAMES required, 1..256");
        if(!$value$plusargs("INPUT=%s",input_path) || !$value$plusargs("OUTPUT=%s",output_path))$fatal(1,"INPUT/OUTPUT required");
        $readmemh(input_path,reference,0,count-1);
        fd=$fopen(output_path,"w");if(!fd)$fatal(1,"cannot open phase output");
        $fdisplay(fd,"ed_frame,es_frame,EDV_LA,ESV_LA,EDV_RA,ESV_RA,EDV_LV,ESV_LV,EDV_RV,ESV_RV");
        repeat(4)@(negedge clk);rst=0;
        for(int f=0;f<count;f++)begin
            @(negedge clk);values=reference[f];frame_valid=1;
            @(negedge clk);frame_valid=0;
        end
        repeat(8)@(negedge clk);$fclose(fd);
        $display("[PASS] real volume sequence: %0d frames, %0d ED/ES pairs (no physiological ground truth asserted)",count,pairs);$finish;
    end
    initial begin #100000;$fatal(1,"real phase sequence timeout");end
endmodule
