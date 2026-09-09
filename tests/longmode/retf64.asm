; Multiboot payload: 64-bit inter-privilege RETF to user CS, then SYSCALL.
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
    test edx, (1 << 11)
    jz fail32

    lgdt [gdt_desc]

    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    mov eax, pml4
    mov cr3, eax

    mov ecx, 0xC0000080
    rdmsr
    or eax, (1 << 8) | 1
    wrmsr

    mov eax, cr0
    or eax, 1 | (1 << 31)
    mov cr0, eax

    mov ecx, 0xC0000080
    rdmsr
    test eax, (1 << 10)
    jz fail32
    test eax, 1
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
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov rsp, stack_top

    lea rax, [tss]
    mov word [tss_desc + 2], ax
    shr rax, 16
    mov byte [tss_desc + 4], al
    mov byte [tss_desc + 7], ah

    lea rax, [rsp0_stack_top]
    mov [tss + 0x04], rax

    mov ax, 0x28
    ltr ax

    mov ecx, 0xC0000081
    xor eax, eax
    mov edx, 0x00100008
    wrmsr

    lea rax, [syscall_entry]
    mov ecx, 0xC0000082
    mov edx, 0
    wrmsr

    mov ecx, 0xC0000084
    mov eax, 0x200
    xor edx, edx
    wrmsr

    ; RETF frame: RIP, CS, RSP, SS. Immediate 16 is added to the *new* RSP.
    mov rax, 0x1B
    push rax
    lea rax, [user_stack_top]
    sub rax, 16
    push rax
    mov rax, 0x23
    push rax
    lea rax, [user_land]
    push rax
    ; NASM 2.16: o64 selects 64-bit operand size (default in 64-bit CS is 32).
    o64 retf 16

user_land:
    mov ax, cs
    cmp ax, 0x23
    jne fail64
    mov ax, ss
    cmp ax, 0x1B
    jne fail64
    lea rax, [user_stack_top]
    cmp rsp, rax
    jne fail64
    syscall
    mov al, 1
    out 0xF4, al
.bad_user:
    hlt
    jmp .bad_user

syscall_entry:
    mov ax, cs
    cmp ax, 0x08
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
gdt:
    dq 0
    dq 0x00AF9B000000FFFF
    dq 0x00CF93000000FFFF
    dq 0x00CFF3000000FFFF
    dq 0x00AFFB000000FFFF
tss_desc:
    dw 0x67
    dw 0
    db 0
    db 0x89
    db 0
    db 0
    dd 0
    dd 0
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt

align 16
tss:
    times 0x68 db 0

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

align 16
    times 4096 db 0
rsp0_stack_top:

align 16
    times 4096 db 0
user_stack_top:
