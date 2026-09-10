`timescale 1ns/1ps

module spk286_machine_cpu_elab_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic ready = 1'b0;
    logic [15:0] data_in = 16'd0;

    logic [23:0] address;
    logic [15:0] data_out;
    logic data_oe, bus_valid, bus_write, bus_bhe_n, bus_lock, hlda;
    logic [3:0] bus_status;
    logic halted, shutdown, control_error, unsupported_opcode;
    logic microcode_fault, operand_blocked, event_completed;
    logic [7:0] debug_event_vector, debug_opcode;
    logic [2:0] debug_event_kind;
    logic [15:0] debug_cs, debug_ip, debug_flags;
    logic [23:0] debug_cs_base;
    logic [127:0] debug_gpr;
    logic [11:0] debug_micro_pc;
    logic [3:0] debug_bus_state;

    always #5 clk = ~clk;

    spk286_machine_cpu dut (
        .clk(clk), .reset(reset), .execute_enable(1'b1),
        .ready(ready), .data_in(data_in),
        .intr(1'b0), .nmi(1'b0), .hold_request(1'b0),
        .address(address), .data_out(data_out), .data_oe(data_oe),
        .bus_valid(bus_valid), .bus_write(bus_write),
        .bus_bhe_n(bus_bhe_n), .bus_status(bus_status),
        .bus_lock(bus_lock), .hlda(hlda),
        .halted(halted), .shutdown(shutdown),
        .control_error(control_error),
        .unsupported_opcode(unsupported_opcode),
        .microcode_fault(microcode_fault),
        .operand_blocked(operand_blocked),
        .event_completed(event_completed),
        .debug_event_vector(debug_event_vector),
        .debug_event_kind(debug_event_kind),
        .debug_opcode(debug_opcode), .debug_cs(debug_cs),
        .debug_cs_base(debug_cs_base), .debug_ip(debug_ip),
        .debug_flags(debug_flags), .debug_gpr(debug_gpr),
        .debug_micro_pc(debug_micro_pc), .debug_bus_state(debug_bus_state)
    );

    initial begin : test
        integer cycles;
        repeat (4) @(posedge clk);
        reset = 1'b0;
        for (cycles = 0; cycles < 40 && !bus_valid; cycles = cycles + 1)
            @(posedge clk);
        if (!bus_valid)
            $fatal(1, "native reset fetch did not become valid");
        if (address !== 24'hfffff0 || bus_status !== 4'hd ||
            bus_write !== 1'b0 || data_oe !== 1'b0 || bus_bhe_n !== 1'b0)
            $fatal(1, "wrong reset request address=%h status=%h bhe_n=%b", address, bus_status, bus_bhe_n);
        if (debug_cs !== 16'hf000 || debug_cs_base !== 24'hff0000 ||
            debug_ip !== 16'hfff0)
            $fatal(1, "wrong native reset state cs=%h base=%h ip=%h", debug_cs, debug_cs_base, debug_ip);
        if (control_error || unsupported_opcode || microcode_fault || shutdown)
            $fatal(1, "unexpected CPU diagnostic during reset fetch");
        $display("I1_CPU_PACKAGE_PASS address=%h cs=%h base=%h ip=%h", address, debug_cs, debug_cs_base, debug_ip);
        $finish;
    end
endmodule
