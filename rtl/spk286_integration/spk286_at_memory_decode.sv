// Authoritative address-range decode for the PCAT-286 AT memory profile.
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
    input  logic         ems_enabled,
    input  logic         ems_window_enabled[0:3],
    input  logic         umb_enabled,
    // OSD code: 0=1 MiB, 1=2 MiB, 2=4 MiB, 3=8 MiB, 4=16 MiB.
    input  logic [2:0]   installed_ram_size,

    output logic         memory_cycle,
    output logic         conventional_ram_select,
    output logic         video_aperture_select,
    output logic         option_region_select,
    output logic         system_bios_select,
    output logic         extended_ram_select,
    output logic         ems_aperture_select,
    output logic         umb_region_select,
    output logic         word_capable,
    output logic         write_allowed,
    output logic         rom_write_blocked,
    output logic         unmapped_request
);
    localparam logic [23:0] SYSTEM_BIOS_BASE       = 24'h0F0000;
    localparam logic [23:0] SYSTEM_BIOS_LIMIT      = 24'h0FFFFF;
    localparam logic [23:0] SYSTEM_BIOS_ALIAS_BASE = 24'hFF0000;
    localparam logic [23:0] SYSTEM_BIOS_ALIAS_LIMIT = 24'hFFFFFF;
    localparam logic [23:0] EXTENDED_RAM_BASE      = 24'h100000;

    logic valid_memory_class;
    logic system_bios_alias_select;
    logic ems_window_select;
    logic ems_page_frame_select;
    logic [23:0] extended_ram_limit;

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
        system_bios_alias_select = valid_memory_class &&
                                   (address >= SYSTEM_BIOS_ALIAS_BASE) &&
                                   (address <= SYSTEM_BIOS_ALIAS_LIMIT);
        system_bios_select       = valid_memory_class &&
                                   (((address >= SYSTEM_BIOS_BASE) &&
                                     (address <= SYSTEM_BIOS_LIMIT)) ||
                                    system_bios_alias_select);
        // The 1 MiB profile has 640 KiB conventional + 384 KiB extended.
        // Larger profiles retain that 384 KiB remap offset. Like the 86Box
        // 16-bit-bus AT model, the 16 MiB profile reserves the top 128 KiB:
        // FE0000h-FEFFFFh is unmapped and FF0000h-FFFFFFh is the BIOS alias.
        case (installed_ram_size)
            3'd0:    extended_ram_limit = 24'h45FFFF;
            3'd1:    extended_ram_limit = 24'h85FFFF;
            3'd2:    extended_ram_limit = 24'hFDFFFF;
            3'd3:    extended_ram_limit = 24'h15FFFF;
            3'd4:    extended_ram_limit = 24'h25FFFF;
            default: extended_ram_limit = 24'h45FFFF;
        endcase
        extended_ram_select      = valid_memory_class &&
                                   (address >= EXTENDED_RAM_BASE) &&
                                   (address <= extended_ram_limit) &&
                                   !system_bios_alias_select;

        ems_window_select       = ((address[15:14] == 2'b00) &&
                                   ems_window_enabled[0]) ||
                                  ((address[15:14] == 2'b01) &&
                                   ems_window_enabled[1]) ||
                                  ((address[15:14] == 2'b10) &&
                                   ems_window_enabled[2]) ||
                                  ((address[15:14] == 2'b11) &&
                                   ems_window_enabled[3]);
        ems_aperture_select     = valid_memory_class && ems_enabled &&
                                  (address >= 24'h0E0000) &&
                                  (address <= 24'h0EFFFF) &&
                                  ems_window_select;
        ems_page_frame_select  = valid_memory_class && ems_enabled &&
                                 (address >= 24'h0E0000) &&
                                 (address <= 24'h0EFFFF);

        // Preserve the EGA option ROM at C0000-C7FFF. The always-on UMB
        // covers C8000-DFFFF, and the EMS page frame occupies E0000-EFFFF.
        umb_region_select      = valid_memory_class && umb_enabled &&
                                 (address >= 24'h0C8000) &&
                                 (address <= 24'h0DFFFF);

        // Only the EGA BIOS window remains in the option-ROM region.
        option_region_select    = valid_memory_class &&
                                   (address >= 24'h0C0000) &&
                                   (address <= 24'h0C7FFF);

        memory_cycle = conventional_ram_select || video_aperture_select ||
                       option_region_select || system_bios_select ||
                       extended_ram_select || ems_aperture_select ||
                       umb_region_select;
        // These regions share the x16 SDRAM backend. EGA and unmapped
        // targets retain byte-lane transactions at the CPU bridge.
        word_capable = conventional_ram_select || option_region_select ||
                       system_bios_select || extended_ram_select ||
                       ems_aperture_select || umb_region_select;
        rom_write_blocked = valid_memory_class && request_write &&
                            (option_region_select || system_bios_select);
        write_allowed = valid_memory_class && request_write &&
                        (conventional_ram_select || video_aperture_select ||
                         extended_ram_select || ems_aperture_select ||
                         umb_region_select);

        // Addresses above the selected RAM profile are explicitly unmapped,
        // except for the separately-owned UMB and translated EMS apertures.
        // The machine-level sink completes other reads with FFh instead of
        // exposing spare SDRAM.
        unmapped_request = request_valid && !memory_cycle;
    end
endmodule
