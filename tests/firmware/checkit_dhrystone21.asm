; Dhrystone 2.x-shaped directed workload for SPK286.
;
; This is a clean-room 16-bit assembly workload, not a copy of CheckIt or of
; a copyrighted source distribution.  It follows the classic Dhrystone
; operation shape: two linked records, discriminated fields, Proc_1..Proc_8,
; Func_1/Func_2-style character/string tests, arrays and enum branches.  It
; uses deterministic fixed addresses so the RTL bench can compare P02 and P03.

bits 16
cpu 286
org 0

%define PTR_GLOB       0x5000
%define NEXT_PTR_GLOB  0x5002
%define INT_GLOB       0x5004
%define BOOL_GLOB      0x5006
%define CH1_GLOB       0x5008
%define CH2_GLOB       0x5009
%define ENUM_GLOB      0x500A
%define INT_LOC1       0x5010
%define INT_LOC2       0x5012
%define INT_LOC3       0x5014
%define ENUM_LOC       0x5016
%define STRING1        0x5100
%define STRING2        0x5140
%define REC_GLOB       0x5200
%define REC_NEXT       0x5240
%define ARR1           0x6000
%define ARR2           0x7000

    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    ; Pointer globals and the two 40-byte records.
    mov word [PTR_GLOB], REC_GLOB
    mov word [NEXT_PTR_GLOB], REC_NEXT
    mov word [REC_GLOB+0], REC_NEXT
    mov word [REC_GLOB+2], 0
    mov word [REC_GLOB+4], 1
    mov word [REC_GLOB+6], 40
    mov word [REC_NEXT+0], REC_GLOB
    mov word [REC_NEXT+2], 1
    mov word [REC_NEXT+4], 2
    mov word [REC_NEXT+6], 30
    mov word [INT_GLOB], 0
    mov byte [BOOL_GLOB], 0
    mov byte [CH1_GLOB], 'A'
    mov byte [CH2_GLOB], 'B'
    mov word [ENUM_GLOB], 2
    mov word [INT_LOC1], 2
    mov word [INT_LOC2], 3
    mov word [ENUM_LOC], 1

    mov si, string_one
    mov di, STRING1
    call copy_string
    mov si, string_two
    mov di, STRING2
    call copy_string
    jmp stage1

string_one db 'DHRYSTONE PROGRAM, 1ST STRING', 0
string_two db 'DHRYSTONE PROGRAM, 2ND STRING', 0

times 0x100-($-$$) db 0x90
stage1:
    ; The classic main loop repeats a mixed procedure/record workload.
    mov cx, 128
.run_loop:
    call proc_5
    call proc_4
    mov word [INT_LOC1], 2
    mov word [INT_LOC2], 3
    mov word [ENUM_LOC], 1
    call func_2
    mov [BOOL_GLOB], al
    call proc_7
    call proc_8
    call proc_1
    call proc_6
    call proc_3
    call proc_2
    loop .run_loop
    jmp stage2

times 0x200-($-$$) db 0x90
stage2:
    ; Array/record tail resembling the post-loop validation and repeated
    ; accesses in the original benchmark family.
    mov si, ARR1
    mov di, ARR2
    mov cx, 256
.array_loop:
    lodsw
    xor ax, [INT_GLOB]
    add ax, [ENUM_GLOB]
    stosw
    loop .array_loop
    mov si, STRING1
    mov di, STRING2
    mov cx, 16
    repe cmpsw
    mov ax, [REC_GLOB+6]
    add ax, [REC_NEXT+6]
    mov [INT_GLOB], ax
    jmp stage3

times 0x300-($-$$) db 0x90
stage3:
    mov cx, 64
.record_tail:
    call proc_1
    call proc_3
    mov ax, [REC_GLOB+6]
    xor ax, [REC_NEXT+6]
    add [INT_GLOB], ax
    loop .record_tail
    jmp stage4

times 0x400-($-$$) db 0x90
stage4:
    mov cx, 64
    mov bx, 5
.integer_tail:
    mov ax, [INT_GLOB]
    mul bx
    xor ax, dx
    xor dx, dx
    div bx
    add ax, [INT_LOC1]
    mov [INT_GLOB], ax
    call func_1
    loop .integer_tail
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

; Proc_1: dereference and update a linked record, then copy a discriminated
; variant field into the next record.
proc_1:
    push ax
    push bx
    push si
    push di
    mov si, [PTR_GLOB]
    mov di, [si+0]
    mov ax, [si+6]
    add ax, 1
    mov [si+6], ax
    mov bx, [di+6]
    add bx, ax
    mov [di+6], bx
    mov ax, [si+2]
    cmp ax, 0
    jne .p1_variant
    mov word [di+4], 2
.p1_variant:
    mov ax, [si+4]
    mov [di+4], ax
    pop di
    pop si
    pop bx
    pop ax
    ret

; Proc_2: integer loop with a character condition and global update.
proc_2:
    push ax
    push bx
    push cx
    mov ax, [INT_LOC1]
    mov bx, [INT_LOC2]
    mov cx, 3
.p2_loop:
    add ax, bx
    sub ax, 1
    cmp byte [CH1_GLOB], 'A'
    jne .p2_next
    inc ax
.p2_next:
    loop .p2_loop
    mov [INT_LOC1], ax
    mov [INT_GLOB], ax
    pop cx
    pop bx
    pop ax
    ret

; Proc_3: follow the global pointer and update its integer component.
proc_3:
    push ax
    push bx
    push si
    mov si, [PTR_GLOB]
    mov bx, [si+0]
    mov ax, [bx+6]
    xor ax, [INT_GLOB]
    mov [si+6], ax
    mov [PTR_GLOB], bx
    pop si
    pop bx
    pop ax
    ret

; Proc_4: set character globals and a boolean expression.
proc_4:
    push ax
    mov al, [CH1_GLOB]
    mov [CH2_GLOB], al
    xor al, al
    cmp byte [CH2_GLOB], 'A'
    jne .p4_not_equal
    inc al
.p4_not_equal:
    mov [BOOL_GLOB], al
    pop ax
    ret

; Proc_5: reset character/string state at the start of a run.
proc_5:
    push ax
    push cx
    push si
    push di
    mov byte [CH1_GLOB], 'A'
    mov byte [BOOL_GLOB], 0
    mov si, STRING1
    mov di, STRING2
    mov cx, 16
    rep movsw
    pop di
    pop si
    pop cx
    pop ax
    ret

; Proc_6: enum selection with the same switch-like branches as Dhrystone.
proc_6:
    push ax
    push bx
    mov ax, [ENUM_LOC]
    mov bx, [REC_GLOB+4]
    cmp bx, 1
    jne .p6_not_one
    cmp ax, 1
    je .p6_store
    mov ax, 0
.p6_not_one:
    cmp bx, 2
    jne .p6_not_two
    mov ax, 2
.p6_not_two:
    test byte [BOOL_GLOB], 1
    jz .p6_store
    mov ax, 3
.p6_store:
    mov [ENUM_GLOB], ax
    mov [ENUM_LOC], ax
    pop bx
    pop ax
    ret

; Proc_7: arithmetic helper with two input integers and one result.
proc_7:
    push ax
    push bx
    mov ax, [INT_LOC1]
    add ax, 2
    mov bx, [INT_LOC2]
    add ax, bx
    mov [INT_LOC3], ax
    pop bx
    pop ax
    ret

; Proc_8: array indexing and repeated two-dimensional-like stores.
proc_8:
    push ax
    push bx
    push cx
    push di
    mov di, ARR1
    mov ax, [INT_LOC1]
    mov bx, [INT_LOC2]
    add ax, bx
    ; Proc_8 in classic Dhrystone touches a small window of each array on
    ; every iteration; keep the window large enough to exercise memory without
    ; turning this directed test into a bulk-copy benchmark.
    mov cx, 32
.p8_loop:
    add ax, 1
    xor ax, [ENUM_GLOB]
    stosw
    loop .p8_loop
    mov di, ARR2
    mov cx, 32
.p8_second:
    mov [di], ax
    add di, 2
    xor ax, 0x005A
    loop .p8_second
    pop di
    pop cx
    pop bx
    pop ax
    ret

; Func_1: character comparison returning an enum-like result in AL.
func_1:
    push bx
    mov al, [CH1_GLOB]
    mov bl, [CH2_GLOB]
    cmp al, bl
    xor al, al
    jne .f1_done
    inc al
.f1_done:
    pop bx
    ret

; Func_2: short string comparison and integer/character decision path.
func_2:
    push ax
    push cx
    push si
    push di
    mov si, STRING1
    mov di, STRING2
    mov cx, 16
    repe cmpsw
    xor al, al
    jne .f2_done
    inc al
.f2_done:
    mov [BOOL_GLOB], al
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

times 0xFFF0-($-$$) db 0xFF
    jmp 0xF000:0
times 65536-($-$$) db 0xFF
