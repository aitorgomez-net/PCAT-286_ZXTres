// SPI-mode SDHC card model for simulation, enough for the DeMiSTify
// firmware: CMD0, CMD8, CMD55/ACMD41, CMD58, CMD9, CMD16, CMD17 (block
// addressing). The image is read from IMAGE (sparse form) at time zero.
// Writes (CMD24) are acknowledged and stored.
`timescale 1ns/1ps
module sd_card_model #(
    parameter string IMAGE = "sd.img.sparse",
    parameter int unsigned BLOCKS = 16384
) (
    input  logic sclk,
    input  logic cs_n,
    input  logic mosi,
    output logic miso
);
    // Sparse memory: IMAGE lists "address value" pairs in hex for the
    // non-zero bytes (make_fat16_image.py writes IMAGE.sparse). Unlisted
    // bytes read as zero.
    logic [7:0] memory [int unsigned];
    initial begin
        int fd, count;
        int unsigned address, value;
        fd = $fopen(IMAGE, "r");
        if (fd == 0) $fatal(1, "sd_card_model: cannot open %s", IMAGE);
        count = 0;
        while ($fscanf(fd, "%h %h", address, value) == 2) begin
            memory[address] = value[7:0];
            count++;
        end
        $fclose(fd);
        $display("sd_card_model: %0d non-zero bytes from %s", count, IMAGE);
    end
    function automatic logic [7:0] read_byte(input int unsigned address);
        return memory.exists(address) ? memory[address] : 8'h00;
    endfunction

    // Bytes in from the host (mode 0: sample on the rising edge).
    logic [7:0] shift_in = 8'hFF;
    logic [2:0] bit_in = 3'd0;
    logic [7:0] out_queue [$];
    logic [7:0] shift_out = 8'hFF;
    logic [7:0] command [0:5];
    int         command_bytes = 0;
    bit         app_command = 0;
    // Pending write: CMD24 accepted, waiting for the data token and block.
    bit         write_pending = 0;
    int         write_count = -1;
    int unsigned write_address;

    assign miso = cs_n ? 1'b1 : shift_out[7];

    task automatic respond(input logic [7:0] b);
        out_queue.push_back(b);
    endtask

    task automatic handle_command();
        logic [5:0] index;
        logic [31:0] argument;
        index = command[0][5:0];
        argument = {command[1], command[2], command[3], command[4]};
        respond(8'hFF);                                  // NCR
        if (app_command && index == 6'd41) begin
            respond(8'h00);
        end else begin
            case (index)
                6'd0:  respond(8'h01);
                6'd8:  begin respond(8'h01); respond(8'h00); respond(8'h00);
                             respond(8'h01); respond(argument[7:0]); end
                6'd55: respond(8'h01);
                6'd58: begin respond(8'h00); respond(8'hC0); respond(8'hFF);
                             respond(8'h80); respond(8'h00); end
                6'd16: respond(8'h00);
                6'd9:  begin                             // CSD v2: C_SIZE = BLOCKS/1024 - 1
                    logic [21:0] c_size;
                    c_size = 22'(BLOCKS / 1024 - 1);
                    respond(8'h00); respond(8'hFF); respond(8'hFE);
                    respond(8'h40); respond(8'h0E); respond(8'h00); respond(8'h32);
                    respond(8'h5B); respond(8'h59); respond(8'h00);
                    respond({2'b00, c_size[21:16]}); respond(c_size[15:8]); respond(c_size[7:0]);
                    respond(8'h7F); respond(8'h80); respond(8'h0A); respond(8'h40);
                    respond(8'h00); respond(8'h01);
                    respond(8'hFF); respond(8'hFF);
                end
                6'd17: begin
                    int unsigned base;
                    base = argument * 512;
                    respond(8'h00); respond(8'hFF); respond(8'hFE);
                    for (int i = 0; i < 512; i++)
                        respond(read_byte(base + i));
                    respond(8'hFF); respond(8'hFF);
                end
                6'd24: begin
                    respond(8'h00);
                    write_pending = 1;
                    write_count = -1;
                    write_address = argument * 512;
                end
                default: respond(8'h04);                 // illegal command
            endcase
        end
        app_command = (index == 6'd55);
    endtask

    always @(posedge sclk or posedge cs_n) begin
        if (cs_n) begin
            bit_in <= 3'd0;
            command_bytes = 0;
        end else begin
            logic [7:0] b;
            b = {shift_in[6:0], mosi};
            shift_in <= b;
            bit_in <= bit_in + 3'd1;
            if (bit_in == 3'd7) begin
                if (write_pending) begin
                    if (write_count < 0) begin
                        if (b == 8'hFE) write_count = 0;
                    end else if (write_count < 512) begin
                        memory[write_address + write_count] = b;
                        write_count++;
                    end else if (write_count < 514) begin
                        write_count++;
                        if (write_count == 514) begin
                            respond(8'h05);              // data accepted
                            respond(8'hFF);
                            write_pending = 0;
                        end
                    end
                end else if (command_bytes == 0) begin
                    if (b[7:6] == 2'b01) begin
                        command[0] = b;
                        command_bytes = 1;
                    end
                end else begin
                    command[command_bytes] = b;
                    command_bytes++;
                    if (command_bytes == 6) begin
                        command_bytes = 0;
                        handle_command();
                    end
                end
            end
        end
    end

    // Bytes out (mode 0: change on the falling edge). A new byte starts on
    // the falling edge after the eighth rising edge of the previous one, so
    // responses stay byte-aligned with the host.
    always @(negedge sclk or posedge cs_n) begin
        if (cs_n) begin
            shift_out <= 8'hFF;
        end else if (bit_in == 3'd0) begin
            shift_out <= (out_queue.size() != 0) ? out_queue.pop_front() : 8'hFF;
        end else begin
            shift_out <= {shift_out[6:0], 1'b1};
        end
    end
endmodule
