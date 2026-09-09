; Multiboot payload: REX.W is ignored on 8-bit / size-independent ops;
; MOVSX/MOVZX r64 still widen to 64 bits (8- and 16-bit sources). CDQE/CQO sign-extend through RAX/RDX.
; TEST r64,imm32 sign-extends the immediate. Exit code is written to port 0xF4 (0 = pass).

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

    ; 1. REX.W ADD AL,1 must not #UD; only AL changes (high 56 bits stay).
    mov rax, 0x0123456789ABCDEF
    db 0x48, 0x04, 0x01
    mov rbx, 0x0123456789ABCDF0
    cmp rax, rbx
    jne fail_add_al

    ; 2. REX.W MOV r/m8,r8 stores one byte.
    mov qword [rel buf], 0xFFFFFFFFFFFFFFFF
    lea rbx, [rel buf]
    mov al, 0xA5
    db 0x48, 0x88, 0x03
    cmp byte [rel buf], 0xA5
    jne fail_mov_rm8
    cmp byte [rel buf + 1], 0xFF
    jne fail_mov_rm8

    ; 3. REX.W JZ rel8: taken when ZF=1, not taken when ZF=0.
    xor eax, eax
    db 0x48, 0x74, (jz_taken - $ - 3)
    jmp fail_jz_taken
jz_taken:
    mov eax, 1
    test eax, eax
    db 0x48, 0x74, (jz_wrong - $ - 3)
    jmp jz_ok
jz_wrong:
    jmp fail_jz_not_taken
jz_ok:

    ; 4. REX.W SAHF/LAHF match the 32-bit ops.
    mov ah, 0xD5
    sahf
    lahf
    mov dl, ah
    xor eax, eax
    mov ah, 0xD5
    db 0x48, 0x9E
    mov ah, 0
    db 0x48, 0x9F
    cmp ah, dl
    jne fail_sahf_lahf

    ; 5. REX.W+B MOV r8b,imm8 writes R8B only.
    mov r8, 0x0123456789ABCDEF
    db 0x49, 0xB0, 0x5A
    mov rax, 0x0123456789ABCD5A
    cmp r8, rax
    jne fail_mov_r8b

    ; 6. Real REX.W ADD r64 still updates the full 64-bit register.
    ; Carry out of AL distinguishes this from an 8-bit ADD.
    mov rax, 0x0123456789ABCDFF
    add rax, 1
    mov rbx, 0x0123456789ABCE00
    cmp rax, rbx
    jne fail_add64

    ; MOVSX r64, r/m8 of 0x80 is 0xFFFFFFFFFFFFFF80.
    ; 32-bit MOVSX + write_reg32 would yield 0x00000000FFFFFF80.
    mov rax, 0x0123456789ABCDEF
    mov bl, 0x80
    movsx rax, bl
    mov rcx, 0xFFFFFFFFFFFFFF80
    cmp rax, rcx
    jne fail_movsx8

    ; MOVSX r64, r/m16 of 0x8000 is 0xFFFFFFFFFFFF8000.
    mov rax, 0x0123456789ABCDEF
    mov dx, 0x8000
    movsx rax, dx
    mov rcx, 0xFFFFFFFFFFFF8000
    cmp rax, rcx
    jne fail_movsx16

    ; MOVZX r64, r/m8 clears the high 56 bits.
    mov rax, 0x0123456789ABCDEF
    mov bl, 0x80
    movzx rax, bl
    cmp rax, 0x80
    jne fail_movzx8

    ; MOVZX r64, r/m16 clears bits 63:16. 0x8000 must not sign-extend
    ; (MOVSX r16 of the same source is already checked above).
    mov rax, 0x0123456789ABCDEF
    mov dx, 0x8000
    movzx rax, dx
    cmp rax, 0x8000
    jne fail_movzx16

    ; CDQE sign-extends EAX to RAX. 32-bit CWDE sign-extends AX and
    ; would leave 0 here (AX of 0x80000000 is 0).
    mov rax, 0x0123456780000000
    cdqe
    mov rbx, 0xFFFFFFFF80000000
    cmp rax, rbx
    jne fail_cdqe

    mov rax, 0xFFFFFFFF7FFFFFFF
    cdqe
    mov rbx, 0x7FFFFFFF
    cmp rax, rbx
    jne fail_cdqe_pos

    ; CQO sign-extends RAX into RDX. 32-bit CDQ writes EDX=-1, which
    ; zero-extends to 0xFFFFFFFF instead of all ones.
    mov rax, -1
    xor edx, edx
    cqo
    cmp rdx, -1
    jne fail_cqo
    mov rax, 1
    cqo
    test rdx, rdx
    jnz fail_cqo_pos

    ; TEST r64, imm32 sign-extends the immediate. 2^32 TEST -1 is
    ; non-zero; 32-bit TEST of EAX=0 with -1 is zero.
    mov rax, 0x100000000
    test rax, -1
    jz fail_testimm

    xor eax, eax
    out 0xF4, al
    jmp hang64

fail_add_al:
    mov al, 2
    out 0xF4, al
    jmp hang64

fail_mov_rm8:
    mov al, 3
    out 0xF4, al
    jmp hang64

fail_jz_taken:
    mov al, 4
    out 0xF4, al
    jmp hang64

fail_jz_not_taken:
    mov al, 5
    out 0xF4, al
    jmp hang64

fail_sahf_lahf:
    mov al, 6
    out 0xF4, al
    jmp hang64

fail_mov_r8b:
    mov al, 7
    out 0xF4, al
    jmp hang64

fail_add64:
    mov al, 8
    out 0xF4, al
    jmp hang64

fail_movsx8:
    mov al, 9
    out 0xF4, al
    jmp hang64

fail_movsx16:
    mov al, 10
    out 0xF4, al
    jmp hang64

fail_movzx8:
    mov al, 11
    out 0xF4, al
    jmp hang64

fail_cdqe:
    mov al, 12
    out 0xF4, al
    jmp hang64

fail_cdqe_pos:
    mov al, 13
    out 0xF4, al
    jmp hang64

fail_cqo:
    mov al, 14
    out 0xF4, al
    jmp hang64

fail_cqo_pos:
    mov al, 15
    out 0xF4, al
    jmp hang64

fail_testimm:
    mov al, 16
    out 0xF4, al
    jmp hang64

fail_movzx16:
    mov al, 17
    out 0xF4, al
    jmp hang64

hang64:
    hlt
    jmp hang64

align 8
buf:
    dq 0

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
