; Multiboot payload: run 64-bit code at a canonical higher-half RIP
; (Linux -2GB window), CMOV r64, SETCC, and ADD/SUB r64. Exit code is written to port 0xF4 (0 = pass).

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
    mov rax, HIGHER_HALF + higher
    jmp rax

higher:
    lea rax, [higher]
    mov rbx, HIGHER_HALF + higher
    cmp rax, rbx
    jne fail64

    mov rax, 0x1122334455667788
    add rax, 1
    mov rbx, 0x1122334455667789
    cmp rax, rbx
    jne fail64

    ; CMOV r64: taken copies the full 64-bit src (higher-half LEA).
    ; 32-bit CMOV would zero-extend the low half of that address.
    mov rax, 0xAAAAAAAAAAAAAAAA
    lea rbx, [higher]
    xor ecx, ecx
    cmove rax, rbx
    cmp rax, rbx
    jne fail_cmov

    ; Not taken must leave dest unchanged. 32-bit CMOV still zero-extends
    ; the dest even when the condition is false.
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov ecx, 1
    test ecx, ecx
    cmove rax, rbx
    mov rcx, 0xAAAAAAAAAAAAAAAA
    cmp rax, rcx
    jne fail_cmov_keep

    ; SETZ writes only the 8-bit dest. 32-bit SETZ of AL still leaves
    ; the rest of RAX; a mistaken write_reg32 would zero-extend to 1.
    mov rax, 0xAAAAAAAAAAAAAAAA
    xor ecx, ecx
    setz al
    mov rbx, 0xAAAAAAAAAAAAAA01
    cmp rax, rbx
    jne fail_setz

    mov rax, 0xAAAAAAAAAAAAAAAA
    mov ecx, 1
    test ecx, ecx
    setz al
    mov rbx, 0xAAAAAAAAAAAAAA00
    cmp rax, rbx
    jne fail_setz_clear

    ; ADD r64 of 0xFFFFFFFF + 1 is 2^32. 32-bit ADD wraps EAX to 0.
    ; `mov rax, 0xFFFFFFFF` would sign-extend to -1; use EAX to zero-extend.
    mov eax, 0xFFFFFFFF
    add rax, 1
    mov rbx, 0x100000000
    cmp rax, rbx
    jne fail_add

    ; SUB r64 of 0 - 1 is all ones. 32-bit SUB writes EAX=0xFFFFFFFF.
    xor eax, eax
    sub rax, 1
    cmp rax, -1
    jne fail_sub

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

fail_cmov:
    mov al, 2
    out 0xF4, al
.hang_cmov:
    hlt
    jmp .hang_cmov

fail_cmov_keep:
    mov al, 3
    out 0xF4, al
.hang_cmov_keep:
    hlt
    jmp .hang_cmov_keep

fail_setz:
    mov al, 4
    out 0xF4, al
.hang_setz:
    hlt
    jmp .hang_setz

fail_setz_clear:
    mov al, 5
    out 0xF4, al
.hang_setz_clear:
    hlt
    jmp .hang_setz_clear

fail_add:
    mov al, 6
    out 0xF4, al
.hang_add:
    hlt
    jmp .hang_add

fail_sub:
    mov al, 7
    out 0xF4, al
.hang_sub:
    hlt
    jmp .hang_sub

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
