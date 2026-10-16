// F12 pauses the AT machine and shows the credits, as PCXT-EGA does.
//
// The key events come from hps_io in the same clock domain as the keyboard
// front end. F12 itself never reaches the machine: its release toggles the
// pause. While paused, new key presses are dropped so typing at the credits
// does nothing; releases still pass, so a key held when the pause began does
// not stay down in the machine afterwards.
//
// Outside the running machine (allow low: boot settling and the splash hold)
// F12 is swallowed without toggling anything. The splash has its own F12
// hold, splash_f12_pause, so the two never act on the same key press.
`timescale 1ns/1ps

module spk286_at_pause_key (
    input  logic        clk,
    input  logic        reset,
    input  logic        allow,
    // {toggle, pressed, extended, code} from hps_io.
    input  logic [10:0] ps2_key_in,
    output logic [10:0] ps2_key_out,
    output logic        pause
);
    localparam logic [7:0] PS2_SET2_F12 = 8'h07;

    logic toggle_q;

    wire event_new = ps2_key_in[10] ^ toggle_q;
    wire pressed   = ps2_key_in[9];
    wire is_f12    = !ps2_key_in[8] && (ps2_key_in[7:0] == PS2_SET2_F12);

    initial begin
        toggle_q    = 1'b0;
        ps2_key_out = 11'd0;
        pause       = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            // Track the framework toggle so no event replays on release.
            toggle_q <= ps2_key_in[10];
            pause    <= 1'b0;
        end else begin
            if (!allow)
                pause <= 1'b0;
            if (event_new) begin
                toggle_q <= ps2_key_in[10];
                if (is_f12) begin
                    if (allow && !pressed)
                        pause <= ~pause;
                end else if (!(pause && pressed)) begin
                    ps2_key_out <= {~ps2_key_out[10], ps2_key_in[9:0]};
                end
            end
        end
    end
endmodule
