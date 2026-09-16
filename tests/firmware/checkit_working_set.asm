; CheckIt-directed dispersed-code workload.
; The benchmark repeatedly calls several routines placed far apart in the
; image.  This stresses a one-line read buffer: each routine has a distinct
; entry line and a body larger than one 8-byte fill.  It models the working
; set/return pattern that the compact Dhrystone-like kernel cannot expose.

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
    mov word [0x7000], 0x1357
    mov word [0x7002], 0x2468
    mov word [0x7004], 0x0001
    mov word [0x7006], 0x0003
    jmp stage1

times 0x100-($-$$) db 0x90
stage1:
    mov cx, 384
.call_loop:
    call routine_a
    call routine_b
    call routine_c
    call routine_d
    call routine_e
    call routine_f
    call routine_g
    call routine_h
    loop .call_loop
    jmp stage2

times 0x200-($-$$) db 0x90
stage2:
    mov si, 0x7200
    mov di, 0x7300
    mov cx, 256
.data_loop:
    lodsw
    xor ax, [0x7000]
    add ax, [0x7002]
    stosw
    loop .data_loop
    jmp stage3

times 0x300-($-$$) db 0x90
stage3:
    mov bx, 0x7300
    mov cx, 256
.branch_loop:
    mov ax, [bx]
    test ax, 1
    jz .even
    rol ax, 1
    add ax, 3
    jmp .store
.even:
    ror ax, 1
    sub ax, 2
.store:
    mov [bx], ax
    add bx, 2
    loop .branch_loop
    jmp stage4

times 0x400-($-$$) db 0x90
stage4:
    mov cx, 256
    mov bx, 11
.arith_loop:
    mov ax, 0x4321
    mul bx
    xor ax, dx
    xor dx, dx
    div bx
    add ax, [0x7004]
    mov [0x7004], ax
    loop .arith_loop
    jmp stage5

times 0x500-($-$$) db 0x90
stage5:
    mov di, 0x2000
    xor ax, ax
    mov cx, 256
.result_words:
    inc ax
    stosw
    loop .result_words
    mov di, 0x4000
    mov ax, 0xA55A
    mov cx, 1024
    rep stosw
    mov ax, 0x600D
    hlt

; Each routine is deliberately separated by 256 bytes.  The body uses a
; mixture of stack traffic, memory operands and branches rather than being a
; single synthetic NOP block.
times 0x800-($-$$) db 0x90
routine_a:
    push ax
    push bx
    push cx
    mov ax, [0x7000]
    add ax, [0x7002]
    xor ax, 0x1357
    mov [0x7000], ax
    test ax, 1
    jz .a_even
    inc ax
.a_even:
    add ax, bx
    mov [0x7002], ax
    pop cx
    pop bx
    pop ax
    ret

times 0x900-($-$$) db 0x90
routine_b:
    push ax
    push bx
    push cx
    mov ax, [0x7002]
    sub ax, [0x7004]
    rol ax, 1
    mov [0x7002], ax
    cmp ax, 0x4000
    jb .b_low
    xor ax, 0x00FF
.b_low:
    add [0x7004], ax
    pop cx
    pop bx
    pop ax
    ret

times 0xA00-($-$$) db 0x90
routine_c:
    push ax
    push bx
    push cx
    mov ax, [0x7004]
    mov bx, 7
    mul bx
    add ax, dx
    xor dx, dx
    div bx
    mov [0x7004], ax
    or ax, ax
    jnz .c_nonzero
    inc word [0x7004]
.c_nonzero:
    pop cx
    pop bx
    pop ax
    ret

times 0xB00-($-$$) db 0x90
routine_d:
    push ax
    push bx
    push cx
    mov bx, [0x7000]
    mov ax, [0x7002]
    xor ax, bx
    add bx, ax
    mov [0x7000], bx
    test bx, 0x8000
    jz .d_positive
    neg bx
.d_positive:
    mov [0x7002], bx
    pop cx
    pop bx
    pop ax
    ret

times 0xC00-($-$$) db 0x90
routine_e:
    push ax
    push bx
    push cx
    mov ax, [0x7000]
    mov bx, [0x7002]
    xchg ax, bx
    add ax, 0x0101
    sbb bx, 0
    mov [0x7000], ax
    mov [0x7002], bx
    pop cx
    pop bx
    pop ax
    ret

times 0xD00-($-$$) db 0x90
routine_f:
    push ax
    push bx
    push cx
    mov ax, [0x7004]
    mov bx, 3
    imul bx
    xor ax, dx
    mov [0x7004], ax
    test ax, 4
    jz .f_clear
    and ax, 0xFFF0
.f_clear:
    add ax, 5
    mov [0x7004], ax
    pop cx
    pop bx
    pop ax
    ret

times 0xE00-($-$$) db 0x90
routine_g:
    push ax
    push bx
    push cx
    mov ax, [0x7000]
    mov bx, [0x7004]
    sub ax, bx
    xor bx, 0x0F0F
    add ax, bx
    mov [0x7000], ax
    cmp ax, 0x2000
    ja .g_large
    inc word [0x7002]
.g_large:
    pop cx
    pop bx
    pop ax
    ret

times 0xF00-($-$$) db 0x90
routine_h:
    push ax
    push bx
    push cx
    mov ax, [0x7002]
    mov bx, [0x7000]
    add ax, bx
    ror ax, 1
    mov [0x7002], ax
    test ax, 1
    jnz .h_odd
    xor ax, 0xAAAA
.h_odd:
    mov [0x7000], ax
    pop cx
    pop bx
    pop ax
    ret

times 0xFFF0-($-$$) db 0xFF
    jmp 0xF000:0
times 65536-($-$$) db 0xFF
