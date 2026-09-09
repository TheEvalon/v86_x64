; Multiboot payload: 64-bit ENTER (0xC8) / LEAVE, plus IMUL/DIV/IDIV r64.
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

    ; Distinct frame pointer so [rbp] after ENTER is a real check.
    mov rbp, 0x1122334455667788
    mov r12, rsp
    mov r13, rbp

    enter 32, 0

    ; RBP == old_RSP - 8
    mov rax, r12
    sub rax, 8
    cmp rbp, rax
    jne fail_rbp_slot

    ; [rbp] == old_RBP
    cmp qword [rbp], r13
    jne fail_saved_rbp

    ; RSP == RBP - 32
    mov rax, rbp
    sub rax, 32
    cmp rsp, rax
    jne fail_alloc

    leave

    cmp rsp, r12
    jne fail_leave_rsp
    cmp rbp, r13
    jne fail_leave_rbp

    ; IMUL r64, r/m64: 2^32 * 3. 32-bit IMUL would use EAX=0.
    mov rax, 0x100000000
    mov rbx, 3
    imul rax, rbx
    mov rcx, 0x300000000
    cmp rax, rcx
    jne fail_imul

    ; IMUL r64, r/m64, imm8.
    mov rax, 0x100000000
    imul rdx, rax, 3
    cmp rdx, rcx
    jne fail_imul_imm

    ; DIV r64: 2^64 / 2. 32-bit DIV uses EDX:EAX = 2^32 / 2 = 2^31.
    mov rdx, 1
    xor eax, eax
    mov rbx, 2
    div rbx
    mov rcx, 0x8000000000000000
    cmp rax, rcx
    jne fail_div
    test rdx, rdx
    jnz fail_div

    ; Remainder occupies RDX: 0x300000001 / 3 = 2^32 rem 1.
    xor edx, edx
    mov rax, 0x300000001
    mov rbx, 3
    div rbx
    mov rcx, 0x100000000
    cmp rax, rcx
    jne fail_div_rem
    cmp rdx, 1
    jne fail_div_rem

    ; IDIV r64 truncates toward zero: -7 / 3 = -2 rem -1.
    ; 32-bit IDIV writes EAX=-2, which zero-extends instead of staying -2.
    mov rdx, -1
    mov rax, -7
    mov rbx, 3
    idiv rbx
    cmp rax, -2
    jne fail_idiv
    cmp rdx, -1
    jne fail_idiv

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_rbp_slot:
    mov al, 2
    jmp fail_out
fail_saved_rbp:
    mov al, 3
    jmp fail_out
fail_alloc:
    mov al, 4
    jmp fail_out
fail_leave_rsp:
    mov al, 5
    jmp fail_out
fail_leave_rbp:
    mov al, 6
    jmp fail_out
fail_imul:
    mov al, 7
    jmp fail_out
fail_imul_imm:
    mov al, 8
    jmp fail_out
fail_div:
    mov al, 9
    jmp fail_out
fail_div_rem:
    mov al, 10
    jmp fail_out
fail_idiv:
    mov al, 11
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
