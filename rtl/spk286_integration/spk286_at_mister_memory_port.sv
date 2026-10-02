`timescale 1ns/1ps

// MiSTer-facing memory ownership boundary for the normalized AT machine.
//
// This block deliberately stops at an abstract 16-bit backend port.  The
// physical SDRAM/HPS implementation can therefore be changed independently
// of the AT CPU, DMA, and refresh protocol.  A request is accepted once,
// remains owned by its initiator until completion, and keeps its address and
// byte lanes stable while the backend is stalled.

module spk286_at_mister_memory_port (
    input  logic        clk,
    input  logic        reset,
    // CPU-local reset cancels only CPU ownership. Accepted physical accesses
    // are drained with their response discarded; loader/DMA/refresh continue.
    input  logic        cancel_cpu,

    input  logic        cpu_valid,
    input  logic        cpu_command_valid,
    input  logic        cpu_write,
    input  logic        cpu_code_fetch,
    input  logic [3:0]  cpu_cycle_class,
    input  logic [24:0] cpu_address,
    input  logic [1:0]  cpu_byte_enable,
    input  logic [15:0] cpu_data_out,
    output logic        cpu_accept,
    output logic        cpu_ready,
    output logic [15:0] cpu_read_data,
    output logic        cpu_read_data_valid,

    input  logic        loader_valid,
    input  logic        loader_write,
    input  logic [23:0] loader_address,
    input  logic [1:0]  loader_byte_enable,
    input  logic [15:0] loader_data_out,
    output logic        loader_accept,
    output logic        loader_ready,
    output logic [15:0] loader_read_data,

    input  logic        dma_valid,
    input  logic        dma_write,
    input  logic [24:0] dma_address,
    input  logic [1:0]  dma_byte_enable,
    input  logic [15:0] dma_data_out,
    output logic        dma_accept,
    output logic        dma_ready,
    output logic [15:0] dma_read_data,

    input  logic        refresh_valid,
    input  logic [23:0] refresh_address,
    output logic        refresh_accept,
    output logic        refresh_ready,

    output logic        backend_valid,
    output logic        backend_command_valid,
    output logic [1:0]  backend_owner,
    output logic        backend_write,
    output logic        backend_refresh,
    output logic        backend_code_fetch,
    output logic [3:0]  backend_cycle_class,
    output logic [24:0] backend_address,
    output logic [1:0]  backend_byte_enable,
    output logic [15:0] backend_data_out,
    input  logic        backend_accept,
    input  logic        backend_ready,
    input  logic [15:0] backend_read_data,
    input  logic        backend_read_data_valid,

    output logic [4:0]  debug_state,
    output logic        protocol_error
);

    localparam logic [1:0] OWNER_CPU     = 2'd0;
    localparam logic [1:0] OWNER_DMA     = 2'd1;
    localparam logic [1:0] OWNER_REFRESH = 2'd2;
    localparam logic [1:0] OWNER_LOADER  = 2'd3;

    logic       active_q;
    logic       accepted_q;
    logic [1:0] owner_q;
    logic       write_q;
    logic       code_fetch_q;
    logic [3:0] cycle_class_q;
    logic [24:0] address_q;
    logic [1:0] byte_enable_q;
    logic [15:0] data_out_q;
    logic       cpu_cancelled_q;

    logic response_complete;
    logic selected_accept;
    wire cpu_candidate = cpu_valid && !cancel_cpu;

    assign debug_state = {active_q, accepted_q, owner_q, cpu_cancelled_q};

    wire cpu_entry_command = !active_q && !loader_valid &&
                             cpu_candidate && cpu_command_valid && !reset;

    assign selected_accept = active_q && !accepted_q && backend_accept &&
                             backend_command_valid;
    assign response_complete = active_q && accepted_q && backend_ready &&
                               (write_q ||
                                (owner_q == OWNER_REFRESH) ||
                                backend_read_data_valid);

    always_comb begin
        backend_valid         = active_q;
        backend_command_valid = 1'b0;
        backend_owner         = owner_q;
        backend_write         = write_q;
        backend_refresh       = (owner_q == OWNER_REFRESH);
        backend_code_fetch    = code_fetch_q;
        backend_cycle_class   = cycle_class_q;
        backend_address       = address_q;
        backend_byte_enable   = byte_enable_q;
        backend_data_out      = data_out_q;

        cpu_accept            = 1'b0;
        cpu_ready             = 1'b0;
        cpu_read_data         = backend_read_data;
        cpu_read_data_valid   = 1'b0;
        dma_accept            = 1'b0;
        dma_ready             = 1'b0;
        dma_read_data         = backend_read_data;
        refresh_accept        = 1'b0;
        refresh_ready         = 1'b0;
        loader_accept         = 1'b0;
        loader_ready          = 1'b0;
        loader_read_data      = backend_read_data;

        if (active_q) begin
            // A CPU command not accepted at entry retries from this retained
            // record. DMA/refresh enter command after their record is selected.
            if (owner_q == OWNER_CPU)
                backend_command_valid = !accepted_q && cpu_command_valid &&
                                        !cancel_cpu && !cpu_cancelled_q;
            else
                backend_command_valid = !accepted_q;

            if (owner_q == OWNER_CPU)
                cpu_accept = selected_accept && !cancel_cpu && !cpu_cancelled_q;
            else if (owner_q == OWNER_DMA)
                dma_accept = selected_accept;
            else if (owner_q == OWNER_REFRESH)
                refresh_accept = selected_accept;
            else if (owner_q == OWNER_LOADER)
                loader_accept = selected_accept;

            // A read response is complete only when the backend supplies
            // valid data.  Writes and refreshes need only the ready response.
            if (owner_q == OWNER_CPU) begin
                cpu_ready           = response_complete && !cancel_cpu &&
                                      !cpu_cancelled_q;
                cpu_read_data_valid = cpu_ready && !write_q;
            end else if (owner_q == OWNER_DMA) begin
                dma_ready = response_complete;
            end else if (owner_q == OWNER_REFRESH) begin
                refresh_ready = response_complete;
            end else if (owner_q == OWNER_LOADER) begin
                loader_ready = response_complete;
            end
        end else if (cpu_entry_command) begin
            // Arbitration, address capture and backend
            // command acceptance share one edge. Completion is still qualified
            // by the retained active/accepted record on a later edge.
            backend_valid         = 1'b1;
            backend_command_valid = 1'b1;
            backend_owner         = OWNER_CPU;
            backend_write         = cpu_write;
            backend_refresh       = 1'b0;
            backend_code_fetch    = cpu_code_fetch;
            backend_cycle_class   = cpu_cycle_class;
            backend_address       = cpu_address;
            backend_byte_enable   = cpu_byte_enable;
            backend_data_out      = cpu_data_out;
            cpu_accept            = backend_accept;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            active_q      <= 1'b0;
            accepted_q    <= 1'b0;
            owner_q       <= OWNER_CPU;
            write_q       <= 1'b0;
            code_fetch_q  <= 1'b0;
            cycle_class_q <= 4'b0000;
            address_q     <= 25'h0000000;
            byte_enable_q <= 2'b00;
            data_out_q    <= 16'h0000;
            cpu_cancelled_q <= 1'b0;
            protocol_error <= 1'b0;
        end else begin
            if (!active_q) begin
                cpu_cancelled_q <= 1'b0;
                // The loader wins during boot, then CPU wins over refresh,
                // and refresh wins over DMA.  Normal machine operation
                // presents only one candidate; detecting a collision here
                // makes an accidental double-owner visible.
                if (loader_valid) begin
                    active_q      <= 1'b1;
                    owner_q       <= OWNER_LOADER;
                    write_q       <= loader_write;
                    code_fetch_q  <= 1'b0;
                    cycle_class_q <= 4'b0000;
                    address_q     <= {1'b0, loader_address};
                    byte_enable_q <= loader_byte_enable;
                    data_out_q    <= loader_data_out;
                end else if (cpu_candidate) begin
                    accepted_q    <= cpu_entry_command && backend_accept;
                    active_q      <= 1'b1;
                    owner_q       <= OWNER_CPU;
                    write_q       <= cpu_write;
                    code_fetch_q  <= cpu_code_fetch;
                    cycle_class_q <= cpu_cycle_class;
                    address_q     <= cpu_address;
                    byte_enable_q <= cpu_byte_enable;
                    data_out_q    <= cpu_data_out;
                end else if (refresh_valid) begin
                    active_q      <= 1'b1;
                    owner_q       <= OWNER_REFRESH;
                    write_q       <= 1'b0;
                    code_fetch_q  <= 1'b0;
                    cycle_class_q <= 4'b0000;
                    address_q     <= {1'b0, refresh_address};
                    byte_enable_q <= 2'b11;
                    data_out_q    <= 16'h0000;
                end else if (dma_valid) begin
                    active_q      <= 1'b1;
                    owner_q       <= OWNER_DMA;
                    write_q       <= dma_write;
                    code_fetch_q  <= 1'b0;
                    cycle_class_q <= 4'b0000;
                    address_q     <= dma_address;
                    byte_enable_q <= dma_byte_enable;
                    data_out_q    <= dma_data_out;
                end

                if ((loader_valid && cpu_candidate) ||
                    (loader_valid && refresh_valid) ||
                    (loader_valid && dma_valid) ||
                    (cpu_candidate && refresh_valid) ||
                    (cpu_candidate && dma_valid) ||
                    (refresh_valid && dma_valid))
                    protocol_error <= 1'b1;
            end else begin
                if (cancel_cpu && owner_q == OWNER_CPU)
                    cpu_cancelled_q <= 1'b1;
                if (selected_accept)
                    accepted_q <= 1'b1;

                // No physical command exists yet, so this CPU record can
                // be discarded immediately. A new fetch must never inherit
                // its stale address when reset releases.
                if ((cancel_cpu && owner_q == OWNER_CPU && !accepted_q) ||
                    response_complete) begin
                    active_q   <= 1'b0;
                    accepted_q <= 1'b0;
                    cpu_cancelled_q <= 1'b0;
                end

                if (backend_accept && !backend_command_valid)
                    protocol_error <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(cpu_accept && dma_accept))
                else $error("AT MiSTer memory port accepted CPU and DMA together");
            assert (!(cpu_accept && refresh_accept))
                else $error("AT MiSTer memory port accepted CPU and refresh together");
            assert (!(dma_accept && refresh_accept))
                else $error("AT MiSTer memory port accepted DMA and refresh together");
            assert (!(cpu_ready && dma_ready))
                else $error("AT MiSTer memory port completed CPU and DMA together");
            assert (!(cpu_ready && refresh_ready))
                else $error("AT MiSTer memory port completed CPU and refresh together");
            assert (!(dma_ready && refresh_ready))
                else $error("AT MiSTer memory port completed DMA and refresh together");
        end
    end
`endif

endmodule
