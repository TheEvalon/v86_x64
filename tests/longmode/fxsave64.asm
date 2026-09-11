; Multiboot payload: 64-bit FXSAVE/FXRSTOR format in long mode.
; Exit code is written to port 0xF4 (0 = pass).

BITS 32
ORG 0x100000

MULTIBOOT_MAGIC equ 0x1BADB002
MULTIBOOT_FLAGS equ 0x00010000

header:
    dd MULTIBOOT_MAGIC
    dd MULTIBOOT_FLAGS
    dd -(MULTIBOOT_MAGIC + MULTIBOOT_FLAGS)
    dd header
    dd 0x100000
    dd 0
    dd 0
    dd _start

_start:
    cli
    mov esp, stack_top

    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb fail32

    mov eax, 0x80000001
    cpuid
    test edx, (1 << 29)
    jz fail32

    lgdt [gdt_desc]

    mov eax, cr4
    or eax, (1 << 5) | (1 << 9)
    mov cr4, eax

    mov eax, pml4
    mov cr3, eax

    mov ecx, 0xC0000080
    rdmsr
    or eax, 1 << 8
    wrmsr

    mov eax, cr0
    or eax, 1 | (1 << 31)
    mov cr0, eax

    mov ecx, 0xC0000080
    rdmsr
    test eax, (1 << 10)
    jz fail32

    jmp 0x08:start64

fail32:
    mov al, 1
    out 0xF4, al
.hang:
    hlt
    jmp .hang

BITS 64
DEFAULT REL
start64:
    mov rsp, stack_top
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    mov eax, gp_handler
    mov word [idt_vec13], ax
    shr eax, 16
    mov word [idt_vec13 + 6], ax
    lidt [idt_desc]

    lea rdi, [fx_buf]
    mov rcx, 64
    mov rax, -1
    rep stosq

    fninit
    fld1
    movdqa xmm0, [xmm_in]

    fxsave64 [fx_buf]

    ; 32-bit FXSAVE stores FCS at +12 (CS=0x08). 64-bit FIP[47:32] must be 0.
    cmp word [fx_buf + 12], 0x08
    je fail_format
    cmp dword [fx_buf + 12], 0
    jne fail_format

    ; ST0 = +1.0 (80-bit)
    mov rax, 0x8000000000000000
    cmp qword [fx_buf + 32], rax
    jne fail_st0
    cmp word [fx_buf + 40], 0x3FFF
    jne fail_st0

    mov rax, 0x0123456789ABCDEF
    cmp qword [fx_buf + 160], rax
    jne fail_xmm0
    mov rax, 0xFEDCBA9876543210
    cmp qword [fx_buf + 168], rax
    jne fail_xmm0

    cmp qword [fx_buf + 288], 0
    jne fail_xmm8
    cmp qword [fx_buf + 296], 0
    jne fail_xmm8

    ; FXSAVE64 must not zero reserved +416..511 (XP KERNEL_STACK_CONTROL at +0x1B0).
    mov rcx, 12
    lea rsi, [fx_buf + 416]
.check_fx64_res:
    cmp qword [rsi], -1
    jne fail_fxsave64_reserved
    add rsi, 8
    dec rcx
    jnz .check_fx64_res
    cmp qword [fx_buf + 0x1B0], -1
    jne fail_fxsave64_reserved

    fninit
    xorps xmm0, xmm0
    fxrstor64 [fx_buf]
    fxsave64 [fx_buf2]

    mov rax, 0x8000000000000000
    cmp qword [fx_buf2 + 32], rax
    jne fail_restore_st
    cmp word [fx_buf2 + 40], 0x3FFF
    jne fail_restore_st

    mov rax, 0x0123456789ABCDEF
    cmp qword [fx_buf2 + 160], rax
    jne fail_restore_xmm
    mov rax, 0xFEDCBA9876543210
    cmp qword [fx_buf2 + 168], rax
    jne fail_restore_xmm

    ; Legacy FXSAVE (no REX.W) in 64-bit CS uses the 32-bit image: FCS at +12,
    ; XMM0–7 only, bytes 288–511 left untouched (XP header lives at +0x1B0).
    lea rdi, [fx_buf]
    mov rcx, 64
    mov rax, 0xA5A5A5A5A5A5A5A5
    rep stosq

    fninit
    fld1
    movdqa xmm0, [xmm_in]
    fxsave [fx_buf]

    mov rax, 0x0123456789ABCDEF
    cmp qword [fx_buf + 160], rax
    jne fail_xmm0

    mov rax, 0xA5A5A5A5A5A5A5A5
    mov rcx, 28
    lea rsi, [fx_buf + 288]
.check_legacy_res:
    cmp qword [rsi], rax
    jne fail_legacy_reserved
    add rsi, 8
    dec rcx
    jnz .check_legacy_res
    cmp qword [fx_buf + 0x1B0], rax
    jne fail_legacy_reserved

    mov byte [gp_expected], 1
    fxsave64 [fx_buf + 1]
    mov al, 8
    out 0xF4, al
    jmp hang64

gp_handler:
    pop rcx
    cmp byte [gp_expected], 1
    jne fail_gp
    test ecx, ecx
    jnz fail_gp
    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_format:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_st0:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_xmm0:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_xmm8:
    mov al, 5
    out 0xF4, al
    jmp hang64

fail_restore_st:
    mov al, 6
    out 0xF4, al
    jmp hang64

fail_restore_xmm:
    mov al, 7
    out 0xF4, al
    jmp hang64

fail_gp:
    mov al, 9
    out 0xF4, al
    jmp hang64

fail_fxsave64_reserved:
    mov al, 10
    out 0xF4, al
    jmp hang64

fail_legacy_reserved:
    mov al, 11
    out 0xF4, al
    jmp hang64

hang64:
    hlt
    jmp hang64

align 8
gdt:
    dq 0
    dq 0x00AF9B000000FFFF
    dq 0x00CF93000000FFFF
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt

align 16
idt:
    times 13 * 16 db 0
idt_vec13:
    dw 0
    dw 0x08
    db 0
    db 0x8E
    dw 0
    dd 0
    dd 0
idt_end:

idt_desc:
    dw idt_end - idt - 1
    dq idt

align 16
xmm_in:
    dq 0x0123456789ABCDEF
    dq 0xFEDCBA9876543210

gp_expected:
    db 0

align 16
fx_buf:
    times 512 db 0

align 16
fx_buf2:
    times 512 db 0

align 4096
pml4:
    dq pdpt + 0x07
    times 511 dq 0

align 4096
pdpt:
    dq pd + 0x07
    times 511 dq 0

align 4096
pd:
    dq 0x00000000000001E7
    times 511 dq 0

align 16
    times 4096 db 0
stack_top:
