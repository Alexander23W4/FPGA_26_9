
// generator 产生一个随机transaction激励, 通过mailbox传给driver

class generator;
    packet pkt;
    mailbox mbx;

    event gen_end;   // ★
    int repeat_cnt;    //

    function new(mailbox mbx);
        this.mbx = mbx;
    endfunction

/*
    在 module、interface 等作用域中声明的 task/function： 默认是 static
    在 class 中声明的 task/function： 默认是 automatic
*/
    task automatic gen;
        pkt = new();
        repeat(repeat_cnt) begin
            if(pkt.randomize()) begin
                mbx.put(pkt);
            end else begin
                $fatal("error randomization");
            end
        end
        ->gen_end;  // 
    endtask

endclass