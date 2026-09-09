; Multiboot payload: local APIC CPUID/MSR/MMIO with ACPI off.
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

    ; CPUID.1 EDX bit 9: local APIC present.
    mov eax, 1
    cpuid
    test edx, (1 << 9)
    jz fail_cpuid

    ; RDMSR IA32_APIC_BASE: phys 0xFEE00000, BSP set.
    mov ecx, 0x1B
    rdmsr
    mov ebx, eax
    and ebx, 0xFFFFF000
    cmp ebx, 0xFEE00000
    jne fail_msr_addr
    test eax, (1 << 8)
    jz fail_msr_bsp

    ; Enable the local APIC if the EN bit is clear.
    test eax, (1 << 11)
    jnz en_ok
    or eax, (1 << 11)
    wrmsr
    rdmsr
    test eax, (1 << 11)
    jz fail_en
en_ok:

    ; MMIO: APIC version register at 0xFEE00030 is 0x50014.
    ; Identity map: PDPT[3], PD[(0xFEE00000 >> 21) & 0x1FF] = PD[0x1F7].
    mov rsi, 0xFEE00030
    mov eax, [rsi]
    cmp eax, 0x50014
    jne fail_mmio

    xor eax, eax
    out 0xF4, al
    jmp hang64

fail_cpuid:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_msr_addr:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_msr_bsp:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_en:
    mov al, 5
    out 0xF4, al
    jmp hang64

fail_mmio:
    mov al, 6
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
    times 2 dq 0
    dq pd_apic + 0x07
    times 508 dq 0

align 4096
pd:
    dq 0x00000000000001E7
    times 511 dq 0

align 4096
pd_apic:
    times 0x1F7 dq 0
    dq 0x00000000FEE001E7
    times (512 - 0x1F7 - 1) dq 0

align 16
    times 4096 db 0
stack_top:
