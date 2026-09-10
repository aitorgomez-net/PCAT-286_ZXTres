; PCAT-286 project-owned Real Mode diagnostic ROM.
; It executes exclusively through architectural instructions and ordinary bus
; transfers from the native 80286 reset state.
bits 16
org 0

start:
    cli
    mov ax, 0x1000
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xff00

    mov dx, 0x0080
    mov al, 0x10
    out dx, al

    mov word [0x0200], 0x1234
    mov bx, [0x0200]
    cmp bx, 0x1234
    je memory_word_ok
    mov al, 0xe1
    jmp failure
memory_word_ok:
    mov byte [0x0202], 0x5a
    mov al, [0x0202]
    cmp al, 0x5a
    je memory_byte_ok
    mov al, 0xe1
    jmp failure
memory_byte_ok:
    mov al, 0x20
    out dx, al

    mov word [0xfee0], 0xcafe
    mov ax, 0xbeef
    push ax
    xor ax, ax
    pop ax
    cmp ax, 0xbeef
    je stack_value_ok
    mov al, 0xe2
    jmp failure
stack_value_ok:
    call 0xf000:far_subroutine
    cmp bp, 0x0bad
    je far_call_ok
    mov al, 0xe2
    jmp failure
far_call_ok:
    cmp word [0xfee0], 0xcafe
    je stack_guard_ok
    mov al, 0xe2
    jmp failure
stack_guard_ok:
    mov al, 0x30
    out dx, al

    mov word [0x0300], 0x1234
    mov word [0x0302], 0xabcd
    mov word [0x0320], 0x0000
    mov word [0x0322], 0x0000
    mov si, 0x0300
    mov di, 0x0320
    mov cx, 4
    cld
    rep movsb
    cmp word [0x0320], 0x1234
    je string_low_ok
    mov al, 0xe3
    jmp failure
string_low_ok:
    cmp word [0x0322], 0xabcd
    je string_high_ok
    mov al, 0xe3
    jmp failure
string_high_ok:
    mov al, 0x40
    out dx, al

    mov dx, 0x0060
    in al, dx
    cmp al, 0xa6
    je io_ok
    mov al, 0xe4
    jmp failure
io_ok:
    mov dx, 0x0080
    mov al, 0x50
    out dx, al

    ; The machine model must ignore CPU writes to the loaded BIOS region.
    mov ax, 0xf000
    mov es, ax
    mov byte [es:0x8000], 0x00
    cmp byte [es:0x8000], 0xff
    je rom_protection_ok
    mov al, 0xe5
    jmp failure
rom_protection_ok:

    mov word [0x0500], 0x2860
    mov word [0x0502], 0x5a3c
    mov al, 0x86
    out dx, al
pass_halt:
    hlt
    jmp pass_halt

far_subroutine:
    mov bp, 0x0bad
    retf

failure:
    mov dx, 0x0081
    out dx, al
failure_halt:
    hlt
    jmp failure_halt

times 0xfff0 - ($ - $$) db 0xff
reset_vector:
    jmp 0xf000:start
times 0x10000 - ($ - $$) db 0xff
