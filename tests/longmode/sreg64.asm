; Multiboot payload: 64-bit PUSH/POP FS and GS in long mode.
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

    ; PUSH FS: 8-byte stack, selector zero-extended (not 32-bit PUSH).
    mov rsp, stack_top
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov [rsp-8], rax
    mov ax, 0x10
    mov fs, ax
    push fs
    mov rbx, stack_top
    sub rbx, rsp
    cmp rbx, 8
    jne fail_push_fs_size
    pop rax
    cmp rax, 0x10
    jne fail_push_fs_ext

    ; PUSH GS / POP RAX: same 8-byte zero-extended write.
    mov rsp, stack_top
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov [rsp-8], rax
    mov ax, 0x10
    mov gs, ax
    push gs
    mov rbx, stack_top
    sub rbx, rsp
    cmp rbx, 8
    jne fail_push_gs_size
    pop rax
    cmp rax, 0x10
    jne fail_push_gs_ext

    ; Round-trip PUSH FS / POP FS restores the selector.
    mov rsp, stack_top
    mov ax, 0x10
    mov fs, ax
    xor eax, eax
    push fs
    mov fs, ax
    pop fs
    mov ax, fs
    cmp ax, 0x10
    jne fail_pop_fs

    ; PUSH FS / POP GS copies the selector.
    mov rsp, stack_top
    mov ax, 0x10
    mov fs, ax
    xor eax, eax
    mov gs, ax
    push fs
    pop gs
    mov ax, gs
    cmp ax, 0x10
    jne fail_pop_gs

    ; 66h is ignored: operand size stays 64 bits.
    mov rsp, stack_top
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov [rsp-8], rax
    mov ax, 0x10
    mov fs, ax
    o16 push fs
    mov rbx, stack_top
    sub rbx, rsp
    cmp rbx, 8
    jne fail_o16_push
    pop rax
    cmp rax, 0x10
    jne fail_o16_push

    mov rsp, stack_top
    mov ax, 0x10
    mov fs, ax
    xor eax, eax
    push fs
    mov fs, ax
    o16 pop fs
    mov rbx, stack_top
    sub rbx, rsp
    cmp rbx, 0
    jne fail_o16_pop
    mov ax, fs
    cmp ax, 0x10
    jne fail_o16_pop

    xor eax, eax
    out 0xF4, al
    jmp hang64

fail_push_fs_size:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_push_fs_ext:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_push_gs_size:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_push_gs_ext:
    mov al, 5
    out 0xF4, al
    jmp hang64

fail_pop_fs:
    mov al, 6
    out 0xF4, al
    jmp hang64

fail_pop_gs:
    mov al, 7
    out 0xF4, al
    jmp hang64

fail_o16_push:
    mov al, 8
    out 0xF4, al
    jmp hang64

fail_o16_pop:
    mov al, 9
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
