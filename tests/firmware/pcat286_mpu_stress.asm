; MPU-401 UART-mode stress diagnostic for the real 80286/AT boundary.
; It deliberately exercises the sequence used by DOS drivers rather than
; only a single FF/FE transaction: reset, UART-mode entry, two polled ACKs and
; a short MIDI transmission after the second ACK.
bits 16
org 0

start:
    cli
    xor ax, ax
    mov ds, ax
    mov word [0x01c4], mpu_handler
    mov word [0x01c6], 0xf000
    mov word [0x0020], irq0_handler
    mov word [0x0022], 0xf000

    mov ax, 0x1000
    mov ds, ax
    mov ss, ax
    mov sp, 0xff00
    mov word [0x0600], 0x0000       ; receive IRQ count
    mov word [0x0602], 0x0000       ; last received byte
    mov word [0x0604], 0x0000       ; IRQ0 marker

    ; AT 8259A pair: master vector 08h, slave vector 70h, cascade on IR2.
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
    mov al, 0xfd                  ; unmask slave IRQ9
    out dx, al

    ; PIT channel 0, mode 2, divisor 0020h: supplies a wake-up IRQ0.
    mov dx, 0x0043
    mov al, 0x34
    out dx, al
    mov dx, 0x0040
    mov al, 0x20
    out dx, al
    xor al, al
    out dx, al

    sti

    ; MPU reset command and polled ACK.
    mov dx, 0x0331
    mov al, 0xff
    out dx, al
wait_first:
    hlt
    cmp word [0x0600], 0x0001
    jb wait_first

    ; Enter UART mode and poll the second FE ACK.
    mov dx, 0x0331
    mov al, 0x3f
    out dx, al
wait_second:
    hlt
    cmp word [0x0600], 0x0002
    jb wait_second
    cmp word [0x0602], 0x00fe
    jne fail_ack

    ; Typical MT-32 note-on and note-off messages, followed by a sustained
    ; stream. The UART-mode MPU must accept consecutive writes without
    ; producing another command ACK or wedging the CPU bus.
    mov dx, 0x0330
    mov al, 0x90
    out dx, al
    mov al, 0x3c
    out dx, al
    mov al, 0x7f
    out dx, al
    mov al, 0x80
    out dx, al
    mov al, 0x3c
    out dx, al
    mov al, 0x00
    out dx, al

    mov cx, 0x0100
    mov al, 0x40
stream_bytes:
    out dx, al
    inc al
    loop stream_bytes

    mov dx, 0x0080
    mov al, 0x70
    out dx, al
    mov al, 0x72
    out dx, al
    mov al, 0x71
    out dx, al
    mov al, 0x86
    out dx, al
pass_halt:
    hlt
    jmp pass_halt

irq0_handler:
    push ax
    push dx
    inc word [0x0604]
    mov dx, 0x0020
    mov al, 0x20
    out dx, al
    pop dx
    pop ax
    iret

mpu_handler:
    push ax
    push dx
    mov dx, 0x0330
    in al, dx
    mov word [0x0602], 0x00fe
    inc word [0x0600]
    mov dx, 0x00a0
    mov al, 0x20
    out dx, al
    mov dx, 0x0020
    out dx, al
    pop dx
    pop ax
    iret

fail_ack:
    mov dx, 0x0081
    mov al, 0xe8
    out dx, al
fail_halt:
    hlt
    jmp fail_halt

times 0xfff0 - ($ - $$) db 0xff
    jmp 0xf000:start
times 0x10000 - ($ - $$) db 0xff
