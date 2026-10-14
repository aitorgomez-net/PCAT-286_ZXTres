`timescale 1ns/1ps

// spk286_at_mister_ddram_owner through ega_ddr_arbiter against an Avalon
// DDRAM model: 50 MHz AT side, 57.27 MHz DDRAM side, random waitrequest and
// read latency, competing framebuffer read bursts, and machine resets that
// land while a request is in flight. Every AT read is checked against a
// byte-level reference; four-word line fills must return their beats in
// order with ready on the last one. Runs of back-to-back writes fill the
// request queue, and at the end DDR3 itself must hold every write, not just
// the owner's cache.
//
// AT addresses are drawn from two 1 MiB windows, the bottom and the top of
// the 32 MiB AT space, so the reference and the DDRAM model stay small.

module spk286_at_mister_ddram_owner_tb;
    localparam logic [28:0] BASE = 29'h6200000;
    localparam integer OPS = 6000;
    localparam logic [21:0] TOP_WORD = 22'h3E0000;   // AT 1F00000h >> 3

    logic clk = 1'b0;
    logic ddr_clk = 1'b0;
    always #10 clk = ~clk;           // 50 MHz
    always #8.73 ddr_clk = ~ddr_clk; // 57.27 MHz
    logic reset = 1'b1;
    logic ddr_reset = 1'b1;

    logic        request_valid = 1'b0;
    logic        request_command_valid = 1'b0;
    logic        request_owner_refresh = 1'b0;
    logic        request_write = 1'b0;
    logic        request_burst = 1'b0;
    logic [24:0] request_address = '0;
    logic [1:0]  request_byte_enable = 2'b00;
    logic [15:0] request_data_out = '0;
    wire         request_accept, request_ready, request_read_data_valid;
    wire [15:0]  request_read_data;
    wire         physical_idle, protocol_error;
    wire [7:0]   debug_state;

    wire        at_req, at_write, at_done, at_rvalid;
    wire [28:0] at_addr;
    wire [7:0]  at_be, at_burstcnt;
    wire [63:0] at_din, at_rdata;

    spk286_at_mister_ddram_owner #(.DDRAM_BASE(BASE)) dut (
        .clk(clk), .reset(reset),
        .request_valid(request_valid), .request_command_valid(request_command_valid),
        .request_owner_refresh(request_owner_refresh), .request_write(request_write),
        .request_code_fetch(1'b0), .request_burst(request_burst),
        .request_cycle_class(4'h5), .request_address(request_address),
        .request_byte_enable(request_byte_enable), .request_data_out(request_data_out),
        .request_accept(request_accept), .request_ready(request_ready),
        .request_read_data(request_read_data),
        .request_read_data_valid(request_read_data_valid),
        .physical_idle(physical_idle), .debug_state(debug_state),
        .protocol_error(protocol_error),
        .ddr_clk(ddr_clk), .ddr_req(at_req), .ddr_write(at_write), .ddr_addr(at_addr),
        .ddr_be(at_be), .ddr_din(at_din), .ddr_burstcnt(at_burstcnt),
        .ddr_rvalid(at_rvalid), .ddr_rdata(at_rdata), .ddr_done(at_done)
    );

    // Framebuffer read client: random bursts outside the AT window.
    logic        fb_rd_req = 1'b0;
    logic [28:0] fb_rd_addr = 29'h6000000;
    logic [7:0]  fb_rd_burstcnt = 8'd8;
    wire         fb_rd_grant, fb_rd_data_valid;
    wire [63:0]  fb_rd_data;

    wire        ddram_busy;
    wire [7:0]  ddram_burstcnt;
    wire [28:0] ddram_addr;
    wire [63:0] ddram_din, ddram_dout;
    wire [7:0]  ddram_be;
    wire        ddram_we, ddram_rd, ddram_dout_ready;

    ega_ddr_arbiter arbiter (
        .clk(ddr_clk), .reset(ddr_reset),
        .ddram_busy(ddram_busy), .ddram_burstcnt(ddram_burstcnt), .ddram_addr(ddram_addr),
        .ddram_din(ddram_din), .ddram_be(ddram_be), .ddram_we(ddram_we), .ddram_rd(ddram_rd),
        .ddram_dout(ddram_dout), .ddram_dout_ready(ddram_dout_ready),
        .rd_req(fb_rd_req), .rd_addr(fb_rd_addr), .rd_burstcnt(fb_rd_burstcnt),
        .rd_grant(fb_rd_grant), .rd_data(fb_rd_data), .rd_data_valid(fb_rd_data_valid),
        .wr_req(1'b0), .wr_addr(29'd0), .wr_burstcnt(8'd0), .wr_din(64'd0),
        .wr_busy_out(), .wr_grant(),
        .at_req(at_req), .at_write(at_write), .at_addr(at_addr), .at_be(at_be),
        .at_din(at_din), .at_burstcnt(at_burstcnt), .at_done(at_done),
        .at_rvalid(at_rvalid), .at_rdata(at_rdata)
    );

    // ------------------------------------------------------------------
    // Avalon DDRAM model: random waitrequest, in-order reads after a random
    // latency, byte-enabled writes. Unwritten words read as a function of the
    // address so stale data cannot match by accident.
    // ------------------------------------------------------------------
    function automatic logic [63:0] fresh_word(input logic [28:0] a);
        fresh_word = {a, 3'b101, a, 3'b011};
    endfunction

    // DDRAM words of the two AT test windows: index = {top, word[16:0]}.
    logic [63:0] ddr_mem   [0:262143];
    logic        ddr_valid [0:262143];
    function automatic integer ddr_index(input logic [28:0] a);
        logic [28:0] rel;
        rel = a - BASE;
        if (rel < 29'h20000) ddr_index = rel;
        else if (rel >= {7'd0, TOP_WORD} && rel < {7'd0, TOP_WORD} + 29'h20000)
            ddr_index = 32'h20000 + (rel - {7'd0, TOP_WORD});
        else ddr_index = -1;
    endfunction
    function automatic logic [63:0] ddr_word(input logic [28:0] a);
        integer i;
        i = ddr_index(a);
        ddr_word = (i >= 0 && ddr_valid[i]) ? ddr_mem[i] : fresh_word(a);
    endfunction

    logic busy_q = 1'b1;
    assign ddram_busy = busy_q;
    // In-order read command queue.
    logic [28:0] rq_addr  [0:15];
    integer      rq_beats [0:15];
    integer      rq_delay [0:15];
    integer      rq_head = 0, rq_count = 0;
    logic        dout_ready_q = 1'b0;
    logic [63:0] dout_q = '0;
    assign ddram_dout_ready = dout_ready_q;
    assign ddram_dout = dout_q;
    integer write_beat = 0;
    integer fb_reads = 0, fb_beats_expected = 0, fb_beats_seen = 0;
    // Occasional long waitrequest, as when other HPS masters or DDR3 refresh
    // hold the port: stores keep arriving and queue up behind it.
    integer busy_hold = 0;

    always @(posedge ddr_clk) begin : ddram_model
        integer slot, i, b;
        logic [28:0] a;
        logic [63:0] word;
        if (busy_hold == 0 && ($urandom % 400) == 0) busy_hold = 30 + ($urandom % 300);
        if (busy_hold != 0) busy_hold = busy_hold - 1;
        busy_q <= (busy_hold != 0) || (($urandom % 4) == 0);
        dout_ready_q <= 1'b0;
        if (ddram_rd && !ddram_busy) begin
            if (rq_count == 16) $fatal(1, "DDRAM model read queue overflow");
            slot = (rq_head + rq_count) % 16;
            rq_addr[slot]  = ddram_addr;
            rq_beats[slot] = ddram_burstcnt;
            rq_delay[slot] = 3 + ($urandom % 25);
            rq_count = rq_count + 1;
        end
        if (ddram_we && !ddram_busy) begin
            a = ddram_addr + write_beat;
            i = ddr_index(a);
            if (i < 0) $fatal(1, "DDRAM write outside the AT test windows: %h", a);
            word = ddr_word(a);
            for (b = 0; b < 8; b = b + 1)
                if (ddram_be[b]) word[8*b +: 8] = ddram_din[8*b +: 8];
            ddr_mem[i] = word;
            ddr_valid[i] = 1'b1;
            write_beat = (write_beat + 1 == ddram_burstcnt) ? 0 : write_beat + 1;
        end
        if (rq_count != 0) begin
            if (rq_delay[rq_head] != 0)
                rq_delay[rq_head] = rq_delay[rq_head] - 1;
            else begin
                dout_ready_q <= 1'b1;
                dout_q <= ddr_word(rq_addr[rq_head]);
                rq_addr[rq_head] = rq_addr[rq_head] + 1;
                rq_beats[rq_head] = rq_beats[rq_head] - 1;
                if (rq_beats[rq_head] == 0) begin
                    rq_head = (rq_head + 1) % 16;
                    rq_count = rq_count - 1;
                end
            end
        end
    end

    // The arbiter's reset is the video pipeline reset (OSD reset, reset
    // button, video PLL lock). It is held for long stretches while the AT
    // machine keeps using its RAM, e.g. while MiSTer loads the BIOS.
    integer video_reset_left = 0, video_resets = 0;
    always @(posedge ddr_clk) begin
        if (video_reset_left != 0) begin
            video_reset_left = video_reset_left - 1;
            if (video_reset_left == 0) ddr_reset <= 1'b0;
        end else if (!ddr_reset && ($urandom % 3000) == 0) begin
            ddr_reset <= 1'b1;
            video_reset_left = 200 + ($urandom % 30000);
            video_resets = video_resets + 1;
        end
    end

    // Framebuffer reader: issues a burst, waits for all beats, pauses.
    integer fb_gap = 0;
    always @(posedge ddr_clk) begin
        if (fb_rd_grant) begin
            fb_rd_req <= 1'b0;
            fb_reads = fb_reads + 1;
            fb_beats_expected = fb_beats_expected + fb_rd_burstcnt;
        end
        if (fb_rd_data_valid) fb_beats_seen = fb_beats_seen + 1;
        if (!fb_rd_req && !fb_rd_grant && !ddr_reset && fb_beats_seen == fb_beats_expected) begin
            if (fb_gap != 0) fb_gap = fb_gap - 1;
            else begin
                fb_gap = 20 + ($urandom % 200);
                fb_rd_addr     <= 29'h6000000 + ($urandom % 29'h40000);
                fb_rd_burstcnt <= 8'd1 + ($urandom % 32);
                fb_rd_req      <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // AT-side reference: bytes of the two windows, index = {top, a[19:0]}.
    // ------------------------------------------------------------------
    logic [7:0] ref_mem   [0:2097151];
    logic       ref_valid [0:2097151];
    logic       unknown   [0:2097151];
    function automatic integer ref_index(input logic [24:0] a);
        ref_index = {(a[24:20] == 5'h1F), a[19:0]};
    endfunction
    function automatic logic [15:0] ref_word(input logic [24:0] a);
        logic [63:0] w;
        logic [24:0] ba;
        integer b;
        w = fresh_word(BASE + {7'd0, a[24:3]});
        for (b = 0; b < 2; b = b + 1) begin
            ba = {a[24:1], 1'b0} + b;
            ref_word[8*b +: 8] = ref_valid[ref_index(ba)] ? ref_mem[ref_index(ba)]
                                                          : w[8*ba[2:0] +: 8];
        end
    endfunction

    integer reads = 0, bursts = 0, writes = 0, refreshes = 0, resets = 0, errors = 0;
    integer busy_cycles = 0;

    task automatic issue(input logic write, input logic burst, input logic refresh,
                         input logic [24:0] address, input logic [1:0] lanes,
                         input logic [15:0] data, input bit allow_reset);
        integer beat, wait_cycles, b;
        bit done, do_reset;
        logic [24:0] a, ba;
        logic [15:0] expected;
        do_reset = allow_reset && (($urandom % 40) == 0);
        @(negedge clk);
        request_valid = 1'b1; request_command_valid = 1'b1;
        request_owner_refresh = refresh; request_write = write; request_burst = burst;
        request_address = address; request_byte_enable = lanes; request_data_out = data;
        // Let request_accept settle before sampling it; it is taken on the
        // next rising edge, and the request is withdrawn after that edge.
        #1;
        while (!request_accept) begin @(negedge clk); #1; end
        @(negedge clk);
        request_valid = 1'b0; request_command_valid = 1'b0;
        if (do_reset) begin
            // Reset lands while the access may be in flight: the response is
            // lost to the CPU and a write may or may not have landed.
            repeat ($urandom % 6) @(negedge clk);
            reset = 1'b1;
            @(negedge clk);
            reset = 1'b0;
            resets = resets + 1;
            if (write)
                for (b = 0; b < 2; b = b + 1)
                    if (lanes[b]) unknown[ref_index({address[24:1], 1'b0} + b)] = 1'b1;
        end else begin
            beat = 0;
            wait_cycles = 0;
            done = 0;
            while (!done) begin
                if (request_read_data_valid) begin
                    a = burst ? {address[24:3], beat[1:0], 1'b0} : address;
                    expected = ref_word(a);
                    for (b = 0; b < 2; b = b + 1) begin
                        ba = {a[24:1], 1'b0} + b;
                        if (unknown[ref_index(ba)]) expected[8*b +: 8] = request_read_data[8*b +: 8];
                    end
                    if (request_read_data !== expected) begin
                        $display("FAIL read %h beat %0d: got %h expected %h", a, beat,
                                 request_read_data, expected);
                        errors = errors + 1;
                    end
                    beat = beat + 1;
                end
                if (request_ready) done = 1;
                else begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                    // A DDRAM access, even behind a framebuffer burst, takes far
                    // less; a video reset must never hold the AT bus.
                    if (wait_cycles > 1500) $fatal(1, "AT access to %h stalled %0d cycles (video reset %b)",
                                                   address, wait_cycles, ddr_reset);
                end
            end
            busy_cycles = busy_cycles + wait_cycles;
            if (write)
                for (b = 0; b < 2; b = b + 1)
                    if (lanes[b]) begin
                        ba = {address[24:1], 1'b0} + b;
                        ref_mem[ref_index(ba)] = data[8*b +: 8];
                        ref_valid[ref_index(ba)] = 1'b1;
                        unknown[ref_index(ba)] = 1'b0;
                    end
            if (!write && !refresh && beat != (burst ? 4 : 1)) begin
                $display("FAIL %s at %h returned %0d beats", burst ? "line" : "read", address, beat);
                errors = errors + 1;
            end
            if (refresh) refreshes = refreshes + 1;
            else if (write) writes = writes + 1;
            else if (burst) bursts = bursts + 1;
            else reads = reads + 1;
        end
    endtask

    integer n, kind, k, storm, ddr_checked;
    logic [24:0] a;
    logic [63:0] w;
    initial begin
        for (k = 0; k < 262144; k = k + 1) ddr_valid[k] = 1'b0;
        for (k = 0; k < 2097152; k = k + 1) begin ref_valid[k] = 1'b0; unknown[k] = 1'b0; end
        repeat (5) @(posedge clk);
        reset = 1'b0;
        ddr_reset = 1'b0;
        storm = 0;
        for (n = 0; n < OPS; n = n + 1) begin
            // Mostly a 16 KiB hot spot so reads meet earlier partial writes;
            // the bottom and top windows share cache sets, so they evict
            // each other.
            a = {5'd0, 6'd0, 14'($urandom)};
            if (($urandom % 8) == 0) a = {5'd0, 20'($urandom)};
            if (($urandom % 8) == 0) a = {5'h1F, 20'($urandom)};
            // Occasionally a run of stores, as from REP STOSW, that outruns
            // DDR3 and fills the request queue.
            if (storm == 0 && ($urandom % 200) == 0) storm = 20 + ($urandom % 40);
            kind = (storm != 0) ? 0 : $urandom % 16;
            if (storm != 0) storm = storm - 1;
            if (kind < 6)
                issue(1'b1, 1'b0, 1'b0, {a[24:1], 1'b0},
                      (($urandom % 3) == 0) ? 2'b11 : 2'(1 + ($urandom % 3)), 16'($urandom), 1'b1);
            else if (kind < 11)
                issue(1'b0, 1'b0, 1'b0, {a[24:1], 1'b0}, 2'b11, 16'h0, 1'b1);
            else if (kind < 15)
                issue(1'b0, 1'b1, 1'b0, {a[24:3], 3'b000}, 2'b11, 16'h0, 1'b1);
            else
                issue(1'b0, 1'b0, 1'b1, a, 2'b11, 16'h0, 1'b0);
        end
        // Any request cut by a reset, and every queued write, must drain.
        repeat (2000) @(posedge clk);
        if (!physical_idle) begin $display("FAIL owner not idle at the end"); errors = errors + 1; end
        if (protocol_error) begin $display("FAIL protocol_error"); errors = errors + 1; end
        if (fb_beats_seen != fb_beats_expected) begin
            $display("FAIL framebuffer beats %0d/%0d", fb_beats_seen, fb_beats_expected);
            errors = errors + 1;
        end
        // Reads may have been answered from the cache: DDR3 itself must hold
        // every write whose outcome is known.
        ddr_checked = 0;
        for (k = 0; k < 2097152; k = k + 1)
            if (ref_valid[k] && !unknown[k]) begin
                a = {(k >= 1048576) ? 5'h1F : 5'h00, 20'(k)};
                w = ddr_word(BASE + {7'd0, a[24:3]});
                if (w[8*a[2:0] +: 8] !== ref_mem[k]) begin
                    if (errors < 20)
                        $display("FAIL DDR3 byte %h holds %h, expected %h", a,
                                 w[8*a[2:0] +: 8], ref_mem[k]);
                    errors = errors + 1;
                end
                ddr_checked = ddr_checked + 1;
            end
        if (dut.debug_hits == 0 || dut.debug_misses == 0 || dut.debug_write_hits == 0 ||
            dut.debug_queue_stalls == 0 || dut.debug_discarded_beats == 0) begin
            $display("FAIL cache paths not exercised: hits=%0d misses=%0d write_hits=%0d queue_stalls=%0d discarded_beats=%0d",
                     dut.debug_hits, dut.debug_misses, dut.debug_write_hits,
                     dut.debug_queue_stalls, dut.debug_discarded_beats);
            errors = errors + 1;
        end
        if (errors != 0) $fatal(1, "AT_MISTER_DDRAM_OWNER_TEST_FAIL errors=%0d", errors);
        $display("AT_MISTER_DDRAM_OWNER_TB_PASS reads=%0d lines=%0d writes=%0d refresh=%0d resets=%0d video_resets=%0d fb_bursts=%0d avg_wait=%0d",
                 reads, bursts, writes, refreshes, resets, video_resets, fb_reads,
                 busy_cycles / (reads + bursts + writes + refreshes));
        $display("AT_MISTER_DDRAM_OWNER_CACHE read_hits=%0d read_misses=%0d writes=%0d write_hits=%0d queue_stalls=%0d discarded_beats=%0d ddr3_bytes_checked=%0d",
                 dut.debug_hits, dut.debug_misses, dut.debug_writes, dut.debug_write_hits,
                 dut.debug_queue_stalls, dut.debug_discarded_beats, ddr_checked);
        $finish;
    end
endmodule
