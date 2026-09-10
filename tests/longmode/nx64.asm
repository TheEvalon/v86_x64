; Multiboot payload: load a legacy PAE PDPTE with NX (bit 63) while LME is
; still clear — XP x64 NTLDR does this — then enter long mode and #PF on an
; NX 4K fetch. Data reads of that page must succeed. Port 0xF4 (0 = pass).

BITS 32
ORG 0x100000

MULTIBOOT_MAGIC equ 0x1BADB002
MULTIBOOT_FLAGS equ 0x00010000
NX_VA           equ 0x200000

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
    test edx, (1 << 20)
    jz fail32

    lgdt [gdt_desc]

    mov eax, cr4
    or eax, 1 << 5
    mov cr4, eax

    ; Legacy PAE + NX in the PDPTE, paging on, LME still 0.
    mov eax, pae_pdpt
    mov cr3, eax
    mov eax, cr0
    or eax, 1 | (1 << 31)
    mov cr0, eax
    mov eax, [0x100000]
    mov eax, cr0
    and eax, 0x7FFFFFFF
    mov cr0, eax

    mov eax, pml4
    mov cr3, eax

    mov ecx, 0xC0000080
    rdmsr
    or eax, (1 << 8) | (1 << 11)
    wrmsr

    mov eax, cr0
    or eax, 1 | (1 << 31)
    mov cr0, eax

    mov ecx, 0xC0000080
    rdmsr
    test eax, (1 << 10)
    jz fail32
    test eax, (1 << 11)
    jz fail32

    jmp 0x08:start64

fail32:
    mov al, 1
    out 0xF4, al
.hang:
    hlt
    jmp .hang

BITS 64
start64:
    mov rsp, stack_top
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    mov eax, pf_handler
    mov word [idt_vec14], ax
    shr eax, 16
    mov word [idt_vec14 + 6], ax
    lidt [idt_desc]

    ; Data read of the NX page must not #PF.
    mov rax, NX_VA
    mov eax, [rax]

    mov rax, NX_VA
    jmp rax

pf_handler:
    pop rcx
    test ecx, (1 << 4)
    jz fail_ec
    test ecx, (1 << 1)
    jnz fail_ec
    mov rax, cr2
    mov rbx, NX_VA
    cmp rax, rbx
    jne fail_cr2
    mov rax, [rsp]
    cmp rax, rbx
    jne fail_rip
    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_ec:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_cr2:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_rip:
    mov al, 5
    out 0xF4, al
    jmp hang64

hang64:
    hlt
    jmp hang64

fail64:
    mov al, 2
    out 0xF4, al
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
    times 14 * 16 db 0
idt_vec14:
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

; 4-entry PAE PDPT (not the 512-entry IA-32e PDPT). Bit 63 = NX.
align 32
pae_pdpt:
    dq pae_pd + 0x8000000000000001
    dq 0
    dq 0
    dq 0

align 4096
pae_pd:
    dq 0x00000000000001E7
    times 511 dq 0

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
    dq pt_nx + 0x03
    times 510 dq 0

align 4096
pt_nx:
    dq nx_payload + 0x8000000000000003
    times 511 dq 0

align 4096
nx_payload:
    ud2
    mov al, 6
    out 0xF4, al
    times 4096 - ($ - nx_payload) db 0

align 16
    times 4096 db 0
stack_top:
