
`include "transaction.sv"
`include "generator.sv"
`include "driver.sv"
`include "monitor.sv"
`include "scoreboard.sv"
`include "adder.sv"

/*
Environment is container class contains all verification components

整合仿真组件, 搭建仿真全流程
但是不连接DUT
*/

class env;
    generator gen;
    driver dr;
    monitor mon;
    scoreboard scb;
    cov cov;

    mailbox mbx_t, mbx_m;

    virtual intf itf;

    function new(intf itf);   // [初始化] new 的作用就是把这个class(新object)里面的 变量/类 能初始化的都初始化好
        this.itf = itf;

        mbx_t = new();
        mbx_m = new();

        gen = new(mbx_t);
        dr = new(mbx_t, itf);
        mon = new(mbx_m, itf);
        scb = new(mbx_m);

        cov = new(itf);
    endfunction

    task pre_test();
        // dr.reset();
    endtask

    task test();
        fork
            gen.gen();
            dr.send();
            mon.samp();
            scb.main();
        join_any
    endtask

    task post_test();
        wait(gen.ended.triggered);    // gen里面的gen.ended事件在这里用上了, 控制仿真结束
        wait(gen.repeat_count == driv.no_transactions);

        cov.cg.get_coverage();   // 
    endtask

    task run;
        pre_test();
        test();
        post_test();
        $finish;
    endtask

endclass
