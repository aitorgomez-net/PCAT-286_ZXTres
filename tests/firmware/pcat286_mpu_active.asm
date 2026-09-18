; MPU-401 IRQ9 diagnostic while the 286 keeps IF=1 and spins.
; This catches a stale INT level that would re-enter the MPU ISR after IRET.
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
    mov word [0x0600], 0x0000       ; MPU ISR count
    mov word [0x0602], 0xcafe

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

    ; Keep IRQ0 alive so the CPU also services a normal master interrupt while
    ; the MPU interrupt is being acknowledged.
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

wait_for_mpu:
    cmp word [0x0600], 0x0001
    jb wait_for_mpu
    cli
    cmp word [0x0600], 0x0001
    jne failure

    mov dx, 0x0080
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
    inc word [0x0600]
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

failure:
    mov dx, 0x0081
    mov al, 0xe9
    out dx, al
failure_halt:
    hlt
    jmp failure_halt

times 0xfff0 - ($ - $$) db 0xff
    jmp 0xf000:start
times 0x10000 - ($ - $$) db 0xff
