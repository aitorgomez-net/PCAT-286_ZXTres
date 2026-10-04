; T286REF: fixed-work real-mode timing reference, DOS .COM, 8086 instructions.
; Assemble with NASM -f bin. No PIT divisor/mode or PIC programming occurs.
bits 16
cpu 8086
org 100h

%define ITERATIONS 256
%define REPETITIONS 7
%define WINDOW_LOW 8192
%define WINDOW_HIGH 16384
%define MAX_TICKS 10000
%define POLL_LIMIT 32768

start:
    push cs
    pop ds
    pushf
    pop ax
    mov [entry_flags], ax
    cli
    mov ax, cs
    mov ss, ax
    mov sp, stack_top
    push word [entry_flags]
    popf
    cld
    test word [entry_flags], 0200h
    jnz .if_ok
    sti                      ; unsupported entry: DOS must not run under CLI
    mov dx, err_if
    jmp fatal
.if_ok:
    ; The first command-tail token is metadata, never a loop calibrator.
    xor cx, cx
    mov cl, [80h]
    mov si, 81h
    mov di, nominal
.skip:
    jcxz .default
    lodsb
    dec cx
    cmp al, ' '
    je .skip
    mov bx, 16
.copy:
    cmp al, ' '
    jbe .end_token
    cmp al, ','
    je .bad_token
    cmp al, '$'
    je .bad_token
    stosb
    dec bx
    jz .end_token
    jcxz .end_token
    lodsb
    dec cx
    jmp .copy
.bad_token:
    mov dx, err_label
    jmp fatal
.default:
    mov si, unknown_label
    mov cx, 7
    rep movsb
.end_token:
    mov byte [di], '$'
    mov dx, banner
    call puts
    mov dx, meta_nominal
    call puts
    mov dx, nominal
    call puts
    call newline
    mov dx, meta_segment
    call puts
    mov ax, cs
    call decimal
    call newline
    mov dx, meta_address
    call puts
    mov ax, data_words
    call decimal
    call newline
    call pit_probe
    jc .timer_bad
    mov dx, meta_mode
    call puts
    xor ax, ax
    mov al, [pit_mode]
    call decimal
    call newline
    mov dx, meta_status
    call puts
    xor ax, ax
    mov al, [pit_status]
    call decimal
    call newline
    mov dx, meta_probe_max
    call puts
    mov ax, [probe_max]
    call decimal
    call newline
    mov dx, meta_probe_zero
    call puts
    xor ax, ax
    mov al, [probe_zero]
    call decimal
    call newline
    mov dx, headers
    call puts
    mov byte [case_index], 0
.case:
    mov byte [kind_index], 0
.kind:
    mov byte [rep_index], 0
.repeat:
    mov word [data_words], 1234h
    mov word [data_words+2], 5678h
    mov word [data_words+4], 0
    mov word [data_words+6], 3c3ch
    mov word [kernel_ptr], kernel_baseline
    cmp byte [kind_index], 0
    je .selected
    xor bx, bx
    mov bl, [case_index]
    shl bx, 1
    mov ax, [kernel_table+bx]
    mov [kernel_ptr], ax
.selected:
    call measure
    jc .sample_bad
    ; Stored before the end latch, with identical overhead for every sample.
    cmp word [result_cx], 0
    jne .functional_bad
    cmp word [result_dx], 9abch
    jne .functional_bad
    cmp word [result_di], 0def0h
    jne .functional_bad
    mov ax, 1234h
    mov bx, 5678h
    cmp byte [kind_index], 0
    je .check_registers
    cmp byte [case_index], 0
    jne .other_case
    mov ax, 09b4h
    mov bx, 5778h
    jmp short .check_registers
.other_case:
    cmp byte [case_index], 2
    jne .check_registers
    mov ax, 68ach
.check_registers:
    cmp ax, [result_ax]
    jne .functional_bad
    cmp bx, [result_bx]
    jne .functional_bad
    cmp byte [case_index], 2
    jne .functional_ok
    cmp byte [kind_index], 1
    jne .functional_ok
    cmp word [data_words+4], 68ach
    jne .functional_bad
    cmp word [data_words+6], 3c3ch
    jne .functional_bad
.functional_ok:
    xor bx, bx
    mov bl, [rep_index]
    shl bx, 1
    mov ax, [sample_ticks]
    mov [ticks+bx], ax
    call emit_sample
    inc byte [rep_index]
    cmp byte [rep_index], REPETITIONS
    jb .repeat
    call emit_summary
    inc byte [kind_index]
    cmp byte [kind_index], 2
    jb .kind
    inc byte [case_index]
    cmp byte [case_index], 3
    jb .case
    mov dx, done
    call puts
    mov ax, 4c00h
    int 21h
.timer_bad:
    mov dx, err_timer
    jmp fatal
.sample_bad:
    mov dx, err_window
    jmp fatal
.functional_bad:
    mov dx, err_function
    jmp fatal

; Coherent counter0 status+count: Intel8254 Read-Back 11000010b.
; The status is returned before the low and high count bytes. Atomic even if
; called with IF=1. Preserve the caller's flags (including IF), BX/CX/SI/DI.
pit_read:
    pushf
    cli
    mov al, 0c2h
    out 43h, al
    jmp short .delay0
.delay0:
    in al, 40h
    mov dl, al
    jmp short .delay1
.delay1:
    in al, 40h
    mov ah, al
    jmp short .delay2
.delay2:
    in al, 40h
    xchg al, ah
    popf
    ret

; AX=count, DL=status. CF=error. Neither changes the timer nor reads a divisor.
pit_validate:
    push bx
    mov bl, dl
    and bl, 7fh
    cmp bl, [pit_status]
    jne .bad
    cmp byte [pit_mode], 3
    jne .ok
    test ax, 1
    jnz .bad
.ok:
    pop bx
    clc
    ret
.bad:
    pop bx
    stc
    ret

; AX=count, DL=status -> BX=phase in PIT input ticks, conditional on the
; documented EVEN divisor65536 assumption. In mode3 CE decreases by2 and
; reloads at both OUT edges: (-count mod65536)/2 + (OUT ? 0 : 32768).
pit_phase:
    mov bx, ax
    neg bx
    cmp byte [pit_mode], 3
    jne .done
    shr bx, 1
    test dl, 80h
    jnz .done
    or bx, 8000h
.done:
    ret

; Observe mode/status, two mode3 OUT transitions or two mode2 reloads, and
; a count near65536. IF stays enabled between each atomic read-back. This
; compatibility probe does NOT establish the exact programmed reload value.
pit_probe:
    call pit_read
    mov bl, dl
    and bl, 71h             ; null0, RW=LSB/MSB, binary
    cmp bl, 30h
    jne .bad
    mov bl, dl
    and bl, 7fh
    mov [pit_status], bl
    mov bl, dl
    shr bl, 1
    and bl, 3               ; Intel modes6/7 alias2/3
    cmp bl, 2
    jb .bad
    mov [pit_mode], bl
    mov [probe_previous_count], ax
    mov [probe_previous_status], dl
    mov cx, POLL_LIMIT
.loop:
    call pit_read
    call pit_validate
    jc .bad
    or ax, ax
    jnz .nonzero
    mov byte [probe_zero], 1
.nonzero:
    cmp ax, [probe_max]
    jbe .edges
    mov [probe_max], ax
.edges:
    cmp byte [pit_mode], 3
    jne .mode2
    mov bl, dl
    xor bl, [probe_previous_status]
    test bl, 80h
    jz .no_edge
    inc byte [probe_edges]
    jmp short .no_edge
.mode2:
    cmp ax, [probe_previous_count]
    jbe .no_edge
    inc byte [probe_edges]
.no_edge:
    mov [probe_previous_count], ax
    mov [probe_previous_status], dl
    cmp byte [probe_edges], 2
    jae .observed
    loop .loop
    jmp short .bad
.observed:
    cmp byte [probe_zero], 1
    je .ok
    cmp word [probe_max], 0ff00h
    jb .bad
.ok:
    clc
    ret
.bad:
    stc
    ret

; Start away from IRQ0 and the mode3 half-period reload. IF is enabled during
; polling; the timed CLI interval has a fixed256-iteration kernel. Post-check
; requires an increasing phase and <=10000ticks, without a half-period edge.
; An abnormally stalled interval spanning whole periods cannot be certified
; from endpoints alone; README explicitly excludes that unsupported case.
measure:
    mov cx, POLL_LIMIT
.wait:
    call pit_read
    call pit_validate
    jc .bad
    call pit_phase
    cmp bx, WINDOW_LOW
    jb .next
    cmp bx, WINDOW_HIGH
    jb .start
.next:
    loop .wait
.bad:
    stc
    ret
.start:
    pushf
    cli
    call pit_read
    call pit_validate
    jc .abort
    call pit_phase
    cmp bx, WINDOW_LOW
    jb .abort
    cmp bx, WINDOW_HIGH
    jae .abort
    mov [start_count], ax
    mov [start_status], dl
    mov [start_phase], bx
    mov ax, 1234h
    mov bx, 5678h
    mov dx, 9abch
    mov di, 0def0h
    mov cx, ITERATIONS
    call word [kernel_ptr]
    mov [result_ax], ax
    mov [result_bx], bx
    mov [result_cx], cx
    mov [result_dx], dx
    mov [result_di], di
    call pit_read
    mov [end_count], ax
    mov [end_status], dl
    call pit_validate
    jc .abort
    call pit_phase
    mov [end_phase], bx
    sub bx, [start_phase]
    jc .abort
    cmp bx, MAX_TICKS
    ja .abort
    mov [sample_ticks], bx
    cmp byte [pit_mode], 3
    jne .good
    test dl, 80h
    jz .abort
.good:
    mov ax, [start_count]
    sub ax, [end_count]
    mov [raw_delta], ax
    popf                     ; restore caller IF before any DOS output
    clc
    ret
.abort:
    popf
    stc
    ret

; These exact kernels, including the outer LOOP, are identical at all clocks.
kernel_baseline:
.loop:
    loop .loop
    ret
kernel_r0:
.loop:
    add ax, bx
    xor dx, di
    add bx, 1
    xor di, 55aah
    loop .loop
    ret
kernel_b0:
.loop:
    cmp ax, ax
    jne .never
    je .taken
.never:
    inc ax
.taken:
    jmp short .join
    nop
.join:
    loop .loop
    ret
kernel_m0:
.loop:
    mov ax, [data_words]
    add ax, [data_words+2]
    mov [data_words+4], ax
    xor word [data_words+6], 5a5ah
    loop .loop
    ret

emit_case_kind:
    xor bx, bx
    mov bl, [case_index]
    shl bx, 1
    mov dx, [case_table+bx]
    call puts
    call comma
    mov dx, label_baseline
    cmp byte [kind_index], 0
    je .kind
    mov dx, label_gross
.kind:
    call puts
    ret
emit_sample:
    mov dx, label_sample
    call puts
    call emit_case_kind
    call comma
    xor ax, ax
    mov al, [rep_index]
    inc ax
    call decimal
    call comma
    mov ax, ITERATIONS
    call decimal
    call comma
    xor ax, ax
    mov al, [start_status]
    call decimal
    call comma
    mov ax, [start_count]
    call decimal
    call comma
    xor ax, ax
    test byte [start_status], 80h
    jz .out0
    inc ax
.out0:
    call decimal
    call comma
    mov ax, [start_phase]
    call decimal
    call comma
    xor ax, ax
    mov al, [end_status]
    call decimal
    call comma
    mov ax, [end_count]
    call decimal
    call comma
    xor ax, ax
    test byte [end_status], 80h
    jz .out1
    inc ax
.out1:
    call decimal
    call comma
    mov ax, [end_phase]
    call decimal
    call comma
    mov ax, [raw_delta]
    call decimal
    call comma
    mov ax, [sample_ticks]
    call decimal
    call comma
    mov ax, [result_ax]
    call decimal
    call comma
    mov ax, [result_bx]
    call decimal
    call comma
    mov ax, [result_cx]
    call decimal
    call comma
    mov ax, [result_dx]
    call decimal
    call comma
    mov ax, [result_di]
    call decimal
    call newline
    ret
emit_summary:
    ; Bubble sort just seven unsigned tick counts, outside timing/CLI.
    mov cx, REPETITIONS-1
.outer:
    mov si, ticks
    mov bx, cx
.inner:
    mov ax, [si]
    cmp ax, [si+2]
    jbe .ordered
    xchg ax, [si+2]
    mov [si], ax
.ordered:
    add si, 2
    dec bx
    jnz .inner
    loop .outer
    mov dx, label_summary
    call puts
    call emit_case_kind
    call comma
    mov ax, ITERATIONS
    call decimal
    call comma
    mov ax, [ticks]
    call decimal
    call comma
    mov ax, [ticks+6]
    call decimal
    call comma
    mov ax, [ticks+12]
    call decimal
    call newline
    ret

; DOS standard-output writes permit >REF.CSV. No output happens under CLI.
puts:
    push ax
    push bx
    push cx
    push dx
    push si
    mov si, dx
    xor cx, cx
.length:
    cmp byte [si], '$'
    je .write
    inc si
    inc cx
    jmp short .length
.write:
    mov bx, 1
    mov ah, 40h
    int 21h
    jc .failed
    cmp ax, cx
    jne .failed
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret
.failed:
    ; Do not try to report an error recursively to an unusable stdout.
    mov ax, 4c01h
    int 21h
decimal:
    push ax
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
.digit:
    pop ax
    add al, '0'
    mov [character], al
    push cx
    mov dx, character
    call puts
    pop cx
    loop .digit
    pop dx
    pop cx
    pop bx
    pop ax
    ret
comma:
    push dx
    mov dx, comma_text
    call puts
    pop dx
    ret
newline:
    push dx
    mov dx, newline_text
    call puts
    pop dx
    ret
fatal:
    call puts
    mov ax, 4c01h
    int 21h

banner db 'meta,version,T286REF2',13,10
    db 'meta,cpu_contract,REAL_MODE_8086_INSTRUCTIONS_286_TARGET',13,10
    db 'meta,timer_qualification,NOT_CALIBRATED',13,10
    db 'meta,timer_divisor,65536',13,10
    db 'meta,divisor_source,ASSUMED_STANDARD_BIOS',13,10
    db 'meta,pit_input_hz,1193182_NOMINAL',13,10
    db 'meta,interrupt_policy,IF_PRESERVED_SHORT_CLI_NO_IRQ_TIMING_CLAIM',13,10
    db 'meta,window_phase_min,8192',13,10
    db 'meta,window_phase_max_exclusive,16384',13,10
    db 'meta,max_sample_ticks,10000',13,10
    db 'meta,repetitions,7',13,10,'$'
meta_nominal db 'meta,nominal_mhz,$'
meta_segment db 'meta,code_segment_decimal,$'
meta_address db 'meta,aligned_word_offset_decimal,$'
meta_mode db 'meta,pit_mode,$'
meta_status db 'meta,pit_status_without_out,$'
meta_probe_max db 'meta,probe_max_raw_count,$'
meta_probe_zero db 'meta,probe_observed_raw_zero,$'
headers db 'header_sample,case,kind,rep,loops,status_start,count_start,out_start,phase_start,status_end,count_end,out_end,phase_end,raw_delta,ticks,result_ax,result_bx,result_cx,result_dx,result_di',13,10
    db 'header_summary,case,kind,loops,min_ticks,median_ticks,max_ticks',13,10,'$'
label_sample db 'sample,$'
label_summary db 'summary,$'
label_baseline db 'baseline$'
label_gross db 'gross$'
label_r0 db 'R0$'
label_b0 db 'B0$'
label_m0 db 'M0$'
unknown_label db 'UNKNOWN'
nominal times 17 db 0
done db 'result,PASS_RAW_FIXED_WORK',13,10,'$'
err_if db 'result,REJECT_ENTRY_IF_DISABLED',13,10,'$'
err_label db 'result,REJECT_NOMINAL_LABEL',13,10,'$'
err_timer db 'result,REJECT_PIT_MODE_STATUS_OR_RELOAD_PROBE',13,10,'$'
err_window db 'result,REJECT_SAMPLE_WINDOW_OR_TIMER_STATUS',13,10,'$'
err_function db 'result,REJECT_KERNEL_FUNCTIONAL_RESULT',13,10,'$'
comma_text db ',$'
newline_text db 13,10,'$'
character db '0$'
align 2, db 0
entry_flags dw 0
kernel_ptr dw 0
kernel_table dw kernel_r0, kernel_b0, kernel_m0
case_table dw label_r0, label_b0, label_m0
case_index db 0
kind_index db 0
rep_index db 0
pit_mode db 0
pit_status db 0
probe_zero db 0
probe_edges db 0
probe_previous_status db 0
start_status db 0
end_status db 0
align 2, db 0
probe_max dw 0
probe_previous_count dw 0
start_count dw 0
end_count dw 0
start_phase dw 0
end_phase dw 0
sample_ticks dw 0
raw_delta dw 0
result_ax dw 0
result_bx dw 0
result_cx dw 0
result_dx dw 0
result_di dw 0
ticks times REPETITIONS dw 0
align 16, db 0
data_words dw 1234h, 5678h, 0, 3c3ch
align 2, db 0
stack_bottom times 256 db 0
stack_top:
