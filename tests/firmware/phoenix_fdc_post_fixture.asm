; Simulation fixture only. Original Phoenix FDC/IRQ0/IRQ6/PIT routines remain
; byte-for-byte intact. The on-disk production ROM is never modified.
cpu 286
bits 16
org 0
%ifndef PHOENIX_ROM
%define PHOENIX_ROM "SW/ROMs/test/Phoenix_AT_Clone_A286_v1.01_64K.ROM"
%endif
start:
    cli
    cld
    xor ax,ax
    mov ds,ax
    mov es,ax
    mov ss,ax
    mov sp,7000h
    xor di,di
    mov cx,800h
    rep stosw
    mov word [20h],0b842h
    mov word [22h],0f000h
    mov word [38h],0a071h
    mov word [3ah],0f000h
    mov word [40h],iret_stub
    mov word [42h],0f000h
    mov word [54h],int15_stub
    mov word [56h],0f000h
    mov word [70h],iret_stub
    mov word [72h],0f000h
    mov word [78h],0efc7h
    mov word [7ah],0f000h
    mov al,13h
    out 20h,al
    mov al,08h
    out 21h,al
    mov al,01h
    out 21h,al
    mov al,0beh
    out 21h,al
    mov al,36h
    out 43h,al
    xor al,al
    out 40h,al
    out 40h,al
    sti
    call 0a16ch
    cli
    hlt
    jmp $-1
int15_stub:
    stc
    retf 2
iret_stub:
    iret
times 200h-($-$$) db 0
incbin PHOENIX_ROM,200h,0fff0h-200h
    jmp 0f000h:start
incbin PHOENIX_ROM,0fff5h
