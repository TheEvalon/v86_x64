; Multiboot payload: REX.B/R, REX.W group1, MOVSXD, and higher-half data.
; Exit code is written to port 0xF4 (0 = pass).

BITS 32
ORG 0x100000

MULTIBOOT_MAGIC equ 0x1BADB002
MULTIBOOT_FLAGS equ 0x00010000
HIGHER_HALF     equ 0xFFFFFFFF80000000

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

    jmp 0x08:start64

fail32:
    mov al, 1
    out 0xF4, al
.hang:
    hlt
    jmp .hang

BITS 64
start64:
    mov r8d, 0x11
    mov r9d, 0x22
    add r8d, r9d
    cmp r8d, 0x33
    jne fail64

    mov dh, 0x55
    mov sil, 0xAA
    cmp sil, 0xAA
    jne fail64
    cmp dh, 0x55
    jne fail64

    mov rax, 0xF0
    or rax, 0x0F
    cmp rax, 0xFF
    jne fail64

    mov ecx, 0xFFFFFFFF
    movsxd rax, ecx
    mov rbx, 0xFFFFFFFFFFFFFFFF
    cmp rax, rbx
    jne fail64

    mov rax, 1
    shl rax, 4
    cmp rax, 16
    jne fail64

    mov rax, 0x0123456789ABCDEF
    mov rbx, HIGHER_HALF + scratch
    mov [rbx], rax
    mov rcx, [rbx]
    cmp rax, rcx
    jne fail64
    cmp rax, [scratch]
    jne fail64

    ; 32-bit writes zero-extend (IA-32e, including compatibility mode).
    mov rax, 0xFFFFFFFFFFFFFFFF
    mov eax, 0x12345678
    mov rbx, 0x12345678
    cmp rax, rbx
    jne fail64

    ; Linux's 32-bit decompressor JITs `mov edi, 0xb8000` after LMA but before
    ; CS.L. A stale high half makes the later 64-bit VGA write non-canonical.
    mov rdi, 0x0200000000B8000
    jmp far [compat_ptr]

BITS 32
compat32:
    mov edi, 0xB8000
    jmp 0x08:back64

BITS 64
back64:
    mov rsi, 0xB8000
    cmp rdi, rsi
    jne fail64

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail64:
    mov al, 1
    out 0xF4, al
.bad:
    hlt
    jmp .bad

align 8
scratch:
    dq 0

align 8
compat_ptr:
    dq compat32
    dw 0x18

align 8
gdt:
    dq 0
    dq 0x00AF9B000000FFFF
    dq 0x00CF93000000FFFF
    dq 0x00CF9B000000FFFF
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt

align 4096
pml4:
    dq pdpt + 0x07
    times 510 dq 0
    dq pdpt_high + 0x07

align 4096
pdpt:
    dq pd + 0x07
    times 511 dq 0

align 4096
pdpt_high:
    times 510 dq 0
    dq pd + 0x07
    dq 0

align 4096
pd:
    dq 0x00000000000001E7
    times 511 dq 0

align 16
    times 4096 db 0
stack_top:
