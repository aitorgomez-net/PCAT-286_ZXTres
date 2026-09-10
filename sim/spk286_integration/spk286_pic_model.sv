// Portable functional PIC boundary for the dual-simulator whole-CPU event
// test. The production path is separately executed with the unchanged KF8259.
// This model implements only the programmed single-controller edge mode used
// by pcat286_event_diag.rom; it is not a replacement machine component.
`timescale 1ns/1ps

module spk286_pic_model (
    input  logic       clock,
    input  logic       reset,
    input  logic       chip_select_n,
    input  logic       read_enable_n,
    input  logic       write_enable_n,
    input  logic       address,
    input  logic [7:0] data_bus_in,
    output logic [7:0] data_bus_out,
    output logic       data_bus_io,
    input  logic [2:0] cascade_in,
    output logic [2:0] cascade_out,
    output logic       cascade_io,
    input  logic       slave_program_n,
    output logic       buffer_enable,
    output logic       slave_program_or_enable_buffer,
    input  logic       interrupt_acknowledge_n,
    output logic       interrupt_to_cpu,
    input  logic [7:0] interrupt_request
);
    logic [7:0] vector_base;
    logic [7:0] interrupt_mask;
    logic [7:0] previous_request;
    logic       request_pending;
    logic       previous_write_n;
    logic       previous_inta_n;
    logic [1:0] initialization_step;
    logic [1:0] acknowledge_count;

    always_ff @(posedge clock) begin
        if (reset) begin
            vector_base <= 8'h08;
            interrupt_mask <= 8'hff;
            previous_request <= 8'h00;
            request_pending <= 1'b0;
            previous_write_n <= 1'b1;
            previous_inta_n <= 1'b1;
            initialization_step <= 2'd0;
            acknowledge_count <= 2'd0;
        end else begin
            previous_request <= interrupt_request;
            previous_write_n <= write_enable_n;
            previous_inta_n <= interrupt_acknowledge_n;

            if (|(interrupt_request & ~previous_request & ~interrupt_mask)) begin
                request_pending <= 1'b1;
                acknowledge_count <= 2'd0;
            end

            if (previous_write_n && !write_enable_n && !chip_select_n) begin
                if (!address && data_bus_in[4])
                    initialization_step <= 2'd1;
                else if (address && initialization_step == 2'd1) begin
                    vector_base <= {data_bus_in[7:3], 3'b000};
                    initialization_step <= 2'd2;
                end else if (address && initialization_step == 2'd2)
                    initialization_step <= 2'd3;
                else if (address) begin
                    interrupt_mask <= data_bus_in;
                    initialization_step <= 2'd0;
                end
            end

            if (previous_inta_n && !interrupt_acknowledge_n) begin
                acknowledge_count <= acknowledge_count + 2'd1;
                request_pending <= 1'b0;
            end
        end
    end

    always_comb begin
        data_bus_out = 8'h00;
        data_bus_io = 1'b1;
        if (!interrupt_acknowledge_n && acknowledge_count != 0) begin
            data_bus_out = vector_base;
            data_bus_io = 1'b0;
        end else if (!chip_select_n && !read_enable_n) begin
            data_bus_out = address ? interrupt_mask : 8'h00;
            data_bus_io = 1'b0;
        end
    end

    assign interrupt_to_cpu = request_pending;
    assign cascade_out = 3'b000;
    assign cascade_io = 1'b0;
    assign buffer_enable = 1'b0;
    assign slave_program_or_enable_buffer = slave_program_n;

    logic unused;
    assign unused = ^{cascade_in, slave_program_n};
endmodule
