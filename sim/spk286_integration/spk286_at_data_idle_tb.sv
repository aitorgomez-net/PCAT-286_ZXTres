`timescale 1ns/1ps
module spk286_at_data_idle_tb;
    logic clk = 0, reset = 1;
    always #5 clk = ~clk;
    logic cancel_cpu = 0, enable = 1;
    logic in_valid = 0, in_command_valid = 0;
    logic [1:0] in_owner = 0;
    logic in_write = 0, in_refresh = 0, in_code_fetch = 0, in_burst = 0;
    logic [3:0] in_cycle_class = 5;
    logic [24:0] in_address = 0;
    logic [1:0] in_byte_enable = 3;
    logic [15:0] in_data_out = 0;
    wire in_accept, in_ready, in_read_data_valid;
    wire [15:0] in_read_data;
    wire out_valid, out_command_valid;
    wire [1:0] out_owner, out_byte_enable;
    wire out_write, out_refresh, out_code_fetch, out_burst;
    wire [3:0] out_cycle_class;
    wire [24:0] out_address;
    wire [15:0] out_data_out;
    wire out_accept, out_ready, out_read_data_valid;
    wire [15:0] out_read_data;
    wire [31:0] debug_hit_count, debug_miss_count, debug_fill_count, debug_write_update_count;
    wire [1:0] debug_state;
    spk286_at_sdram_data_buffer #(.WORD_COUNT(512)) dut (.*);

    logic backend_active = 0;
    logic [24:0] backend_address = 0;
    integer accepted = 0, completed = 0, physical = 0;
    assign out_accept = out_valid && out_command_valid && !backend_active;
    assign out_ready = backend_active;
    assign out_read_data_valid = backend_active;
    assign out_read_data = backend_address[15:0] ^ 16'hA55A;
    always @(posedge clk) begin
        if (reset) begin
            backend_active <= 0;
            backend_address <= 0;
            accepted <= 0;
            completed <= 0;
            physical <= 0;
        end else begin
            if (in_accept) accepted <= accepted + 1;
            if (in_ready && in_valid) completed <= completed + 1;
            if (out_accept) begin
                if (out_write || out_refresh || out_code_fetch || out_burst)
                    $fatal(1, "Unexpected backend request class");
                backend_active <= 1;
                backend_address <= out_address;
                physical <= physical + 1;
            end else if (backend_active && out_ready) begin
                backend_active <= 0;
            end
        end
    end

    task automatic read_word(input logic [24:0] address);
        integer guard;
        begin
            @(negedge clk);
            in_address = address;
            in_valid = 1;
            in_command_valid = 1;
            guard = 0;
            do begin
                @(posedge clk);
                guard++;
                if (guard > 20) $fatal(1, "Acceptance timeout");
            end while (!in_accept);
            @(negedge clk);
            in_command_valid = 0;
            guard = 0;
            do begin
                @(posedge clk);
                guard++;
                if (guard > 20) $fatal(1, "Response timeout");
            end while (!in_ready);
            if (!in_read_data_valid || in_read_data !== (address[15:0] ^ 16'hA55A))
                $fatal(1, "Read data mismatch");
            @(negedge clk);
            in_valid = 0;
            #1;
            $display("LEGITIMATE_READ_COMPLETE address=%0d accepted=%0d completed=%0d physical=%0d fills=%0d",
                     address, accepted, completed, physical, debug_fill_count);
        end
    endtask

    task automatic observe_idle(input integer edge_number);
        begin
            #1;
            if (debug_state != 0 || in_valid || in_command_valid || in_accept ||
                in_ready || in_read_data_valid || out_valid || out_command_valid ||
                backend_active || accepted != 3 || completed != 3 || physical != 3 ||
                debug_hit_count != 0 || debug_miss_count != 3 || debug_fill_count != 3 ||
                debug_write_update_count != 0)
                $fatal(1, "IDLE observation has an active request or side effect");
            // Read-only observations: no force, deposit, valid-array/state write,
            // or initialization of the private tag/data arrays is used.
            $display("IDLE_OBSERVATION edge=%0d state=%0d input_index=%0d retained_index=%0d input_valid=%b input_command=%b accept=%b ready=%b response_valid=%b out_valid=%b out_command=%b backend=%b lookup_valid=%b%b tag0=%h tag1=%h retained_tag=%h raw_double_hit=%b accepted=%0d completed=%0d physical=%0d fills=%0d",
                     edge_number, debug_state, dut.input_index, dut.index_q,
                     in_valid, in_command_valid, in_accept, in_ready, in_read_data_valid,
                     out_valid, out_command_valid, backend_active,
                     dut.lookup_valid1_q, dut.lookup_valid0_q,
                     dut.lookup0_q[31:16], dut.lookup1_q[31:16], dut.address_q[24:9],
                     dut.tag_hit0 && dut.tag_hit1, accepted, completed, physical, debug_fill_count);
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        reset = 0;
        read_word(25'd2);
        read_word(25'd514);
        read_word(25'd0);
        observe_idle(0);
        // Unowned idle address buses may change without accepting a request.
        @(negedge clk);
        in_address = 25'd2;
        observe_idle(1);
        @(negedge clk);
        observe_idle(2);
        @(negedge clk);
        observe_idle(3);
        read_word(25'd2);
        if (accepted != 4 || completed != 4 || physical != 3 ||
            debug_hit_count != 1 || debug_miss_count != 3 ||
            debug_fill_count != 3 || debug_write_update_count != 0)
            $fatal(1, "Future cached read did not hit without physical traffic");
        $display("AT_DATA_IDLE_PASS actual512_geometry no_private_writes no_idle_requests accepted=4 completed=4 physical=3 hits=1 fills=3 cached_read_data_checked=A558");
        $finish;
    end
    initial begin
        #2000;
        $fatal(1, "Overall timeout");
    end
endmodule
