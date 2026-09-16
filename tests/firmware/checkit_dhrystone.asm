; CheckIt-directed integer workload.
; This is intentionally not a copy of the commercial CheckIt binary.  It
; models the Dhrystone characteristics documented by CheckIt: procedure
; calls, record/pointer fields, array accesses, string operations and integer
; branches.  The final memory pattern is shared with the existing AT perf
; scoreboard so the workload can use the same physical memory model.

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
    jmp stage1

times 0x100-($-$$) db 0x90
stage1:
    mov word [0x5000], 0x1357
    mov word [0x5002], 0x2468
    mov word [0x5004], 0x0001
    mov word [0x5006], 0x0003
    mov di, 0x5200
    mov ax, 0x3141
    mov cx, 16
    rep stosw
    mov di, 0x5600
    mov ax, 0x5700
    mov cx, 128
.pointer_init:
    stosw
    add ax, 2
    loop .pointer_init
    mov cx, 512
.loop:
    call proc_record
    call proc_strings
    call proc_branch
    loop .loop
    jmp stage2

times 0x200-($-$$) db 0x90
stage2:
    mov si, 0x5200
    mov di, 0x5400
    mov cx, 256
.copy_loop:
    lodsw
    xor ax, 0x5A5A
    add ax, 0x0101
    stosw
    loop .copy_loop
    mov si, 0x5400
    mov di, 0x5500
    mov cx, 256
    rep movsw
    jmp stage3

times 0x300-($-$$) db 0x90
stage3:
    mov bx, 0x5600
    mov cx, 128
.pointer_loop:
    mov si, [bx]
    mov ax, [si]
    add ax, [0x5000]
    xor ax, [0x5002]
    mov [si], ax
    add bx, 2
    loop .pointer_loop
    mov si, 0x5500
    mov cx, 128
.compare_loop:
    lodsw
    cmp ax, 0
    jne .compare_nonzero
    inc ax
.compare_nonzero:
    xor ax, 0x00FF
    loop .compare_loop
    jmp stage4

times 0x400-($-$$) db 0x90
stage4:
    mov cx, 256
    mov bx, 7
.arith_loop:
    mov ax, 0x1234
    mul bx
    add ax, dx
    xor dx, dx
    div bx
    xor ax, 0x00A5
    test ax, 1
    jz .arith_even
    add ax, 3
.arith_even:
    loop .arith_loop
    jmp stage5

times 0x500-($-$$) db 0x90
stage5:
    ; Expected by the common scoreboard: byte address 2000h maps to word
    ; address 1000h in the SDRAM model, and 4000h maps to 2000h.
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

; A small Dhrystone-like record procedure.  Its memory traffic is deliberately
; mixed with register work and a call/return boundary.
proc_record:
    push ax
    push bx
    push si
    push di
    mov si, 0x5000
    mov di, 0x5002
    mov ax, [si]
    add ax, [si+2]
    xor ax, [di]
    rol ax, 1
    mov [si], ax
    mov bx, [di]
    add bx, ax
    mov [di], bx
    pop di
    pop si
    pop bx
    pop ax
    ret

; Copy/compare a short character-like record, as in the string operations in
; the classic Dhrystone family.
proc_strings:
    push ax
    push cx
    push si
    push di
    push es
    push ds
    pop es
    mov si, 0x5200
    mov di, 0x5300
    mov cx, 16
    rep movsw
    mov si, 0x5300
    mov di, 0x5200
    mov cx, 16
    repe cmpsw
    pop es
    pop di
    pop si
    pop cx
    pop ax
    ret

proc_branch:
    push ax
    push bx
    push cx
    push dx
    mov ax, [0x5004]
    mov bx, [0x5006]
    xor ax, bx
    test ax, 1
    jz .even
    add ax, 0x1111
    adc bx, 0
    jmp .store
.even:
    sub ax, 0x0101
    sbb bx, 0
.store:
    mov [0x5004], ax
    mov [0x5006], bx
    pop dx
    pop cx
    pop bx
    pop ax
    ret

times 0xFFF0-($-$$) db 0xFF
    jmp 0xF000:0
times 65536-($-$$) db 0xFF
