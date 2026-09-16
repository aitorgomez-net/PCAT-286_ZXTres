// MiSTer top-level for the normalized PCAT-286 AT machine.
//
// This is the only machine top kept by the project.  sys_top selects emu_at
// through AT_PROFILE, so the legacy XT chipset is not present as a second
// SDRAM owner.
`timescale 1ns/1ps

module emu_at
(
`include "sys/emu_ports.vh"
);

    // Keep the AT profile's System & BIOS page local to the PCAT-286 top.
    // These indices are part of the HPS/OSD contract: bit 7 is splash,
    // bit 71 enables the diagnostic overlay and bits 73:72 select its page.
    // The ROM marker is required for MiSTer to expose a real file selector.
    localparam CONF_STR_HALT_AT = {
        "h4-,HALTED: no PCAT ROM selected;",
        "h5-,HALTED: no EGA BIOS selected;"
    };

`ifndef SPK286_AT_NO_DEBUG
    localparam CONF_STR_AT_DEBUG = {
        "P1O[71],SPK286 Debug,Off,On;",
        "P1O[73:72],Debug Page,CPU,Registers,Bus,Trace;"
    };
`endif

    localparam CONF_STR_AT = {
        "PCAT-286;",
        CONF_STR_HALT_AT,
        "S0,IMGIMAVFD,Floppy A:;",
        "S1,IMGIMAVFD,Floppy B:;",
        "OJK,Write Protect,None,A:,B:,A: & B:;",
        "-;",
        "S2,VHD,IDE 0-0;",
        "S3,VHD,IDE 0-1;",
        "OLM,2nd SD card,Disable,IDE 0-0,IDE 0-1;",
        "-;",
        "P1,System & BIOS;",
        "P1-;",
        "P1O7,Boot Splash Screen,Yes,No;",
        "P1FC0,ROM,PCAT BIOS:;",
        "P1FC2,ROM,EC00 BIOS:;",
        "P1FC3,ROM,EGA BIOS:;",
        "P1-;",
        // An empty packed Verilog string is an 8-bit NUL, not zero bytes.
        // Omit the entire element so the host can read the remaining entries.
`ifndef SPK286_AT_NO_DEBUG
        CONF_STR_AT_DEBUG,
`endif
        "P1-;",
        "-;",
        "R0,Reset & apply settings;",
        "J,Fire 1,Fire 2;",
        "V,v"
    };

    wire [35:0] EXT_BUS;
    wire [21:0] gamma_bus;
    assign gamma_bus[21] = 1'b0;

    wire [15:0] at_mgmt_din;
    wire [15:0] at_mgmt_dout;
    wire [15:0] at_mgmt_address;
    wire        at_mgmt_read;
    wire        at_mgmt_write;
    wire [1:0]  at_floppy_present;
    wire [1:0]  at_floppy_request;
    wire [2:0]  at_ide_request;
    wire [7:0]  at_mgmt_request = {at_floppy_request, 3'b000,
                                   at_ide_request};

    // Use the same MiSTer management transport and request bit layout as the
    // XT profile. Requests 7:6 are floppy A/B and 2:0 belong to XT-IDE.
    // RTC/CMOS updates are host-pushed writes in the F4xx window and therefore
    // need no request bit.
    hps_ext hps_ext_at (
        .clk_sys     (CLK_50M),
        .EXT_BUS     (EXT_BUS),
        .ext_din     (at_mgmt_din),
        .ext_dout    (at_mgmt_dout),
        .ext_addr    (at_mgmt_address),
        .ext_rd      (at_mgmt_read),
        .ext_wr      (at_mgmt_write),
        .ext_midi    (),
        .ext_req     (at_mgmt_request),
        .ext_hotswap (2'b00)
    );

    wire [31:0] joystick_0;
    wire [31:0] joystick_1;
    wire [15:0] joystick_l_analog_0;
    wire [15:0] joystick_l_analog_1;
    wire [1:0]  hps_buttons;
    wire        forced_scandoubler;
    wire        direct_video;
    wire [127:0] hps_status;
    wire [15:0]  hps_status_menumask;
    wire         at_debug_enable = hps_status[71];
    wire [1:0]   at_debug_page = hps_status[73:72];
    wire [10:0]  ps2_key;
    wire          ps2_kbd_clk_out;
    wire          ps2_kbd_data_out;
    wire          ps2_mouse_clk_out;
    wire          ps2_mouse_data_out;
    wire [7:0]    uart_mode;

    wire        ioctl_download;
    wire [15:0] ioctl_index;
    wire        ioctl_wr;
    wire [26:0] ioctl_addr;
    wire [15:0] ioctl_data;
    wire        ioctl_wait;

    // No legacy PS/2 device is instantiated in this profile.  hps_io still
    // supplies its decoded event stream, which is translated into the AT
    // 8042 host-byte boundary below.
    wire ps2_kbd_clk_in  = 1'b1;
    wire ps2_kbd_data_in = 1'b1;
    wire ps2_mouse_clk_in  = 1'b1;
    wire ps2_mouse_data_in = 1'b1;

    hps_io #(
        .CONF_STR (CONF_STR_AT),
        .PS2DIV   (2000),
        .PS2WE    (1),
        .WIDE     (1)
    ) hps_io_at (
        .clk_sys              (CLK_50M),
        .HPS_BUS              (HPS_BUS),
        .EXT_BUS              (EXT_BUS),
        .gamma_bus            (gamma_bus),
        .forced_scandoubler   (forced_scandoubler),
        .direct_video         (direct_video),
        .buttons              (hps_buttons),
        .status               (hps_status),
        .status_menumask      (hps_status_menumask),
        .video_rotated        (1'b0),
        .new_vmode            (1'b0),
        .info_req             (1'b0),
        .info                 (8'h00),
        .status_in            (128'h0),
        .status_set           (1'b0),
        .uart_mode            (uart_mode),
        .ps2_key              (ps2_key),
        .ps2_kbd_clk_in       (ps2_kbd_clk_in),
        .ps2_kbd_data_in      (ps2_kbd_data_in),
        .ps2_kbd_clk_out      (ps2_kbd_clk_out),
        .ps2_kbd_data_out     (ps2_kbd_data_out),
        .ps2_mouse_clk_in     (ps2_mouse_clk_in),
        .ps2_mouse_data_in    (ps2_mouse_data_in),
        .ps2_mouse_clk_out    (ps2_mouse_clk_out),
        .ps2_mouse_data_out   (ps2_mouse_data_out),
        .joystick_0           (joystick_0),
        .joystick_1           (joystick_1),
        .joystick_l_analog_0  (joystick_l_analog_0),
        .joystick_l_analog_1  (joystick_l_analog_1),
        .ioctl_download       (ioctl_download),
        .ioctl_index          (ioctl_index),
        .ioctl_wr             (ioctl_wr),
        .ioctl_addr           (ioctl_addr),
        .ioctl_dout           (ioctl_data),
        .ioctl_wait           (ioctl_wait),
        .ioctl_upload_req     (1'b0),
        .ioctl_upload_index   (8'h00),
        .ioctl_din            (16'h0000)
    );

    wire        physical_idle;
    wire [12:0] sdram_address;
    wire        sdram_cke;
    wire        sdram_cs;
    wire        sdram_ras;
    wire        sdram_cas;
    wire        sdram_we;
    wire [1:0]  sdram_ba;
    wire [15:0] sdram_dq_in;
    wire [15:0] sdram_dq_out;
    wire        sdram_dq_io;
    wire        sdram_ldqm;
    wire        sdram_udqm;
    logic       sdram_initialized_q;

    assign sdram_dq_in = SDRAM_DQ;
    assign SDRAM_DQ = ~sdram_dq_io ? sdram_dq_out : 16'hzzzz;
    assign SDRAM_CLK = CLK_50M;
    assign SDRAM_A   = sdram_address;
    assign SDRAM_CKE = sdram_cke;
    assign SDRAM_BA  = sdram_ba;
    assign SDRAM_nCS = sdram_cs;
    assign SDRAM_nRAS = sdram_ras;
    assign SDRAM_nCAS = sdram_cas;
    assign SDRAM_nWE  = sdram_we;
    assign SDRAM_DQML = sdram_ldqm;
    assign SDRAM_DQMH = sdram_udqm;

    // physical_idle is a transaction-state signal and therefore drops for
    // every SDRAM access.  The HPS loader needs a monotonic initialization
    // indication so an active ROM word is not reset at the next command.
    always_ff @(posedge CLK_50M or posedge RESET) begin
        if (RESET)
            sdram_initialized_q <= 1'b0;
        else if (physical_idle)
            sdram_initialized_q <= 1'b1;
    end

    wire        loader_valid;
    wire        loader_write;
    wire [23:0] loader_address;
    wire [1:0]  loader_byte_enable;
    wire [15:0] loader_data_out;
    wire        loader_accept;
    wire        loader_ready;
    wire [2:0]  bios_protect_flag;
    wire        main_rom_loaded;
    wire        ega_rom_loaded;
    wire        xtide_rom_loaded;
    wire        loader_active;
    wire        loader_protocol_error;

    // Match the PCXT status_menumask contract: bits 4 and 5 expose the
    // missing-main/EGA indicators used by h4/h5 in the configuration string.
    // The lower four bits are intentionally clear because this profile has no
    // hidden MIDI/legacy entries occupying those positions.
    assign hps_status_menumask = {10'd0, ~ega_rom_loaded, ~main_rom_loaded,
                                  4'b0000};

    spk286_at_hps_rom_loader u_at_hps_rom_loader (
        .clk                (CLK_50M),
        .reset              (RESET),
        .sdram_initialized  (sdram_initialized_q),
        .ioctl_download     (ioctl_download),
        .ioctl_index        (ioctl_index[7:0]),
        .ioctl_wr           (ioctl_wr),
        .ioctl_addr         (ioctl_addr[24:0]),
        .ioctl_data         (ioctl_data),
        .ioctl_wait         (ioctl_wait),
        .loader_valid       (loader_valid),
        .loader_write       (loader_write),
        .loader_address     (loader_address),
        .loader_byte_enable (loader_byte_enable),
        .loader_data_out    (loader_data_out),
        .loader_accept      (loader_accept),
        .loader_ready       (loader_ready),
        .bios_protect_flag  (bios_protect_flag),
        .main_rom_loaded    (main_rom_loaded),
        .ega_rom_loaded     (ega_rom_loaded),
        .xtide_rom_loaded   (xtide_rom_loaded),
        .load_active        (loader_active),
        .protocol_error     (loader_protocol_error)
    );

    wire        cpu_memory_valid;
    wire        cpu_memory_command_valid;
    wire        cpu_memory_write;
    wire        cpu_memory_code_fetch;
    wire [3:0]  cpu_memory_cycle_class;
    wire [23:0] cpu_memory_address;
    wire [1:0]  cpu_memory_byte_enable;
    wire [15:0] cpu_memory_data_out;
    wire        cpu_memory_accept;
    wire        cpu_memory_ready;
    wire [15:0] cpu_memory_read_data;
    wire        cpu_memory_read_data_valid;

    wire        at_cpu_data_oe;
    wire [23:0] at_cpu_address;
    wire [15:0] at_cpu_data_out;
    wire [15:0] at_cpu_data_in;
    wire        at_cpu_bus_valid;
    wire        at_cpu_bus_write;
    wire        at_cpu_bus_bhe_n;
    wire [3:0]  at_cpu_bus_status;
    wire        at_cpu_bus_lock;
    wire        at_cpu_hlda;
    wire        at_cpu_ready;
    wire        at_cpu_halted;
    wire        at_cpu_shutdown;
    wire        at_debug_bridge_error;
    wire        at_debug_control_error;
    wire        at_debug_unsupported_opcode;
    wire        at_debug_microcode_fault;
    wire        at_debug_operand_blocked;
    wire        at_debug_event_completed;
    wire [7:0]  at_debug_event_vector;
    wire [2:0]  at_debug_event_kind;
    wire [7:0]  at_debug_opcode;
    wire [15:0] at_debug_cs;
    wire [23:0] at_debug_cs_base;
    wire [15:0] at_debug_ip;
    wire [15:0] at_debug_flags;
    wire [127:0] at_debug_gpr;
    wire [63:0] at_debug_segment_selectors;
    wire        at_debug_fetch_blocked;
    wire [16:0] at_debug_fetch_cursor;
    wire [11:0] at_debug_micro_pc;
    wire [11:0] at_debug_micro_entry;
    wire [7:0]  at_debug_micro_instruction;
    wire        at_debug_micro_active;
    wire [3:0]  at_debug_prefetch_count;
    wire [3:0]  at_debug_bus_state;
    wire [7:0]  at_debug_biu_detail;
    wire [7:0]  at_debug_last_post;
    wire [15:0] at_debug_cpu_cycle_count;
    wire [15:0] at_debug_at_cycle_count;
    wire [31:0] at_debug_trace0;
    wire [31:0] at_debug_trace1;
    wire [31:0] at_debug_trace2;
    wire [31:0] at_debug_trace3;
    wire [7:0]  at_debug_keyboard_keycode;
    wire        at_debug_keyboard_irq;
    wire [7:0]  at_debug_keyboard_port_b;
    wire        at_debug_keyboard_pic_int;
    wire [3:0]  at_debug_dma_request;
    wire [3:0]  at_debug_dma_acknowledge_n;
    wire [19:0] at_debug_address;
    wire [7:0]  at_debug_data_out;
    wire [7:0]  at_debug_data_in;
    wire [2:0]  at_debug_status;
    wire        at_debug_valid;
    wire        at_debug_write;
    wire        at_debug_io;
    wire        at_debug_inta;
    wire        at_debug_code;
    wire        at_debug_byte_high;
    wire        at_debug_memory_projection;
    wire        at_debug_cycle_active;
    wire        at_debug_ready;
    wire        at_debug_hold_request;
    wire        at_debug_bridge_idle;
    wire        at_speaker_active;
    wire        at_speaker_level;

    wire        dma_memory_valid;
    wire        dma_memory_write;
    wire        dma_memory_read;
    wire [23:0] dma_memory_address;
    wire [1:0]  dma_memory_byte_enable;
    wire [15:0] dma_memory_data_out;
    wire        dma_memory_accept;
    wire        dma_memory_ready;
    wire [15:0] dma_memory_data_in;

    wire        refresh_memory_valid;
    wire [23:0] refresh_memory_address;
    wire        refresh_memory_accept;
    wire        refresh_memory_ready;

    wire        backend_valid;
    wire        backend_command_valid;
    wire [1:0]  backend_owner;
    wire        backend_write;
    wire        backend_refresh;
    wire        backend_code_fetch;
    wire [3:0]  backend_cycle_class;
    wire [23:0] backend_address;
    wire [1:0]  backend_byte_enable;
    wire [15:0] backend_data_out;
    wire        backend_accept;
    wire        backend_ready;
    wire [15:0] backend_read_data;
    wire        backend_read_data_valid;
    wire        memory_port_protocol_error;

    wire        p03_out_valid;
    wire        p03_out_command_valid;
    wire [1:0]  p03_out_owner;
    wire        p03_out_write;
    wire        p03_out_refresh;
    wire        p03_out_code_fetch;
    wire        p03_out_burst;
    wire [3:0]  p03_out_cycle_class;
    wire [23:0] p03_out_address;
    wire [1:0]  p03_out_byte_enable;
    wire [15:0] p03_out_data_out;
    wire        p03_in_accept;
    wire        p03_in_ready;
    wire [15:0] p03_in_read_data;
    wire        p03_in_read_data_valid;
    wire        p03_out_accept;
    wire        p03_out_ready;
    wire [15:0] p03_out_read_data;
    wire        p03_out_read_data_valid;
    wire [31:0] p03_hit_count;
    wire [31:0] p03_miss_count;
    wire [31:0] p03_fill_count;
    wire [31:0] p03_physical_read_count;
    wire [31:0] p03_invalidation_count;

    // Keep the existing logical-backend debug names pointed at the response
    // seen by the memory port. The physical owner handshake is intentionally
    // private to the P03 fill/bypass state machine.
    assign backend_accept          = p03_in_accept;
    assign backend_ready           = p03_in_ready;
    assign backend_read_data       = p03_in_read_data;
    assign backend_read_data_valid = p03_in_read_data_valid;

    spk286_at_mister_memory_port u_at_memory_port (
        .clk                    (CLK_50M),
        .reset                  (RESET),
        .cancel_cpu             (at_machine_reset | at_cpu_reset_request),
        .cpu_valid              (cpu_memory_valid),
        .cpu_command_valid      (cpu_memory_command_valid),
        .cpu_write              (cpu_memory_write),
        .cpu_code_fetch         (cpu_memory_code_fetch),
        .cpu_cycle_class        (cpu_memory_cycle_class),
        .cpu_address            (cpu_memory_address),
        .cpu_byte_enable        (cpu_memory_byte_enable),
        .cpu_data_out           (cpu_memory_data_out),
        .cpu_accept             (cpu_memory_accept),
        .cpu_ready              (cpu_memory_ready),
        .cpu_read_data          (cpu_memory_read_data),
        .cpu_read_data_valid    (cpu_memory_read_data_valid),
        .loader_valid           (loader_valid),
        .loader_write           (loader_write),
        .loader_address         (loader_address),
        .loader_byte_enable     (loader_byte_enable),
        .loader_data_out        (loader_data_out),
        .loader_accept          (loader_accept),
        .loader_ready           (loader_ready),
        .loader_read_data       (),
        .dma_valid              (dma_memory_valid),
        .dma_write              (dma_memory_write),
        .dma_address            (dma_memory_address),
        .dma_byte_enable        (dma_memory_byte_enable),
        .dma_data_out           (dma_memory_data_out),
        .dma_accept             (dma_memory_accept),
        .dma_ready              (dma_memory_ready),
        .dma_read_data          (dma_memory_data_in),
        .refresh_valid          (refresh_memory_valid),
        .refresh_address        (refresh_memory_address),
        .refresh_accept         (refresh_memory_accept),
        .refresh_ready          (refresh_memory_ready),
        .backend_valid          (backend_valid),
        .backend_command_valid  (backend_command_valid),
        .backend_owner          (backend_owner),
        .backend_write          (backend_write),
        .backend_refresh        (backend_refresh),
        .backend_code_fetch     (backend_code_fetch),
        .backend_cycle_class    (backend_cycle_class),
        .backend_address        (backend_address),
        .backend_byte_enable    (backend_byte_enable),
        .backend_data_out       (backend_data_out),
        .backend_accept         (p03_in_accept),
        .backend_ready          (p03_in_ready),
        .backend_read_data      (p03_in_read_data),
        .backend_read_data_valid(p03_in_read_data_valid),
        .protocol_error         (memory_port_protocol_error)
    );

    // P03 is placed below the single-owner memory port. The port still
    // serializes CPU, DMA, loader and refresh ownership; the buffer can
    // therefore invalidate one line on every accepted write without adding
    // a second coherence arbiter.
    spk286_at_sdram_read_buffer #(
        .ENABLE(1'b1)
    ) u_at_sdram_read_buffer (
        .clk                     (CLK_50M),
        .reset                   (RESET),
        .cancel_cpu              (at_machine_reset | at_cpu_reset_request),
        .enable                  (1'b1),
        .in_valid                (backend_valid),
        .in_command_valid        (backend_command_valid),
        .in_owner                (backend_owner),
        .in_write                (backend_write),
        .in_refresh              (backend_refresh),
        .in_code_fetch           (backend_code_fetch),
        .in_cycle_class          (backend_cycle_class),
        .in_address              (backend_address),
        .in_byte_enable          (backend_byte_enable),
        .in_data_out             (backend_data_out),
        .in_accept               (p03_in_accept),
        .in_ready                (p03_in_ready),
        .in_read_data            (p03_in_read_data),
        .in_read_data_valid      (p03_in_read_data_valid),
        .out_valid               (p03_out_valid),
        .out_command_valid       (p03_out_command_valid),
        .out_owner               (p03_out_owner),
        .out_write               (p03_out_write),
        .out_refresh             (p03_out_refresh),
        .out_code_fetch          (p03_out_code_fetch),
        .out_burst               (p03_out_burst),
        .out_cycle_class         (p03_out_cycle_class),
        .out_address             (p03_out_address),
        .out_byte_enable         (p03_out_byte_enable),
        .out_data_out            (p03_out_data_out),
        .out_accept              (p03_out_accept),
        .out_ready               (p03_out_ready),
        .out_read_data           (p03_out_read_data),
        .out_read_data_valid     (p03_out_read_data_valid),
        .debug_hit_count         (p03_hit_count),
        .debug_miss_count        (p03_miss_count),
        .debug_fill_count        (p03_fill_count),
        .debug_physical_read_count(p03_physical_read_count),
        .debug_invalidation_count(p03_invalidation_count)
    );

    wire        sdram_owner_protocol_error;
    spk286_at_mister_sdram_owner u_at_sdram_owner (
        .clk                    (CLK_50M),
        .reset                  (RESET),
        .request_valid          (p03_out_valid),
        .request_command_valid  (p03_out_command_valid),
        .request_owner_refresh  (p03_out_refresh),
        .request_write          (p03_out_write),
        .request_code_fetch     (p03_out_code_fetch),
        .request_burst          (p03_out_burst),
        .request_cycle_class    (p03_out_cycle_class),
        .request_address        (p03_out_address),
        .request_byte_enable    (p03_out_byte_enable),
        .request_data_out       (p03_out_data_out),
        .request_accept         (p03_out_accept),
        .request_ready          (p03_out_ready),
        .request_read_data      (p03_out_read_data),
        .request_read_data_valid(p03_out_read_data_valid),
        .physical_idle          (physical_idle),
        .protocol_error         (sdram_owner_protocol_error),
        .sdram_address           (sdram_address),
        .sdram_cke               (sdram_cke),
        .sdram_cs                (sdram_cs),
        .sdram_ras               (sdram_ras),
        .sdram_cas               (sdram_cas),
        .sdram_we                (sdram_we),
        .sdram_ba                (sdram_ba),
        .sdram_dq_in             (sdram_dq_in),
        .sdram_dq_out            (sdram_dq_out),
        .sdram_dq_io             (sdram_dq_io),
        .sdram_ldqm              (sdram_ldqm),
        .sdram_udqm              (sdram_udqm)
    );

    logic counter_clock;
    spk286_at_pit_clock u_pit_clock(.clk(CLK_50M), .reset(RESET), .counter_clock(counter_clock));
    logic periodic_tick;
    logic second_tick;
    logic [25:0] tick_counter;
    always_ff @(posedge CLK_50M or posedge RESET) begin
        if (RESET) begin
            periodic_tick <= 1'b0;
            second_tick   <= 1'b0;
            tick_counter  <= 26'd0;
        end else begin
            periodic_tick <= (tick_counter[11:0] == 12'h000);
            second_tick   <= (tick_counter == 26'd49_999_999);
            if (tick_counter == 26'd49_999_999)
                tick_counter <= 26'd0;
            else
                tick_counter <= tick_counter + 1'b1;
        end
    end

    wire keyboard_byte_valid;
    wire [7:0] keyboard_byte;
    wire keyboard_byte_ready;
    wire keyboard_translate_set1;
    wire keyboard_event_overflow;

    // Keep the AT machine in reset until the private video PLL is usable as
    // well as until the system BIOS has arrived.  The BIOS loader and SDRAM
    // remain in the 50 MHz domain, so this does not change download timing.
    wire at_video_clk_28;
    wire at_video_clk_57;
    wire at_video_clk_57_ps;
    wire at_video_clk_native;
    wire at_video_pll_locked;
    pll_system u_at_video_pll (
        .refclk   (CLK_50M),
        .rst      (1'b0),
        .outclk_0 (at_video_clk_28),
        .outclk_1 (at_video_clk_57),
        .outclk_2 (at_video_clk_57_ps),
        .outclk_3 (at_video_clk_native),
        .locked   (at_video_pll_locked)
    );

    // Keep the reset that gates the splash sequencer separate from the
    // machine reset.  The XT profile holds the CPU in reset while its splash
    // is visible; feeding the machine reset back into the sequencer would
    // clear the timer as soon as the splash became active.
    // Reuse the XT reset controls without clearing the loaded ROM flags.
    wire at_boot_reset = RESET | hps_status[0] | hps_buttons[1] |
                         !main_rom_loaded | !at_video_pll_locked;

    spk286_at_keyboard u_at_keyboard (
        .clk                    (CLK_50M),
        .reset                  (at_boot_reset),
        .ps2_key                (ps2_key),
        .translate_set1         (keyboard_translate_set1),
        .keyboard_byte_ready    (keyboard_byte_ready),
        .keyboard_byte_valid    (keyboard_byte_valid),
        .keyboard_byte          (keyboard_byte),
        .overflow               (keyboard_event_overflow)
    );

    // Keep the XT-compatible second-SD routing selection stable until the
    // machine is reset, matching the XT profile's use_mmc latch.  Bits 22:21
    // are free in the AT profile and are reserved for this shared OSD field.
    logic [1:0] at_use_mmc_q;
    always_ff @(posedge CLK_50M or posedge RESET) begin
        if (RESET)
            at_use_mmc_q <= 2'b00;
        else if (at_boot_reset)
            at_use_mmc_q <= hps_status[22:21];
    end

    // Keep the AT splash lifetime aligned with the XT profile.  Previously
    // this was wired directly to hps_status[7], which made the default
    // "Yes" setting hold the image forever while the CPU continued running
    // behind it.
    wire at_splashscreen;
    wire at_splash_boot_hold;
    spk286_at_splash_control u_at_splash_control (
        .clk         (CLK_50M),
        .reset       (at_boot_reset),
        .option_off  (hps_status[7]),
        .second_tick (second_tick),
        .splash_active(at_splashscreen),
        .boot_hold   (at_splash_boot_hold)
    );

    // The splash is a real boot hold, not only a video overlay.  This keeps
    // CPU/BIU state frozen from boot settling until the image is removed.
    // As in XT, the pending interval is part of the boot hold; otherwise
    // the CPU runs before the first timer tick and is reset a second time.
    wire at_machine_reset = at_boot_reset | at_splash_boot_hold;
    wire at_cpu_reset_request;
    logic at_video_pipe_reset_57_q1;
    logic at_video_pipe_reset_57_q2;
    logic at_video_pipe_reset_57_ps_q1;
    logic at_video_pipe_reset_57_ps_q2;
    wire  at_video_pipe_reset_57 = at_video_pipe_reset_57_q2;
    wire  at_video_pipe_reset_57_ps = at_video_pipe_reset_57_ps_q2;

    // Reset release for each output pipeline is synchronized to its own
    // phase. This keeps PLL lock/BIOS-load reset out of recovery paths in the
    // 57.272 MHz output registers.
    always_ff @(posedge at_video_clk_57 or posedge at_boot_reset) begin
        if (at_boot_reset) begin
            at_video_pipe_reset_57_q1 <= 1'b1;
            at_video_pipe_reset_57_q2 <= 1'b1;
        end else begin
            // The output pipeline must remain live while the splash is
            // displayed; only the AT machine itself is held in reset.
            at_video_pipe_reset_57_q1 <= 1'b0;
            at_video_pipe_reset_57_q2 <= at_video_pipe_reset_57_q1;
        end
    end

    always_ff @(posedge at_video_clk_57_ps or posedge at_boot_reset) begin
        if (at_boot_reset) begin
            at_video_pipe_reset_57_ps_q1 <= 1'b1;
            at_video_pipe_reset_57_ps_q2 <= 1'b1;
        end else begin
            at_video_pipe_reset_57_ps_q1 <= 1'b0;
            at_video_pipe_reset_57_ps_q2 <= at_video_pipe_reset_57_ps_q1;
        end
    end
    wire cpu_fault;
    wire machine_protocol_error;

    // Raw EGA timing and colour signals stay in the raster clock domain until
    // they enter the established 57.272 MHz MiSTer output pipeline below.
    wire [5:0] at_video_red_raw;
    wire [5:0] at_video_green_raw;
    wire [5:0] at_video_blue_raw;
    wire       at_video_hsync_raw;
    wire       at_video_hblank_raw;
    wire       at_video_dbl_hsync_raw;
    wire       at_video_vsync_raw;
    wire       at_video_vblank_raw;
    wire       at_video_vblank_border_raw;
    wire       at_video_de_raw;
    wire       at_video_dot_toggle_raw;
    wire       at_video_scandouble_raw;
    wire       at_video_vmode_toggle_raw;
    wire       at_video_mode350_raw;
    wire [11:0] at_video_active_dots_raw;
    wire [9:0]  at_video_active_lines_raw;

    spk286_at_machine u_at_machine (
        .clk                    (CLK_50M),
        // Keep the AT devices and EGA raster alive during the splash.  Only
        // the CPU/BIU reset is extended over the splash interval.
        .reset                  (at_boot_reset),
        .cpu_reset              (at_machine_reset),
        .clk_video              (at_video_clk_28),
        .splashscreen           (at_splashscreen),
        .execute_enable         (1'b1),
        .counter_clock          (counter_clock),
        .refresh_enable         (1'b1),
        .keyboard_byte_valid    (keyboard_byte_valid),
        .keyboard_byte          (keyboard_byte),
        .keyboard_byte_ready    (keyboard_byte_ready),
        .keyboard_translate_set1(keyboard_translate_set1),
        .periodic_tick          (periodic_tick),
        .second_tick             (second_tick),
        .parity_event           (1'b0),
        .channel_check_event    (1'b0),
        .external_nmi_event     (1'b0),
        .mgmt_address           (at_mgmt_address),
        .mgmt_writedata         (at_mgmt_dout),
        .mgmt_write             (at_mgmt_write),
        .mgmt_read              (at_mgmt_read),
        .mgmt_readdata          (at_mgmt_din),
        .use_mmc                (at_use_mmc_q),
        .floppy_write_protect   (hps_status[20:19]),
        .floppy_present         (at_floppy_present),
        .floppy_request         (at_floppy_request),
        .ide_request            (at_ide_request),
        .cpu_address            (at_cpu_address),
        .cpu_data_out           (at_cpu_data_out),
        .cpu_data_in            (at_cpu_data_in),
        .cpu_data_oe            (at_cpu_data_oe),
        .cpu_bus_valid          (at_cpu_bus_valid),
        .cpu_bus_write          (at_cpu_bus_write),
        .cpu_bus_bhe_n          (at_cpu_bus_bhe_n),
        .cpu_bus_status         (at_cpu_bus_status),
        .cpu_bus_lock           (at_cpu_bus_lock),
        .cpu_hlda               (at_cpu_hlda),
        .cpu_ready              (at_cpu_ready),
        .cpu_halted             (at_cpu_halted),
        .cpu_shutdown           (at_cpu_shutdown),
`ifndef SPK286_AT_NO_DEBUG
        .debug_bridge_error     (at_debug_bridge_error),
        .debug_control_error    (at_debug_control_error),
        .debug_unsupported_opcode(at_debug_unsupported_opcode),
        .debug_microcode_fault  (at_debug_microcode_fault),
        .debug_operand_blocked  (at_debug_operand_blocked),
        .debug_event_completed  (at_debug_event_completed),
        .debug_event_vector     (at_debug_event_vector),
        .debug_event_kind       (at_debug_event_kind),
        .debug_opcode           (at_debug_opcode),
        .debug_cs               (at_debug_cs),
        .debug_cs_base          (at_debug_cs_base),
        .debug_ip               (at_debug_ip),
        .debug_flags            (at_debug_flags),
        .debug_gpr              (at_debug_gpr),
        .debug_segment_selectors(at_debug_segment_selectors),
        .debug_fetch_blocked    (at_debug_fetch_blocked),
        .debug_fetch_cursor     (at_debug_fetch_cursor),
        .debug_micro_pc         (at_debug_micro_pc),
        .debug_micro_entry      (at_debug_micro_entry),
        .debug_micro_instruction(at_debug_micro_instruction),
        .debug_micro_active     (at_debug_micro_active),
        .debug_prefetch_count   (at_debug_prefetch_count),
        .debug_bus_state        (at_debug_bus_state),
        .debug_biu_detail       (at_debug_biu_detail),
        .debug_last_post        (at_debug_last_post),
        .debug_cpu_cycle_count  (at_debug_cpu_cycle_count),
        .debug_at_cycle_count   (at_debug_at_cycle_count),
        .debug_trace0           (at_debug_trace0),
        .debug_trace1           (at_debug_trace1),
        .debug_trace2           (at_debug_trace2),
        .debug_trace3           (at_debug_trace3),
        .debug_keyboard_keycode (at_debug_keyboard_keycode),
        .debug_keyboard_irq     (at_debug_keyboard_irq),
        .debug_keyboard_port_b  (at_debug_keyboard_port_b),
        .debug_keyboard_pic_int (at_debug_keyboard_pic_int),
        .debug_dma_request      (at_debug_dma_request),
        .debug_dma_acknowledge_n(at_debug_dma_acknowledge_n),
        .debug_at_address       (at_debug_address),
        .debug_at_data_out      (at_debug_data_out),
        .debug_at_data_in       (at_debug_data_in),
        .debug_at_status        (at_debug_status),
        .debug_at_valid         (at_debug_valid),
        .debug_at_write         (at_debug_write),
        .debug_at_io            (at_debug_io),
        .debug_at_inta          (at_debug_inta),
        .debug_at_code          (at_debug_code),
        .debug_at_byte_high     (at_debug_byte_high),
        .debug_at_memory_projection(at_debug_memory_projection),
        .debug_at_cycle_active  (at_debug_cycle_active),
        .debug_at_ready         (at_debug_ready),
        .cpu_hold_request       (at_debug_hold_request),
        .bridge_idle            (at_debug_bridge_idle),
`endif
        .memory_request_valid   (cpu_memory_valid),
        .memory_command_valid   (cpu_memory_command_valid),
        .memory_write           (cpu_memory_write),
        .memory_code_fetch      (cpu_memory_code_fetch),
        .memory_cycle_class     (cpu_memory_cycle_class),
        .memory_address         (cpu_memory_address),
        .memory_byte_enable     (cpu_memory_byte_enable),
        .memory_data_out        (cpu_memory_data_out),
        .memory_accept          (cpu_memory_accept),
        .memory_ready           (cpu_memory_ready),
        .memory_read_data       (cpu_memory_read_data),
        .memory_read_data_valid (cpu_memory_read_data_valid),
        .dma_memory_valid       (dma_memory_valid),
        .dma_memory_write       (dma_memory_write),
        .dma_memory_read        (dma_memory_read),
        .dma_memory_address     (dma_memory_address),
        .dma_memory_byte_enable (dma_memory_byte_enable),
        .dma_memory_data_out    (dma_memory_data_out),
        .dma_memory_accept      (dma_memory_accept),
        .dma_memory_ready       (dma_memory_ready),
        .dma_memory_data_in     (dma_memory_data_in),
        .refresh_memory_valid   (refresh_memory_valid),
        .refresh_memory_address (refresh_memory_address),
        .refresh_memory_accept  (refresh_memory_accept),
        .refresh_memory_ready   (refresh_memory_ready),
        .cpu_fault              (cpu_fault),
        .cpu_reset_request      (at_cpu_reset_request),
        .speaker_active         (at_speaker_active),
        .speaker_level          (at_speaker_level),
        .protocol_error         (machine_protocol_error),
        .video_red              (at_video_red_raw),
        .video_green            (at_video_green_raw),
        .video_blue             (at_video_blue_raw),
        .video_hsync            (at_video_hsync_raw),
        .video_hblank           (at_video_hblank_raw),
        .video_dbl_hsync        (at_video_dbl_hsync_raw),
        .video_vsync            (at_video_vsync_raw),
        .video_vblank           (at_video_vblank_raw),
        .video_vblank_border    (at_video_vblank_border_raw),
        .video_de               (at_video_de_raw),
        .video_dot_toggle       (at_video_dot_toggle_raw),
        .video_scandouble_active(at_video_scandouble_raw),
        .video_vmode_toggle     (at_video_vmode_toggle_raw),
        .video_mode350          (at_video_mode350_raw),
        .video_active_dots      (at_video_active_dots_raw),
        .video_active_lines     (at_video_active_lines_raw)
    );

    // The AT device owns the EGA registers, planar VRAM and raster.  The EGA
    // itself runs at 28.636 MHz; MiSTer's video shell receives the same
    // 57.272 MHz phase-shifted pipeline clock used by the established XT
    // profile.  A dot toggle is crossed to the pipeline domain so CE_PIXEL
    // remains the real EGA dot enable in both 14.318 and 16.257 MHz modes.
    logic       at_video_dot_d_q;
    logic       at_video_dot_dd_q;
    logic [7:0] at_video_r_pipe_q;
    logic [7:0] at_video_g_pipe_q;
    logic [7:0] at_video_b_pipe_q;
    logic       at_video_hs_pipe_q;
    logic       at_video_hb_pipe_q;
    logic       at_video_vs_pipe_q;
    logic       at_video_vb_pipe_q;
    logic       at_video_de_pipe_q;
    logic       at_video_ce_pipe_q;
    logic [7:0] at_video_r_out_q;
    logic [7:0] at_video_g_out_q;
    logic [7:0] at_video_b_out_q;
    logic       at_video_hs_out_q;
    logic       at_video_hb_out_q;
    logic       at_video_vs_out_q;
    logic       at_video_vb_out_q;
    logic       at_video_de_out_q;
    logic       at_video_ce_out_q;

    always_ff @(posedge at_video_clk_57) begin
        if (at_video_pipe_reset_57) begin
            at_video_dot_d_q  <= 1'b0;
            at_video_dot_dd_q <= 1'b0;
            at_video_r_pipe_q <= 8'h00;
            at_video_g_pipe_q <= 8'h00;
            at_video_b_pipe_q <= 8'h00;
            at_video_hs_pipe_q <= 1'b1;
            at_video_hb_pipe_q <= 1'b1;
            at_video_vs_pipe_q <= 1'b1;
            at_video_vb_pipe_q <= 1'b1;
            at_video_de_pipe_q <= 1'b0;
            at_video_ce_pipe_q <= 1'b0;
        end else begin
            at_video_dot_d_q  <= at_video_dot_toggle_raw;
            at_video_dot_dd_q <= at_video_dot_d_q;
            at_video_r_pipe_q <= {at_video_red_raw, 2'b00};
            at_video_g_pipe_q <= {at_video_green_raw, 2'b00};
            at_video_b_pipe_q <= {at_video_blue_raw, 2'b00};
            at_video_hs_pipe_q <= at_video_hsync_raw;
            at_video_hb_pipe_q <= at_video_hblank_raw;
            at_video_vs_pipe_q <= at_video_vsync_raw;
            at_video_vb_pipe_q <= at_video_vblank_raw;
            at_video_de_pipe_q <= at_video_de_raw;
            at_video_ce_pipe_q <= at_video_dot_d_q ^ at_video_dot_dd_q;
        end
    end

    always_ff @(posedge at_video_clk_57_ps) begin
        if (at_video_pipe_reset_57_ps) begin
            at_video_r_out_q <= 8'h00;
            at_video_g_out_q <= 8'h00;
            at_video_b_out_q <= 8'h00;
            at_video_hs_out_q <= 1'b0;
            at_video_hb_out_q <= 1'b1;
            at_video_vs_out_q <= 1'b0;
            at_video_vb_out_q <= 1'b1;
            at_video_de_out_q <= 1'b0;
            at_video_ce_out_q <= 1'b0;
        end else begin
            at_video_r_out_q <= at_video_r_pipe_q;
            at_video_g_out_q <= at_video_g_pipe_q;
            at_video_b_out_q <= at_video_b_pipe_q;
            at_video_hs_out_q <= at_video_hs_pipe_q;
            at_video_hb_out_q <= at_video_hb_pipe_q;
            at_video_vs_out_q <= at_video_vs_pipe_q;
            at_video_vb_out_q <= at_video_vb_pipe_q;
            at_video_de_out_q <= at_video_de_pipe_q;
            at_video_ce_out_q <= at_video_ce_pipe_q;
        end
    end

    wire        at_debug_hb_out;
    wire        at_debug_vb_out;
    wire [23:0] at_debug_rgb_out;

`ifndef SPK286_AT_NO_DEBUG
    // The overlay is intentionally limited to live CPU, register, bus and
    // rolling transaction views. It is passive and never drives the machine.
    spk286_debug_overlay #(
        .COLW   (8),
        .AT_MODE(1'b1)
    ) u_at_debug_overlay (
        .rst                     (at_video_pipe_reset_57_ps),
        // The source observer must remain alive during the CPU reset so it can
        // publish the real RST=1 state instead of leaving a stale snapshot.
        .src_rst                 (at_boot_reset),
        .src_clk                 (CLK_50M),
        .clk                     (at_video_clk_57_ps),
        .pxl_cen                 (at_video_ce_out_q),
        .HS                      (at_video_hs_out_q),
        .VS                      (at_video_vs_out_q),
        .HB                      (at_video_hb_out_q),
        .VB                      (at_video_vb_out_q),
        .rgb_in                  ({at_video_r_out_q,
                                   at_video_g_out_q,
                                   at_video_b_out_q}),
        .page                    (at_debug_page),
        .cpu_reset               (at_machine_reset | at_cpu_reset_request),
        .cpu_halted              (at_cpu_halted),
        .cpu_shutdown            (at_cpu_shutdown),
        .cpu_control_error       (at_debug_control_error),
        .cpu_unsupported_opcode  (at_debug_unsupported_opcode),
        .cpu_microcode_fault     (at_debug_microcode_fault),
        .cpu_operand_blocked     (at_debug_operand_blocked),
        .cpu_event_completed     (at_debug_event_completed),
        .cpu_event_vector        (at_debug_event_vector),
        .cpu_event_kind          (at_debug_event_kind),
        .cpu_opcode              (at_debug_opcode),
        .cpu_cs                  (at_debug_cs),
        .cpu_cs_base             (at_debug_cs_base),
        .cpu_ip                  (at_debug_ip),
        .cpu_flags               (at_debug_flags),
        .cpu_gpr                 (at_debug_gpr),
        .cpu_segments            (at_debug_segment_selectors),
        .cpu_fetch_blocked       (at_debug_fetch_blocked),
        .cpu_fetch_cursor        (at_debug_fetch_cursor),
        .cpu_micro_pc            (at_debug_micro_pc),
        .cpu_micro_entry         (at_debug_micro_entry),
        .cpu_micro_instruction   (at_debug_micro_instruction),
        .cpu_micro_active        (at_debug_micro_active),
        .cpu_prefetch_count      (at_debug_prefetch_count),
        .cpu_biu_state           (at_debug_bus_state),
        .cpu_address             (at_cpu_address),
        .cpu_data_out            (at_cpu_data_out),
        .cpu_data_in             (at_cpu_data_in),
        .cpu_bus_status          (at_cpu_bus_status),
        .cpu_bus_valid           (at_cpu_bus_valid),
        .cpu_bus_write           (at_cpu_bus_write),
        .cpu_bhe_n               (at_cpu_bus_bhe_n),
        .cpu_bus_lock            (at_cpu_bus_lock),
        .cpu_hlda                (at_cpu_hlda),
        .cpu_ready               (at_cpu_ready),
        .xt_address              (at_debug_address),
        .xt_data_out             (at_debug_data_out),
        .xt_data_in              (at_debug_data_in),
        .xt_status               (at_debug_status),
        .xt_valid                (at_debug_valid),
        .xt_write                (at_debug_write),
        .xt_io                   (at_debug_io),
        .xt_inta                 (at_debug_inta),
        .xt_code                 (at_debug_code),
        .xt_byte_high            (at_debug_byte_high),
        .xt_memory_projection    (at_debug_memory_projection),
        .xt_cycle_active         (at_debug_cycle_active),
        .xt_ready                (at_debug_ready),
        .bridge_idle             (at_debug_bridge_idle),
        .bridge_error            (at_debug_bridge_error | keyboard_event_overflow),
        .hold_request            (at_debug_hold_request),
        .biu_detail              (at_debug_biu_detail),
        .last_post               (at_debug_last_post),
        .cpu_cycle_count         (at_debug_cpu_cycle_count),
        .xt_cycle_count          (at_debug_at_cycle_count),
        .trace0                  (at_debug_trace0),
        .trace1                  (at_debug_trace1),
        .trace2                  (at_debug_trace2),
        .trace3                  (at_debug_trace3),
        .keyboard_keycode        (at_debug_keyboard_keycode),
        .keyboard_irq            (at_debug_keyboard_irq),
        .keyboard_port_b         (at_debug_keyboard_port_b),
        .keyboard_pic_int        (at_debug_keyboard_pic_int),
        .dma_request             (at_debug_dma_request),
        .dma_acknowledge_n       (at_debug_dma_acknowledge_n),
        .HB_out                  (at_debug_hb_out),
        .VB_out                  (at_debug_vb_out),
        .rgb_out                 (at_debug_rgb_out)
    );
`endif

`ifndef SPK286_AT_NO_DEBUG
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic at_debug_enable_sync1_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic at_debug_enable_sync2_q;
    always_ff @(posedge at_video_clk_57_ps) begin
        if (at_video_pipe_reset_57_ps) begin
            at_debug_enable_sync1_q <= 1'b0;
            at_debug_enable_sync2_q <= 1'b0;
        end else begin
            at_debug_enable_sync1_q <= at_debug_enable;
            at_debug_enable_sync2_q <= at_debug_enable_sync1_q;
        end
    end

    logic at_use_debug_q;
    always_ff @(posedge at_video_clk_57_ps) begin
        if (at_video_pipe_reset_57_ps)
            at_use_debug_q <= 1'b0;
        else if (at_video_vb_out_q)
            at_use_debug_q <= at_debug_enable_sync2_q;
    end
`else
    logic at_use_debug_q;
    assign at_use_debug_q = 1'b0;
    assign at_debug_hb_out = 1'b0;
    assign at_debug_vb_out = 1'b0;
    assign at_debug_rgb_out = 24'h000000;
`endif

    wire at_video_fault = cpu_fault | machine_protocol_error | keyboard_event_overflow |
                          memory_port_protocol_error |
                          sdram_owner_protocol_error |
                          loader_protocol_error;

    assign CLK_VIDEO    = at_video_clk_57_ps;
    assign CE_PIXEL     = at_video_ce_out_q;
    assign VIDEO_ARX    = 13'd4;
    assign VIDEO_ARY    = 13'd3;
    assign VGA_R        = at_use_debug_q ? at_debug_rgb_out[23:16] :
                          at_video_r_out_q;
    assign VGA_G        = at_use_debug_q ? at_debug_rgb_out[15:8] :
                          at_video_g_out_q;
    assign VGA_B        = at_use_debug_q ? at_debug_rgb_out[7:0] :
                          at_video_b_out_q;
    assign VGA_HS       = at_video_hs_out_q;
    assign VGA_VS       = at_video_vs_out_q;
    assign VGA_DE       = at_use_debug_q ?
                          (~at_debug_hb_out & ~at_debug_vb_out) :
                          at_video_de_out_q;
    assign VGA_F1       = 1'b0;
    assign VGA_SL       = 2'b00;
    assign VGA_SCALER   = 1'b0;
    assign VGA_DISABLE  = 1'b0;
    assign HDMI_FREEZE  = 1'b0;
    assign HDMI_BLACKOUT = 1'b0;
    assign HDMI_BOB_DEINT = 1'b0;
    assign LED_USER     = cpu_fault | machine_protocol_error | keyboard_event_overflow |
                          memory_port_protocol_error |
                          sdram_owner_protocol_error |
                          loader_protocol_error;
    assign LED_POWER    = 2'b00;
    assign LED_DISK     = {1'b0, main_rom_loaded};
    assign BUTTONS      = hps_buttons;
    // Minimal PC speaker PCM.  The AT machine supplies a square-wave logic
    // level from PIT channel 2; present it as a centered signed sample and
    // leave the output at digital silence while the speaker is gated off.
    assign AUDIO_L      = !at_speaker_active ? 16'h0000 :
                          at_speaker_level ? 16'h4000 : 16'hC000;
    assign AUDIO_R      = !at_speaker_active ? 16'h0000 :
                          at_speaker_level ? 16'h4000 : 16'hC000;
    assign AUDIO_S      = 1'b1;
    assign AUDIO_MIX    = 2'b00;
    assign ADC_BUS      = 4'hz;
    assign SD_SCK       = 1'bz;
    assign SD_MOSI      = 1'bz;
    assign SD_CS        = 1'bz;
    assign DDRAM_CLK    = CLK_50M;
    assign DDRAM_ADDR   = 29'h0;
    assign DDRAM_BURSTCNT = 8'h0;
    assign DDRAM_RD     = 1'b0;
    assign DDRAM_DIN    = 64'h0;
    assign DDRAM_BE     = 8'h0;
    assign DDRAM_WE     = 1'b0;
    assign UART_RTS     = 1'b0;
    assign UART_TXD     = 1'b1;
    assign UART_DTR     = 1'b0;
    assign USER_OUT     = 7'h00;

endmodule
