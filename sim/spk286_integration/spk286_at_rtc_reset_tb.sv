`timescale 1ns/1ps
module spk286_at_rtc_reset_tb;
  reg clk=0, reset=1, valid=0;
  always #5 clk=~clk;
  wire fault;
  spk286_at_rtc_cmos dut(.clk(clk),.reset(reset),
    .request_valid(valid),.request_command_valid(valid),.request_write(1'b0),
    .request_io(1'b1),.request_address(24'h70),.installed_ram_size(3'd0),
    .request_byte_enable(2'b10),
    .request_data_out(16'h0),.periodic_tick(1'b0),.second_tick(1'b0),
    .mgmt_address(16'h0000),.mgmt_writedata(16'h0000),.mgmt_write(1'b0),
    .protocol_error(fault));
  initial begin
    repeat(3) @(negedge clk);
    if (!$test$plusargs("WARM_ONLY") && fault !== 1'b0)
      $fatal(1,"RTC_COLD_RESET_FAIL protocol_error=%b",fault);
    reset=0; valid=1;
    repeat(2) @(negedge clk);
    if(fault !== 1'b1) $fatal(1,"RTC_INVALID_LANE_NOT_DETECTED");
    valid=0; reset=1;
    repeat(3) @(negedge clk);
    if(fault !== 1'b0) $fatal(1,"RTC_WARM_RESET_FAIL protocol_error=%b",fault);
    reset=0;
    repeat(3) @(negedge clk);
    if(fault !== 1'b0) $fatal(1,"RTC_RESET_RELEASE_FAIL");
    $display("AT_RTC_RESET_PASS cold_and_sticky_clear"); $finish;
  end
endmodule
