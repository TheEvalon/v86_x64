; Multiboot payload: 64-bit POPCNT (F3 REX.W 0F B8) in long mode.
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

    ; 1. 32 bits set across both halves; 32-bit POPCNT would count only 16.
    mov rax, 0xFFFF0000FFFF0000
    popcnt rcx, rax
    jc fail_flags
    jo fail_flags
    js fail_flags
    jp fail_flags
    jz fail_zf0
    cmp rcx, 32
    jne fail_count32

    ; 2. Zero source: result 0, ZF=1.
    xor rax, rax
    popcnt rax, rax
    jnz fail_zf1
    test rax, rax
    jnz fail_zero

    ; 3. Memory form: three bits including bit 63.
    mov rax, 0x8000000000000005
    mov [mem64], rax
    popcnt rax, [mem64]
    cmp rax, 3
    jne fail_mem

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_count32:
    mov al, 2
    jmp fail_out
fail_zf0:
    mov al, 3
    jmp fail_out
fail_flags:
    mov al, 4
    jmp fail_out
fail_zero:
    mov al, 5
    jmp fail_out
fail_zf1:
    mov al, 6
    jmp fail_out
fail_mem:
    mov al, 7
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
mem64:
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
