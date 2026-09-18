// Tandy/PCJr 2 Button Analog Joysticks

module tandy_pcjr_joy
(
    input   logic           clk,
    input   logic           reset,
    input   logic           en,
    input   logic   [1:0]   clk_select,
    input   logic   [4:0]   joy_opts,
    input   logic   [13:0]  joy0,
    input   logic   [13:0]  joy1,
    input   logic   [15:0]  joya0,
    input   logic   [15:0]  joya1,
    output  logic   [7:0]   d_out
);

    logic [7:0] joy0_x_r;
    logic [7:0] joy1_x_r;
    logic [7:0] joy0_y_r;
    logic [7:0] joy1_y_r;
    logic [9:0] joy0_x;
    logic [9:0] joy1_x;
    logic [9:0] joy0_y;
    logic [9:0] joy1_y;
    logic [8:0] counter;
    logic [8:0] pulse_div;
    logic       en_d;

    assign joy0_x = joy_opts[0] ? (joy0[0] ? 8'hFF : joy0[1] ? 8'h00 : 8'h80) : 8'd128 + joya0[7:0];
    assign joy1_x = joy_opts[2] ? (joy1[0] ? 8'hFF : joy1[1] ? 8'h00 : 8'h80) : 8'd128 + joya1[7:0];
    assign joy0_y = joy_opts[0] ? (joy0[2] ? 8'hFF : joy0[3] ? 8'h00 : 8'h80) : 8'd128 + joya0[15:8];
    assign joy1_y = joy_opts[2] ? (joy1[2] ? 8'hFF : joy1[3] ? 8'h00 : 8'h80) : 8'd128 + joya1[15:8];

    assign pulse_div = joy_opts[4] ? (clk_select == 1 ? 9'd200 :
                                      clk_select == 2 ? 9'd170 :
                                      clk_select == 3 ? 9'd90 : 9'd265) : 9'd265;

    always_ff @(posedge clk) begin
        en_d <= en;
        if (reset) begin
            counter <= 9'h0;
            en_d <= 1'b0;
        end else if (en && !en_d) begin
            joy0_x_r <= joy0_x[7:0] < 8'h70 || joy0_x[7:0] > 8'h90 ? joy0_x[7:0] : 8'h80;
            joy1_x_r <= joy1_x[7:0] < 8'h70 || joy1_x[7:0] > 8'h90 ? joy1_x[7:0] : 8'h80;
            joy0_y_r <= joy0_y[7:0] < 8'h70 || joy0_y[7:0] > 8'h90 ? joy0_y[7:0] : 8'h80;
            joy1_y_r <= joy1_y[7:0] < 8'h70 || joy1_y[7:0] > 8'h90 ? joy1_y[7:0] : 8'h80;
            counter <= 9'h0;
        end else if (counter == pulse_div) begin
            if (joy0_x_r != 0) joy0_x_r <= joy0_x_r - 1'b1;
            if (joy1_x_r != 0) joy1_x_r <= joy1_x_r - 1'b1;
            if (joy0_y_r != 0) joy0_y_r <= joy0_y_r - 1'b1;
            if (joy1_y_r != 0) joy1_y_r <= joy1_y_r - 1'b1;
            counter <= 9'h0;
        end else begin
            counter <= counter + 1'b1;
        end
    end

    assign d_out = {~joy1[5], ~joy1[4], ~joy0[5], ~joy0[4],
                    joy_opts[3] || |joy1_y_r, joy_opts[3] || |joy1_x_r,
                    joy_opts[1] || |joy0_y_r, joy_opts[1] || |joy0_x_r};

endmodule
