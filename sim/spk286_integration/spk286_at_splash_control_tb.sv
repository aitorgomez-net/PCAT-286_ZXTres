`timescale 1ns/1ps

module spk286_at_splash_control_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic option_off = 1'b0;
    logic second_tick = 1'b0;
    wire  splash_active;
    wire  boot_hold;
    wire  cpu_reset = reset | boot_hold;
    wire  fetch_bus_valid;
    wire [23:0] fetch_address;
    wire fetch_response_valid;
    wire [15:0] fetch_response_data;
    wire [15:0] fetch_response_ip;
    wire [1:0] fetch_response_count;
    logic fetch_ready = 1'b0;

    always #5 clk = ~clk;

    spk286_at_splash_control dut (
        .clk(clk), .reset(reset), .option_off(option_off),
        .second_tick(second_tick), .splash_active(splash_active),
        .boot_hold(boot_hold)
    );

    // Use the real CPU fetch service: the original top-level reset expression
    // released this service during the pending interval, before the splash.
    spk286_fetch fetch (
        .clk(clk), .reset(cpu_reset), .ready(fetch_ready),
        .data_in(16'h12EA), .code_base(24'hFF0000),
        .code_limit(16'hFFFF), .restart(1'b0), .restart_ip(16'hFFF0),
        .request(1'b1), .suspend(1'b0), .response_ready(1'b1),
        .request_ready(), .response_valid(fetch_response_valid),
        .response_data(fetch_response_data), .response_ip(fetch_response_ip),
        .response_count(fetch_response_count), .cursor(), .blocked(),
        .bus_valid(fetch_bus_valid), .bus_bhe_n(), .address(fetch_address)
    );

    always @(negedge clk) begin
        if (boot_hold && fetch_bus_valid)
            $fatal(1, "CPU fetch escaped the boot hold");
    end

    task automatic check_first_fetch;
        begin
            repeat (3) @(negedge clk);
            if (!fetch_bus_valid || fetch_address != 24'hFFFFF0)
                $fatal(1, "first fetch was not the 286 reset vector");
            repeat (8) begin
                @(negedge clk);
                if (!fetch_bus_valid || fetch_address != 24'hFFFFF0 ||
                    fetch_response_valid)
                    $fatal(1, "fetch advanced without READY");
            end
            fetch_ready = 1'b1;
            @(negedge clk);
            fetch_ready = 1'b0;
            if (!fetch_response_valid || fetch_response_ip != 16'hFFF0 ||
                fetch_response_data != 16'h12EA || fetch_response_count != 2'd2)
                $fatal(1, "reset fetch response mismatch");
        end
    endtask

    task automatic pulse_second;
        begin
            @(negedge clk);
            second_tick = 1'b1;
            @(negedge clk);
            second_tick = 1'b0;
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        reset = 1'b0;
        repeat (12) begin
            @(negedge clk);
            if (splash_active || !boot_hold || fetch_bus_valid)
                $fatal(1, "pending splash must hold the CPU before displaying");
        end

        pulse_second();
        #1;
        if (!splash_active || !boot_hold)
            $fatal(1, "splash did not start after the delay");

        repeat (4) begin
            pulse_second();
            #1;
            if (!splash_active || !boot_hold)
                $fatal(1, "splash released the CPU too soon");
        end
        pulse_second();
        #1;
        if (splash_active || boot_hold)
            $fatal(1, "splash did not expire after five seconds");
        check_first_fetch();

        @(negedge clk);
        reset = 1'b1;
        option_off = 1'b0;
        repeat (2) @(negedge clk);
        reset = 1'b0;
        option_off = 1'b1;
        pulse_second();
        #1;
        if (splash_active || boot_hold)
            $fatal(1, "OSD No option did not suppress splash");
        check_first_fetch();

        // Turning Yes back on after a suppressed splash must not restart it.
        option_off = 1'b0;
        repeat (2) pulse_second();
        #1;
        if (splash_active || boot_hold)
            $fatal(1, "OSD Yes unexpectedly restarted the completed boot hold");

        @(negedge clk);
        reset = 1'b1;
        repeat (2) @(negedge clk);
        reset = 1'b0;
        pulse_second();
        #1;
        if (!splash_active || !boot_hold)
            $fatal(1, "reset did not rearm the splash");
        option_off = 1'b1;
        @(negedge clk);
        #1;
        if (splash_active || boot_hold)
            $fatal(1, "OSD No did not dismiss the active splash");
        check_first_fetch();

        $display("AT_SPLASH_RESET_FETCH_PASS address=fffff0 data=12ea");
        $display("AT_SPLASH_CONTROL_PASS");
        $finish;
    end
endmodule
