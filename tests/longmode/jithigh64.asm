; Multiboot payload: 32-bit-opsize loop at a canonical higher-half RIP
; (Linux -2GB window). The JIT must compile it (RIP > 4GiB) without
; widening instruction_pointer. Exit code is written to port 0xF4 (0 = pass).

BITS 32
ORG 0x100000

MULTIBOOT_MAGIC equ 0x1BADB002
MULTIBOOT_FLAGS equ 0x00010000
HIGHER_HALF     equ 0xFFFFFFFF80000000
ITERATIONS      equ 250000

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
DEFAULT REL
start64:
    mov rax, HIGHER_HALF + higher
    jmp rax

higher:
    lea rax, [higher]
    mov rbx, HIGHER_HALF + higher
    cmp rax, rbx
    jne fail64

    ; 67h + [edi+disp32] is 7 bytes in 64-bit CS. High-RIP JIT trampolines
    ; 67h (32-bit JIT EA != interpreter RIP-rel/FS-GS). The interpreter must
    ; still load scratch; decode16 would use [bx+si] and fail the magic
    ; compare. Use the 32-bit identity address (low 2MB is mapped).
    mov edi, scratch

    ; REX.W encodings trampoline; this loop should compile as 32-bit-opsize JIT.
    xor eax, eax
    mov ecx, ITERATIONS
.loop:
    add eax, 1
    mov ebx, eax
    db 0x67, 0x8B, 0x87
    dd 0
    cmp eax, 0x11223344
    jne fail_asize
    mov eax, ebx
    sub ecx, 1
    jnz .loop

    cmp eax, ITERATIONS
    jne fail64

    lea rax, [after_loop]
    mov rbx, HIGHER_HALF + after_loop
    cmp rax, rbx
    jne fail_rip
after_loop:
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

fail_rip:
    mov al, 2
    out 0xF4, al
.hang_rip:
    hlt
    jmp .hang_rip

fail_asize:
    mov al, 3
    out 0xF4, al
.hang_asize:
    hlt
    jmp .hang_asize

align 8
scratch:
    dd 0x11223344

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
