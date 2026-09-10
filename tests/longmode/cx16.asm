; Multiboot payload: CMPXCHG8B, CMPXCHG16B, CMPXCHG r64/r16, XCHG r64, CMP r64, and CPUID.1 CX16 in long mode.
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

    mov eax, 1
    cpuid
    test ecx, (1 << 13)
    jz fail_cx16

    mov eax, gp_handler
    mov word [idt_vec13], ax
    shr eax, 16
    mov word [idt_vec13 + 6], ax
    lidt [idt_desc]

    ; Mismatch: m128 is loaded into RDX:RAX, memory is unchanged, ZF=0.
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov rdx, 0xBBBBBBBBBBBBBBBB
    mov rbx, 0x3333333333333333
    mov rcx, 0x4444444444444444
    lock cmpxchg16b [m128]
    jz fail_mismatch
    mov r8, 0xA1A2A3A4A5A6A7A8
    mov r9, 0xB1B2B3B4B5B6B7B8
    cmp rax, r8
    jne fail_mismatch
    cmp rdx, r9
    jne fail_mismatch
    cmp qword [m128], r8
    jne fail_mismatch
    cmp qword [m128 + 8], r9
    jne fail_mismatch

    ; Match: RCX:RBX is stored, ZF=1, RDX:RAX unchanged.
    mov rbx, 0xC1C2C3C4C5C6C7C8
    mov rcx, 0xD1D2D3D4D5D6D7D8
    lock cmpxchg16b [m128]
    jnz fail_match
    cmp rax, r8
    jne fail_match
    cmp rdx, r9
    jne fail_match
    cmp qword [m128], rbx
    jne fail_match
    cmp qword [m128 + 8], rcx
    jne fail_match

    ; CMPXCHG8B uses EDX:EAX / ECX:EBX even in 64-bit CS (not RDX:RAX).
    mov eax, 0xAAAAAAAA
    mov edx, 0xBBBBBBBB
    mov ebx, 0x33333333
    mov ecx, 0x44444444
    lock cmpxchg8b [m64]
    jz fail_c8_miss
    cmp eax, 0xA1A2A3A4
    jne fail_c8_miss
    cmp edx, 0xB1B2B3B4
    jne fail_c8_miss
    cmp dword [m64], 0xA1A2A3A4
    jne fail_c8_miss
    cmp dword [m64 + 4], 0xB1B2B3B4
    jne fail_c8_miss

    mov ebx, 0xC1C2C3C4
    mov ecx, 0xD1D2D3D4
    lock cmpxchg8b [m64]
    jnz fail_c8_match
    cmp dword [m64], 0xC1C2C3C4
    jne fail_c8_match
    cmp dword [m64 + 4], 0xD1D2D3D4
    jne fail_c8_match

    ; CMPXCHG r64, r64 uses RAX. Mismatch: dest -> RAX, dest unchanged, ZF=0.
    mov r8, 0x1111111111111111
    mov r9, 0x2222222222222222
    mov rax, 0xAAAAAAAAAAAAAAAA
    cmpxchg r8, r9
    jz fail_cx_miss
    mov rbx, 0x1111111111111111
    cmp rax, rbx
    jne fail_cx_miss
    cmp r8, rbx
    jne fail_cx_miss

    ; Match: r9 is stored, ZF=1, RAX unchanged.
    cmpxchg r8, r9
    jnz fail_cx_match
    cmp r8, r9
    jne fail_cx_match
    cmp rax, rbx
    jne fail_cx_match

    ; 66 0F B1 CMPXCHG r/m16. Must not run as 32-bit: XP MMPFN ReferenceCount
    ; is a word at +0x18 with flags in the next word. A dword compare of
    ; EAX=refcount vs [m]=refcount|flags<<16 fails, or a dword store zeros flags.
    mov dword [m16], 0xAABB0002
    mov eax, 2
    mov ecx, 1
    cmpxchg word [m16], cx
    jnz fail_cx16w
    cmp word [m16], 1
    jne fail_cx16w
    cmp word [m16 + 2], 0xAABB
    jne fail_cx16w
    cmp eax, 2
    jne fail_cx16w

    mov dword [m16], 0xAABB0005
    mov eax, 2
    mov ecx, 9
    cmpxchg word [m16], cx
    jz fail_cx16w_miss
    cmp eax, 5
    jne fail_cx16w_miss
    cmp dword [m16], 0xAABB0005
    jne fail_cx16w_miss

    ; XCHG r64 swaps the full 64-bit registers. 32-bit XCHG would leave
    ; the high halves in place (both sources are 0 below 2^32).
    mov rax, 0x100000000
    mov rbx, 0x200000000
    xchg rax, rbx
    mov rcx, 0x200000000
    cmp rax, rcx
    jne fail_xchg
    mov rcx, 0x100000000
    cmp rbx, rcx
    jne fail_xchg
    mov rax, 0x100000000
    mov r8, 0x300000000
    xchg rax, r8
    mov rcx, 0x300000000
    cmp rax, rcx
    jne fail_xchg
    mov rcx, 0x100000000
    cmp r8, rcx
    jne fail_xchg

    ; CMP r64 of 2^32 vs 1. 32-bit CMP of EAX=0 vs 1 is below.
    mov rax, 0x100000000
    cmp rax, 1
    jb fail_cmp
    je fail_cmp
    cmp rax, rax
    jne fail_cmp

    mov byte [gp_expected], 1
    lock cmpxchg16b [m128 + 1]
    mov al, 5
    out 0xF4, al
    jmp hang64

gp_handler:
    pop rcx
    cmp byte [gp_expected], 1
    jne fail_gp
    test ecx, ecx
    jnz fail_gp
    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_cx16:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_mismatch:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_match:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_gp:
    mov al, 6
    out 0xF4, al
    jmp hang64

fail_c8_miss:
    mov al, 7
    out 0xF4, al
    jmp hang64

fail_c8_match:
    mov al, 8
    out 0xF4, al
    jmp hang64

fail_cx_miss:
    mov al, 9
    out 0xF4, al
    jmp hang64

fail_cx_match:
    mov al, 10
    out 0xF4, al
    jmp hang64

fail_xchg:
    mov al, 11
    out 0xF4, al
    jmp hang64

fail_cmp:
    mov al, 12
    out 0xF4, al
    jmp hang64

fail_cx16w:
    mov al, 13
    out 0xF4, al
    jmp hang64

fail_cx16w_miss:
    mov al, 14
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
idt:
    times 13 * 16 db 0
idt_vec13:
    dw 0
    dw 0x08
    db 0
    db 0x8E
    dw 0
    dd 0
    dd 0
idt_end:

idt_desc:
    dw idt_end - idt - 1
    dq idt

align 8
m64:
    dd 0xA1A2A3A4
    dd 0xB1B2B3B4

align 4
m16:
    dd 0

align 16
m128:
    dq 0xA1A2A3A4A5A6A7A8
    dq 0xB1B2B3B4B5B6B7B8

gp_expected:
    db 0

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
