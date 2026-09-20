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
            !contains("P1FC2,ROM,C800 BIOS:;") ||
            !contains("P1FC3,ROM,EGA BIOS:;") ||
            !contains("P3OB,2MB EMS D000-DFFF,Enabled,Disabled;") ||
            !contains("P3OC,UMB E000-EFFF,Enabled,Disabled;") ||
            !contains("S2,VHD,IDE 0-0;") ||
            !contains("R0,Reset & apply settings;") ||
            !contains("J,Fire 1,Fire 2;") ||
            dut.hps_io_at.CONF_STR[23:0] !== "V,v")
            $fatal(1, "AT_CONFIG: host configuration is incomplete");
`ifdef SPK286_AT_NO_DEBUG
        if (contains("Debug") || contains("Trace") || dut.at_use_debug_q !== 1'b0)
            $fatal(1, "AT_CONFIG: debug is active in the production profile");
        $display("AT_CONFIG_NO_DEBUG_PASS bytes=%0d", byte_count);
`else
        if (!contains("P1O[71],SPK286 Debug,Off,On;"))
            $fatal(1, "AT_CONFIG: debug build lost its menu");
        $display("AT_CONFIG_DEBUG_PASS bytes=%0d", byte_count);
`endif
        $finish;
    end
endmodule
