; Numeric DOS frontend for the hash-pinned CheckIt 3.03C benchmark routines.
; The builder retains their original relative segment addresses and runtime.
bits 16
cpu 286
org 0x000a

start:
    push bp
    mov bp,sp
    sub sp,160

dhrystone_call:
    call 0x0ec1:0x000c
    mov bx,ax
    mov es,dx
    push word [es:bx+6]
    push word [es:bx+4]
    push word [es:bx+2]
    push word [es:bx]
    push ds
    push word 0x6572
    push ss
    lea ax,[bp-128]
    push ax
dhrystone_format_call:
    call 0x2691:0x0460
    add sp,16
    mov cx,ax
    lea dx,[bp-128]
    call write
    jc output_error

    ; The unused progress-widget argument points to reserved stack storage.
    push ss
    lea ax,[bp-160]
    push ax
whetstone_call:
    call 0x0f2e:0x000c
    add sp,4
    mov bx,ax
    push ds
    mov ds,dx
    ; Original Microsoft software-FP token: load qword DS:[BX], synchronize.
    db 0xcd,0x39,0x07,0xcd,0x3d
    pop ds
    ; Same 1000.0 division and stack-store tokens as CheckIt's display path.
    db 0xcd,0x38,0x36,0xa2,0xb9
    sub sp,8
    mov bx,sp
    ; CRT sets SS == DS (DGROUP), so [BX] addresses the argument stack.
    db 0xcd,0x39,0x1f,0xcd,0x3d
    push ds
    push word 0x6583
    push ss
    lea ax,[bp-128]
    push ax
whetstone_format_call:
    call 0x2691:0x0460
    add sp,16
    mov cx,ax
    lea dx,[bp-128]
    call write
    jc output_error
    xor ax,ax
    jmp finish
output_error:
    mov ax,1
finish:
    mov sp,bp
    pop bp
    retf

write:
    push ds
    push ss
    pop ds
    mov bx,1
    mov ah,0x40
    int 0x21
    pop ds
    jc .done
    cmp ax,cx
    je .done
    stc
.done:
    ret

stub_end:
; Relocation offsets come from NASM labels, never from scanning opcode bytes.
dw dhrystone_call+3
dw dhrystone_format_call+3
dw whetstone_call+3
dw whetstone_format_call+3
dw stub_end-start
db 'CKRL'
