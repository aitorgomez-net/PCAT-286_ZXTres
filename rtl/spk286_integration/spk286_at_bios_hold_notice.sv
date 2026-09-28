// Keep the AT CPU stopped while a required BIOS is missing and periodically
// request an explanatory MiSTer Info notice.
module spk286_at_bios_hold_notice #(
    parameter logic [26:0] INFO_PERIOD = 27'd75_000_000, // 1.5 s at 50 MHz
    parameter logic [26:0] INFO_WIDTH  = 27'd256,
    parameter logic [26:0] NOTICE_DELAY = 27'd100_000_000, // 2 s at 50 MHz
    parameter logic [7:0]  INFO_MAIN   = 8'd2,
    parameter logic [7:0]  INFO_EGA    = 8'd3
) (
    input  logic       clock,
    input  logic       splash_boot_phase,
    input  logic       bios_missing_main,
    input  logic       bios_missing_ega,
    output logic       hold,
    output logic [7:0] info,
    output logic       info_req
);

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [1:0] missing_main_sync = 2'b00;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [1:0] missing_ega_sync = 2'b00;

    logic [26:0] info_count = 27'd0;
    logic [26:0] missing_stable_count = 27'd0;

    assign hold = !splash_boot_phase &&
                  (missing_main_sync[1] || missing_ega_sync[1]);

    always_ff @(posedge clock) begin
        missing_main_sync <= {missing_main_sync[0], bios_missing_main};
        missing_ega_sync  <= {missing_ega_sync[0], bios_missing_ega};

        if (!hold) begin
            missing_stable_count <= 27'd0;
            info_count <= 27'd0;
            info_req   <= 1'b0;
            info       <= 8'd0;
        end else if (missing_stable_count < NOTICE_DELAY) begin
            // ROM download flags can briefly report "missing" during core
            // startup even when the configured images are about to load.
            // Keep the machine held immediately, but wait for a stable
            // missing state before raising a user-facing Info notice.
            missing_stable_count <= missing_stable_count + 27'd1;
            info_count <= 27'd0;
            info_req   <= 1'b0;
            info       <= 8'd0;
        end else begin
            if (info_count == INFO_PERIOD)
                info_count <= 27'd0;
            else
                info_count <= info_count + 27'd1;

            // Report the system BIOS first; the EGA BIOS is only actionable
            // after the machine BIOS is present.
            info <= missing_main_sync[1] ? INFO_MAIN : INFO_EGA;
            info_req <= info_count < INFO_WIDTH;
        end
    end

endmodule
