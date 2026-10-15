
/*
Scoreboard receives the sampled packet from the monitor and compare with the expected result, 
an error will be reported if the comparison results in a mismatch.

所以这里我们可以使用 immediate assert 去断言结果, 并输出结果
*/

class scoreboard;
    mailbox mbx;
    packet pkt;

    int num_transac;  //

    function new(mailbox mbx);
        this.mbx = mbx;
    endfunction

    task automatic main;
        forever begin
            mbx.get(pkt);
            assert(pkt.a + pkt.b == pkt.c);  //
            num_transac++;
            display("[SCOREBOARD]")
        end
    endtask

endclass
