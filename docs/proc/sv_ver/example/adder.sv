
/*
--> Monitor
Samples the interface signals and converts the signal level activity to the transaction level.
Send the sampled transaction to Scoreboard via Mailbox.
*/

module adder(
    input logic [7:0] a;
    input logic [7:0] b;
    output logic [7:0] c;
);
    assign c = a + b;
endmodule

interface intf;
    logic [7:0] a;
    logic [7:0] b;
    logic [7:0] c;
endinterface

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