; Exercise cached code, conflicting lines, odd data words, IRQ0/IRET and AT
; refresh before the integration harness requests a warm CPU reset.
bits 16
org 0
start:
    cli
    xor ax, ax
    mov ds, ax
    mov word [0x80], irq0
    mov word [0x82], 0xf000
    mov ax, 0x1000
    mov ds, ax
    mov ss, ax
    mov sp, 0xff00
    mov word [0x600], 0
    mov dx, 0x20
    mov al, 0x13
    out dx, al
    inc dx
    mov al, 0x20
    out dx, al
    mov al, 1
    out dx, al
    mov al, 0xfe
    out dx, al
    mov dx, 0x43
    mov al, 0x34
    out dx, al
    mov dx, 0x40
    mov al, 0x40
    out dx, al
    xor al, al
    out dx, al
    mov dx, 0x43
    mov al, 0x74
    out dx, al
    mov dx, 0x41
    mov al, 0x12
    out dx, al
    xor al, al
    out dx, al
    sti
    jmp block_a
times 0x100-($-$$) db 0x90
block_a:
    mov ax, 0xa55a
    mov [7], ax
    cmp ax, [7]
    jne failure
    jmp block_b
times 0x300-($-$$) db 0x90
block_b:
    inc word [0x602]
    jmp block_a
irq0:
    push ax
    push dx
    inc word [0x600]
    mov dx, 0x20
    mov al, 0x20
    out dx, al
    pop dx
    pop ax
    iret
failure:
    ud2
times 0xfff0-($-$$) db 0xff
    jmp 0xf000:start
times 0x10000-($-$$) db 0xff
