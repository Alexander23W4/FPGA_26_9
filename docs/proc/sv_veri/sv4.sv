
// covergroup的本质目的就是 统计命中, 也可以用来衡量 coverage 
module cov;

    // 自动采样
    covergroup cg @(posedge clk);
    coverpoint a;
    endgroup

    cg cov_inst = new();

    // 手动sample采样
    covergroup cg;
    coverpoint a;
    endgroup

    cg cov_inst = new();

    always @(abc)
    cov_inst.sample();  //


    covergroup cg @(posedge clk);
        coverpoint a;

        cp_b: coverpoint b;   // 可以加个标签
    endgroup

    cg cp_a = new();

/*
如果没有显式定义 bins，工具会自动创建隐式覆盖桶，通常按取值统计。
对于这个 8 位无符号变量，就是 256 个可能的取值桶。

如果希望把地址分组统计，就可以显式定义 bins。
*/

    // 分组统计命中
    byte a;
    covergroup cg @(posedge clk);
        coverpoint a {
            bins b1 = {0, 2, 7};
            bins b2 = {[10:20]};
            bins b3 = {[30: 40], [50: 80]};

            bins low = {[0: 10]};
            bins mid = {[11: 50]};
            bins high = {[51: $]};
        }
    endgroup
endmodule