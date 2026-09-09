; Multiboot payload: XMM8–15 storage and FXSAVE64 slots in long mode.
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
    or eax, (1 << 5) | (1 << 9)
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

    ; XMM8 is a distinct register (not XMM0 overlay).
    movdqa xmm0, [pat8]
    movdqa xmm8, xmm0
    pxor xmm0, xmm0
    movdqa xmm0, xmm8
    movdqa [tmp], xmm0
    mov rax, [pat8]
    cmp qword [tmp], rax
    jne fail_xmm8
    mov rax, [pat8 + 8]
    cmp qword [tmp + 8], rax
    jne fail_xmm8

    ; XMM15 is a distinct register (not XMM0 overlay).
    movdqa xmm0, [pat15]
    movdqa xmm15, xmm0
    pxor xmm0, xmm0
    movdqa xmm0, xmm15
    movdqa [tmp], xmm0
    mov rax, [pat15]
    cmp qword [tmp], rax
    jne fail_xmm15
    mov rax, [pat15 + 8]
    cmp qword [tmp + 8], rax
    jne fail_xmm15

    ; Keep XMM8/XMM15 loaded for FXSAVE64.
    movdqa xmm8, [pat8]
    movdqa xmm15, [pat15]

    lea rdi, [fx_buf]
    mov rcx, 64
    xor eax, eax
    rep stosq

    fxsave64 [fx_buf]

    mov rax, [pat8]
    cmp qword [fx_buf + 288], rax
    jne fail_fxsave8
    mov rax, [pat8 + 8]
    cmp qword [fx_buf + 296], rax
    jne fail_fxsave8

    mov rax, [pat15]
    cmp qword [fx_buf + 400], rax
    jne fail_fxsave15
    mov rax, [pat15 + 8]
    cmp qword [fx_buf + 408], rax
    jne fail_fxsave15

    pxor xmm8, xmm8
    pxor xmm15, xmm15
    fxrstor64 [fx_buf]

    movdqa [tmp], xmm8
    mov rax, [pat8]
    cmp qword [tmp], rax
    jne fail_fxrstor8
    mov rax, [pat8 + 8]
    cmp qword [tmp + 8], rax
    jne fail_fxrstor8

    movdqa [tmp], xmm15
    mov rax, [pat15]
    cmp qword [tmp], rax
    jne fail_fxrstor15
    mov rax, [pat15 + 8]
    cmp qword [tmp + 8], rax
    jne fail_fxrstor15

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_xmm8:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_xmm15:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_fxsave8:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_fxsave15:
    mov al, 5
    out 0xF4, al
    jmp hang64

fail_fxrstor8:
    mov al, 6
    out 0xF4, al
    jmp hang64

fail_fxrstor15:
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
gdt_end:

gdt_desc:
    dw gdt_end - gdt - 1
    dd gdt

align 16
pat8:
    dq 0x0808080808080808
    dq 0x8888888888888888

align 16
pat15:
    dq 0x0F0F0F0F0F0F0F0F
    dq 0xF5F5F5F5F5F5F5F5

align 16
tmp:
    times 16 db 0

align 16
fx_buf:
    times 512 db 0

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
