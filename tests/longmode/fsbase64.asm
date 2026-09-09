; Multiboot payload: MOV FS/GS in long mode copies the descriptor base into
; IA32_FS_BASE / IA32_GS_BASE (so [fs:disp] is not stuck at the prior MSR).
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

    mov rdi, 0x2000
    mov rax, 0x1122334455667788
    mov [rdi], rax

    mov rdi, 0x3000
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov [rdi], rax

    ; Red herring: WRMSR FS_BASE to 0x3000, then load selector 0x18 (base 0x2000).
    mov ecx, 0xC0000100
    mov eax, 0x3000
    xor edx, edx
    wrmsr

    mov ax, 0x18
    mov fs, ax

    xor esi, esi
    mov rbx, [fs:rsi]
    mov rax, 0x1122334455667788
    cmp rbx, rax
    jne fail_fs

    mov ecx, 0xC0000100
    rdmsr
    cmp eax, 0x2000
    jne fail_fs_msr
    test edx, edx
    jnz fail_fs_msr

    ; Null FS in 64-bit mode preserves the previous base.
    xor eax, eax
    mov fs, ax
    xor esi, esi
    mov rbx, [fs:rsi]
    mov rax, 0x1122334455667788
    cmp rbx, rax
    jne fail_fs_null

    mov rdi, 0x3000
    mov rax, 0xBBBBBBBBBBBBBBBB
    mov [rdi], rax

    mov ecx, 0xC0000101
    mov eax, 0x3000
    xor edx, edx
    wrmsr

    mov ax, 0x18
    mov gs, ax

    xor esi, esi
    mov rbx, [gs:rsi]
    mov rax, 0x1122334455667788
    cmp rbx, rax
    jne fail_gs

    mov ecx, 0xC0000101
    rdmsr
    cmp eax, 0x2000
    jne fail_gs_msr
    test edx, edx
    jnz fail_gs_msr

    xor eax, eax
    mov gs, ax
    xor esi, esi
    mov rbx, [gs:rsi]
    mov rax, 0x1122334455667788
    cmp rbx, rax
    jne fail_gs_null

    xor eax, eax
    out 0xF4, al
    jmp hang64

fail_fs:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_fs_msr:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_fs_null:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_gs:
    mov al, 5
    out 0xF4, al
    jmp hang64

fail_gs_msr:
    mov al, 6
    out 0xF4, al
    jmp hang64

fail_gs_null:
    mov al, 7
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
    ; selector 0x18: data, base 0x2000, limit 0xFFFF, P=1 DPL=0 S=1 RW, D=1 G=0
    dq 0x004F93002000FFFF
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
