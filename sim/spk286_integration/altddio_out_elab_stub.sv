// Configuration/elaboration model only. Physical timing comes from Quartus;
// forwarding waveform checks use the official altera_mf simulation library.
`timescale 1ns/1ps
module altddio_out #(
    parameter extend_oe_disable = "OFF",
    parameter intended_device_family = "Cyclone V",
    parameter invert_output = "OFF", lpm_hint = "UNUSED",
    parameter lpm_type = "altddio_out", oe_reg = "UNREGISTERED",
    parameter power_up_high = "OFF", parameter width = 1
) (
    input wire [width-1:0] datain_h, datain_l,
    input wire outclock, aclr, aset, oe, outclocken, sclr, sset,
    output wire [width-1:0] dataout
);
    assign dataout = oe ? (outclock ? datain_h : datain_l) : {width{1'bz}};
endmodule
