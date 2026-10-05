; Minimal standalone 1.44 MB floppy loader. Payload has COM origin 100h.
cpu 286
bits 16
org 7c00h
%ifndef LOAD_SEGMENT
%define LOAD_SEGMENT 1000h
%endif
jmp 0:entry
entry:
    cli
    xor ax,ax
    mov ds,ax
    mov ss,ax
    mov sp,7c00h
    sti
    mov [drive],dl
    mov ax,LOAD_SEGMENT
    mov es,ax
    mov byte [es:80h],0            ; Also permits a normal COM payload in tests.
    mov bx,100h
    mov si,1
.read:
    ; LBA si -> 18 sectors/track, two heads, one sector per BIOS read.
    mov ax,si
    xor dx,dx
    mov cx,18
    div cx
    mov cl,dl
    inc cl
    xor dx,dx
    mov di,2
    div di
    mov ch,al
    mov dh,dl
    mov dl,[drive]
    mov ax,0201h
    push si
    push bx
    int 13h
    pop bx
    pop si
    jc .error
    add bx,512
    inc si
    cmp si,PAYLOAD_SECTORS+1
    jb .read
    jmp LOAD_SEGMENT:100h
.error:
    mov ax,0e45h
    xor bx,bx
    int 10h
    cli
    hlt
    jmp .error
drive: db 0
times 510-($-$$) db 0
dw 0aa55h
