; CheckIt-directed no-NPU mathematics workload.
; The real Whetstone score uses the software floating-point path when no 287
; is present.  This workload keeps the same pressure points with signed Q8.8
; fixed-point values: calls, multiply/divide, branches and repeated data
; loads/stores.  It is a deterministic proxy, not a reimplementation of the
; proprietary benchmark body.

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
    mov word [0x6000], 0x0180
    mov word [0x6002], 0x00C0
    mov word [0x6004], 0x0020
    mov word [0x6006], 0x0100
    mov di, 0x6100
    mov ax, 0x0100
    mov cx, 128
.table_init:
    stosw
    add ax, 3
    loop .table_init
    jmp stage1

times 0x100-($-$$) db 0x90
stage1:
    mov cx, 512
.loop:
    call fixed_add
    call fixed_mul
    call fixed_div
    call fixed_branch
    loop .loop
    jmp stage2

times 0x200-($-$$) db 0x90
stage2:
    mov si, 0x6100
    mov di, 0x6200
    mov cx, 128
.table_loop:
    lodsw
    add ax, [0x6000]
    xor ax, [0x6002]
    stosw
    loop .table_loop
    mov si, 0x6200
    mov cx, 128
.reduce_loop:
    lodsw
    add [0x6004], ax
    adc word [0x6006], 0
    loop .reduce_loop
    jmp stage3

times 0x300-($-$$) db 0x90
stage3:
    mov cx, 256
.matrix_loop:
    call fixed_mul
    mov ax, [0x6000]
    sub ax, [0x6004]
    mov [0x6000], ax
    call fixed_add
    loop .matrix_loop
    jmp stage4

times 0x400-($-$$) db 0x90
stage4:
    mov cx, 256
.convergence_loop:
    mov ax, [0x6000]
    mov bx, [0x6002]
    or bx, bx
    jz .nonzero_divisor
    cwd
    idiv bx
    add ax, [0x6004]
    mov [0x6000], ax
.nonzero_divisor:
    xor word [0x6002], 0x0031
    call fixed_branch
    loop .convergence_loop
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

times 0x800-($-$$) db 0x90

fixed_add:
    push ax
    push bx
    mov ax, [0x6000]
    add ax, [0x6002]
    sub ax, [0x6004]
    mov bx, [0x6006]
    adc bx, 0
    mov [0x6000], ax
    mov [0x6006], bx
    pop bx
    pop ax
    ret

fixed_mul:
    push ax
    push bx
    push dx
    mov ax, [0x6000]
    mov bx, [0x6002]
    imul bx
    ; Keep the high product involved, then return to Q8.8 scale.
    xor dx, dx
    mov [0x6000], ax
    pop dx
    pop bx
    pop ax
    ret

fixed_div:
    push ax
    push bx
    push dx
    mov ax, [0x6000]
    mov bx, [0x6004]
    or bx, bx
    jz .done
    cwd
    idiv bx
    mov [0x6002], ax
.done:
    pop dx
    pop bx
    pop ax
    ret

fixed_branch:
    push ax
    push bx
    mov ax, [0x6000]
    test ax, 0x0080
    jz .positive
    neg ax
    xor ax, 0x0011
    jmp .store
.positive:
    add ax, 0x0007
.store:
    mov bx, [0x6006]
    xor bx, ax
    mov [0x6000], ax
    mov [0x6006], bx
    pop bx
    pop ax
    ret

times 0xFFF0-($-$$) db 0xFF
    jmp 0xF000:0
times 65536-($-$$) db 0xFF
