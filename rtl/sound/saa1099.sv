//============================================================================
// 
//  SAA1099 sound generator
//  Copyright (C) 2016-2019 Sorgelig
//
//  Based on SAA1099.v code from Miguel Angel Rodriguez Jodar
//  Based on SAASound code  from Dave Hooper
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================
`timescale 1ns / 1ps
//`default_nettype none


module saa1099
(
	input        clk_sys,
	input        ce,      // 8 MHz
	input        rst_n,
	input        cs_n,
	input        a0,      // 0=data, 1=address
	input        wr_n,
	input  [7:0] din,
	output [7:0] out_l,
	output [7:0] out_r
);

reg [7:0] amplit0, amplit1, amplit2, amplit3, amplit4, amplit5;
reg [7:0] freq0, freq1, freq2, freq3, freq4, freq5;
reg [7:0] oct10, oct32, oct54;
reg [7:0] freqenable;
reg [7:0] noiseenable;
reg [7:0] noisegen;
reg [7:0] envelope0, envelope1;
reg [7:0] ctrl;

reg [4:0] addr;
wire      rst = ~rst_n | ctrl[1];
reg       wr;

always @(posedge clk_sys) begin
	reg old_wr;
	old_wr <= wr_n;

	wr <= 0;
	if(~rst_n) begin
		addr <= 0;
		{amplit0, amplit1, amplit2, amplit3, amplit4, amplit5} <= 0;
		{freq0, freq1, freq2, freq3, freq4, freq5} <= 0;
		{oct10, oct32, oct54} <= 0;
		{freqenable, noiseenable, noisegen} <= 0;
		{envelope0, envelope1} <= 0;
		ctrl <= 0;
	end
	else begin
		if(!cs_n & old_wr & !wr_n) begin
			wr <= 1;
			if(a0) addr <= din[4:0];
			else begin
				case (addr)
					'h00: amplit0 <= din;
					'h01: amplit1 <= din;
					'h02: amplit2 <= din;
					'h03: amplit3 <= din;
					'h04: amplit4 <= din;
					'h05: amplit5 <= din;

					'h08: freq0   <= din;
					'h09: freq1   <= din;
					'h0A: freq2   <= din;
					'h0B: freq3   <= din;
					'h0C: freq4   <= din;
					'h0D: freq5   <= din;

					'h10: oct10   <= din;
					'h11: oct32   <= din;
					'h12: oct54   <= din;

					'h14: freqenable <= din;
					'h15: noiseenable<= din;
					'h16: noisegen   <= din;

					'h18: envelope0  <= din;
					'h19: envelope1  <= din;

					'h1C: ctrl       <= din;
				endcase
			end
		end
	end
end

wire [21:0] out0;
wire [7:0] top_vol [3];
wire [7:0] top_freq [3];
wire [2:0] top_octave [3];
assign top_vol[0] = amplit0;
assign top_vol[1] = amplit1;
assign top_vol[2] = amplit2;
assign top_freq[0] = freq0;
assign top_freq[1] = freq1;
assign top_freq[2] = freq2;
assign top_octave[0] = oct10[2:0];
assign top_octave[1] = oct10[6:4];
assign top_octave[2] = oct32[2:0];
saa1099_triplet top
(
	.*,
	.vol(top_vol),
	.env(envelope0),

	.freq(top_freq),
	.octave(top_octave),
	.freq_en(freqenable[2:0]),

	.noise_en(noiseenable[2:0]),
	.noise_freq(noisegen[1:0]),

	.wr_addr(wr &  a0 & (din[4:0] == 'h18)),
	.wr_data(wr & !a0 & (addr == 'h18)),

	.out(out0)
);

wire [21:0] out1;
wire [7:0] bottom_vol [3];
wire [7:0] bottom_freq [3];
wire [2:0] bottom_octave [3];
assign bottom_vol[0] = amplit3;
assign bottom_vol[1] = amplit4;
assign bottom_vol[2] = amplit5;
assign bottom_freq[0] = freq3;
assign bottom_freq[1] = freq4;
assign bottom_freq[2] = freq5;
assign bottom_octave[0] = oct32[6:4];
assign bottom_octave[1] = oct54[2:0];
assign bottom_octave[2] = oct54[6:4];
saa1099_triplet bottom
(
	.*,
	.vol(bottom_vol),
	.env(envelope1),

	.freq(bottom_freq),
	.octave(bottom_octave),
	.freq_en(freqenable[5:3]),

	.noise_en(noiseenable[5:3]),
	.noise_freq(noisegen[5:4]),

	.wr_addr(wr &  a0 & (din[4:0] == 'h19)),
	.wr_data(wr & !a0 & (addr == 'h19)),

	.out(out1)
);

saa1099_output_mixer outmix_l(.*, .en(ctrl[0]), .in0(out0[10:0]),  .in1(out1[10:0]),  .out(out_l));
saa1099_output_mixer outmix_r(.*, .en(ctrl[0]), .in0(out0[21:11]), .in1(out1[21:11]), .out(out_r));

endmodule

/////////////////////////////////////////////////////////////////////////////////
module saa1099_triplet
(
	input        rst,
	input        clk_sys,
	input        ce,

	input  [7:0] vol[3],
	input  [7:0] env,

	input  [7:0] freq[3],
	input  [2:0] octave[3],
	input  [2:0] freq_en,

	input  [2:0] noise_en,
	input  [1:0] noise_freq,

	input        wr_addr,
	input        wr_data,

	output[21:0] out
);

wire       tone0, tone1, tone2, noise;
wire       pulse_noise, pulse_envelope;
wire[17:0] out0, out1, out2;

saa1099_tone  freq_gen0(.*, .out(tone0), .octave(octave[0]), .freq(freq[0]), .pulse(pulse_noise));
saa1099_tone  freq_gen1(.*, .out(tone1), .octave(octave[1]), .freq(freq[1]), .pulse(pulse_envelope));
saa1099_tone  freq_gen2(.*, .out(tone2), .octave(octave[2]), .freq(freq[2]), .pulse());
saa1099_noise noise_gen(.*, .out(noise));

saa1099_amp amp0(.*, .mixmode({noise_en[0], freq_en[0]}), .tone(tone0), .envreg(8'd0), .vol(vol[0]), .out(out0));
saa1099_amp amp1(.*, .mixmode({noise_en[1], freq_en[1]}), .tone(tone1), .envreg(8'd0), .vol(vol[1]), .out(out1));
saa1099_amp amp2(.*, .mixmode({noise_en[2], freq_en[2]}), .tone(tone2), .envreg(env), .vol(vol[2]), .out(out2));

assign out[10:0]  = {2'b00, out0[8:0] } + {2'b00, out1[8:0] } + {2'b00, out2[8:0] };
assign out[21:11] = {2'b00, out0[17:9]} + {2'b00, out1[17:9]} + {2'b00, out2[17:9]};

endmodule

/////////////////////////////////////////////////////////////////////////////////

module saa1099_tone
(
	input       rst,
	input       clk_sys,
	input       ce,
	input [2:0] octave,
	input [7:0] freq,
	output reg  out,
	output reg  pulse
);

wire [16:0] fcount = ((17'd511 - freq) << (4'd8 - octave)) - 1'd1;
always @(posedge clk_sys) begin
	reg [16:0] count;

	pulse <= 0;
	if(rst) begin
		count <= fcount;
		out   <= 0;
	end else if(ce) begin
		if(!count) begin
			count <= fcount;
			pulse <= 1;
			out <= ~out;
		end else begin
			count <= count - 1'd1;
		end
	end
end

endmodule

/////////////////////////////////////////////////////////////////////////////////

module saa1099_noise
(
	input       rst,
	input       clk_sys,
	input       ce,
	input       pulse_noise,
	input [1:0] noise_freq,
	output      out
);

reg  [16:0] lfsr = 0;
wire [16:0] new_lfsr = {(lfsr[0] ^ lfsr[2] ^ !lfsr), lfsr[16:1]};
wire [10:0] fcount = (11'd256 << noise_freq) - 1'b1;

always @(posedge clk_sys) begin
	reg [10:0] count;

	if(rst) begin
		count <= fcount;
	end else
	if(noise_freq != 3) begin
		if(ce) begin
			if(!count) begin
				count <= fcount;
				lfsr <= new_lfsr;
			end else begin
				count <= count - 1'd1;
			end
		end
	end else if(pulse_noise) begin
		lfsr <= new_lfsr;
	end
end

assign out = lfsr[0];

endmodule

/////////////////////////////////////////////////////////////////////////////////

module saa1099_amp
(
	input             rst,
	input             clk_sys,
	input       [7:0] envreg,
	input       [1:0] mixmode,
	input             tone,
	input             noise,
	input             wr_addr,
	input             wr_data,
	input             pulse_envelope,
	input       [7:0] vol,
	output reg [17:0] out
);

// These small lookup tables were array literals in the original source.
// Express them as functions as well so Quartus 17 and the lightweight
// regression simulators elaborate the same envelope shapes consistently.
function automatic phase_limit(input [2:0] shape_i);
	case (shape_i)
		3'd4, 3'd5: phase_limit = 1'b1;
		default:    phase_limit = 1'b0;
	endcase
endfunction

function automatic [1:0] envelope_shape(input [2:0] shape_i,
		input phase_i);
	case (shape_i)
		3'd0: envelope_shape = 2'd0;
		3'd1: envelope_shape = 2'd1;
		3'd2, 3'd3: envelope_shape = 2'd2;
		3'd4, 3'd5: envelope_shape = phase_i ? 2'd2 : 2'd3;
		3'd6, 3'd7: envelope_shape = phase_i ? 2'd0 : 2'd3;
		default:    envelope_shape = 2'd0;
	endcase
endfunction

function automatic [3:0] envelope_level(input [1:0] shape_i,
		input [3:0] counter_i);
	case (shape_i)
		2'd0: envelope_level = 4'd0;
		2'd1: envelope_level = 4'd15;
		2'd2: envelope_level = 4'd15 - counter_i;
		2'd3: envelope_level = counter_i;
		default: envelope_level = 4'd0;
	endcase
endfunction

reg [2:0] shape;
reg       stereo;
wire      resolution = envreg[4];
wire      enable     = envreg[7];
reg [3:0] counter;
reg       phase;
wire[3:0] mask = {3'b000, resolution};

always @(posedge clk_sys) begin
	reg clock;
	reg new_data;

	if(rst | ~enable) begin
		new_data <= 0;
		stereo   <= envreg[0];
		shape    <= envreg[3:1];
		clock    <= envreg[5];
		phase    <= 0;
		counter  <= 0;
	end
	else begin
		if(wr_data) new_data <= 1;
		if(clock ? wr_addr : pulse_envelope) begin  // pulse from internal or external clock?
			counter <= counter + resolution + 1'd1;
			if((counter | mask) == 15) begin
				if(phase >= phase_limit(shape)) begin
					if(~shape[0]) counter <= 15;
					if(new_data | shape[0]) begin // if we reached one of the designated points (3) or (4) and there is pending data, load it
						new_data <= 0;
						stereo   <= envreg[0];
						shape    <= envreg[3:1];
						clock    <= envreg[5];
						phase    <= 0;
						if(new_data) counter <= 0;
					end
				end else begin
					phase <= 1;
				end
			end
		end
	end
end

wire [3:0] env_l = envelope_level(envelope_shape(shape, phase), counter) & ~mask;
wire [3:0] env_r = stereo ? (4'd15 & ~mask) - env_l : env_l; // bit 0 of envreg inverts envelope shape

reg  [1:0] outmix;
always_comb begin
	case(mixmode)
		0: outmix <= 0;
		1: outmix <= {tone,  1'b0};
		2: outmix <= {noise, 1'b0};
		3: outmix <= {tone & ~noise, tone & noise};
	endcase
end

wire [8:0] vol_mix_l = {vol[3:1], vol[0] & ~enable, 5'b00000} >> outmix[0];
wire [8:0] vol_mix_r = {vol[7:5], vol[4] & ~enable, 5'b00000} >> outmix[0];
wire [8:0] env_out_l;
wire [8:0] env_out_r;
saa1099_mul_env mod_l(.vol(vol_mix_l[8:4]), .env(env_l), .out(env_out_l));
saa1099_mul_env mod_r(.vol(vol_mix_r[8:4]), .env(env_r), .out(env_out_r));

always_comb begin
	case({enable, outmix})
		'b100, 'b101: out = {env_out_r, env_out_l};
		'b001, 'b010: out = {vol_mix_r, vol_mix_l};
		     default: out = 0;
	endcase
end

endmodule

/////////////////////////////////////////////////////////////////////////////////

module saa1099_mul_env
(
	input  [4:0] vol,
	input  [3:0] env,
	output [8:0] out
);

assign out = (env[0] ?      vol     : 9'd0)+
             (env[1] ? {  vol,1'b0} : 9'd0)+
             (env[2] ? { vol,2'b00} : 9'd0)+
             (env[3] ? {vol,3'b000} : 9'd0);

endmodule

/////////////////////////////////////////////////////////////////////////////////

module saa1099_output_mixer
(
	input            clk_sys,
	input            ce,
	input            en,
	input     [10:0] in0,
	input     [10:0] in1,
	output reg [7:0] out
);

wire [17:0] o = 18'd91 * ({1'b0,in0} + {1'b0,in1});

// Clean the audio.
always @(posedge clk_sys) begin
	reg ced;
	ced <= ce;
	if(ced) out <= ~en ? 8'h00 : o[17:10];
end

endmodule
