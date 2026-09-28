; Test-only RAM environment for the unmodified MR BIOS 1.65 IRQ1 handler.
; Run after its first-64-KiB POST has passed. No ROM bytes are patched.
bits 16
org 0x7000
start:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x6c00
    mov word [8*4], timer_irq
    mov word [8*4+2], 0
    mov word [9*4], 0xf104
    mov word [9*4+2], 0xf000
    mov word [0x15*4], 0xff53 ; ROM IRET leaves keyboard intercept CF set
    mov word [0x15*4+2], 0xf000
    mov byte [0x417], 0
    mov byte [0x418], 0
    mov byte [0x496], 0
    mov byte [0x497], 0
    mov word [0x41a], 0x1e
    mov word [0x41c], 0x1e
    mov word [0x480], 0x1e
    mov word [0x482], 0x3e
    mov al, 0x11
    out 0x20, al
    out 0xa0, al
    mov al, 8
    out 0x21, al
    mov al, 0x70
    out 0xa1, al
    mov al, 4
    out 0x21, al
    mov al, 2
    out 0xa1, al
    mov al, 1
    out 0x21, al
    out 0xa1, al
    mov al, 0xff
    out 0xa1, al
    mov al, 0xfc ; IRQ0 and IRQ1 enabled
    out 0x21, al
    mov al, 0x36
    out 0x43, al
    mov al, 0x80 ; shortened timer period exercises nested IRQ0 during IRQ1
    out 0x40, al
    xor al, al
    out 0x40, al
    call input_empty
    mov al, 0x60
    out 0x64, al
    call input_empty
    mov al, 0x45 ; system flag, IRQ1 and set-1 translation
    out 0x60, al
    call input_empty
    mov al, 0xae
    out 0x64, al
    call input_empty
    mov al, 0xe1
    out 0x80, al
    sti
%ifdef MRBIOS_REP_IDLE
    mov ax, 0x1000
    mov ds, ax
    mov ax, 0x2000
    mov es, ax
%endif
idle:
%ifdef MRBIOS_REP_IDLE
    xor si, si
    xor di, di
    mov cx, 0x8000
    rep movsw
%endif
    jmp idle
input_empty:
    in al, 0x64
    test al, 2
    jnz input_empty
    ret
timer_irq:
    push ax
    inc word [cs:0x6f00]
    mov al, 0x20
    out 0x20, al
    pop ax
    iret
