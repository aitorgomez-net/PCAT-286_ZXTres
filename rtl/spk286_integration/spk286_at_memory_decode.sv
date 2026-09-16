// Authoritative address-range decode for the first AT memory profile.
//
// This unit only classifies a normalized memory/code request.  It does not
// implement RAM, ROM images or video side effects; those remain chipset
// owners.  The full 24-bit address is deliberately retained in every output
// decision, and I/O/INTA classes never select the memory path.
`timescale 1ns/1ps

module spk286_at_memory_decode (
    input  logic         request_valid,
    input  logic         request_write,
    input  logic [3:0]   cycle_class,
    input  logic [23:0]  address,

    output logic         memory_cycle,
    output logic         conventional_ram_select,
    output logic         video_aperture_select,
    output logic         option_region_select,
    output logic         system_bios_select,
    output logic         extended_ram_select,
    output logic         word_capable,
    output logic         write_allowed,
    output logic         rom_write_blocked,
    output logic         unmapped_request
);
    localparam logic [23:0] SYSTEM_BIOS_BASE       = 24'h0F0000;
    localparam logic [23:0] SYSTEM_BIOS_LIMIT      = 24'h0FFFFF;
    localparam logic [23:0] SYSTEM_BIOS_ALIAS_BASE = 24'hFFF000;
    localparam logic [23:0] SYSTEM_BIOS_ALIAS_LIMIT = 24'hFFFFFF;
    localparam logic [23:0] EXTENDED_RAM_BASE      = 24'h100000;
    localparam logic [23:0] EXTENDED_RAM_LIMIT     = 24'h15FFFF;

    logic valid_memory_class;
    logic system_bios_alias_select;

    always_comb begin
        case (cycle_class)
            4'h5, 4'h6, 4'hD:
                valid_memory_class = request_valid;
            default:
                valid_memory_class = 1'b0;
        endcase

        conventional_ram_select = valid_memory_class &&
                                   (address <= 24'h09FFFF);
        video_aperture_select    = valid_memory_class &&
                                   (address >= 24'h0A0000) &&
                                   (address <= 24'h0BFFFF);
        option_region_select     = valid_memory_class &&
                                   (address >= 24'h0C0000) &&
                                   (address <= 24'h0EFFFF);
        system_bios_alias_select = valid_memory_class &&
                                   (address >= SYSTEM_BIOS_ALIAS_BASE) &&
                                   (address <= SYSTEM_BIOS_ALIAS_LIMIT);
        system_bios_select       = valid_memory_class &&
                                   (((address >= SYSTEM_BIOS_BASE) &&
                                     (address <= SYSTEM_BIOS_LIMIT)) ||
                                    system_bios_alias_select);
        extended_ram_select      = valid_memory_class &&
                                   (address >= EXTENDED_RAM_BASE) &&
                                   (address <= EXTENDED_RAM_LIMIT) &&
                                   !system_bios_alias_select;

        memory_cycle = conventional_ram_select || video_aperture_select ||
                       option_region_select || system_bios_select ||
                       extended_ram_select;
        // These regions share the x16 SDRAM backend. EGA and unmapped
        // targets retain byte-lane transactions at the CPU bridge.
        word_capable = conventional_ram_select || option_region_select ||
                       system_bios_select || extended_ram_select;
        rom_write_blocked = valid_memory_class && request_write &&
                            (option_region_select || system_bios_select);
        write_allowed = valid_memory_class && request_write &&
                        (conventional_ram_select || video_aperture_select ||
                         extended_ram_select);

        // Addresses above the installed 1 MiB profile (640 KiB conventional
        // plus 384 KiB extended) are explicitly unmapped. The machine-level
        // sink completes such reads with FFh instead of exposing spare SDRAM.
        unmapped_request = request_valid && !memory_cycle;
    end
endmodule
