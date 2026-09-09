; Multiboot payload: 67h selects 32-bit addressing in 64-bit CS.
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

    mov rax, 0x0123456789ABCDEF
    mov [buf], rax

    lea rbx, [buf]
    mov rax, [rbx]
    mov rcx, 0x0123456789ABCDEF
    cmp rax, rcx
    jne fail_store

    ; RAX = buf + 4GiB; EAX still equals buf.
    mov rax, rbx
    mov rcx, 0x0000000100000000
    or rax, rcx
    mov edx, eax
    cmp rdx, rbx
    jne fail_low

    ; 67 48 8B 00: mov rax, [eax] — 32-bit address, not #PF at +4GiB.
    db 0x67, 0x48, 0x8B, 0x00
    mov rcx, 0x0123456789ABCDEF
    cmp rax, rcx
    jne fail_mov

    ; Same fat RAX; 67 48 8D 00: lea rax, [eax] — zero-extended EAX.
    mov rax, rbx
    mov rcx, 0x0000000100000000
    or rax, rcx
    db 0x67, 0x48, 0x8D, 0x00
    cmp rax, rbx
    jne fail_lea

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_store:
    mov al, 2
    jmp fail_out
fail_low:
    mov al, 3
    jmp fail_out
fail_mov:
    mov al, 4
    jmp fail_out
fail_lea:
    mov al, 5
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
buf:
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
