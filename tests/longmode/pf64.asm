; Multiboot payload: higher-half RIP at Linux's 0xffffffff81000000 window,
; RIP-relative LGDT/LIDT, higher-half IDT/#PF delivery, and IRETQ.
; Exit code is written to port 0xF4 (0 = pass).

BITS 32
ORG 0x100000

MULTIBOOT_MAGIC equ 0x1BADB002
MULTIBOOT_FLAGS equ 0x00010000
HIGHER_KERNEL   equ 0xFFFFFFFF81000000
PHYS_KERNEL     equ 0x1000000

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
    mov esp, stack_low

    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb fail32

    mov eax, 0x80000001
    cpuid
    test edx, (1 << 29)
    jz fail32

    ; Copy the 64-bit payload to 16MB so VA 0xffffffff81000000 maps it
    ; through a 2MB PDE (same layout as Linux PT_LOAD at LOAD_PHYSICAL_ADDR).
    mov esi, high_entry
    mov edi, PHYS_KERNEL
    mov ecx, high_end - high_entry
    cld
    rep movsb

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
    mov rax, HIGHER_KERNEL
    jmp rax

; Relocated to physical 0x1000000 / virtual 0xffffffff81000000.
high_entry:
    cld
    lea rax, [high_entry]
    mov rbx, HIGHER_KERNEL
    cmp rax, rbx
    jne fail_not_high

    lea rsp, [stack_high]
    lea rax, [gdt_high]
    mov [gdt_desc_high + 2], rax
    lgdt [gdt_desc_high]
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    lea rax, [handler]
    mov [idt_vec30], ax
    shr rax, 16
    mov [idt_vec30 + 6], ax
    shr rax, 16
    mov [idt_vec30 + 8], eax
    lea rax, [idt]
    mov [idt_desc_high + 2], rax
    lidt [idt_desc_high]

    xor eax, eax
    int 0x30
    mov ebx, 0xAABBCCDD
    cmp rax, rbx
    jne fail_int

    lea rax, [pf_handler]
    lea rdi, [idt]
    add rdi, 14 * 16
    mov [rdi], ax
    mov word [rdi + 2], 0x08
    mov byte [rdi + 4], 0
    mov byte [rdi + 5], 0x8E
    shr rax, 16
    mov [rdi + 6], ax
    shr rax, 16
    mov [rdi + 8], eax

    xor ebx, ebx
    mov rax, 0xFFFFFFFF90000000
    mov rbx, [rax]
    mov ecx, 0xAABBCCDD
    cmp rax, rcx
    jne fail_pf
    cmp ebx, 0
    jne fail_pf

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

handler:
    mov rax, 0xAABBCCDD
    iretq

pf_handler:
    add rsp, 8
    add qword [rsp], 3
    mov rax, 0xAABBCCDD
    iretq

fail_not_high:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_int:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_pf:
    mov al, 4
    out 0xF4, al
    jmp hang64
hang64:
    hlt
    jmp hang64

align 8
gdt_high:
    dq 0
    dq 0x00AF9B000000FFFF
    dq 0x00CF93000000FFFF
gdt_high_end:

gdt_desc_high:
    dw gdt_high_end - gdt_high - 1
    dq gdt_high

align 16
idt:
    times 0x30 * 16 db 0
idt_vec30:
    dw 0
    dw 0x08
    db 0
    db 0x8E
    dw 0
    dd 0
    dd 0
idt_end:

idt_desc_high:
    dw idt_end - idt - 1
    dq idt

align 16
    times 4096 db 0
stack_high:

high_end:

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
    times 510 dq 0
    dq pdpt_high + 0x07

align 4096
pdpt:
    dq pd + 0x07
    times 511 dq 0

align 4096
pdpt_high:
    times 510 dq 0
    dq pd + 0x07
    dq 0

align 4096
pd:
    dq 0x00000000000001E7
    times 7 dq 0
    dq 0x00000000010001E7
    times 503 dq 0

align 16
    times 4096 db 0
stack_low:
