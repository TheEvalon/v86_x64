; Multiboot payload: 67h truncates RSI/RDI/RCX for string ops and LOOP.
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
    cld

    mov rax, 0x0123456789ABCDEF
    mov [buf], rax
    mov qword [buf + 8], 0

    lea rbx, [buf]

    ; 67h LODSQ: RSI = buf|4GiB uses EAX-width RSI, not #PF at +4GiB.
    mov rsi, rbx
    mov rcx, 0x0000000100000000
    or rsi, rcx
    xor eax, eax
    a32 lodsq
    mov rcx, 0x0123456789ABCDEF
    cmp rax, rcx
    jne fail_lods
    lea rcx, [rbx + 8]
    cmp rsi, rcx
    jne fail_lods_rsi

    ; 67h STOSQ: same truncation on RDI; destination is buf, not +4GiB.
    mov rdi, rbx
    mov rcx, 0x0000000100000000
    or rdi, rcx
    mov rax, 0xA5A5A5A5A5A5A5A5
    a32 stosq
    cmp qword [buf], rax
    jne fail_stos
    lea rcx, [rbx + 8]
    cmp rdi, rcx
    jne fail_stos_rdi

    ; 67h REP STOSQ: RCX = 4GiB+2 stores two qwords, then ECX/RCX is 0.
    lea rdi, [buf]
    xor eax, eax
    mov rcx, 0x0000000100000002
    a32 rep stosq
    cmp qword [buf], 0
    jne fail_rep
    cmp qword [buf + 8], 0
    jne fail_rep
    test rcx, rcx
    jnz fail_rep_rcx

    ; 67h LOOP: RCX = 4GiB+3 iterates three times; write_reg32 zeros the high half.
    mov rcx, 0x0000000100000003
    xor eax, eax
.loop67:
    inc eax
    a32 loop .loop67
    cmp eax, 3
    jne fail_loop
    test rcx, rcx
    jnz fail_loop_rcx

    ; 67h JECXZ: ECX=0 even though RCX has bit 32 set.
    mov rcx, 0x0000000100000000
    a32 jecxz jecxz_ok
    jmp fail_jecxz
jecxz_ok:

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_lods:
    mov al, 2
    jmp fail_out
fail_lods_rsi:
    mov al, 3
    jmp fail_out
fail_stos:
    mov al, 4
    jmp fail_out
fail_stos_rdi:
    mov al, 5
    jmp fail_out
fail_rep:
    mov al, 6
    jmp fail_out
fail_rep_rcx:
    mov al, 7
    jmp fail_out
fail_loop:
    mov al, 8
    jmp fail_out
fail_loop_rcx:
    mov al, 9
    jmp fail_out
fail_jecxz:
    mov al, 10
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

align 8
buf:
    times 32 db 0xFF

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
