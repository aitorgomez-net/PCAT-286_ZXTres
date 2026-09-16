; Deterministic CPU/memory workloads. Not CheckIt or a historical MHz test.
bits 16
cpu 286
org 0
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    jmp registers

times 0x100-($-$$) db 0x90
registers:
    mov cx, 256
    xor ax, ax
.loop:
    add ax, 1
    xor ax, 0x5A5A
    xor ax, 0x5A5A
    loop .loop
    cmp ax, 256
    jne failed
    jmp memory

times 0x200-($-$$) db 0x90
memory:
    mov cx, 256
    xor ax, ax
    mov di, 0x2000
.loop:
    mov [di], ax
    add word [di], 1
    mov ax, [di]
    push ax
    pop dx
    cmp ax, dx
    jne failed
    add di, 2
    loop .loop
    cmp ax, 256
    jne failed
    ; Byte writes and an unaligned word must preserve their neighbouring bytes.
    mov word [0x2800], 0x1234
    mov word [0x2802], 0x5678
    mov word [0x2801], 0xABCD
    cmp word [0x2800], 0xCD34
    jne failed
    cmp word [0x2802], 0x56AB
    jne failed
    mov byte [0x2801], 0x9E
    cmp word [0x2800], 0x9E34
    jne failed
    jmp strings

times 0x300-($-$$) db 0x90
strings:
    mov cx, 1024
    mov ax, 0xA55A
    mov di, 0x3000
    rep stosw
    mov si, 0x3000
    mov di, 0x4000
    mov cx, 1024
    rep movsw
    mov di, 0x4000
    mov cx, 1024
    repe scasw
    jne failed
    jmp arithmetic

times 0x400-($-$$) db 0x90
arithmetic:
    mov cx, 128
    mov bx, 7
.loop:
    mov ax, 0x1234
    mul bx
    div bx
    cmp ax, 0x1234
    jne failed
    test dx, dx
    jne failed
    loop .loop
    jmp done

times 0x500-($-$$) db 0x90
done:
    mov ax, 0x600D
    hlt
failed:
    mov ax, 0xDEAD
    hlt
times 0xFFF0-($-$$) db 0xFF
    jmp 0xF000:0
times 65536-($-$$) db 0xFF
