

module IPC;

    semaphore sema;    // 信号量

    initial begin
        sema = new(1);

        fork    // 这里同时创建了两个进程
            display();
            display();
        join
    end

    task automatic display();
        sema.get();

        $display($time, "\tCurrent Simulation Time");

        #30;

        sema.put();
    endtask


  initial begin
    sema=new(4); //creating sema with '4' keys

    fork
      display(2); //process-1
      display(3); //process-2
      display(2); //process-3
      display(1); //process-4
    join
  end

  //display method
  task automatic display(int key);
    sema.get(key); 
    $display($time,"\tCurrent Simulation Time, Got %0d keys",key);
    #30;
    sema.put(key); 
  endtask


endmodule