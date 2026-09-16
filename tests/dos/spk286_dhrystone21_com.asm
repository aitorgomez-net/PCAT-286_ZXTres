; SPK286/286 DOS benchmark helper.
;
; Build with:
;   nasm -O9 -f bin -o SPK286D.COM spk286_dhrystone21_com.asm
;
; This is a clean-room, Dhrystone-2.x-shaped integer workload for comparing
; BASE/T01/T02/T03 on real DOS.  It deliberately avoids DOS and video calls
; during the timed section.  The timer is read directly from the standard BIOS
; Data Area tick counter at 0040:006C, so the result is comparable between
; 86Box and the MiSTer core without depending on screen output speed.

bits 16
cpu 286
org 100h

%define RUNS       10000

start:
    jmp main

main:
    push cs
    pop ds
    cld

    mov dx, msg_banner
    call print_string
    mov dx, msg_runs
    call print_string
    mov ax, RUNS
    call print_u16
    mov dx, msg_crlf
    call print_string

    call init_workload
    call read_ticks
    mov [start_ticks_lo], ax
    mov [start_ticks_hi], dx

    mov cx, RUNS
.run_loop:
    ; Same dominant operation classes as Dhrystone: global state reset,
    ; linked-record updates, enum branches, string compare and array work.
    call proc_5
    call proc_4
    mov word [int_loc1], 2
    mov word [int_loc2], 3
    mov word [enum_loc], 1
    call func_2
    call proc_7
    call proc_8
    call proc_1
    call proc_6
    call proc_3
    call proc_2
    loop .run_loop

    call read_ticks
    sub ax, [start_ticks_lo]
    sbb dx, [start_ticks_hi]
    mov [elapsed_ticks_lo], ax
    mov [elapsed_ticks_hi], dx
    or ax, dx
    jnz .elapsed_nonzero
    mov word [elapsed_ticks_lo], 1
    mov word [elapsed_ticks_hi], 0
.elapsed_nonzero:

    mov dx, msg_ticks
    call print_string
    mov ax, [elapsed_ticks_lo]
    call print_u16
    mov dx, msg_crlf
    call print_string

    mov dx, msg_runs_tick
    call print_string
    mov ax, RUNS
    xor dx, dx
    div word [elapsed_ticks_lo]
    call print_u16
    mov dx, msg_crlf
    call print_string

    mov dx, msg_checksum
    call print_string
    mov ax, [checksum]
    call print_hex16
    mov dx, msg_crlf
    call print_string

    mov ax, 4C00h
    int 21h

; ------------------------ timed workload helpers ------------------------

init_workload:
    mov word [ptr_glob], record_a
    mov word [next_ptr_glob], record_b
    mov word [record_a+0], record_b
    mov word [record_a+2], 0
    mov word [record_a+4], 1
    mov word [record_a+6], 40
    mov word [record_b+0], record_a
    mov word [record_b+2], 1
    mov word [record_b+4], 2
    mov word [record_b+6], 30
    mov word [int_glob], 0
    mov byte [bool_glob], 0
    mov byte [ch1_glob], 'A'
    mov byte [ch2_glob], 'B'
    mov word [enum_glob], 2
    mov word [int_loc1], 2
    mov word [int_loc2], 3
    mov word [enum_loc], 1
    mov si, string_one
    mov di, string1
    call copy_string
    mov si, string_two
    mov di, string2
    call copy_string
    mov word [checksum], 0
    ret

proc_1:
    push ax
    push bx
    push si
    push di
    mov si, [ptr_glob]
    mov di, [si+0]
    mov ax, [si+6]
    inc ax
    mov [si+6], ax
    mov bx, [di+6]
    add bx, ax
    mov [di+6], bx
    mov ax, [si+2]
    or ax, ax
    jnz .p1_variant
    mov word [di+4], 2
.p1_variant:
    mov ax, [si+4]
    mov [di+4], ax
    xor [checksum], ax
    pop di
    pop si
    pop bx
    pop ax
    ret

proc_2:
    push ax
    push bx
    push cx
    mov ax, [int_loc1]
    mov bx, [int_loc2]
    mov cx, 3
.p2_loop:
    add ax, bx
    dec ax
    cmp byte [ch1_glob], 'A'
    jne .p2_next
    inc ax
.p2_next:
    loop .p2_loop
    mov [int_loc1], ax
    mov [int_glob], ax
    xor [checksum], ax
    pop cx
    pop bx
    pop ax
    ret

proc_3:
    push ax
    push bx
    push si
    mov si, [ptr_glob]
    mov bx, [si+0]
    mov ax, [bx+6]
    xor ax, [int_glob]
    mov [si+6], ax
    mov [ptr_glob], bx
    xor [checksum], ax
    pop si
    pop bx
    pop ax
    ret

proc_4:
    push ax
    mov al, [ch1_glob]
    mov [ch2_glob], al
    xor al, al
    cmp byte [ch2_glob], 'A'
    jne .p4_done
    inc al
.p4_done:
    mov [bool_glob], al
    pop ax
    ret

proc_5:
    push ax
    push cx
    push si
    push di
    mov byte [ch1_glob], 'A'
    mov byte [bool_glob], 0
    mov si, string1
    mov di, string2
    mov cx, 16
    rep movsw
    pop di
    pop si
    pop cx
    pop ax
    ret

proc_6:
    push ax
    push bx
    mov ax, [enum_loc]
    mov bx, [record_a+4]
    cmp bx, 1
    jne .p6_not_one
    cmp ax, 1
    je .p6_store
    xor ax, ax
.p6_not_one:
    cmp bx, 2
    jne .p6_not_two
    mov ax, 2
.p6_not_two:
    test byte [bool_glob], 1
    jz .p6_store
    mov ax, 3
.p6_store:
    mov [enum_glob], ax
    mov [enum_loc], ax
    xor [checksum], ax
    pop bx
    pop ax
    ret

proc_7:
    push ax
    push bx
    mov ax, [int_loc1]
    add ax, 2
    mov bx, [int_loc2]
    add ax, bx
    mov [int_loc3], ax
    xor [checksum], ax
    pop bx
    pop ax
    ret

proc_8:
    push ax
    push bx
    push cx
    push di
    mov di, array1
    mov ax, [int_loc1]
    add ax, [int_loc2]
    mov bx, [enum_glob]
    mov cx, 16
.p8_loop:
    inc ax
    xor ax, bx
    stosw
    loop .p8_loop
    mov di, array2
    mov cx, 16
.p8_second:
    mov [di], ax
    add di, 2
    xor ax, 005Ah
    loop .p8_second
    xor [checksum], ax
    pop di
    pop cx
    pop bx
    pop ax
    ret

func_2:
    push ax
    push cx
    push si
    push di
    mov si, string1
    mov di, string2
    mov cx, 16
    repe cmpsw
    xor al, al
    jne .f2_done
    inc al
.f2_done:
    mov [bool_glob], al
    xor ah, ah
    add [checksum], ax
    pop di
    pop si
    pop cx
    pop ax
    ret

copy_string:
    push ax
    push cx
    push si
    push di
    mov cx, 16
    rep movsw
    pop di
    pop si
    pop cx
    pop ax
    ret

; ---------------------------- timing/output -----------------------------

read_ticks:
    push es
    mov dx, 0040h
    mov es, dx
    mov ax, [es:006Ch]
    mov dx, [es:006Eh]
    pop es
    ret

print_string:
    mov ah, 09h
    int 21h
    ret

print_u16:
    push bx
    push cx
    push dx
    xor cx, cx
    mov bx, 10
.divide:
    xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .divide
.emit:
    pop dx
    add dl, '0'
    mov ah, 02h
    int 21h
    loop .emit
    pop dx
    pop cx
    pop bx
    ret

print_hex16:
    push ax
    push bx
    push cx
    push dx
    mov bx, ax
    mov cx, 4
.hex_digit:
    rol bx, 4
    mov dl, bl
    and dl, 0Fh
    cmp dl, 10
    jb .numeric
    add dl, 'A'-10
    jmp short .emit_hex
.numeric:
    add dl, '0'
.emit_hex:
    mov ah, 02h
    int 21h
    loop .hex_digit
    pop dx
    pop cx
    pop bx
    pop ax
    ret

msg_banner      db 13,10,'SPK286 DHRYSTONE-21 DIRECTED TEST',13,10,'$'
msg_runs        db 'Runs: $'
msg_ticks       db 'Elapsed BIOS ticks: $'
msg_runs_tick   db 'Runs per tick: $'
msg_checksum    db 'Checksum: $'
msg_crlf        db 13,10,'$'

string_one      db 'DHRYSTONE PROGRAM, 1ST STRING',0
string_two      db 'DHRYSTONE PROGRAM, 2ND STRING',0

ptr_glob        dw 0
next_ptr_glob   dw 0
int_glob        dw 0
bool_glob       db 0
ch1_glob        db 0
ch2_glob        db 0
enum_glob       dw 0
int_loc1        dw 0
int_loc2        dw 0
int_loc3        dw 0
enum_loc        dw 0
checksum        dw 0
start_ticks_lo  dw 0
start_ticks_hi  dw 0
elapsed_ticks_lo dw 0
elapsed_ticks_hi dw 0

record_a        times 40 db 0
record_b        times 40 db 0
string1         times 32 db 0
string2         times 32 db 0
array1          times 256 db 0
array2          times 256 db 0
