
/*
--> Monitor
Samples the interface signals and converts the signal level activity to the transaction level.
Send the sampled transaction to Scoreboard via Mailbox.
*/

class monitor;
    virtual intf itf;
    mailbox mbx;

    function new(mailbox mbx, intf itf);
        this.mbx = mbx;
        this.itf = itf;
    endfunction

    // Sampling logic and sending the sampled transaction to the scoreboard.
    task samp;

    endtask

endclass

