; Multiboot payload: 64-bit RCL/RCR through CF (REX.W group2 extras 2/3).
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
    or eax, 1 << 5
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

    ; 1. clc; RCL 1 of MSB: dest=0, CF=1, OF=MSB xor CF=1 (D1 form).
    clc
    mov rax, 0x8000000000000000
    rcl rax, 1
    jnc fail_rcl1_cf
    jno fail_rcl1_of
    test rax, rax
    jnz fail_rcl1_rax

    ; 2. stc; RCL 1 of 0: dest=1, CF=0, OF=0.
    xor rax, rax
    stc
    rcl rax, 1
    jc fail_rcl1_stc_cf
    jo fail_rcl1_stc_of
    cmp rax, 1
    jne fail_rcl1_stc_rax

    ; 3. stc; RCR 1 of 1: dest=MSB, CF=1, OF=MSB xor bit62=1.
    stc
    mov rax, 1
    rcr rax, 1
    jnc fail_rcr1_cf
    jno fail_rcr1_of
    mov rbx, 0x8000000000000000
    cmp rax, rbx
    jne fail_rcr1_rax

    ; 4. RCL 2 is a 65-bit rotate through CF, not a 64-bit ROL (C1 imm8).
    ; {CF=1, dest=MSB} RCL 2 -> dest=3, CF=0. ROL 2 would yield dest=2.
    ; n!=1 writes OF=0 (clears the OF left by test 3).
    stc
    mov rax, 0x8000000000000000
    rcl rax, 2
    jc fail_rcl2_cf
    jo fail_rcl2_of
    cmp rax, 3
    jne fail_rcl2_rax

    ; RCR 2: {CF=1, dest=1} -> dest=0xC000000000000000, CF=0 (not ROR's 0x4...).
    stc
    mov rax, 1
    rcr rax, 2
    jc fail_rcr2_cf
    mov rbx, 0xC000000000000000
    cmp rax, rbx
    jne fail_rcr2_rax

    ; 5. Count 64 masks to 0 (same as SHL/ROL): no-op on dest and CF (D3 CL).
    stc
    mov rax, 0x0123456789ABCDEF
    mov cl, 64
    rcl rax, cl
    jnc fail_nop_stc_cf
    mov rbx, 0x0123456789ABCDEF
    cmp rax, rbx
    jne fail_nop_stc_rax

    clc
    rcl rax, cl
    jc fail_nop_clc_cf
    cmp rax, rbx
    jne fail_nop_clc_rax

    ; 6. Memory form: RCL qword [mem], 1.
    ; MOV r/m64, imm32 sign-extends; load the MSB via a 64-bit register.
    mov rax, 0x8000000000000000
    mov [mem64], rax
    clc
    rcl qword [mem64], 1
    jnc fail_mem_cf
    cmp qword [mem64], 0
    jne fail_mem_val

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_rcl1_rax:
    mov al, 2
    jmp fail_out
fail_rcl1_cf:
    mov al, 3
    jmp fail_out
fail_rcl1_of:
    mov al, 4
    jmp fail_out
fail_rcl1_stc_rax:
    mov al, 5
    jmp fail_out
fail_rcl1_stc_cf:
    mov al, 6
    jmp fail_out
fail_rcl1_stc_of:
    mov al, 7
    jmp fail_out
fail_rcr1_rax:
    mov al, 8
    jmp fail_out
fail_rcr1_cf:
    mov al, 9
    jmp fail_out
fail_rcr1_of:
    mov al, 10
    jmp fail_out
fail_rcl2_rax:
    mov al, 11
    jmp fail_out
fail_rcl2_cf:
    mov al, 12
    jmp fail_out
fail_rcl2_of:
    mov al, 13
    jmp fail_out
fail_rcr2_rax:
    mov al, 14
    jmp fail_out
fail_rcr2_cf:
    mov al, 15
    jmp fail_out
fail_nop_stc_rax:
    mov al, 16
    jmp fail_out
fail_nop_stc_cf:
    mov al, 17
    jmp fail_out
fail_nop_clc_rax:
    mov al, 18
    jmp fail_out
fail_nop_clc_cf:
    mov al, 19
    jmp fail_out
fail_mem_val:
    mov al, 20
    jmp fail_out
fail_mem_cf:
    mov al, 21
    jmp fail_out

fail_out:
    out 0xF4, al
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

align 8
mem64:
    dq 0

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
