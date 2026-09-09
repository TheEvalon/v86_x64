; Multiboot payload: CMPXCHG8B, CMPXCHG16B, CMPXCHG r64, and CPUID.1 CX16 in long mode.
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
