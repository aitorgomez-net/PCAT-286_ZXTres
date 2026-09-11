// Functional AT bus ownership arbiter.
//
// CPU is the default requester.  Runtime external owners first request CPU
// HOLD and may be granted only after HLDA, bridge drain and all locked/retained
// CPU intervals have ended.  A loader explicitly owning reset-held memory is
// the one documented exception: it does not wait for HLDA from a CPU that is
// intentionally held in reset.
`timescale 1ns/1ps

module spk286_at_arbiter (
    input  logic         clk,
    input  logic         reset,

    input  logic         cpu_hlda,
    input  logic         cpu_bridge_idle,
    input  logic         cpu_lock,
    input  logic         cpu_odd_word_active,
    input  logic         cpu_inta_lock_chain,
    input  logic         cpu_response_pending,

    input  logic         dma_request,
    input  logic         refresh_request,
    input  logic         loader_request,
    input  logic         loader_reset_owner,
    input  logic         external_done,

    output logic         cpu_hold_request,
    output logic         cpu_grant,
    output logic         external_grant,
    output logic         bus_owner_valid,
    output logic [2:0]   bus_owner,
    output logic         dma_grant,
    output logic         refresh_grant,
    output logic         loader_grant,
    output logic         protocol_error
);
    localparam logic [2:0] OWNER_CPU     = 3'd0;
    localparam logic [2:0] OWNER_DMA     = 3'd1;
    localparam logic [2:0] OWNER_REFRESH = 3'd2;
    localparam logic [2:0] OWNER_LOADER  = 3'd3;
    localparam logic [2:0] OWNER_NONE    = 3'd7;

    logic       owner_active_q;
    logic [2:0] owner_q;
    logic       external_request;
    logic [2:0] selected_external_owner;
    logic       runtime_grant_eligible;
    logic       reset_loader_eligible;
    logic       selected_request_valid;

    // Fixed priority is deliberate for the first functional slice.  Refresh
    // outranks DMA so retention is not delayed indefinitely; the loader wins
    // only when it explicitly requests the bus.
    always_comb begin
        if (loader_request) begin
            selected_external_owner = OWNER_LOADER;
            selected_request_valid = 1'b1;
        end else if (refresh_request) begin
            selected_external_owner = OWNER_REFRESH;
            selected_request_valid = 1'b1;
        end else if (dma_request) begin
            selected_external_owner = OWNER_DMA;
            selected_request_valid = 1'b1;
        end else begin
            selected_external_owner = OWNER_NONE;
            selected_request_valid = 1'b0;
        end
    end

    assign external_request = dma_request || refresh_request || loader_request;
    assign reset_loader_eligible = loader_reset_owner && loader_request;
    assign runtime_grant_eligible = external_request && !loader_reset_owner &&
                                    cpu_hlda && cpu_bridge_idle &&
                                    !cpu_lock && !cpu_odd_word_active &&
                                    !cpu_inta_lock_chain &&
                                    !cpu_response_pending;

    // HOLD remains asserted while an external owner is draining, even if its
    // request source withdraws immediately after seeing its grant.
    assign cpu_hold_request = !loader_reset_owner &&
                              (external_request || owner_active_q);
    assign external_grant = owner_active_q || reset_loader_eligible ||
                            runtime_grant_eligible;
    assign cpu_grant = !owner_active_q && !loader_reset_owner && !cpu_hlda;

    assign bus_owner_valid = external_grant || cpu_grant;
    assign bus_owner = external_grant ?
                       (owner_active_q ? owner_q : selected_external_owner) :
                       (cpu_grant ? OWNER_CPU : OWNER_NONE);
    assign dma_grant = external_grant &&
                       ((owner_active_q ? owner_q : selected_external_owner) == OWNER_DMA);
    assign refresh_grant = external_grant &&
                           ((owner_active_q ? owner_q : selected_external_owner) == OWNER_REFRESH);
    assign loader_grant = external_grant &&
                          ((owner_active_q ? owner_q : selected_external_owner) == OWNER_LOADER);

    always_ff @(posedge clk) begin
        if (reset) begin
            owner_active_q <= 1'b0;
            owner_q <= OWNER_NONE;
            protocol_error <= 1'b0;
        end else if (owner_active_q) begin
            if (external_done) begin
                owner_active_q <= 1'b0;
                owner_q <= OWNER_NONE;
            end
        end else if (reset_loader_eligible) begin
            owner_active_q <= 1'b1;
            owner_q <= OWNER_LOADER;
        end else if (runtime_grant_eligible && selected_request_valid) begin
            owner_active_q <= 1'b1;
            owner_q <= selected_external_owner;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset) begin
            assert (!(dma_grant && refresh_grant))
                else $error("AT arbiter granted DMA and refresh together");
            assert (!(dma_grant && loader_grant))
                else $error("AT arbiter granted DMA and loader together");
            assert (!(refresh_grant && loader_grant))
                else $error("AT arbiter granted refresh and loader together");
            assert (!(external_grant && cpu_grant))
                else $error("AT arbiter granted CPU and external owner together");
            assert (!(runtime_grant_eligible &&
                      (cpu_lock || cpu_odd_word_active ||
                       cpu_inta_lock_chain || cpu_response_pending)))
                else $error("AT arbiter crossed a protected CPU interval");
        end
    end
`endif
endmodule
