; Portable CPU diagnostic, NASM 80286-only instructions.
; Terminal protected-mode program: photograph results, then reset the machine.
; No BIOS/DOS calls after PE=1. All test storage is inside this allocation.
cpu 286
bits 16
org 100h

%ifndef ROM_FLOW
%define ROM_FLOW 0
%endif
%ifndef BOOT
%define BOOT 0
%endif
%ifndef INJECT
%define INJECT 0
%endif
%define CODE 18h
%define DATA 20h
%define VIDEO 30h
%define LDT_A 38h
%define LDT_B 40h
%define TSS_A 48h
%define TSS_B 58h
%define TSS_MAIN 68h
%define GATE_A 78h
%define GATE_B 80h

%macro START 2
    mov bx,%1
    mov si,%2
    call start_test
%endmacro
%macro CHECK 2
    mov ax,%1
    mov dx,%2
    call check_word
%endmacro

start:
    cld
    push cs
    pop ds
%if !BOOT
    ; /S is a real-mode UI/loader smoke only; /? prints the same instructions.
    xor cx,cx
    mov cl,[80h]
    mov si,81h
.arg:
    jcxz .cpu
    lodsb
    and al,0dfh
    cmp al,'S'
    je smoke
    cmp al,'?'
    je smoke
    loop .arg
%endif
.cpu:
    ; 8086/186 cannot clear high FLAGS bits; 286+ can in real mode.
    pushf
    pop bx
    xor ax,ax
    push ax
    popf
    pushf
    pop ax
    push bx
    popf
    test ax,0f000h
    jnz unsupported
    smsw ax
    test ax,1
    jnz unsupported
    cli
    mov ax,cs
    mov ss,ax
    mov sp,main_stack_end
    ; Normalize real-mode NT/IF/DF before creating a protected context.
    push word 2
    popf
    mov ax,cs
    xor dx,dx
    mov cx,4
.base:
    shl ax,1
    rcl dx,1
    loop .base
    mov [image_base],ax
    mov [image_base+2],dx
    ; Determine text video aperture from BIOS data; keep the active mode.
    mov ax,40h
    mov es,ax
    mov ax,0b800h
    cmp byte [es:49h],7
    jne .color
    mov ax,0b000h
.color:
    mov [real_video],ax
    mov es,ax
    xor di,di
    mov ax,0720h
    mov cx,2000
    rep stosw
    mov si,title
    call puts
    mov si,variant
    call puts
    ; Build relocatable 286 descriptors without 32-bit instructions.
    mov si,relocations
.relocate:
    lodsw
    cmp ax,0ffffh
    je .relocated
    mov di,ax
    mov ax,[di+2]
    mov dl,[di+4]
    add ax,[image_base]
    adc dl,[image_base+2]
    mov [di+2],ax
    mov [di+4],dl
    jmp .relocate
.relocated:
    mov ax,[image_base]
    mov dx,[image_base+2]
    add ax,gdt
    adc dx,0
    mov [gdtr+2],ax
    mov [gdtr+4],dl
    mov ax,[image_base]
    mov dx,[image_base+2]
    add ax,idt
    adc dx,0
    mov [idtr+2],ax
    mov [idtr+4],dl
    mov ax,[real_video]
    mov cl,4
    shl ax,cl
    mov [gdt+VIDEO+2],ax
    ; Both B0000h and B8000h have high physical base byte 0Bh.
    mov byte [gdt+VIDEO+4],0bh
    sidt [old_idtr]
    sgdt [old_gdtr]

    START 1,t_tables
    mov si,patterns
    mov bp,4
.pattern:
    lodsw
    mov [table_in],ax
    mov [table_in+2],ax
    mov [table_in+4],ax
    lidt [table_in]
    lgdt [table_in]
    sidt [table_out]
    sgdt [table_out+6]
    ; 286 stores only five architecturally meaningful bytes, as ROM A53D.
    xor bx,bx
.compare:
    mov al,[table_in+bx]
    cmp al,[table_out+bx]
    jne real_table_fail
    cmp al,[table_out+bx+6]
    jne real_gdt_fail
    inc bx
    cmp bx,5
    jb .compare
    dec bp
    jnz .pattern
    lidt [old_idtr]
    CHECK 4,4
    START 2,t_enter
    lgdt [gdtr]
    lidt [idtr]
    smsw ax
    or ax,1
    lmsw ax
    jmp CODE:protected_entry

real_gdt_fail:
    add bx,6
real_table_fail:
    xor ah,ah
    mov dx,ax
    mov al,[table_out+bx]
    lidt [old_idtr]
    lgdt [old_gdtr]
    call check_word
    jmp terminal

unsupported:
%if !BOOT
    mov dx,unsupported_msg
    mov ah,9
    int 21h
    mov ax,4c02h
    int 21h
%else
    jmp terminal
%endif
smoke:
%if !BOOT
    mov dx,smoke_msg
    mov ah,9
    int 21h
    mov ax,4c00h
    int 21h
%endif
    jmp terminal

protected_entry:
    mov ax,DATA
    mov ds,ax
    mov ss,ax
    mov es,ax
    mov sp,main_stack_end
    mov byte [pm_active],1
    smsw ax
    and ax,1
    CHECK ax,1

    START 3,t_ldt
    mov ax,LDT_B
    lldt ax
    sldt ax
    CHECK ax,LDT_B
    START 4,t_ldt_a
    mov ax,LDT_A
    lldt ax
    sldt ax
    CHECK ax,LDT_A

    START 5,t_ltr
    mov ax,TSS_B
    ltr ax
    str ax
    CHECK ax,TSS_B
    START 6,t_ltr_a
    mov ax,TSS_A
    ltr ax
    str ax
    CHECK ax,TSS_A
    ; ROM rewrites the former descriptors available before the task call.
    mov byte [gdt+TSS_A+5],81h
    mov byte [gdt+TSS_B+5],81h
    mov ax,TSS_MAIN
    ltr ax

    START 7,t_sticky
    xor ax,ax
    lmsw ax
    smsw ax
    and ax,1
    CHECK ax,1

    START 8,t_limit
    mov ax,0ch
    mov es,ax
    mov word [expected_ip],limit_fault
    mov word [resume_ip],limit_resume
    mov byte [expect_gp],1
limit_fault:
    mov ax,[es:4]                 ; LDT data descriptor limit=3 -> #GP(0).
limit_resume:
    mov ax,DATA
    mov es,ax
    mov byte [expect_gp],0
    CHECK [caught_gp],1

    START 17,t_clts
    smsw ax
    or ax,8
    lmsw ax
    clts
    smsw ax
    and ax,8
    CHECK ax,0

    START 18,t_direct_call
    ; Independent control: direct TSS, not a task gate. CS=0004 is retained.
    mov byte [simple_call],1
    call TSS_A:0
    CHECK [simple_seen],1
    START 10,t_call_nt
    mov ax,[first_flags]
    and ax,4000h
    CHECK ax,4000h
    START 11,t_link
    CHECK [task_a],TSS_MAIN
    START 12,t_busy
    xor ax,ax
    mov al,[gdt+TSS_A+5]
    and ax,0fh
    CHECK ax,1

    call reset_tasks
    mov byte [use_gates],0
    mov byte [active_block],1
    START 13,t_direct_loop
    call TSS_A:0
    mov ax,[data_a+2]
    add ax,[data_b+2]
    CHECK ax,50
direct_results:
    ; A captured direct-loop failure reaches here WITHOUT counting a return as
    ; successful. Register/FLAGS recovery below is setup, not test evidence.
    mov byte [active_block],0
    START 14,t_counts
    CHECK [data_a+2],25
    START 15,t_counts_b
    CHECK [data_b+2],25
    START 16,t_data
    CHECK [task_error],0
    START 19,t_return_tr
    str ax
    CHECK ax,TSS_MAIN
    mov si,direct_nt_msg
    call flag_observations

    ; If IRET failed (or incorrectly returned without switching tasks), restore
    ; a known supervisor task so the final, independent gate test can still run.
    ; Its original TSS was saved by the direct CALL; do not use POPF to repair NT.
    str ax
    cmp ax,TSS_MAIN
    je final_gate_setup
    mov word [task_main+0eh],final_gate_setup
    mov word [task_main+10h],2
    mov word [task_main+1ah],main_stack_end
    mov word [task_main+22h],DATA
    mov word [task_main+24h],CODE
    mov word [task_main+26h],DATA
    mov word [task_main+28h],DATA
    mov word [task_main+2ah],LDT_A
    mov byte [gdt+TSS_MAIN+5],81h
    jmp TSS_MAIN:0

final_gate_setup:
    mov ax,DATA
    mov ds,ax
    mov es,ax
    mov ss,ax
    mov sp,main_stack_end
    call reset_tasks
    mov byte [use_gates],1
    mov byte [active_block],2
%if INJECT == 3
    ; Negative ordering fixture: rejection of the final gate, not an 86Box fix.
    mov byte [gdt+GATE_A+5],80h
%endif
    START 9,t_gates
    ; The LAST test retains the original gate-based CALL/JMP/IRET sequence.
    call GATE_A:0
    xor ax,ax
    cmp word [data_a+2],25
    jne .gate_checked
    cmp word [data_b+2],25
    jne .gate_checked
    cmp word [task_error],0
    jne .gate_checked
    str bx
    cmp bx,TSS_MAIN
    jne .gate_checked
    inc ax
.gate_checked:
    CHECK ax,1
    mov si,done_msg
    call puts
    mov ax,[failures]
    call hex_word
    call newline
    call observations
    jmp terminal

reset_tasks:
    push ds
    pop es
    mov si,task_a_initial
    mov di,task_a
    mov cx,44
    rep movsb
    mov si,task_b_initial
    mov di,task_b
    mov cx,44
    rep movsb
    mov byte [gdt+TSS_A+5],81h
    mov byte [gdt+TSS_B+5],81h
    mov byte [ldt_a+5],9ah
    mov byte [ldt_b+5],9ah
    mov byte [simple_call],0
    mov word [first_flags],0
    mov word [jmp_flags],0
    mov word [iret_flags],0
    mov word [control_flags],0ffffh
    mov word [data_a],1
    mov word [data_a+2],0
    mov word [data_b],2
    mov word [data_b+2],0
    mov word [task_error],0
%if INJECT == 1
    mov word [data_b],3           ; Deliberate test-data fault, never production.
%endif
%if INJECT == 2
    mov byte [ldt_a+5],1ah       ; Deliberate non-present CS fault.
%endif
    ret

; Separately based task code segments: IP starts at zero in each LDT.
; Functional translation of ROM A4F1/A51A, not a redistributed ROM image.
task_code_a:
    pushf
    pop ax
    mov [es:first_flags],ax
    cmp byte [es:simple_call],0
    je .loop
    mov word [es:simple_seen],1
    iret
.loop:
    xor bx,bx
    cmp word [bx],1
    jne .bad
    cmp word [bx+2],25
    jge .return
    inc word [bx+2]
    ; Original ROM performs two 65536-iteration LOOP delays here.
    ; They are omitted: this diagnostic measures functional behavior only.
    cmp byte [es:use_gates],0
    jne .gate_jump
    jmp TSS_B:0
    jmp .resumed
.gate_jump:
    jmp GATE_B:0
.resumed:
    pushf
    pop ax
    mov [es:jmp_flags],ax
    jmp .loop
.bad:
    mov word [es:task_error],0ffffh
.return:
    pushf
    pop ax
    mov [es:iret_flags],ax
%if !ROM_FLOW
    ; Control makes the intended nested return explicit after the JMP chain.
    or ax,4000h
    push ax
    popf
    pushf
    pop ax
    mov [es:control_flags],ax
%endif
    iret
task_code_a_end:

task_code_b:
.loop:
    xor bx,bx
    cmp word [bx],2
    jne .bad
    inc word [bx+2]
    cmp byte [es:use_gates],0
    jne .gate_jump
    jmp TSS_A:0
    jmp .loop
.gate_jump:
    jmp GATE_A:0
    jmp .loop
.bad:
    mov word [es:task_error],0ffffh
    ; A failing data check must report rather than rely on a bogus stack frame.
    jmp CODE:task_data_fail
task_code_b_end:

task_data_fail:
    mov ax,DATA
    mov ds,ax
    mov ss,ax
    mov sp,main_stack_end
    mov ax,[task_error]
    xor dx,dx
    call check_word
    cmp byte [active_block],1
    je direct_results
    call observations
    jmp terminal

; IDT stubs normalize every frame to vector,error,IP,CS,FLAGS.
%assign vec 0
%rep 32
exception_%+vec:
%if vec != 8 && vec != 10 && vec != 11 && vec != 12 && vec != 13
    push word 0
%endif
    push word vec
    jmp exception_common
%assign vec vec+1
%endrep
exception_common:
    push ds
    push es
    pusha
    mov bp,sp
    mov ax,DATA
    mov ds,ax
    mov ax,[ss:bp+20]
    mov [fault_vector],ax
    mov ax,[ss:bp+22]
    mov [fault_error],ax
    mov ax,[ss:bp+24]
    mov [fault_ip],ax
    mov ax,[ss:bp+26]
    mov [fault_cs],ax
    mov ax,[ss:bp+28]
    mov [fault_flags],ax
    str [fault_tr]
    sldt [fault_ldt]
    smsw [fault_msw]
    cmp byte [expect_gp],1
    jne .unexpected
    cmp word [fault_vector],13
    jne .unexpected
    cmp word [fault_error],0
    jne .unexpected
    cmp word [fault_cs],CODE
    jne .unexpected
    mov ax,[expected_ip]
    cmp [fault_ip],ax
    jne .unexpected
    inc word [caught_gp]
    mov ax,[resume_ip]
    mov [ss:bp+24],ax
    popa
    pop es
    pop ds
    add sp,4
    iret
.unexpected:
    mov ax,DATA
    mov ss,ax
    mov sp,main_stack_end
    inc word [failures]
    mov si,fault_msg
    call puts
    mov ax,[fault_vector]
    call hex_word
    mov si,err_msg
    call puts
    mov ax,[fault_error]
    call hex_word
    mov si,at_msg
    call puts
    mov ax,[fault_cs]
    call hex_word
    mov al,':'
    call putc
    mov ax,[fault_ip]
    call hex_word
    call newline
    cmp byte [active_block],1
    je .direct_abort
    mov si,context_msg
    call puts
    mov ax,[fault_flags]
    call hex_word
    mov al,' '
    call putc
    mov ax,[fault_tr]
    call hex_word
    mov al,' '
    call putc
    mov ax,[fault_ldt]
    call hex_word
    mov al,' '
    call putc
    mov ax,[fault_msw]
    call hex_word
    call newline
    call observations
    jmp terminal
.direct_abort:
    mov ax,DATA
    mov es,ax
    ; Only the isolated direct-loop block is recoverable. The failed test has
    ; already printed EXCEPTION and incremented failures; no IRET is claimed.
    jmp CODE:direct_results

start_test:
    mov [current_test],bx
    mov al,'T'
    call putc
    mov ax,bx
    call hex_word
    mov al,' '
    call putc
    call puts
    ret
check_word:
    push ax
    push dx
    cmp ax,dx
    je .pass
    inc word [failures]
    mov si,fail_msg
    jmp .print
.pass:
    mov si,pass_msg
.print:
    call puts
    pop dx
    pop ax
    call hex_word
    push ax
    mov al,'/'
    call putc
    mov ax,dx
    call hex_word
    call newline
    pop ax
    ret
observations:
    mov si,nt_msg
    call flag_observations
    mov si,count_msg
    call puts
    mov ax,[data_a+2]
    call hex_word
    mov al,' '
    call putc
    mov ax,[data_b+2]
    call hex_word
    call newline
    ret
flag_observations:
    call puts
    mov ax,[first_flags]
    call hex_word
    mov al,' '
    call putc
    mov ax,[jmp_flags]
    call hex_word
    mov al,' '
    call putc
    mov ax,[iret_flags]
    call hex_word
    mov al,' '
    call putc
    mov ax,[control_flags]
    call hex_word
    call newline
    ret
puts:
    push ax
    push si
.next:
    lodsb
    test al,al
    jz .end
    call putc
    jmp .next
.end:
    pop si
    pop ax
    ret
hex_word:
    pusha
    mov bx,ax
    mov cx,4
.digit:
    rol bx,4
    mov al,bl
    and al,15
    add al,'0'
    cmp al,'9'
    jbe .emit
    add al,7
.emit:
    call putc
    loop .digit
    popa
    ret
newline:
    push ax
    mov al,13
    call putc
    mov al,10
    call putc
    pop ax
    ret
putc:
    pusha
    push es
    ; QEMU/Bochs debug port is an optional passive text sink.
    out 0e9h,al
    mov dx,[real_video]
    cmp byte [pm_active],0
    je .video
    mov dx,VIDEO
.video:
    mov es,dx
    mov di,[cursor]
    cmp al,13
    je .end
    cmp al,10
    je .newline
    mov ah,7
    stosw
    jmp .position
.newline:
    mov ax,di
    xor dx,dx
    mov bx,160
    div bx
    inc ax
    mul bx
    mov di,ax
.position:
    cmp di,4000
    jb .save
    ; Scroll one row, preserving data segment and all caller registers.
    push ds
    push es
    pop ds
    mov si,160
    xor di,di
    mov cx,1920
    rep movsw
    mov cx,80
    mov ax,0720h
    rep stosw
    pop ds
    mov di,3840
.save:
    mov [cursor],di
.end:
    pop es
    popa
    ret
terminal:
    cli
    hlt
    jmp terminal

align 8,db 0
%macro DESC 3
    dw %2,%1
    db 0,%3
    dw 0
%endmacro
gdt:
    dq 0                         ; 00 null
    DESC gdt,97h,92h             ; 08 GDT alias
    DESC idt,255,92h             ; 10 IDT alias
    DESC 0,0ffffh,9ah            ; 18 common code
    DESC 0,0ffffh,92h            ; 20 common data/stack
    dq 0                         ; 28 unused
    DESC 0,0ffffh,92h            ; 30 video (patched separately)
    DESC ldt_a,10h,82h           ; 38 first LDT (original limit 10h)
    DESC ldt_b,10h,82h           ; 40 second LDT
    DESC task_a,68h,81h          ; 48 first TSS (original limit 68h)
    DESC task_a,68h,92h          ; 50 TSS alias
    DESC task_b,68h,81h          ; 58 second TSS
    DESC task_b,68h,92h          ; 60 TSS alias
    DESC task_main,68h,81h       ; 68 caller TSS
    DESC task_main,68h,92h       ; 70 TSS alias
    dw 0,TSS_A,8500h,0           ; 78 task gate
    dw 0,TSS_B,8500h,0           ; 80 task gate
    DESC data_a,7,92h            ; 88 shared counters
    DESC 0,0ffffh,92h            ; 90 common data alias
gdt_end:
ldt_a:
    DESC task_code_a,task_code_a_end-task_code_a-1,9ah
    DESC data_a,3,92h
    db 0
ldt_b:
    DESC task_code_b,task_code_b_end-task_code_b-1,9ah
    DESC data_b,3,92h
    db 0
%macro TSS 2
    dw 0,%1,DATA,0,0,0,0         ; link + ring stacks
    dw 0,2                       ; IP, FLAGS
    dw 0,0,0,0,%1,1000h,0,0      ; AX CX DX BX SP BP SI DI
    dw DATA,4,DATA,0ch,%2        ; ES CS SS DS LDTR
%endmacro
task_a: TSS task_stack_a_end,LDT_A
task_b: TSS task_stack_b_end,LDT_B
task_main: times 106 db 0
task_a_initial: TSS task_stack_a_end,LDT_A
task_b_initial: TSS task_stack_b_end,LDT_B
idt:
%assign vec 0
%rep 32
    dw exception_%+vec,CODE,8600h,0
%assign vec vec+1
%endrep
gdtr: dw gdt_end-gdt-1,0,0
idtr: dw 255,0,0
relocations:
    dw gdt+8,gdt+10h,gdt+18h,gdt+20h,gdt+38h,gdt+40h
    dw gdt+48h,gdt+50h,gdt+58h,gdt+60h,gdt+68h,gdt+70h,gdt+88h,gdt+90h
    dw ldt_a,ldt_a+8,ldt_b,ldt_b+8,0ffffh
image_base: dd 0
old_idtr: times 6 db 0
old_gdtr: times 6 db 0
table_in: times 6 db 0
table_out: times 12 db 0
patterns: dw 0,0ffffh,5555h,0aaaah
data_a: dw 1,0
data_b: dw 2,0
task_error: dw 0
real_video: dw 0b800h
cursor: dw 0
current_test: dw 0
failures: dw 0
pm_active: db 0
simple_call: db 0
use_gates: db 0
active_block: db 0
simple_seen: dw 0
first_flags: dw 0
jmp_flags: dw 0
iret_flags: dw 0
control_flags: dw 0ffffh
expect_gp: db 0
caught_gp: dw 0
expected_ip: dw 0
resume_ip: dw 0
fault_vector: dw 0
fault_error: dw 0
fault_ip: dw 0
fault_cs: dw 0
fault_flags: dw 0
fault_tr: dw 0
fault_ldt: dw 0
fault_msw: dw 0
title: db 'SPK286 PM v0.2 - 80286 instructions; hex actual/expected',13,10,0
%if ROM_FLOW
variant: db 'PMROM v0.2: implicit NT; task gates LAST. RESET afterwards.',13,10,0
%else
variant: db 'PM286 v0.2: explicit NT; task gates LAST. RESET afterwards.',13,10,0
%endif
pass_msg: db ' PASS ',0
fail_msg: db ' FAIL ',0
done_msg: db 'COMPLETE failures=',0
fault_msg: db ' EXCEPTION vector=',0
err_msg: db ' error=',0
at_msg: db ' at=',0
context_msg: db 'FLAGS/TR/LDT/MSW: ',0
direct_nt_msg: db 'DIRECT FLAGS CALL/JMP/preIRET/POPF: ',0
nt_msg: db 'GATES FLAGS CALL/JMP/preIRET/POPF: ',0
count_msg: db 'Task counters A/B (expected 0019/0019): ',0
t_tables: db 'GDTR/IDTR four patterns',0
t_enter: db 'LMSW + far JMP entry',0
t_ldt: db 'LLDT/SLDT second table',0
t_ldt_a: db 'LLDT/SLDT first table',0
t_ltr: db 'LTR/STR second task',0
t_ltr_a: db 'LTR/STR first task',0
t_sticky: db 'LMSW cannot clear PE',0
t_limit: db 'LDT data limit #GP(0)',0
t_direct_call: db 'TSS-direct CALL/IRET',0
t_direct_loop: db 'TSS LOOP control',0
t_gates: db 'Superdiag GATES',0
t_return_tr: db 'TSS return restores TR',0
t_call_nt: db 'CALL sets FLAGS.NT',0
t_link: db 'CALL backlink',0
t_busy: db 'IRET clears task BUSY',0
t_counts: db 'First task count',0
t_counts_b: db 'Second task count',0
t_data: db 'Task data/base integrity',0
t_clts: db 'CLTS clears TS',0
smoke_msg: db 'SPK286 PM diagnostic v0.2',13,10
    db 'Direct-TSS controls first; original task-gate chain is LAST (T0009).',13,10
    db 'PM286 sets NT explicitly. PMROM retains the ROM NT dependency.',13,10
    db 'Use clean real-mode DOS on a 286+. No EMM386, Windows or DPMI.',13,10
    db 'Execution takes over the CPU and HALTS. Record the screen, then RESET.',13,10
    db '/S only tests DOS loading/output; NO protected-mode tests run.',13,10
    db 'PM286 UI SMOKE PASS',13,10,'$'
unsupported_msg: db 'Requires a 286+ running in real mode. No PM tests executed.',13,10,'$'
align 2,db 0
task_stack_a: times 512 db 0
task_stack_a_end:
task_stack_b: times 512 db 0
task_stack_b_end:
main_stack: times 1024 db 0
main_stack_end:
%if ($-$$) > 0ef00h
%error Diagnostic must fit inside one DOS COM allocation.
%endif
