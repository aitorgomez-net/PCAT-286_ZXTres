`timescale 1ns/1ps

module spk286_at_ems_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic reset = 1'b1;
    logic ems_enabled = 1'b1;
    logic request_valid = 1'b0;
    logic request_command_valid = 1'b0;
    logic request_write = 1'b0;
    logic request_io = 1'b1;
    logic [23:0] request_address = 24'h000260;
    logic [1:0] request_byte_enable = 2'b01;
    logic [15:0] request_data_out = 16'h0000;
    wire request_accept;
    wire request_ready;
    wire [15:0] request_read_data;
    wire request_read_data_valid;
    wire [6:0] map_ems [0:3];
    wire window_enabled [0:3];
    wire [15:0] side_effect_count;
    wire protocol_error;

    spk286_at_ems dut (
        .clk(clk), .reset(reset), .ems_enabled(ems_enabled),
        .request_valid(request_valid),
        .request_command_valid(request_command_valid),
        .request_write(request_write), .request_io(request_io),
        .request_address(request_address),
        .request_byte_enable(request_byte_enable),
        .request_data_out(request_data_out),
        .request_accept(request_accept), .request_ready(request_ready),
        .request_read_data(request_read_data),
        .request_read_data_valid(request_read_data_valid),
        .map_ems(map_ems), .window_enabled(window_enabled),
        .side_effect_count(side_effect_count),
        .protocol_error(protocol_error)
    );

    task automatic io_write_byte(input logic [1:0] port,
                                 input logic [7:0] value);
        begin
            request_address = 24'h000260 + port;
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_data_out = port[0] ? {value, 8'h00} : {8'h00, value};
            request_write = 1'b1;
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            @(posedge clk);
            while (!request_accept) @(posedge clk);
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            @(posedge clk);
            while (!request_ready) @(posedge clk);
            @(posedge clk);
            request_write = 1'b0;
        end
    endtask

    task automatic io_read_byte(input logic [1:0] port,
                                output logic [7:0] value,
                                output logic       valid);
        begin
            request_address = 24'h000260 + port;
            request_byte_enable = port[0] ? 2'b10 : 2'b01;
            request_write = 1'b0;
            request_valid = 1'b1;
            request_command_valid = 1'b1;
            @(posedge clk);
            while (!request_accept) @(posedge clk);
            request_valid = 1'b0;
            request_command_valid = 1'b0;
            @(posedge clk);
            while (!request_ready) @(posedge clk);
            value = request_byte_enable[1] ? request_read_data[15:8] :
                                            request_read_data[7:0];
            valid = request_read_data_valid;
            @(posedge clk);
        end
    endtask

    logic [7:0] readback;
    logic       read_valid;
    initial begin
        repeat (2) @(posedge clk);
        reset = 1'b0;
        io_write_byte(2'd0, 8'h12);
        if (!window_enabled[0] || map_ems[0] !== 7'h12)
            $fatal(1, "EMS page 0 was not enabled/mapped");
        io_write_byte(2'd1, 8'h34);
        io_write_byte(2'd2, 8'h56);
        io_write_byte(2'd3, 8'h78);
        if (!window_enabled[3] || map_ems[3] !== 7'h78)
            $fatal(1, "EMS odd/even register lane mapping failed");
        io_read_byte(2'd1, readback, read_valid);
        if (readback !== 8'h34 || !read_valid)
            $fatal(1, "EMS page register readback failed: %02h", readback);
        io_write_byte(2'd1, 8'hFF);
        if (window_enabled[1] !== 1'b0)
            $fatal(1, "EMS FF write did not disable window 1");
        ems_enabled = 1'b0;
        @(posedge clk);
        @(posedge clk);
        if (window_enabled[0] !== 1'b0 || map_ems[0] !== 7'h00)
            $fatal(1, "EMS disable did not clear mappings");
        if (protocol_error)
            $fatal(1, "EMS protocol error");
        $display("AT_EMS_REGISTERS_PASS");
        $finish;
    end
endmodule
