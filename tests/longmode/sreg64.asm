; Multiboot payload: 64-bit PUSH/POP FS and GS, LAR/LSL/VERR/VERW, SMSW, and CLTS.
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

    ; PUSH FS: 8-byte stack, selector zero-extended (not 32-bit PUSH).
    mov rsp, stack_top
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov [rsp-8], rax
    mov ax, 0x10
    mov fs, ax
    push fs
    mov rbx, stack_top
    sub rbx, rsp
    cmp rbx, 8
    jne fail_push_fs_size
    pop rax
    cmp rax, 0x10
    jne fail_push_fs_ext

    ; PUSH GS / POP RAX: same 8-byte zero-extended write.
    mov rsp, stack_top
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov [rsp-8], rax
    mov ax, 0x10
    mov gs, ax
    push gs
    mov rbx, stack_top
    sub rbx, rsp
    cmp rbx, 8
    jne fail_push_gs_size
    pop rax
    cmp rax, 0x10
    jne fail_push_gs_ext

    ; Round-trip PUSH FS / POP FS restores the selector.
    mov rsp, stack_top
    mov ax, 0x10
    mov fs, ax
    xor eax, eax
    push fs
    mov fs, ax
    pop fs
    mov ax, fs
    cmp ax, 0x10
    jne fail_pop_fs

    ; PUSH FS / POP GS copies the selector.
    mov rsp, stack_top
    mov ax, 0x10
    mov fs, ax
    xor eax, eax
    mov gs, ax
    push fs
    pop gs
    mov ax, gs
    cmp ax, 0x10
    jne fail_pop_gs

    ; 66h is ignored: operand size stays 64 bits.
    mov rsp, stack_top
    mov rax, 0xAAAAAAAAAAAAAAAA
    mov [rsp-8], rax
    mov ax, 0x10
    mov fs, ax
    o16 push fs
    mov rbx, stack_top
    sub rbx, rsp
    cmp rbx, 8
    jne fail_o16_push
    pop rax
    cmp rax, 0x10
    jne fail_o16_push

    mov rsp, stack_top
    mov ax, 0x10
    mov fs, ax
    xor eax, eax
    push fs
    mov fs, ax
    o16 pop fs
    mov rbx, stack_top
    sub rbx, rsp
    cmp rbx, 0
    jne fail_o16_pop
    mov ax, fs
    cmp ax, 0x10
    jne fail_o16_pop

    ; LAR/LSL of 64-bit CS (0x08): access rights 0x00AF9B00, G-limit 4GiB-1.
    mov ecx, 0x08
    mov rax, -1
    lar eax, ecx
    jnz fail_lar_zf
    cmp eax, 0x00AF9B00
    jne fail_lar
    shr rax, 32
    test rax, rax
    jnz fail_lar_high

    mov rax, -1
    lsl eax, ecx
    jnz fail_lsl_zf
    cmp eax, 0xFFFFFFFF
    jne fail_lsl

    ; REX.W LAR still writes 32-bit access rights (high half zero), not #UD.
    mov rax, -1
    lar rax, rcx
    jnz fail_rexw_lar
    mov rdx, 0x0000000000AF9B00
    cmp rax, rdx
    jne fail_rexw_lar

    ; Null selector: ZF clear, destination unchanged.
    mov eax, 0x12345678
    xor ecx, ecx
    lar eax, ecx
    jz fail_lar_null
    cmp eax, 0x12345678
    jne fail_lar_null

    ; VERR/VERW on writable data (0x10) vs execute-only-readable CS (0x08).
    mov ax, 0x10
    verr ax
    jnz fail_verr
    verw ax
    jnz fail_verw
    mov ax, 0x08
    verr ax
    jnz fail_verr_cs
    verw ax
    jz fail_verw_cs

    ; SMSW r32/r64 stores CR0 (Intel 64-bit: r32 gets CR0[31:0] zero-extended;
    ; r64 gets CR0[63:0]). Memory form is always CR0[15:0]. PE must be set.
    mov rcx, cr0
    test ecx, 1
    jz fail_smsw_pe
    smsw eax
    cmp eax, ecx
    jne fail_smsw_reg
    mov r8, -1
    o64 smsw r8
    cmp r8, rcx
    jne fail_smsw_reg

    mov word [smsw_buf], 0xFFFF
    smsw [smsw_buf]
    mov edx, ecx
    and edx, 0xFFFF
    cmp word [smsw_buf], dx
    jne fail_smsw_mem

    ; CLTS clears CR0.TS (bit 3). Set TS via MOV CR0, then CLTS; PE stays.
    mov rax, cr0
    or eax, 8
    mov cr0, rax
    mov rax, cr0
    test eax, 8
    jz fail_clts_set
    clts
    mov rax, cr0
    test eax, 8
    jnz fail_clts
    test eax, 1
    jz fail_clts

    xor eax, eax
    out 0xF4, al
    jmp hang64

fail_push_fs_size:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_push_fs_ext:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_push_gs_size:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_push_gs_ext:
    mov al, 5
    out 0xF4, al
    jmp hang64

fail_pop_fs:
    mov al, 6
    out 0xF4, al
    jmp hang64

fail_pop_gs:
    mov al, 7
    out 0xF4, al
    jmp hang64

fail_o16_push:
    mov al, 8
    out 0xF4, al
    jmp hang64

fail_o16_pop:
    mov al, 9
    out 0xF4, al
    jmp hang64

fail_lar_zf:
    mov al, 10
    out 0xF4, al
    jmp hang64

fail_lar:
    mov al, 11
    out 0xF4, al
    jmp hang64

fail_lar_high:
    mov al, 12
    out 0xF4, al
    jmp hang64

fail_lsl_zf:
    mov al, 13
    out 0xF4, al
    jmp hang64

fail_lsl:
    mov al, 14
    out 0xF4, al
    jmp hang64

fail_rexw_lar:
    mov al, 15
    out 0xF4, al
    jmp hang64

fail_lar_null:
    mov al, 16
    out 0xF4, al
    jmp hang64

fail_verr:
    mov al, 17
    out 0xF4, al
    jmp hang64

fail_verw:
    mov al, 18
    out 0xF4, al
    jmp hang64

fail_verr_cs:
    mov al, 19
    out 0xF4, al
    jmp hang64

fail_verw_cs:
    mov al, 20
    out 0xF4, al
    jmp hang64

fail_smsw_pe:
    mov al, 21
    out 0xF4, al
    jmp hang64

fail_smsw_reg:
    mov al, 22
    out 0xF4, al
    jmp hang64

fail_smsw_mem:
    mov al, 23
    out 0xF4, al
    jmp hang64

fail_clts_set:
    mov al, 24
    out 0xF4, al
    jmp hang64

fail_clts:
    mov al, 25
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

smsw_buf:
    dw 0

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
