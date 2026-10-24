`timescale 1ns/1ps
module tb_cardiac_phases;
    reg clk=0,rst=1,frame_valid=0,frame_good=1;
    always #5 clk=~clk;
    reg [127:0] values=0;
    wire [127:0] ed,es;
    wire valid,updated;
    wire [31:0] ed_id,es_id,frame_id;
    integer updates=0;
    integer wave[0:22]='{6,8,10,12,12,10,8,6,4,4,6,8,10,11,11,9,7,5,3,3,5,7,9};
    ed_es_tracker dut(.clk(clk),.rst(rst),.frame_valid(frame_valid),.frame_good(frame_good),
        .volumes_x100(values),.ed_values(ed),.es_values(es),
        .result_valid(valid),.result_updated(updated),.ed_frame_id(ed_id),.es_frame_id(es_id),.frame_id(frame_id));
    function automatic [127:0] vector(input integer lv,input bit missing_rv);
        vector={32'(missing_rv?0:lv*8000),32'(lv*1000),32'(30000+lv*3000),32'(200000-lv*5000)};
    endfunction
    always @(posedge clk) if(!rst && updated)begin
        updates++;
        case(updates)
            1:begin
                if(ed_id!==4 || es_id!==9)$fatal(1,"first pair frames %0d/%0d",ed_id,es_id);
                if(ed!=={32'hffffffff,32'd12000,32'd66000,32'd140000} ||
                   es!=={32'hffffffff,32'd4000,32'd42000,32'd180000})
                    $fatal(1,"first phase snapshots wrong ED=%h ES=%h",ed,es);
            end
            2:begin
                if(ed_id!==14 || es_id!==19)$fatal(1,"second pair frames %0d/%0d",ed_id,es_id);
                if(ed!==vector(11,0) || es!==vector(3,0))
                    $fatal(1,"second pair retained historical extrema ED=%h ES=%h",ed,es);
            end
            default:$fatal(1,"unexpected cycle result after a broken/flat sequence");
        endcase
    end
    task automatic sample(input [127:0] v,input bit good);
        @(negedge clk);values=v;frame_good=good;frame_valid=1;
        @(negedge clk);frame_valid=0;
        repeat($urandom_range(0,4))@(negedge clk);
    endtask
    initial begin
        repeat(4)@(negedge clk);rst=0;
        // Flat/noisy sequences must not manufacture ED/ES results.
        for(int i=0;i<30;i++)sample(vector(10,0)+{32'd0,32'((i%3)*10),64'd0},1);
        repeat(3)@(negedge clk);
        if(valid || updates || ed!=={4{32'hffffffff}})$fatal(1,"flat noise created a result");
        rst=1;repeat(3)@(negedge clk);rst=0;
        // A clip starting in contraction must not call its first frame ED.
        sample(vector(12,0),1);sample(vector(10,0),1);sample(vector(8,0),1);
        sample(vector(6,0),1);sample(vector(4,0),1);sample(vector(6,0),1);sample(vector(8,0),1);
        repeat(4)@(negedge clk);
        if(valid || updates)$fatal(1,"truncated initial contraction created an ED/ES pair");
        rst=1;repeat(3)@(negedge clk);rst=0;
        for(int i=0;i<23;i++)sample(vector(wave[i],i==4),1);
        repeat(4)@(negedge clk);
        if(updates!=2 || !valid)$fatal(1,"did not publish both cycles: %0d",updates);
        // An invalid frame splits the waveform; retain last completed pair.
        sample(vector(13,0),1);sample(vector(10,0),1);sample(vector(8,0),1);
        sample(vector(1,0),0);
        sample(vector(4,0),1);sample(vector(6,0),1);sample(vector(8,0),1);
        sample(vector(0,0),1);
        for(int i=0;i<250;i++)sample(vector(5,0),1);
        repeat(4)@(negedge clk);
        if(updates!=2 || ed!==vector(11,0) || es!==vector(3,0))$fatal(1,"invalid data overwrote last pair");
        rst=1;repeat(3)@(negedge clk);
        if(valid || ed!=={4{32'hffffffff}} || es!=={4{32'hffffffff}})$fatal(1,"reset did not clear pair");
        $display("[PASS] tb_cardiac_phases: 2 cycles, lower second ED, shared atrial timing, missing RV, noise, invalid gap, timeout, reset");$finish;
    end
    initial begin #200000;$fatal(1,"phase test timeout");end
endmodule
