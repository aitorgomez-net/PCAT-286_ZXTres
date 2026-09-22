; Directed 80286 XMS-style access through LOADALL and the AT A20 gate.
; This is a synthetic regression, not a replacement for HIMEM.SYS.
cpu 286
bits 16
org 0

start:
    cli
    cld
    xor ax,ax
    mov ss,ax
    mov sp,7000h
    mov es,ax
    push cs
    pop ds
    mov si,image
    mov di,0800h
    mov cx,51
    rep movsw
    xor ax,ax
    mov ds,ax
    mov word [0200h],0beefh

    ; Enable A20 through the production 8042 output-port command.
    mov al,0d1h
    out 64h,al
    mov al,0dfh
    out 60h,al
    db 0fh,05h

fill_extended:
    ; ES has selector zero but a hidden base of 100000h.
    rep stosw
    mov byte [es:0201h],12h
    mov byte [es:0202h],34h
    cmp word [0200h],0beefh
    jne failed
    cmp word [es:0200h],125ah
    jne failed
    cmp word [es:0202h],0a534h
    jne failed

    ; Second LOADALL: read extended memory into conventional RAM.
    mov word [081ah],copy_extended
    mov word [0826h],3000h       ; DI
    mov word [0828h],0200h       ; SI
    mov word [0832h],16          ; CX
    mov byte [0838h],00h         ; ES base high
    mov byte [084ah],10h         ; DS base high
    db 0fh,05h

copy_extended:
    rep movsw
    xor ax,ax
    mov ds,ax                   ; Ordinary load restores the real-mode base.
    cmp word [3000h],125ah
    jne failed
    cmp word [3002h],0a534h
    jne failed
    cmp word [301eh],0a55ah
    jne failed

    ; Closing A20 must alias the same hidden extended base to low RAM.
    mov word [081ah],check_a20
    mov byte [0838h],10h
    mov byte [084ah],00h
    mov al,0d1h
    out 64h,al
    mov al,0ddh
    out 60h,al
    db 0fh,05h

check_a20:
    mov word [es:0200h],5aa5h
    cmp word [0200h],5aa5h
    jne failed
    mov al,0a5h
    out 80h,al
    hlt
    jmp $

failed:
    mov al,0e5h
    out 80h,al
    hlt
    jmp $

align 2
image:
    times 6 db 0
    dw 0fff0h                  ; MSW: remain in real mode
    times 14 db 0
    dw 0,0002h,fill_extended,0  ; TR, FLAGS, IP, LDTR
    dw 0,0,0f000h,0            ; DS, SS, CS, ES selectors
    dw 0200h,0,0,7000h,0,0,16,0a55ah ; DI SI BP SP BX DX CX AX
    dw 0,9310h,0ffffh          ; ES cache: 100000h
    dw 0,9b0fh,0ffffh          ; CS cache: 0F0000h
    dw 0,9300h,0ffffh          ; SS cache: 000000h
    dw 0,9300h,0ffffh          ; DS cache: 000000h
    dw 0,0,0                   ; GDTR
    dw 0,0,0                   ; LDTR cache
    dw 0,0,03ffh               ; IDTR
    dw 0,0,0                   ; TR cache
    times 102-($-image) db 0

times 0fff0h-($-$$) db 0ffh
    jmp 0f000h:start
times 10000h-($-$$) db 0ffh
