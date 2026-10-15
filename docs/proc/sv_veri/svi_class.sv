
// What are parameterized classes?   参数化类
class DataContainer #(parameter type T = int);
    T data;

    function new(T data);
        this.data = data;
    endfunction

    function void display();
        $display("data = %0d", data);
    endfunction
endclass


// What is an abstract class?   抽象类  这个可以在定义 transaction 和 不同用途的的 generator 时使用
virtual class Transaction;

    int id;

    function new(int id);
        this.id = id;
    endfunction

    pure virtual function void display();

endclass

class ReadTransaction extends Transaction;

    function new(int id);
        super.new(id);
    endfunction

    function void display();
        $display("Read transaction, id=%0d", id);
    endfunction

endclass


// What is the difference between an initial and final block of the systemverilog?   类的重写  方法的重载(sv不支持)

class Animal;
    virtual function void speak();
        $display("Animal sound");
    endfunction
endclass

class Dog extends Animal;
    function void speak();
        $display("Woof");
    endfunction
endclass

module tb;
    initial begin
        Animal a;
        a = new Dog();
        a.speak();
    end
endmodule


// Explain the difference between deep copy and shallow copy?  类的 深拷贝 & 浅拷贝

// 浅拷贝  只是虚有其名 实际还是指向原有对象 
class Header;
    int id;
endclass

class Packet;
    Header hdr;
    int data;

    function new();
        hdr = new();
    endfunction
endclass

module tb;
    Packet p1, p2;

    initial begin
        p1 = new();
        p1.hdr.id = 10;
        p1.data = 100;

        p2 = new p1;  // 浅拷贝

        p2.hdr.id = 20;
        p2.data = 200;

        $display("p1.hdr.id = %0d", p1.hdr.id);    // 20
        $display("p1.data   = %0d", p1.data);      // 200
    end
endmodule

// 深拷贝需要自己实现
class Header;
    int id;

    function Header clone();
        Header h = new();
        h.id = this.id;
        return h;
    endfunction
endclass

class Packet;
    Header hdr;
    int data;

    function new();
        hdr = new();
    endfunction

    function Packet clone();
        Packet p = new();
        p.data = this.data;
        p.hdr = this.hdr.clone();
        return p;
    endfunction
endclass

module tb;
    Packet p1, p2;

    initial begin
        p1 = new();
        p1.hdr.id = 10;
        p1.data = 100;

        p2 = p1.clone();  // 深拷贝

        p2.hdr.id = 20;
        p2.data = 200;

        $display("p1.hdr.id = %0d", p1.hdr.id);
        $display("p1.data   = %0d", p1.data);
    end
endmodule



// What is the use of extern?   类外声明
class Packet;
    int addr;

    extern function void print_addr();
endclass

function void Packet::print_addr();
    $display("addr = %0d", addr);
endfunction


// What is the scope of local and private variables?  类内变量可访问性  local protected public(默认)
class Parent;
    local     int a = 10;
    protected int b = 20;
             int c = 30;

    function void show();
        $display("a=%0d b=%0d c=%0d", a, b, c);
    endfunction
endclass

class Child extends Parent;
    function void test();
        // $display("%0d", a); // 编译错误：local 成员不可由派生类访问
        $display("%0d", b);    // 合法：protected 成员可由派生类访问
        $display("%0d", c);    // 合法：默认公开访问
    endfunction
endclass

