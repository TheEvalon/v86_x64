; Multiboot payload: allowlisted MSRs are no-ops in long mode (read 0).
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

    ; IA32_ENERGY_PERF_BIAS (0x1B0): write ignored, read 0.
    mov ecx, 0x1B0
    mov eax, 0xFFFFFFFF
    mov edx, 0xFFFFFFFF
    wrmsr
    xor eax, eax
    xor edx, edx
    rdmsr
    test eax, eax
    jnz fail_epb
    test edx, edx
    jnz fail_epb

    ; IA32_MTRRCAP (0xFE): 0 variable ranges / no WC.
    xor eax, eax
    xor edx, edx
    mov ecx, 0xFE
    rdmsr
    test eax, eax
    jnz fail_mtrr
    test edx, edx
    jnz fail_mtrr

    ; IA32_MTRR_DEF_TYPE (0x2FF) and PHYSBASE0 (0x200).
    mov ecx, 0x2FF
    mov eax, 0x806
    mov edx, 0
    wrmsr
    xor eax, eax
    rdmsr
    test eax, eax
    jnz fail_mtrr
    test edx, edx
    jnz fail_mtrr

    mov ecx, 0x200
    mov eax, 0x6
    mov edx, 0
    wrmsr
    xor eax, eax
    rdmsr
    test eax, eax
    jnz fail_mtrr
    test edx, edx
    jnz fail_mtrr

    ; IA32_MCG_STATUS (0x17A).
    mov ecx, 0x17A
    mov eax, 0x4
    mov edx, 0
    wrmsr
    xor eax, eax
    rdmsr
    test eax, eax
    jnz fail_mcg
    test edx, edx
    jnz fail_mcg

    ; MSR_AMD64_SYSCFG (0xC0010010).
    mov ecx, 0xC0010010
    mov eax, 0x1
    mov edx, 0
    wrmsr
    xor eax, eax
    rdmsr
    test eax, eax
    jnz fail_syscfg
    test edx, edx
    jnz fail_syscfg

    xor eax, eax
    out 0xF4, al
    jmp hang64

fail_epb:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_mtrr:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_mcg:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_syscfg:
    mov al, 5
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
