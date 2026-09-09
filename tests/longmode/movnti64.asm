; Multiboot payload: REX.W MOVNTI m64, r64 and LFENCE/MFENCE/SFENCE in long mode.
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

    ; #UD handler for the register form. Vector 6, no error code.
    mov eax, ud_handler
    mov word [idt_vec6], ax
    shr eax, 16
    mov word [idt_vec6 + 6], ax
    lidt [idt_desc]

    ; 16-byte buffer of 0xFF; only the first qword must change.
    mov rax, -1
    mov [buf], rax
    mov [buf + 8], rax

    mov rax, 0x0123456789ABCDEF
    movnti [buf], rax
    cmp qword [buf], rax
    jne fail_qword
    cmp qword [buf + 8], -1
    jne fail_tail

    ; REX.R: source is r8, not rax.
    mov rax, -1
    mov [buf], rax
    mov [buf + 8], rax
    mov r8, 0xFEDCBA9876543210
    movnti [buf], r8
    cmp qword [buf], r8
    jne fail_r8
    cmp qword [buf + 8], -1
    jne fail_tail

    ; 66 prefix: REX.W still selects 64-bit operand size.
    mov rax, -1
    mov [buf], rax
    mov [buf + 8], rax
    mov rax, 0xA5A5A5A5A5A5A5A5
    db 0x66
    movnti [buf], rax
    cmp qword [buf], rax
    jne fail_66
    cmp qword [buf + 8], -1
    jne fail_tail

    ; LFENCE/MFENCE/SFENCE are serializing nops: no #UD, GPRs and the stored
    ; qword unchanged. REX.W is ignored (same encodings Linux emits).
    mov r8, 0x1111111111111111
    mov r9, 0x2222222222222222
    lfence
    mfence
    sfence
    db 0x48
    lfence
    db 0x48
    mfence
    db 0x48
    sfence
    mov rax, 0x1111111111111111
    cmp r8, rax
    jne fail_fence
    mov rax, 0x2222222222222222
    cmp r9, rax
    jne fail_fence
    mov rax, 0xA5A5A5A5A5A5A5A5
    cmp qword [buf], rax
    jne fail_fence
    cmp qword [buf + 8], -1
    jne fail_tail

    ; Register form is #UD. Encoding: REX.W 0F C3 /r (4 bytes).
    mov dword [ud_count], 0
    db 0x48, 0x0F, 0xC3, 0xD8 ; movnti rax, rbx
    cmp dword [ud_count], 1
    jne fail_ud

    xor eax, eax
    out 0xF4, al
    jmp hang64

ud_handler:
    ; #UD has no error code. IRETQ frame: RIP, CS, RFLAGS, RSP, SS.
    cmp word [rsp + 8], 0x08
    jne fail_frame
    add qword [rsp], 4
    inc dword [ud_count]
    iretq

fail_qword:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_tail:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_r8:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_66:
    mov al, 5
    out 0xF4, al
    jmp hang64

fail_ud:
    mov al, 6
    out 0xF4, al
    jmp hang64

fail_frame:
    mov al, 7
    out 0xF4, al
    jmp hang64

fail_fence:
    mov al, 8
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

align 16
buf:
    times 16 db 0

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
