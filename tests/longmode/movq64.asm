; Multiboot payload: REX.W MOVQ between GPR and XMM/MMX, plus ADC/SBB/TEST r64.
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

    ; PAE (bit 5) for long mode; OSFXSR (bit 9) for XMM.
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

    ; Dirties bits 127:64 so MOVQ must zero them (32-bit MOVD also drops 63:32).
    movdqa xmm0, [pat_full]
    mov rax, 0x0123456789ABCDEF
    movq xmm0, rax          ; 66 REX.W 0F 6E
    movq rbx, xmm0          ; 66 REX.W 0F 7E
    cmp rax, rbx
    jne fail_gpr

    movdqa [tmp], xmm0
    cmp qword [tmp], rax
    jne fail_gpr
    cmp qword [tmp + 8], 0
    jne fail_high

    ; REX.R/B: XMM8 and r8/r9 are not aliases of XMM0/rax.
    mov r8, 0xFEDCBA9876543210
    movq xmm8, r8
    movq r9, xmm8
    cmp r8, r9
    jne fail_xmm8
    cmp r9, rax
    je fail_xmm8
    movdqa [tmp], xmm8
    cmp qword [tmp], r8
    jne fail_xmm8
    cmp qword [tmp + 8], 0
    jne fail_xmm8
    movq rcx, xmm0
    cmp rcx, rax
    jne fail_xmm8

    ; F3 0F 7E MOVQ xmm, xmm/m64 (and F3 REX.W) must not become the GPR store.
    movdqa xmm1, [pat_full]
    movq xmm1, xmm0
    movq rdi, xmm1
    cmp rdi, rax
    jne fail_f3
    movdqa [tmp], xmm1
    cmp qword [tmp + 8], 0
    jne fail_f3
    movdqa xmm3, [pat_full]
    o64 movq xmm3, xmm0
    movq rdi, xmm3
    cmp rdi, rax
    jne fail_f3
    movdqa [tmp], xmm3
    cmp qword [tmp + 8], 0
    jne fail_f3

    ; REX.W 0F 6E / 7E without 66: MOVQ mm, r/m64 and r/m64, mm.
    mov rax, 0x0123456789ABCDEF
    movq mm0, rax
    movq rbx, mm0
    cmp rax, rbx
    jne fail_mmx
    mov rdx, 0xA5A5A5A5A5A5A5A5
    mov [memq], rdx
    movd mm1, qword [memq]
    movq rsi, mm1
    cmp rsi, rdx
    jne fail_mmx
    mov qword [memq], 0
    movd qword [memq], mm1
    cmp qword [memq], rdx
    jne fail_mmx
    emms

    ; ADC r64 of 0xFFFFFFFF + CF. 32-bit ADC wraps EAX to 0.
    stc
    mov rax, 0xFFFFFFFF
    adc rax, 0
    mov rbx, 0x100000000
    cmp rax, rbx
    jne fail_adc

    ; SBB r64 of 0 - CF is all ones. 32-bit SBB writes 0xFFFFFFFF.
    stc
    mov rax, 0
    sbb rax, 0
    cmp rax, -1
    jne fail_sbb

    ; TEST r64 of 2^32 is non-zero. 32-bit TEST of EAX=0 sets ZF.
    mov rax, 0x100000000
    test rax, rax
    jz fail_test
    mov rbx, 0x100000000
    test rax, rbx
    jz fail_test
    xor eax, eax
    test rax, rbx
    jnz fail_test

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_gpr:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_high:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_xmm8:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_f3:
    mov al, 5
    out 0xF4, al
    jmp hang64

fail_mmx:
    mov al, 6
    out 0xF4, al
    jmp hang64

fail_adc:
    mov al, 7
    out 0xF4, al
    jmp hang64

fail_sbb:
    mov al, 8
    out 0xF4, al
    jmp hang64

fail_test:
    mov al, 9
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
pat_full:
    dq 0x1111111111111111
    dq 0x2222222222222222

align 16
tmp:
    times 16 db 0

align 16
memq:
    times 16 db 0

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
