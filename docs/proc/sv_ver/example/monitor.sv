
/*
--> Monitor
Samples the interface signals and converts the signal level activity to the transaction level.
Send the sampled transaction to Scoreboard via Mailbox.
*/

class monitor;
    virtual intf itf;
    mailbox mbx;
    packet pkt;

    function new(mailbox mbx, intf itf);
        this.mbx = mbx;
        this.itf = itf;
    endfunction

    // Sampling logic and sending the sampled transaction to the scoreboard.
    task samp;
        forever begin
            pkt = new();

            @(posedge clk);
            wait(itf.valid);
            pkt.a = itf.a;
            pkt.b = itf.b;

            @(posedge clk);
            pkt.c = itf.c;

            pkt.display("[MONITOR]");
            mbx.put(pkt);
        end
    endtask

endclass

