; Multiboot payload: 64-bit CS loop of 32-bit-opsize ops that the JIT can
; compile (add/sub/jnz, not one-byte INC/DEC 40-4F). Exit code is written to
; port 0xF4 (0 = pass), matching kvm-unit-tests.

BITS 32
ORG 0x100000

MULTIBOOT_MAGIC equ 0x1BADB002
MULTIBOOT_FLAGS equ 0x00010000
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
start64:
    ; REX.W encodings trampoline to the interpreter; the following loop should
    ; be compiled as 32-bit-opsize JIT code.
    mov rax, 0x1122334455667788
    add rax, 1
    mov rbx, 0x1122334455667789
    cmp rax, rbx
    jne fail64

    xor eax, eax
    mov ecx, ITERATIONS
.loop:
    add eax, 1
    sub ecx, 1
    jnz .loop

    cmp eax, ITERATIONS
    jne fail64

    ; Non-REX `mov r32, [r/m]` must use 64-bit RAX, not truncated EAX.
    ; Map linear 4GiB+low_buf to phys 2MiB+low_buf (distinct from identity).
    lea rbx, [low_buf]
    mov dword [rbx], 0x11111111
    mov rax, rbx
    mov rcx, 0x0000000100000000
    or rax, rcx
    ; REX.W store: interpreter writes the high mapping, not the low sentinel.
    mov qword [rax], 0x22222222
    cmp dword [rbx], 0x11111111
    jne fail_clobber
    mov rcx, [rax]
    cmp rcx, 0x22222222
    jne fail_map
    ; 8B 18: mov ebx, [rax] -- no REX. Must read the high sentinel.
    mov ebx, [rax]
    cmp ebx, 0x22222222
    jne fail_trunc

    ; JIT 32-bit ALU writes must zero-extend RAX–RDI (write_reg32 already
    ; does; xor/add on wasm locals did not). Stale high halves turn a NULL
    ; pointer into 0x7FF00000000 (XP x64 SxS isolation 7th arg).
    mov rax, 0x000007FF00000001
    xor eax, eax
    test rax, rax
    jnz fail_zext
    mov rbp, 0x000007FF12345678
    xor ebp, ebp
    test rbp, rbp
    jnz fail_zext
    mov rsi, 0x000007FFABCDEF00
    add esi, 0
    mov rax, 0xABCDEF00
    cmp rsi, rax
    jne fail_zext

    ; `67 65 48 A1 30 00 00 00` is MSVC `mov rax, gs:[0x30]` (TEB PEB).
    ; moffs used to skip FS/GS, so linear=0x30 and XP winlogon AVd.
    mov rax, 0xBAD0BAD0BAD0BAD0
    mov [0x30], rax
    mov rax, 0x0000000100000030
    mov rcx, 0x1122334455667788
    mov [rax], rcx
    mov ecx, 0xC0000101
    xor eax, eax
    mov edx, 1
    wrmsr
    xor eax, eax
    db 0x67, 0x65, 0x48, 0xA1, 0x30, 0x00, 0x00, 0x00
    mov rcx, 0x1122334455667788
    cmp rax, rcx
    jne fail_moffs
    xor eax, eax
    db 0x67, 0x65, 0xA1, 0x30, 0x00, 0x00, 0x00
    mov rcx, 0x55667788
    cmp rax, rcx
    jne fail_moffs

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_map:
    mov al, 2
    jmp fail_out
fail_clobber:
    mov al, 3
    jmp fail_out
fail_trunc:
    mov al, 4
    jmp fail_out
fail_zext:
    mov al, 5
    jmp fail_out
fail_moffs:
    mov al, 6
    jmp fail_out
fail64:
    mov al, 1
fail_out:
    out 0xF4, al
.bad:
    hlt
    jmp .bad

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
    times 3 dq 0
    dq pd_4g + 0x07
    times 507 dq 0

align 4096
pd:
    dq 0x00000000000001E7
    times 511 dq 0

align 4096
pd_4g:
    dq 0x00000000002001E7
    times 511 dq 0

align 16
low_buf:
    dd 0
    dd 0

align 16
    times 4096 db 0
stack_top:
