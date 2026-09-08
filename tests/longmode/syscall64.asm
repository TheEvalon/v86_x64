; Multiboot payload: SYSCALL, SYSRETQ, SWAPGS, and FS/GS base MSRs.
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
    mov rsp, stack_top

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

    mov ecx, 0xC0000101
    mov eax, 0x1111
    xor edx, edx
    wrmsr

    mov ecx, 0xC0000102
    mov eax, 0x2222
    xor edx, edx
    wrmsr

    lea rcx, [user_land]
    mov r11, 2
    sysretq

user_land:
    syscall
    mov al, 1
    out 0xF4, al
.bad_user:
    hlt
    jmp .bad_user

syscall_entry:
    cmp r11, 2
    jne fail64

    swapgs
    mov ecx, 0xC0000101
    rdmsr
    cmp eax, 0x2222
    jne fail64
    mov ecx, 0xC0000102
    rdmsr
    cmp eax, 0x1111
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
