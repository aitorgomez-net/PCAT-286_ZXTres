; PCAT-286 MPU-401/AT-PIC diagnostic ROM.
; Exercises the real 80286 event path: polled MPU ACKs, then a UART-mode
; receive byte -> slave IRQ9 -> master cascade -> vector 71h -> data read and
; EOI.
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
    mov word [0x0600], 0x0000
    mov word [0x0602], 0xcafe
    mov word [0x0608], 0x0000
    mov word [0x060a], 0x0000

    mov dx, 0x0080
    mov al, 0x70
    out dx, al

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
    mov al, 0xb8
    out dx, al
    mov dx, 0x00a1
    mov al, 0xfd
    out dx, al

    ; PIT channel 0, mode 2, divisor 0020h: supplies the wake-up IRQ0.
    mov dx, 0x0043
    mov al, 0x34
    out dx, al
    mov dx, 0x0040
    mov al, 0x20
    out dx, al
    xor al, al
    out dx, al

    sti
    mov dx, 0x0331
    mov al, 0xff
    out dx, al

wait_reset_ack:
    in al, dx
    test al, 0x80
    jnz wait_reset_ack
    mov dx, 0x0330
    in al, dx
    cmp al, 0xfe
    je reset_ack_ok
    jmp mpu_failure
reset_ack_ok:

    ; Command ACKs are polled.  UART-mode receive data is what should raise
    ; IRQ9, so enter UART mode before waiting for the real interrupt path.
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
    je uart_ack_ok
    jmp mpu_failure
uart_ack_ok:

wait_for_irq:
    sti
    hlt
    cmp word [0x0600], 0xa55a
    jne wait_for_irq
    cmp word [0x0602], 0xcafe
    jne frame_failure
    cmp word [0x0608], 0x4d50
    jne mpu_failure
    cmp word [0x060a], 0x0000
    jne mpu_failure

    mov dx, 0x0080
    mov al, 0x71
    out dx, al
    mov word [0x0604], 0x2864
    mov al, 0x86
    out dx, al
pass_halt:
    hlt
    jmp pass_halt

irq0_handler:
    push ax
    push dx
    mov word [0x0600], 0xa55a
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
    ; Any received byte proves the UART-mode IRQ path.  The standalone serial
    ; test owns exact 8N1 payload validation; reject FEh here because that is
    ; the command ACK whose premature IRQ would reproduce the AT hang.
    cmp al, 0xfe
    jne mpu_expected_byte
    mov word [0x060a], 0x0001
    jmp mpu_ack_eoi
mpu_expected_byte:
    mov word [0x0608], 0x4d50
mpu_ack_eoi:
    mov dx, 0x0080
    mov al, 0x72
    out dx, al
    mov dx, 0x00a0
    mov al, 0x20
    out dx, al
    mov dx, 0x0020
    out dx, al
    pop dx
    pop ax
    iret

event_failure:
    mov al, 0xe6
    jmp failure
frame_failure:
    mov al, 0xe7
    jmp failure
mpu_failure:
    mov al, 0xe8
failure:
    mov dx, 0x0081
    out dx, al
failure_halt:
    hlt
    jmp failure_halt

times 0xfff0 - ($ - $$) db 0xff
    jmp 0xf000:start
times 0x10000 - ($ - $$) db 0xff
