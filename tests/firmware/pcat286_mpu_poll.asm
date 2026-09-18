; MPU-401 polling diagnostic for the real 80286/AT boundary.
; This follows the path used by many DOS drivers: command ACKs are obtained
; through the status port, and every UART byte waits for TX-ready before it is
; written.  No MPU interrupt is enabled in this test.
bits 16
org 0

start:
    cli
    xor ax, ax
    mov ds, ax

    mov ax, 0x1000
    mov ds, ax
    mov ss, ax
    mov sp, 0xff00

    ; AT 8259A pair: keep IRQ0/cascade alive for the machine boundary check,
    ; but leave the MPU's slave IRQ9 masked because this is the polling path.
    mov dx, 0x0020
    mov al, 0x11
    out dx, al
    mov dx, 0x00a0
    out dx, al
    mov dx, 0x0021
    mov al, 0x08
    out dx, al
    mov dx, 0x00a1
    mov al, 0x70
    out dx, al
    mov dx, 0x0021
    mov al, 0x04
    out dx, al
    mov dx, 0x00a1
    mov al, 0x02
    out dx, al
    mov dx, 0x0021
    mov al, 0x01
    out dx, al
    mov dx, 0x00a1
    out dx, al
    mov dx, 0x0021
    mov al, 0xb8                  ; unmask IRQ0 and cascade IRQ2
    out dx, al
    mov dx, 0x00a1
    mov al, 0xff                  ; keep IRQ9 masked for polling
    out dx, al

    ; PIT channel 0, mode 2, divisor 0020h: supplies a wake-up IRQ0 request.
    mov dx, 0x0043
    mov al, 0x34
    out dx, al
    mov dx, 0x0040
    mov al, 0x20
    out dx, al
    xor al, al
    out dx, al

    mov dx, 0x0080
    mov al, 0x70
    out dx, al

    ; With an idle MIDI input, the first status read must report no pending
    ; input and a ready transmitter: 80h, as on the XT/ao486 implementations.
    mov dx, 0x0331
    in al, dx
    cmp al, 0x80
    jne fail_idle_status

    ; Reset and poll the FE acknowledgement through status bit 7.
    mov al, 0xff
    out dx, al
wait_reset_ack:
    in al, dx
    test al, 0x80
    jnz wait_reset_ack
    mov dx, 0x0330
    in al, dx
    cmp al, 0xfe
    jne fail_ack
    mov dx, 0x0080
    mov al, 0x72
    out dx, al

    ; Enter UART mode and poll the second FE acknowledgement the same way.
    mov dx, 0x0331
    mov al, 0x3f
    out dx, al
wait_uart_ack:
    in al, dx
    test al, 0x80
    jnz wait_uart_ack
    mov dx, 0x0330
    in al, dx
    cmp al, 0xfe
    jne fail_ack
    mov dx, 0x0080
    mov al, 0x71
    out dx, al

    ; A representative note message followed by a longer stream.  Bit 6 of
    ; the status port is TX-full; wait until it clears before each byte.
    mov dx, 0x0330
    mov al, 0x90
    call send_midi_byte
    mov al, 0x3c
    call send_midi_byte
    mov al, 0x7f
    call send_midi_byte
    mov al, 0x80
    call send_midi_byte
    mov al, 0x3c
    call send_midi_byte
    xor al, al
    call send_midi_byte

    mov cx, 0x0100
    mov al, 0x40
stream_bytes:
    call send_midi_byte
    inc al
    loop stream_bytes

    mov dx, 0x0080
    mov al, 0x86
    out dx, al
pass_halt:
    hlt
    jmp pass_halt

send_midi_byte:
    push ax
    push dx
    mov dx, 0x0331
wait_tx:
    in al, dx
    test al, 0x40
    jnz wait_tx
    pop dx
    pop ax
    out dx, al
    ret

fail_ack:
    mov dx, 0x0081
    mov al, 0xe8
    out dx, al
    jmp fail_halt
fail_idle_status:
    mov dx, 0x0081
    mov al, 0xea
    out dx, al
fail_halt:
    hlt
    jmp fail_halt

times 0xfff0 - ($ - $$) db 0xff
    jmp 0xf000:start
times 0x10000 - ($ - $$) db 0xff
