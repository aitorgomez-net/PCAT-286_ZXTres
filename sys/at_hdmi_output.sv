// Native-rate direct video and scaled video retain their own clocks up to
// the final I/O register. select_direct controls BOTH the hardware clock mux
// and the data mux. It changes only while the transmitter registers are reset.
// As with MiSTer's normal clock mux, a mode change requires receiver relock;
// no uninterrupted/glitch-free external clock is promised during that change.
module at_hdmi_output (
    input wire clk_sys, clk_video, clk_hdmi, clk_tx,
    input wire src_idle, direct_video, vga_fb, csync,
    input wire [26:0] direct_pixel, scaled_pixel,
    input wire scaled_csync,
    output reg select_direct = 0,
    output reg [26:0] tx_pixel = 0
);
    reg target_q = 0;
    reg switch_reset_q = 1;
    // Quartus 17's automatic FSM extraction starts this reset-less machine
    // in its first case state. Keep that state at zero and make it release
    // the startup reset, even when no mode change is requested. Initializing
    // state_q to a later case left the fitted machine idle with reset held.
    localparam [1:0] RELEASE_RESET = 0, ASSERT_RESET = 1, RUN = 2;
    reg [1:0] state_q = RELEASE_RESET;
    reg [4:0] wait_q = 31;
    reg idle_q = 0;
    reg csync_request_q = 0;
    always @(posedge clk_sys) begin
        idle_q <= src_idle;
        if (src_idle && idle_q) csync_request_q <= direct_video && csync;
        case (state_q)
            RELEASE_RESET: if (wait_q != 0) wait_q <= wait_q - 1'b1;
               else begin switch_reset_q <= 0; state_q <= RUN; end
            ASSERT_RESET: if (wait_q != 0) wait_q <= wait_q - 1'b1;
               else begin
                   select_direct <= target_q;
                   wait_q <= 31;
                   state_q <= RELEASE_RESET;
               end
            RUN: if (src_idle && idle_q && ((direct_video && !vga_fb) != select_direct)) begin
                target_q <= direct_video && !vga_fb;
                switch_reset_q <= 1;
                wait_q <= 7;
                state_q <= ASSERT_RESET;
            end
            default: begin switch_reset_q <= 1; state_q <= RELEASE_RESET; wait_q <= 31; end
        endcase
    end

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON", preserve *)
    reg csync_meta = 0, csync_sync = 0;
    (* preserve *) reg [26:0] direct_q1 = 0, direct_q2 = 0, scaled_q = 0;
    always @(posedge clk_video) begin
        direct_q1 <= direct_pixel;
        direct_q2 <= direct_q1;
    end
    always @(posedge clk_hdmi) begin
        csync_meta <= csync_request_q;
        csync_sync <= csync_meta;
        scaled_q <= {csync_sync ? scaled_csync : scaled_pixel[26], scaled_pixel[25:0]};
    end

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS; -name DONT_MERGE_REGISTER ON", preserve *)
    reg reset_meta = 1, reset_sync = 1;
    always @(posedge clk_tx or posedge switch_reset_q) begin
        if (switch_reset_q) begin reset_meta <= 1; reset_sync <= 1; end
        else begin reset_meta <= 0; reset_sync <= reset_meta; end
    end
    always @(posedge clk_tx or posedge reset_sync) begin
        if (reset_sync) tx_pixel <= 0;
        else tx_pixel <= select_direct ? direct_q2 : scaled_q;
    end
endmodule
