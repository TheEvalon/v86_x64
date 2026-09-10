; Multiboot payload: 64-bit PUSH/POP/CALL/RET/LEAVE and RIP-relative load.
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

    mov rax, 0x1111111111111111
    push rax
    pop rbx
    cmp rax, rbx
    jne fail64

    push 2
    pop rcx
    cmp rcx, 2
    jne fail64

    mov rax, 0
    call near_fn
    cmp rax, 0x42
    jne fail64

    mov rdx, indirect_fn
    call rdx
    cmp rax, 0x43
    jne fail64

    xor eax, eax
    add rax, [imm64]
    mov rbx, 0x0123456789ABCDEF
    cmp rax, rbx
    jne fail64

    lea rdi, [imm64]
    mov rsi, [rdi]
    cmp rsi, rbx
    jne fail64

    push rbp
    mov rbp, rsp
    sub rsp, 16
    leave

    pushfq
    popfq

    ; 66h must not turn PUSH r / CALL / RET into 16-bit stack ops.
    mov rax, 0x0123456789ABCDEF
    mov r8, rsp
    db 0x66
    push rax
    mov r9, rsp
    sub r8, r9
    cmp r8, 8
    jne fail66
    pop r10
    cmp r10, rax
    jne fail66

    mov r8, rsp
    db 0x66
    call osize_ret
    cmp rax, 0x44
    jne fail66
    cmp rsp, r8
    jne fail66

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

near_fn:
    mov rax, 0x42
    ret

indirect_fn:
    mov rax, 0x43
    ret

osize_ret:
    mov rax, 0x44
    db 0x66
    ret

fail66:
    mov al, 2
    out 0xF4, al
    jmp fail64.bad

fail64:
    mov al, 1
    out 0xF4, al
.bad:
    hlt
    jmp .bad

align 8
imm64:
    dq 0x0123456789ABCDEF

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
