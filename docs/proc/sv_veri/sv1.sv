
module sv1_enum (
    ports
);
/*
enum {IDLE = 0, OPERATE, FEEDBACK} States;

first()	returns the value of the first member of the enumeration
last()	returns the value of the last member of the enumeration
next()	returns the value of next member of the enumeration
next(N)	returns the value of next Nth member of the enumeration
prev()	returns the value of previous member of the enumeration
prev(N)	returns the value of previous Nth member of the enumeration
num()	returns the number of elements in the given enumeration
name()	returns the string representation of the given enumeration value
*/
    enum {RED = 0, YELLOW = 1, BLUE, BLACK} Color;
    string s0 = "Hello World";

    // process begins:
    initial begin
        Color = Color.first

        for (integer i = 0; i < 4; i++ ) begin
            $display("Color :: color of %0s is %0d. ", Color.name, Color);
            Color = Colors.next;
        end
    end
    
endmodule


module sv1_arr (
    ports
);
    
/*
int array1 [6];            //fixed size single dimension array
int array2 [5:0];          //fixed size single dimension array
int array3 [3:0][2:0];     //fixed size multi dimension array
bit [7:0] array4[2:0];     //unpacked array declaration
bit [2:0][7:0] array5;     //packed array declaration
bit [2:0][7:0] array6 [3]; //mixed packed and unpacked array
*/

    bit [7:0] arr1 [3:0];
    bit [7:0][3:0] arr2 [3:0];

    byte arr3 [3:0];
    byte arr4 [5]; // 0-4

/*
The space for a dynamic array doesn’t exist until the array is explicitly created at run-time, 
    space is allocated when new[number] is called. 

new[ ]    –> allocates the storage.
size( )    –> returns the current size of a dynamic array.
delete( ) –> empties the array, resulting in a zero-sized array.
*/

    bit [7:0] arr [];

/*
   bit    queue_1[$];     // queue of bits  (unbound queue)
   int    queue_2[$];     // queue of int  
   byte   queue_3[$:255]; // queue of byte (bounded queue with 256 entries)
   string queue_4[$];     // queue of strings
*/



endmodule

module proc;

    initial begin
        
        rst = 1;

        repeat(5) begin
            @(posedge clk) begin
                $display("%0d", rst);
            end
        end

        @(negedge clk);
        rst = 0;
    end

    int a;
    initial begin
        $display("-----------------------------------------------------------------");
    
        forever begin
        $display("\tValue of a=%0d",a);
        a++;
        #5;
        end
    
        $display("-----------------------------------------------------------------");
    end
    initial begin
        #20 $finish;
    end   

    class temp
        rand int a;
        randc int b;
    endclass //temp

    initial begin
        temp tp;
        tp = new();
        repeat (10) begin
            tp.randomize();
            $display(...);
        end
    end

    int a;

    class temp;
        rand bit [31:0] addr;
        rand bit [31:0] data;
    endclass

    initial begin
        temp tp;
        tp = new();

        tp.addr.random_mode(0);   // disable randomization for addr
        
        tp.randomize();
    end

    class temp;
        bit fix_data;
        rand bit [31:0] data;
        rand bit [31:0] add;
        bit [31:0] sum;

        function void pre_randomize();    // 
            if(fix_data) begin
                data.rand_mode(0);
            end else begin
                data.rand_mode(1);
            end

            add.rand_mode(!fix_data);
        endfunction

        function void post_randomize();   // 
            sum = data + add; 
        endfunction

        constraint add_range{
            data > 10;
        }

    endclass

    initial begin
        temp tp;
        tp = new();

        repeat(10) begin
            assert(tp.randomize());   //

        end
    end

    class axi_lite_read;
        rand bit [31:0] araddr;
        bit arvalid;
        bit rready;

        rand bit [31:0] addr_start;
        rand bit [31:0] addr_end;

        constraint addr_range_0 {     //
            ! (araddr inside {[addr_start: addr_end]})   //
        }
        
        constraint addr_range {
            if(arvalid) begin
                araddr inside {32'h0000, 32'h0f0f};  //
            end
        }
    endclass

    // dist 例如大多数时候连续传输像素，偶尔插入传输间隔，或者提高边界像素、特殊寄存器值的测试频率。

    class axi_lite_write;
        rand bit [15:0] awaddr;
        rand bit [15:0] wdata;

        constraint wdata_range{
            wdata dist {                  //
                [0:16'h7fff] := 1,           //
                [16'h8000:16'hffff] := 2
            };
        }

        constraint awaddr_range{
            awaddr dist {
                [0:16'h7fff] := 5,      // 每个都有5份的权重
                [16'h8000:16'hffff] :/ 10    // 所有分摊10份的权重
            }
        }
    endclass

    class temp;
        rand byte addr[4];

        constraint addr_range {
            foreach (addr[i]) {     // 生成有规律的随机数
                addr[i] > i * 4;
                addr[i] < (i + 1) * 8;
            }
        }
    endclass

    // 这个例子更具实用价值: constraint框 内部可以加各种判断来操作随机数约束
    class axi_write_txn;
        rand bit [15:0] awaddr;
        rand bit [31:0] wdata;
        rand bit [3:0]  wstrb;

        constraint addr_range {
            awaddr inside {[16'h0000:16'hFFFF]};
        }

        constraint aligned_addr {
            awaddr[1:0] == 2'b00;
        }
    endclass

// ★: 刚刚我们定义的这些类都是transaction 类
/*
    Transaction 类
    定义事务有哪些字段、哪些值合法

    创建对象并调用 randomize()
    生成一组满足约束的地址、数据和字节使能

    Driver
    读取事务字段，按时序驱动 AXI 信号

    DUT
    接收实际的总线传输
*/

endmodule


