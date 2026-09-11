; Multiboot payload: higher-half RIP at Linux's 0xffffffff81000000 window,
; RIP-relative LGDT/LIDT, higher-half IDT/#PF delivery, IRETQ, and INVLPG.
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
    mov r13, rsp
    mov rax, 0xFFFFFFFF90000000
    mov rbx, [rax]
    cmp rsp, r13
    jne fail_iret_rsp
    mov ecx, 0xAABBCCDD
    cmp rax, rcx
    jne fail_pf
    cmp ebx, 0
    jne fail_pf
    mov rax, [rel saved_cr2]
    mov rcx, 0xFFFFFFFF90000000
    cmp rax, rcx
    jne fail_cr2

    ; Direct-map VA (PML4[273]). Linux copy_bootdata uses __va(boot_params).
    mov qword [rel saved_cr2], 0
    mov rax, 0xffff888000083cb0
    mov rbx, [rax]
    mov rax, [rel saved_cr2]
    mov rcx, 0xffff888000083cb0
    cmp rax, rcx
    jne fail_cr2

    ; INVLPG of the mapped higher-half page: no #PF/#GP, first byte still `cld`.
    ; `mov m64, imm64` does not exist; keep the sentinel as a 32-bit 0.
    mov qword [rel saved_cr2], 0
    mov rax, HIGHER_KERNEL
    invlpg [rax]
    db 0x48
    invlpg [rax]
    cmp qword [rel saved_cr2], 0
    jne fail_invlpg
    cmp byte [rax], 0xFC
    jne fail_invlpg

    ; INVLPG of an unmapped canonical hole must not itself #PF; the load still
    ; does, with CR2 equal to the hole. Encoding of `mov rbx, [rax]` is 3 bytes
    ; so the existing #PF handler's RIP skip stays correct.
    mov qword [rel saved_cr2], 0
    mov rax, 0xFFFFFFFF90000000
    invlpg [rax]
    cmp qword [rel saved_cr2], 0
    jne fail_invlpg
    xor ebx, ebx
    mov rbx, [rax]
    mov ecx, 0xAABBCCDD
    cmp rax, rcx
    jne fail_invlpg_pf
    cmp ebx, 0
    jne fail_invlpg_pf
    mov rax, [rel saved_cr2]
    mov rcx, 0xFFFFFFFF90000000
    cmp rax, rcx
    jne fail_invlpg_cr2

    ; 1GB page at VA 0x40000000 identity-maps phys 0. The relocated
    ; payload at 16MB starts with `cld`.
    mov rax, 0x41000000
    cmp byte [rax], 0xFC
    jne fail_1g
    mov ebx, [rax]
    test ebx, ebx
    jz fail_1g

    ; POP m64 into a higher-half page whose low 32 bits are >4K from RSP
    ; (stack is in 0xffffffff8100xxxx). A leftover pending_linear64 from the
    ; stack read used to truncate the store to VA 0x80001000 (unmapped).
    mov rax, 0xFFFFFFFF80001000
    mov rbx, 0x1122334455667788
    mov qword [rax], 0
    push rbx
    pop qword [rax]
    cmp qword [rax], rbx
    jne fail_popm

    ; XLAT uses RBX+AL. is_asize_32() is sticky-true in 64-bit CS, so the
    ; 32-bit helper would truncate a higher-half table pointer.
    lea rbx, [bitmap]
    mov byte [rbx], 0xAA
    mov byte [rbx + 1], 0xBB
    mov al, 1
    xlat
    cmp al, 0xBB
    jne fail_xlat

    ; 32-bit BTS with a bit offset one page away. bt_mem used i32
    ; arithmetic and the 4K pending window, so the bit landed at a
    ; truncated low VA instead of bitmap+0x1000.
    lea rax, [bitmap]
    xor ecx, ecx
    mov [rax], ecx
    mov [rax + 0x1000], ecx
    mov ecx, 0x8000
    bts dword [rax], ecx
    test byte [rax + 0x1000], 1
    jz fail_bts32
    cmp byte [rax], 0
    jne fail_bts32

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
    db 0x0f, 0x20, 0xd0
    mov [rel saved_cr2], rax
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

fail_cr2:
    mov al, 5
    out 0xF4, al
    jmp hang64

fail_invlpg:
    mov al, 6
    out 0xF4, al
    jmp hang64

fail_invlpg_pf:
    mov al, 7
    out 0xF4, al
    jmp hang64

fail_invlpg_cr2:
    mov al, 8
    out 0xF4, al
    jmp hang64
fail_1g:
    mov al, 9
    out 0xF4, al
    jmp hang64
fail_popm:
    mov al, 10
    out 0xF4, al
    jmp hang64
fail_bts32:
    mov al, 11
    out 0xF4, al
    jmp hang64
fail_xlat:
    mov al, 12
    out 0xF4, al
    jmp hang64
fail_iret_rsp:
    mov al, 13
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

align 8
saved_cr2:
    dq 0

align 16
    times 4096 db 0
stack_high:

align 4096
bitmap:
    times 8192 db 0

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
    dq 0x0000000000000183
    times 510 dq 0

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
    times 119 dq 0
    ; PDE[128] is VA 0xffffffff90000000. Not-present with bits 32–47 set
    ; (prototype-style software fields). Checking phys>32 before Present
    ; used to panic the debug wasm instead of delivering #PF.
    dq 0x0000FFFF00000000
    times 383 dq 0

align 16
    times 4096 db 0
stack_low:
