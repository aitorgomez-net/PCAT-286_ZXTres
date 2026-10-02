; PCAT-286 I4 event-path diagnostic ROM.
; Programs the imported KF8259-compatible PIC and PIT-facing ports, sleeps in
; HLT, services IRQ0 through vector 20h, sends EOI, returns with IRET and emits
; independent memory/port signatures.
bits 16
cpu 286
org 0

start:
    cli

%ifdef ENTRY_MEMORY_PROBE
    ; Exercise actual early-entry transactions before the usual event path.
    ; A ROM write must finish through the sink without changing either lane.
    mov ax, 0xf000
    mov ds, ax
    mov bx, [0x0000]
    mov ax, bx
    not ax
    mov [0x0000], ax
    cmp [0x0000], bx
    je .rom_word_ok
    jmp entry_failure
.rom_word_ok:
    mov byte [0x0001], 0x5a
    cmp [0x0000], bx
    je .rom_byte_ok
    jmp entry_failure
.rom_byte_ok:

    ; A20 is initially off: FFFF:1220 aliases 0000:1210. Check real read
    ; and write data through the machine mapping, not just decode outputs.
    xor ax, ax
    mov ds, ax
    mov word [0x1210], 0x5ac3
    mov ax, 0xffff
    mov ds, ax
    cmp word [0x1220], 0x5ac3
    je .a20_read_ok
    jmp entry_failure
.a20_read_ok:
    mov word [0x1220], 0x286a
    xor ax, ax
    mov ds, ax
    cmp word [0x1210], 0x286a
    je .a20_write_ok
    jmp entry_failure
.a20_write_ok:
%endif

    ; Install vector 20h before selecting the diagnostic data segment.
    xor ax, ax
    mov ds, ax
    mov word [0x0008], nmi_handler
    mov word [0x000a], 0xf000
    mov word [0x0080], irq0_handler
    mov word [0x0082], 0xf000

    mov ax, 0x1000
    mov ds, ax
    mov ss, ax
    mov sp, 0xff00
    mov word [0x0600], 0x0000
    mov word [0x0602], 0xcafe

    mov dx, 0x0080
    mov al, 0x70
    out dx, al

    ; 8259A: edge-triggered, single controller, ICW4 present, vector base 20h,
    ; 8086 mode, then unmask IRQ0 only.
    mov dx, 0x0020
    mov al, 0x13
    out dx, al
    inc dx
    mov al, 0x20
    out dx, al
    mov al, 0x01
    out dx, al
    mov al, 0xfe
    out dx, al

    ; Initialize PIT channel 1 as an AT BIOS does: mode 2, divisor 18.
    ; Real AT refresh ownership now follows OUT1 instead of a free-running
    ; simulation requester, so the diagnostic must initialize its source.
    mov dx, 0x0043
    mov al, 0x74
    out dx, al
    mov dx, 0x0041
    mov al, 18
    out dx, al
    xor al, al
    out dx, al

    ; Program PIT channel 0, mode 2, divisor 0020h. The focused simulation
    ; observes these writes and supplies the corresponding IRQ0 edge; the full
    ; machine routes the real timer output to the PIC.
    mov dx, 0x0043
    mov al, 0x34
    out dx, al
    mov dx, 0x0040
    mov al, 0x20
    out dx, al
    xor al, al
    out dx, al

    sti
wait_for_irq:
    hlt
    cli

    cmp word [0x0600], 0xa55a
    jne event_failure
    cmp word [0x0602], 0xcafe
    jne frame_failure

    mov dx, 0x0080
    mov al, 0x71
    out dx, al
    mov word [0x0604], 0x2864
    mov al, 0x86
    out dx, al
pass_halt:
    hlt
    jmp pass_halt

irq0_handler:
    push ax
    push dx
    mov word [0x0600], 0xa55a
    mov dx, 0x0080
    mov al, 0x72
    out dx, al
    mov dx, 0x0020
    mov al, 0x20
    out dx, al
    pop dx
    pop ax
    iret

nmi_handler:
    push ax
    push dx
    mov word [0x0606], 0x2bad
    mov dx, 0x0080
    mov al, 0x73
    out dx, al
    pop dx
    pop ax
    iret

event_failure:
    mov al, 0xe6
    jmp failure
%ifdef ENTRY_MEMORY_PROBE
entry_failure:
    mov al, 0xe5
    jmp failure
%endif
frame_failure:
    mov al, 0xe7
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
