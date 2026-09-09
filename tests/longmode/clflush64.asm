; Multiboot payload: CLFLUSH (0F AE /7) as a cache no-op in long mode.
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

    ; CPUID.1: EDX bit 19 (CLFSH), EBX[15:8] clflush line size non-zero.
    mov eax, 1
    cpuid
    test edx, (1 << 19)
    jz fail_clfsh
    mov eax, ebx
    shr eax, 8
    and eax, 0xFF
    test eax, eax
    jz fail_csize

    ; Fill a 64-byte line with a known pattern.
    mov rax, 0xA5A5A5A5A5A5A5A5
    mov rcx, 8
    lea rdi, [buf]
    rep stosq

    lea rax, [buf]
    clflush [rax]

    mov rax, 0xA5A5A5A5A5A5A5A5
    mov rcx, 8
    lea rsi, [buf]
.check0:
    cmp qword [rsi], rax
    jne fail_clflush
    add rsi, 8
    dec rcx
    jnz .check0

    ; Offset inside the same line must also be a no-op / no #UD.
    lea rax, [buf]
    clflush [rax + 32]

    mov rax, 0xA5A5A5A5A5A5A5A5
    mov rcx, 8
    lea rsi, [buf]
.check32:
    cmp qword [rsi], rax
    jne fail_mid
    add rsi, 8
    dec rcx
    jnz .check32

    ; 66 prefix + clflush is CLFLUSHOPT encoding: no #UD, no memory change.
    lea rax, [buf]
    db 0x66
    clflush [rax]

    mov rax, 0xA5A5A5A5A5A5A5A5
    mov rcx, 8
    lea rsi, [buf]
.check66:
    cmp qword [rsi], rax
    jne fail_opt
    add rsi, 8
    dec rcx
    jnz .check66

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_clfsh:
    mov al, 2
    jmp fail_out
fail_csize:
    mov al, 3
    jmp fail_out
fail_clflush:
    mov al, 4
    jmp fail_out
fail_mid:
    mov al, 5
    jmp fail_out
fail_opt:
    mov al, 6
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

align 64
buf:
    times 64 db 0

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
