`timescale 1ns/1ps

// Check the packed configuration actually passed to hps_io, not source text.
// MiSTer stops reading at the first NUL, so even one embedded zero hides all
// subsequent menu entries and the version marker from the host.
module spk286_at_config_tb;
    emu_at dut ();
    string config_text;
    integer byte_count;
    reg [7:0] config_byte;

    function automatic bit contains(input string token);
        integer i, j;
        bit token_equal;
        begin
            contains = 0;
            for (i = 0; i <= config_text.len() - token.len(); i = i + 1) begin
                token_equal = 1;
                for (j = 0; j < token.len(); j = j + 1)
                    if (config_text[i+j] != token[j]) token_equal = 0;
                if (token_equal) contains = 1;
            end
        end
    endfunction

    initial begin
        #1;
        if (!dut.u_at_machine.is_a5_io_port(16'h03f8) ||
            !dut.u_at_machine.is_a5_io_port(16'h03ff) ||
            dut.u_at_machine.is_a5_io_port(16'h0400))
            $fatal(1, "AT_CONFIG: COM1 does not reach the AT device router");
        config_text = "";
        byte_count = $bits(dut.hps_io_at.CONF_STR) / 8;
        for (integer i = 0; i < byte_count; i = i + 1) begin
            config_byte = dut.hps_io_at.CONF_STR[(byte_count-i-1)*8 +: 8];
            if (config_byte === 8'h00 || (^config_byte) === 1'bx)
                $fatal(1, "AT_CONFIG: invalid byte at offset %0d of %0d", i, byte_count);
            config_text = {config_text, config_byte};
        end
        if (!contains("PCAT-286;") ||
            !contains("P1FC0,ROM,PCAT BIOS:;") ||
            !contains("P1FC3,ROM,EGA BIOS:;") ||
            contains("P1FC2,ROM,C800 BIOS:;") ||
            contains("2MB EMS D000-DFFF") ||
            contains("UMB E000-EFFF") ||
            !contains("S2,VHD,IDE 0-0;") ||
            !contains("R0,Reset & apply settings;") ||
            !contains("O[77:75],CPU Speed,MAX,6 MHz,8 MHz,10 MHz,12.5 MHz,16 MHz,20 MHz,25 MHz;") ||
            contains("P3O[77:75],CPU Speed,") ||
            !contains("J,Fire 1,Fire 2;") ||
            dut.hps_io_at.CONF_STR[23:0] !== "V,v")
            $fatal(1, "AT_CONFIG: host configuration is incomplete");
        if (contains("Debug") || contains("Trace") || dut.at_use_debug_q !== 1'b0)
            $fatal(1, "AT_CONFIG: debug is active in the production profile");
        $display("AT_CONFIG_NO_DEBUG_PASS bytes=%0d", byte_count);
        $finish;
    end
endmodule
