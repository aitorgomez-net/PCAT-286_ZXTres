; Simulation fixture for the original Phoenix A286 INT 15h/AH=87h path.
; The protected-mode service itself (F000:B1AD onward) remains byte-for-byte
; identical to the source ROM. Only the private reset fixture is replaced.
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
    cmp word [0600h],0ca87h
    je warm_resume

    mov word [0600h],0ca87h
    mov es,ax
    mov ss,ax
    mov sp,7000h

    ; Direct the software interrupt to the untouched Phoenix INT 15h handler.
    mov word [15h*4],0b1adh
    mov word [15h*4+2],0f000h

    ; INT 15h/AH=87h receives a caller-owned GDT at ES:SI. Phoenix fills the
    ; pseudo-descriptor, code and stack entries. The caller supplies selectors
    ; 10h and 18h for source and destination respectively.
    mov word [1010h],0ffffh
    mov word [1012h],2000h
    mov byte [1014h],00h
    mov byte [1015h],93h
    mov word [1016h],0000h

    mov word [1018h],0ffffh
    mov word [101ah],3000h
    mov byte [101ch],00h
    mov byte [101dh],93h
    mov word [101eh],0000h

    mov word [2000h],0a55ah
    mov word [3000h],0000h
    mov si,1000h
    mov cx,1
    mov ah,87h
    int 15h

    cli
    xor ax,ax
    mov ds,ax
    cmp word [3000h],0a55ah
    jne failed
    mov al,0a7h
    out 80h,al
    hlt
    jmp $

warm_resume:
    ; Phoenix normally selects this continuation from its CMOS shutdown-code
    ; dispatcher. Enter it directly because this reduced fixture has not run
    ; POST or built a valid CMOS configuration/checksum. The protected-mode
    ; service, saved-stack restore and INT 15h return remain original bytes.
    jmp 0f000h:0b306h

failed:
    mov al,0e7h
    out 80h,al
    hlt
    jmp $

times 200h-($-$$) db 0
incbin PHOENIX_ROM,200h,0fff0h-200h
    jmp 0f000h:start
incbin PHOENIX_ROM,0fff5h
