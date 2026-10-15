

class cov;
    intf itf;

    function new(intf itf);
        this.itf = itf;
    endfunction

    covergroup cg @(posedge clk)
        cp_a: coverpoint itf.a {
            option.auto_bin_max = 128;
        }

        cp_b: coverpoint itf.b;

        cross cp_a, cp_b;
    endgroup

endclass