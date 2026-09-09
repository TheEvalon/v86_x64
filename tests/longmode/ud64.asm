; Multiboot payload: #UD for opcodes that are invalid in 64-bit mode.
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

    mov eax, ud_handler
    mov word [idt_vec6], ax
    shr eax, 16
    mov word [idt_vec6 + 6], ax
    lidt [idt_desc]

    mov dword [ud_count], 0
    nop
    cmp dword [ud_count], 0
    jne fail_nop

    ; One-byte opcodes that are invalid in 64-bit mode. The handler skips 1 byte.
    db 0x27 ; DAA
    db 0x60 ; PUSHAD
    db 0xCE ; INTO

    cmp dword [ud_count], 3
    jb fail_count

    xor eax, eax
    out 0xF4, al
    jmp hang64

ud_handler:
    ; #UD has no error code. IRETQ frame: RIP, CS, RFLAGS, RSP, SS.
    cmp word [rsp + 8], 0x08
    jne fail_frame
    add qword [rsp], 1
    inc dword [ud_count]
    iretq

fail_nop:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_count:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_frame:
    mov al, 4
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
    times 6 * 16 db 0
idt_vec6:
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

ud_count:
    dd 0

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
