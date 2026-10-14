
// covergroup的本质目的就是 统计命中, 也可以用来衡量 coverage 
// 覆盖率统计的是被命中的 bin 占全部 bin 的比例，不一定是被采样过的不同数值占所有可能数值的比
module cov;

    // 自动采样    这样driver给激励之前, 只要new一个cg的object, 就会自动统计coverage
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
            // 取值覆盖
            bins b1 = {0, 2, 7};
            bins b2 = {[10:20]};
            bins b3 = {[30: 40], [50: 80]};

            bins low = {[0: 10]};
            bins mid = {[11: 50]};
            bins high = {[51: $]};

            bins default_bin = default;  // 剩下的值, 适合发现未被分类的数据   不计入覆盖率分母

            // 转换覆盖
            bins t1 = (10, 20 => 30, 40 => 127);

            // 覆盖率不统计这些值
            ignore_bins igb = {6, 60, 66};
            illegal_bins ilb = {100, 111};
        }
    endgroup


/*
cross coverage:
覆盖率的经典问题:

单变量覆盖率不能说明问题, 需要看看多变量一起的种种情况有没有被充分覆盖
*/

    covergroup cg @(posedge clk);
        coverpoint a;
        coverpoint b;
        AxB: cross a, b;   // 统计 a, b 的交叉覆盖情况

        CaD: coverpoint: c + d;
        cross  AxB, CaD;

        aXb: cross a, b+c; // 不合法

    endgroup

    bit [7:0] addr;

    covergroup cg @(posedge clk);
        coverpoint a {
            option.at_least = 2;
            option.auto_bin_max = 128;    // 注意! 系统是会自己分bins的, 默认auto_bin_max是64
            option.cross_auto_bin_max = 128;
        }
    endgroup

// 能用 parameter 表达的模块配置，优先使用 parameter；需要控制条件编译或预处理文本替换时，再使用 `define。

endmodule