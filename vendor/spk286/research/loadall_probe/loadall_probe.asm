; LOADALL hardware probe for a real 80286.
;
; This is a DOS .COM program.  It deliberately uses only 16-bit instructions
; and emits the probe result on screen.  The program
; stays in real mode.  It tests opcode classification, a controlled 0F05
; LOADALL return, FLAGS reserved bits, and a hidden DS base above 1 MiB when
; A20 and extended RAM are available.  It does not enter protected mode.
;
; The 102-byte image follows the Intel 80286 LOADALL note layout used by the
; SPK286 milestone: physical 000800h, 51 little-endian words.

cpu 286
bits 16
org 100h

%define IMAGE_PHYS     0800h
%define HIGH_SEG       0ffffh
%define HIGH_OFF       2010h       ; HIGH_SEG:HIGH_OFF = physical 102000h
%define TEST_OFF       2000h
%define STACK_TOP      0f000h
%define LOADALL_SP     (STACK_TOP - 2) ; preserve the caller's COM return word
%define LINE_MAX       160

; Intel's 102-byte 80286 image layout.  The first six bytes are reserved;
; word offsets below are kept as byte offsets so they can be checked directly
; against physical addresses 000806h..000864h in reference implementations.
%define IMAGE_MSW      006h
%define IMAGE_TR       016h
%define IMAGE_FLAGS    018h
%define IMAGE_IP       01ah
%define IMAGE_LDTR     01ch
%define IMAGE_DS       01eh
%define IMAGE_SS       020h
%define IMAGE_CS       022h
%define IMAGE_ES       024h
%define IMAGE_DI       026h
%define IMAGE_SI       028h
%define IMAGE_BP       02ah
%define IMAGE_SP       02ch
%define IMAGE_BX       02eh
%define IMAGE_DX       030h
%define IMAGE_CX       032h
%define IMAGE_AX       034h
%define IMAGE_ES_CACHE 036h
%define IMAGE_CS_CACHE 03ch
%define IMAGE_SS_CACHE 042h
%define IMAGE_DS_CACHE 048h
%define IMAGE_GDTR    04eh
%define IMAGE_LDTR_CACHE 054h
%define IMAGE_IDTR    05ah
%define IMAGE_TR_CACHE 060h

    jmp start

; ---------------------------------------------------------------------------
; DOS/CPU state and diagnostic results

initial_flags       dw 0
cpu_286             db 0
current_cs          dw 0
current_ds          dw 0
current_ss          dw 0
current_sp          dw 0
current_msw         dw 0
current_tr          dw 0
current_ldtr        dw 0
gdt_saved           times 6 db 0
idt_saved           times 6 db 0
cs_base_low         dw 0
cs_base_high        db 0

old_ud_off          dw 0
old_ud_seg          dw 0
old_gp_off          dw 0
old_gp_seg          dw 0
handlers_installed  db 0

ud_seen             db 0
ud_saved_ip         dw 0
ud_saved_cs         dw 0
ud_saved_flags      dw 0
gp_seen             db 0
gp_error            dw 0
gp_saved_ip         dw 0
gp_saved_cs         dw 0
gp_saved_flags      dw 0

op04_returned       db 0
op04_ud             db 0
op04_ip             dw 0
op04_cs             dw 0
op04_flags          dw 0

op05_returned       db 0
op05_ud             db 0
op05_ip             dw 0
op05_cs             dw 0
op05_flags          dw 0
flags_after_05      dw 0

a20_enabled         db 0
a20_low_saved       dw 0
a20_high_saved      dw 0
a20_low_after       dw 0
a20_high_after      dw 0
high_ram_ok         db 0

hidden_returned     db 0
hidden_ud           db 0
hidden_observed     dw 0
hidden_match        db 0
hidden_low_saved    dw 0
hidden_high_saved   dw 0

flags_reserved_returned db 0
flags_reserved_ud       db 0
flags_reserved_observed dw 0
flags_restored           db 0

image_flags         dw 0002h
image_msw           dw 0000h
image_target_ip     dw 0
image_ds_high       db 0
image_buf           times 102 db 0
image_backup        times 102 db 0

line_len            dw 0
line_buf            times LINE_MAX db 0
crlf                db 13, 10
hex_chars           db '0123456789ABCDEF'

low_marker_original dw 0
high_marker_original dw 0

stack_space         times 256 db 0
stack_top:

msg_title           db 'SPK286 80286 LOADALL hardware probe', 0
msg_scope           db 'Real mode only; reset is not required by this probe.', 0
msg_phase_cpu       db 'Phase: checking CPU mode.', 0
msg_phase_capture   db 'Phase: capturing real-mode CPU state.', 0
msg_phase_save      db 'Phase: saving physical 000800h.', 0
msg_phase_handlers  db 'Phase: installing #UD/#GP handlers.', 0
msg_phase_handlers_done db 'Phase: #UD/#GP handlers installed.', 0
msg_phase_a20       db 'Phase: detecting A20.', 0
msg_phase_a20_done  db 'Phase: A20 detection complete.', 0
msg_phase_04        db 'Phase: executing opcode 0F 04.', 0
msg_phase_05        db 'Phase: executing opcode 0F 05.', 0
msg_phase_hidden    db 'Phase: executing hidden-cache test.', 0
msg_phase_flags     db 'Phase: executing reserved-FLAGS test.', 0
msg_abort_cpu       db 'ABORT: this program requires an 80286 or newer CPU.', 0
msg_cpu             db 'State: CS=', 0
msg_ds              db ' DS=', 0
msg_ss              db ' SS=', 0
msg_msw             db ' MSW=', 0
msg_tr              db ' TR=', 0
msg_ldtr            db ' LDTR=', 0
msg_state_note      db 'TR/LDTR assumed zero; STR/SLDT are #UD in real mode.', 0
msg_abort_pm        db 'ABORT: CPU is already in protected mode.', 0
msg_a20             db 'A20: ', 0
msg_enabled         db 'enabled', 0
msg_disabled        db 'disabled', 0
msg_high_ram        db 'Extended RAM at 102000h: ', 0
msg_available       db 'available', 0
msg_unavailable     db 'not writable/readable; high-cache test skipped', 0
msg_04              db '0F 04: ', 0
msg_05              db '0F 05: ', 0
msg_ud              db '#UD', 0
msg_loadall         db 'LOADALL returned', 0
msg_unexpected      db 'unexpected return', 0
msg_frame           db ' saved CS:IP=', 0
msg_flags           db ' FLAGS=', 0
msg_flags_result    db '0F 05 resulting FLAGS=', 0
msg_flags_probe     db 'Reserved FLAGS image F002h -> observed ', 0
msg_hidden          db 'Hidden DS base 100000h: observed DS:2000h=', 0
msg_match           db ' (PASS: high physical 102000h)', 0
msg_mismatch        db ' (FAIL: hidden base not observed)', 0
msg_hidden_ud       db ' (SKIP: 0F 05 raised #UD)', 0
msg_skipped         db 'SKIP: A20 or extended RAM unavailable.', 0
msg_gp               db 'FATAL #GP: error=', 0
msg_done             db 'Probe complete. Photograph this screen and report the result.', 0
msg_bad              db 'FAIL', 0
msg_pass              db 'PASS', 0

; ---------------------------------------------------------------------------
; Entry and top-level flow

start:
    pushf
    pop ax
    mov bx, cs
    mov ds, bx
    mov es, bx
    mov [initial_flags], ax
    cld
    cli
    mov ss, bx
    mov sp, STACK_TOP

    sti

    call line_reset
    mov si, msg_title
    call line_text
    call write_line
    call line_reset
    mov si, msg_scope
    call line_text
    call write_line

    call line_reset
    mov si, msg_phase_cpu
    call line_text
    call write_line
    call detect_286
    cmp byte [cpu_286], 1
    jne abort_cpu

    call line_reset
    mov si, msg_phase_capture
    call line_text
    call write_line
    cli
    call capture_state
    sti

    call line_reset
    mov si, msg_phase_save
    call line_text
    call write_line
    cli
    call save_image_area
    sti

    call print_state

    test word [current_msw], 1
    jnz abort_protected

    call line_reset
    mov si, msg_phase_handlers
    call line_text
    call write_line
    call install_handlers
    call line_reset
    mov si, msg_phase_handlers_done
    call line_text
    call write_line
    call line_reset
    mov si, msg_phase_a20
    call line_text
    call write_line
    call detect_a20
    call line_reset
    mov si, msg_phase_a20_done
    call line_text
    call write_line
    call print_a20

    cmp byte [a20_enabled], 1
    jne no_high_test
    call detect_high_ram
    call print_high_ram
    cmp byte [high_ram_ok], 1
    jne no_high_test

    call line_reset
    mov si, msg_phase_04
    call line_text
    call write_line
    call run_opcode_04
    call line_reset
    mov si, msg_phase_05
    call line_text
    call write_line
    call run_opcode_05
    call line_reset
    mov si, msg_phase_hidden
    call line_text
    call write_line
    call run_hidden_cache
    call line_reset
    mov si, msg_phase_flags
    call line_text
    call write_line
    call run_reserved_flags
    jmp short probe_done

no_high_test:
    call line_reset
    mov si, msg_phase_04
    call line_text
    call write_line
    call run_opcode_04
    call line_reset
    mov si, msg_phase_05
    call line_text
    call write_line
    call run_opcode_05
    call line_reset
    mov si, msg_phase_flags
    call line_text
    call write_line
    call run_reserved_flags
    call line_reset
    mov si, msg_skipped
    call line_text
    call write_line

probe_done:
    call line_reset
    mov si, msg_done
    call line_text
    call write_line
    call restore_image_area
    call restore_handlers
    sti
    mov ax, 4c00h
    int 21h

abort_cpu:
    call line_reset
    mov si, msg_abort_cpu
    call line_text
    call write_line
    sti
    mov ax, 4c01h
    int 21h

abort_protected:
    call line_reset
    mov si, msg_abort_pm
    call line_text
    call write_line
    jmp short clean_abort

clean_abort:
    call restore_image_area
    sti
    mov ax, 4c01h
    int 21h

; ---------------------------------------------------------------------------
; State capture and image construction

detect_286:
    ; This probe must reject an 8086/8088/80186 before executing any 0F xx
    ; instruction.  Those processors cannot clear FLAGS bits 12..15 with
    ; POPF; a 286 can.  The original FLAGS are restored before returning.
    pushf
    pop ax
    mov bx, ax
    xor ax, ax
    push ax
    popf
    pushf
    pop ax
    push bx
    popf
    mov byte [cpu_286], 0
    test ax, 0f000h
    jnz .done
    mov byte [cpu_286], 1
.done:
    ret

capture_state:
    mov ax, cs
    mov [current_cs], ax
    mov ax, ds
    mov [current_ds], ax
    mov ax, ss
    mov [current_ss], ax
    mov ax, sp
    mov [current_sp], ax
    smsw ax
    mov [current_msw], ax
    ; Intel specifies STR and SLDT as #UD in real-address mode.  Do not use
    ; them here: this program cannot safely inspect TR/LDTR without first
    ; entering protected mode.  Clean real-mode DOS is required, so the
    ; image records the architecturally expected zero selectors.
    xor ax, ax
    mov [current_tr], ax
    mov [current_ldtr], ax
    sgdt [gdt_saved]
    sidt [idt_saved]

    ; The program normalizes all visible real-mode data selectors to CS.  The
    ; image uses this real-mode base and 286 access bytes for the cache records.
    mov ax, [current_cs]
    xor dx, dx
    mov cx, 4
.base_shift:
    shl ax, 1
    rcl dx, 1
    loop .base_shift
    mov [cs_base_low], ax
    mov [cs_base_high], dl
    ret

build_image:
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov di, image_buf
    xor ax, ax
    mov cx, 51
    rep stosw

    mov ax, [image_msw]
    mov [image_buf+IMAGE_MSW], ax
    mov ax, [current_tr]
    mov [image_buf+IMAGE_TR], ax
    mov ax, [image_flags]
    mov [image_buf+IMAGE_FLAGS], ax
    mov ax, [image_target_ip]
    mov [image_buf+IMAGE_IP], ax
    mov ax, [current_ldtr]
    mov [image_buf+IMAGE_LDTR], ax
    mov ax, [current_cs]
    mov [image_buf+IMAGE_DS], ax
    mov [image_buf+IMAGE_SS], ax
    mov [image_buf+IMAGE_CS], ax
    mov [image_buf+IMAGE_ES], ax

    ; DI, SI, BP, SP, BX, DX, CX, AX.  These values are intentionally visible
    ; in a debugger and leave the stack in the program's own segment.
    mov word [image_buf+IMAGE_DI], 0d1d1h
    mov word [image_buf+IMAGE_SI], 0c1c1h
    mov word [image_buf+IMAGE_BP], 0b1b1h
    ; Each LOADALL test is called with its return address at SP-2.  Keeping
    ; that value as the loaded SP lets the test return normally after the
    ; instruction has replaced the stack state.
    mov word [image_buf+IMAGE_SP], LOADALL_SP
    mov word [image_buf+IMAGE_BX], 0a1a1h
    mov word [image_buf+IMAGE_DX], 09191h
    mov word [image_buf+IMAGE_CX], 08181h
    mov word [image_buf+IMAGE_AX], 07171h

    ; ES cache: base, base-high/access, limit.
    mov ax, [cs_base_low]
    mov [image_buf+IMAGE_ES_CACHE], ax
    xor ax, ax
    mov al, [cs_base_high]
    mov ah, 093h
    mov [image_buf+IMAGE_ES_CACHE+2], ax
    mov word [image_buf+IMAGE_ES_CACHE+4], 0ffffh

    ; CS cache uses the 286 present executable/readable access byte.
    mov ax, [cs_base_low]
    mov [image_buf+IMAGE_CS_CACHE], ax
    xor ax, ax
    mov al, [cs_base_high]
    mov ah, 09bh
    mov [image_buf+IMAGE_CS_CACHE+2], ax
    mov word [image_buf+IMAGE_CS_CACHE+4], 0ffffh

    ; SS cache.
    mov ax, [cs_base_low]
    mov [image_buf+IMAGE_SS_CACHE], ax
    xor ax, ax
    mov al, [cs_base_high]
    mov ah, 093h
    mov [image_buf+IMAGE_SS_CACHE+2], ax
    mov word [image_buf+IMAGE_SS_CACHE+4], 0ffffh

    ; DS cache is either ordinary real-mode CS base or the 1 MiB hidden base.
    cmp byte [image_ds_high], 0
    je .normal_ds
    mov word [image_buf+IMAGE_DS_CACHE], 0000h
    mov word [image_buf+IMAGE_DS_CACHE+2], 9310h
    mov word [image_buf+IMAGE_DS_CACHE+4], 0ffffh
    jmp short .tables
.normal_ds:
    mov ax, [cs_base_low]
    mov [image_buf+IMAGE_DS_CACHE], ax
    xor ax, ax
    mov al, [cs_base_high]
    mov ah, 093h
    mov [image_buf+IMAGE_DS_CACHE+2], ax
    mov word [image_buf+IMAGE_DS_CACHE+4], 0ffffh

.tables:
    ; SGDT/SIDT store limit first, then base.  LOADALL stores these two
    ; system-cache records as base low, base high, limit, so they must be
    ; rearranged rather than copied byte-for-byte.
    mov ax, [gdt_saved+2]
    mov [image_buf+IMAGE_GDTR], ax
    xor ax, ax
    mov al, [gdt_saved+4]
    mov [image_buf+IMAGE_GDTR+2], ax
    mov ax, [gdt_saved]
    mov [image_buf+IMAGE_GDTR+4], ax

    mov ax, [idt_saved+2]
    mov [image_buf+IMAGE_IDTR], ax
    xor ax, ax
    mov al, [idt_saved+4]
    mov [image_buf+IMAGE_IDTR+2], ax
    mov ax, [idt_saved]
    mov [image_buf+IMAGE_IDTR+4], ax
    ; LDT cache at 54h and TSS cache at 60h remain zero for a clean
    ; real-mode DOS process.
    ret

save_image_area:
    mov ax, cs
    mov es, ax
    xor ax, ax
    mov ds, ax
    mov si, IMAGE_PHYS
    mov di, image_backup
    mov cx, 51
    rep movsw
    mov ax, cs
    mov ds, ax
    mov es, ax
    ret

copy_image:
    mov ax, cs
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov si, image_buf
    mov di, IMAGE_PHYS
    mov cx, 51
    rep movsw
    mov ax, cs
    mov ds, ax
    mov es, ax
    ret

restore_image_area:
    mov ax, cs
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov si, image_backup
    mov di, IMAGE_PHYS
    mov cx, 51
    rep movsw
    mov ax, cs
    mov ds, ax
    mov es, ax
    ret

; ---------------------------------------------------------------------------
; Opcode and LOADALL probes

run_opcode_04:
    mov word [image_flags], 0002h
    mov word [image_msw], 0000h
    mov byte [image_ds_high], 0
    mov word [image_target_ip], after_04
    call build_image
    call copy_image
    mov byte [ud_seen], 0
    mov byte [op04_returned], 0
    cli
    db 0fh, 04h
after_04:
    mov byte [cs:op04_returned], 1
    sti
    mov al, [ud_seen]
    mov [op04_ud], al
    mov ax, [ud_saved_ip]
    mov [op04_ip], ax
    mov ax, [ud_saved_cs]
    mov [op04_cs], ax
    mov ax, [ud_saved_flags]
    mov [op04_flags], ax

    call line_reset
    mov si, msg_04
    call line_text
    cmp byte [op04_ud], 0
    je .returned
    mov si, msg_ud
    call line_text
    call append_frame
    jmp short .print
.returned:
    mov si, msg_loadall
    call line_text
.print:
    call write_line
    ret

run_opcode_05:
    mov word [image_flags], 0002h
    mov word [image_msw], 0000h
    mov byte [image_ds_high], 0
    mov word [image_target_ip], after_05
    call build_image
    call copy_image
    mov byte [ud_seen], 0
    mov byte [op05_returned], 0
    cli
    db 0fh, 05h
after_05:
    mov byte [cs:op05_returned], 1
    pushf
    pop ax
    mov [cs:flags_after_05], ax
    sti
    mov al, [ud_seen]
    mov [op05_ud], al
    mov ax, [ud_saved_ip]
    mov [op05_ip], ax
    mov ax, [ud_saved_cs]
    mov [op05_cs], ax
    mov ax, [ud_saved_flags]
    mov [op05_flags], ax

    call line_reset
    mov si, msg_05
    call line_text
    cmp byte [op05_ud], 0
    je .returned
    mov si, msg_ud
    call line_text
    call append_frame_05
    jmp short .print
.returned:
    mov si, msg_loadall
    call line_text
    call write_line
    call line_reset
    mov si, msg_flags_result
    call line_text
    mov ax, [flags_after_05]
    call append_hex_word
    call write_line
    ret
.print:
    call write_line
    ret

run_hidden_cache:
    mov word [image_flags], 0002h
    mov word [image_msw], 0000h
    mov byte [image_ds_high], 1
    mov word [image_target_ip], after_hidden

    mov si, TEST_OFF
    mov ax, [cs:si]
    mov [low_marker_original], ax
    mov word [cs:si], 0a55ah
    mov ax, HIGH_SEG
    mov es, ax
    mov di, HIGH_OFF
    mov ax, [es:di]
    mov [high_marker_original], ax
    mov ax, 05aa5h
    mov [es:di], ax
    mov ax, cs
    mov es, ax

    call build_image
    call copy_image
    mov byte [ud_seen], 0
    mov byte [hidden_returned], 0
    mov byte [hidden_match], 0
    cli
    db 0fh, 05h
after_hidden:
    mov byte [cs:hidden_returned], 1
    mov ax, [ds:TEST_OFF]
    mov [cs:hidden_observed], ax
    cmp ax, 05aa5h
    jne .not_match
    mov byte [cs:hidden_match], 1
.not_match:
    ; Return to a conventional DS/ES before calling DOS or touching variables.
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov si, TEST_OFF
    mov ax, [low_marker_original]
    mov [cs:si], ax
    mov ax, HIGH_SEG
    mov es, ax
    mov di, HIGH_OFF
    mov ax, [high_marker_original]
    mov [es:di], ax
    mov ax, cs
    mov es, ax
    sti

    mov al, [ud_seen]
    mov [hidden_ud], al
    call line_reset
    mov si, msg_hidden
    call line_text
    mov ax, [hidden_observed]
    call append_hex_word
    cmp byte [hidden_ud], 0
    jne .ud_line
    cmp byte [hidden_match], 1
    jne .not_match_line
    mov si, msg_match
    call line_text
    jmp short .write
.ud_line:
    mov si, msg_hidden_ud
    call line_text
    jmp short .write
.not_match_line:
    mov si, msg_mismatch
    call line_text
.write:
    call write_line
    ret

run_reserved_flags:
    mov word [image_flags], 0f002h
    mov word [image_msw], 0000h
    mov byte [image_ds_high], 0
    mov word [image_target_ip], after_flags_reserved
    call build_image
    call copy_image
    mov byte [ud_seen], 0
    mov byte [flags_reserved_returned], 0
    cli
    db 0fh, 05h
after_flags_reserved:
    mov byte [cs:flags_reserved_returned], 1
    pushf
    pop ax
    mov [cs:flags_reserved_observed], ax
    mov al, [ud_seen]
    mov [cs:flags_reserved_ud], al

    ; Restore a safe real-mode FLAGS word through a second controlled LOADALL.
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov word [image_flags], 0002h
    mov word [image_msw], 0000h
    mov byte [image_ds_high], 0
    mov word [image_target_ip], after_flags_restore
    call build_image
    call copy_image
    cli
    db 0fh, 05h
after_flags_restore:
    mov byte [cs:flags_restored], 1
    sti

    call line_reset
    mov si, msg_flags_probe
    call line_text
    cmp byte [flags_reserved_ud], 0
    je .flags_value
    mov si, msg_ud
    call line_text
    call write_line
    ret
.flags_value:
    mov ax, [flags_reserved_observed]
    call append_hex_word
    call write_line
    ret

append_frame:
    mov si, msg_frame
    call line_text
    mov ax, [op04_cs]
    call append_hex_word
    mov al, ':'
    call append_char
    mov ax, [op04_ip]
    call append_hex_word
    mov si, msg_flags
    call line_text
    mov ax, [op04_flags]
    call append_hex_word
    ret

append_frame_05:
    mov si, msg_frame
    call line_text
    mov ax, [op05_cs]
    call append_hex_word
    mov al, ':'
    call append_char
    mov ax, [op05_ip]
    call append_hex_word
    mov si, msg_flags
    call line_text
    mov ax, [op05_flags]
    call append_hex_word
    ret

; ---------------------------------------------------------------------------
; A20 and extended-memory checks

detect_a20:
    cli
    xor ax, ax
    mov ds, ax
    mov ax, HIGH_SEG
    mov es, ax
    mov si, HIGH_OFF-10h
    mov di, HIGH_OFF
    mov ax, [ds:TEST_OFF]
    mov [cs:a20_low_saved], ax
    mov ax, [es:di]
    mov [cs:a20_high_saved], ax
    mov ax, 0a55ah
    mov [ds:TEST_OFF], ax
    mov ax, 05aa5h
    mov [es:di], ax
    mov ax, [ds:TEST_OFF]
    mov [cs:a20_low_after], ax
    mov ax, [es:di]
    mov [cs:a20_high_after], ax
    mov ax, [cs:a20_low_saved]
    mov [ds:TEST_OFF], ax
    mov ax, [cs:a20_high_saved]
    mov [es:di], ax
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov byte [a20_enabled], 0
    cmp word [a20_low_after], 0a55ah
    jne .done
    cmp word [a20_high_after], 05aa5h
    jne .done
    mov byte [a20_enabled], 1
.done:
    sti
    ret

detect_high_ram:
    cli
    mov ax, HIGH_SEG
    mov es, ax
    mov di, HIGH_OFF
    mov ax, [es:di]
    mov [cs:high_marker_original], ax
    mov ax, 05aa5h
    mov [es:di], ax
    mov ax, [es:di]
    cmp ax, 05aa5h
    jne .not_ok
    mov byte [cs:high_ram_ok], 1
    jmp short .restore
.not_ok:
    mov byte [cs:high_ram_ok], 0
.restore:
    mov ax, [cs:high_marker_original]
    mov [es:di], ax
    mov ax, cs
    mov es, ax
    sti
    ret

print_a20:
    call line_reset
    mov si, msg_a20
    call line_text
    cmp byte [a20_enabled], 1
    jne .off
    mov si, msg_enabled
    call line_text
    jmp short .write
.off:
    mov si, msg_disabled
    call line_text
.write:
    call write_line
    ret

print_high_ram:
    call line_reset
    mov si, msg_high_ram
    call line_text
    cmp byte [high_ram_ok], 1
    jne .no
    mov si, msg_available
    call line_text
    jmp short .write
.no:
    mov si, msg_unavailable
    call line_text
.write:
    call write_line
    ret

; ---------------------------------------------------------------------------
; Exception vectors.  #UD returns after the two-byte probe opcode.  #GP is
; terminal because a real-mode COM cannot safely infer a protected fault frame.
; The IVT is updated directly so the probe does not depend on DOS vector
; services while preparing to execute the sensitive instructions.

install_handlers:
    cli
    xor ax, ax
    mov es, ax
    mov bx, 6*4
    mov ax, [es:bx]
    mov [cs:old_ud_off], ax
    mov ax, [es:bx+2]
    mov [cs:old_ud_seg], ax
    mov ax, ud_handler
    mov [es:bx], ax
    mov ax, cs
    mov [es:bx+2], ax

    mov bx, 0dh*4
    mov ax, [es:bx]
    mov [cs:old_gp_off], ax
    mov ax, [es:bx+2]
    mov [cs:old_gp_seg], ax
    mov ax, gp_handler
    mov [es:bx], ax
    mov ax, cs
    mov [es:bx+2], ax

    mov ax, cs
    mov ds, ax
    mov es, ax
    mov byte [handlers_installed], 1
    sti
    ret

restore_handlers:
    cmp byte [handlers_installed], 1
    jne .done
    cli
    mov ax, cs
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov bx, 6*4
    mov ax, [cs:old_ud_off]
    mov [es:bx], ax
    mov ax, [cs:old_ud_seg]
    mov [es:bx+2], ax
    mov bx, 0dh*4
    mov ax, [cs:old_gp_off]
    mov [es:bx], ax
    mov ax, [cs:old_gp_seg]
    mov [es:bx+2], ax
    mov ax, cs
    mov es, ax
    mov ds, ax
    mov byte [handlers_installed], 0
    sti
.done:
    ret

ud_handler:
    push ax
    push bp
    mov bp, sp
    mov byte [cs:ud_seen], 1
    mov ax, [ss:bp+4]
    mov [cs:ud_saved_ip], ax
    mov ax, [ss:bp+6]
    mov [cs:ud_saved_cs], ax
    mov ax, [ss:bp+8]
    mov [cs:ud_saved_flags], ax
    add word [ss:bp+4], 2
    pop bp
    pop ax
    iret

gp_handler:
    push ax
    push bp
    mov bp, sp
    mov byte [cs:gp_seen], 1
    mov ax, [ss:bp+4]
    mov [cs:gp_error], ax
    mov ax, [ss:bp+6]
    mov [cs:gp_saved_ip], ax
    mov ax, [ss:bp+8]
    mov [cs:gp_saved_cs], ax
    mov ax, [ss:bp+10]
    mov [cs:gp_saved_flags], ax
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, STACK_TOP
    jmp fatal_gp

fatal_gp:
    sti
    call line_reset
    mov si, msg_gp
    call line_text
    mov ax, [gp_error]
    call append_hex_word
    call append_frame_gp
    call write_line
    call restore_image_area
    call restore_handlers
    mov ax, 4c02h
    int 21h

append_frame_gp:
    mov si, msg_frame
    call line_text
    mov ax, [gp_saved_cs]
    call append_hex_word
    mov al, ':'
    call append_char
    mov ax, [gp_saved_ip]
    call append_hex_word
    mov si, msg_flags
    call line_text
    mov ax, [gp_saved_flags]
    call append_hex_word
    ret

; ---------------------------------------------------------------------------
; Minimal line writer.  It writes directly through BIOS INT 10h, so the
; diagnostic output does not depend on a DOS console handle.  All calls occur
; after DS has been restored to CS.

write_line:
    push ax
    push bx
    push cx
    push dx
    push si
    push ds
    mov ax, cs
    mov ds, ax
    mov cx, [line_len]
    mov si, line_buf
.next:
    jcxz .crlf
    mov al, [si]
    inc si
    push cx
    push si
    call bios_putc
    pop si
    pop cx
    dec cx
    jmp short .next
.crlf:
    mov al, 13
    call bios_putc
    mov al, 10
    call bios_putc
    pop ds
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

bios_putc:
    push bx
    mov ah, 0eh
    xor bh, bh
    mov bl, 07h
    int 10h
    pop bx
    ret

line_reset:
    mov word [line_len], 0
    ret

line_text:
    push ax
.next:
    mov al, [cs:si]
    inc si
    or al, al
    jz .done
    call append_char
    jmp short .next
.done:
    pop ax
    ret

append_char:
    push bx
    push di
    mov bx, [line_len]
    cmp bx, LINE_MAX-1
    jae .done
    mov di, line_buf
    add di, bx
    mov [di], al
    inc bx
    mov [line_len], bx
.done:
    pop di
    pop bx
    ret

append_hex_word:
    push ax
    push bx
    push cx
    push dx
    mov dx, ax
    mov ax, dx
    mov cl, 12
    shr ax, cl
    call append_hex_nibble
    mov ax, dx
    mov cl, 8
    shr ax, cl
    call append_hex_nibble
    mov ax, dx
    mov cl, 4
    shr ax, cl
    call append_hex_nibble
    mov ax, dx
    call append_hex_nibble
    pop dx
    pop cx
    pop bx
    pop ax
    ret

append_hex_nibble:
    and al, 0fh
    xor ah, ah
    mov bx, hex_chars
    xlat
    jmp append_char

print_state:
    call line_reset
    mov si, msg_cpu
    call line_text
    mov ax, [current_cs]
    call append_hex_word
    mov si, msg_ds
    call line_text
    mov ax, [current_ds]
    call append_hex_word
    mov si, msg_ss
    call line_text
    mov ax, [current_ss]
    call append_hex_word
    mov si, msg_msw
    call line_text
    mov ax, [current_msw]
    call append_hex_word
    mov si, msg_tr
    call line_text
    mov ax, [current_tr]
    call append_hex_word
    mov si, msg_ldtr
    call line_text
    mov ax, [current_ldtr]
    call append_hex_word
    call write_line
    call line_reset
    mov si, msg_state_note
    call line_text
    call write_line
    ret
