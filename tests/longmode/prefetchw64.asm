; Multiboot payload: PREFETCH/PREFETCHW (0F 0D /r), 0F 18 hints, and 0F 1F NOP.
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

    ; CPUID.80000001: ECX bit 8 (PREFETCHW).
    mov eax, 0x80000001
    cpuid
    test ecx, (1 << 8)
    jz fail_cpuid

    mov rax, 0xA5A5A5A5A5A5A5A5
    mov [buf], rax

    prefetchw [buf]
    cmp qword [buf], rax
    jne fail_prefetchw

    prefetch [buf]
    cmp qword [buf], rax
    jne fail_prefetch

    ; 0F 18 PREFETCHNTA/T0/T1/T2 are hint nops; memory unchanged.
    prefetcht0 [buf]
    prefetcht1 [buf]
    prefetcht2 [buf]
    prefetchnta [buf]
    cmp qword [buf], rax
    jne fail_18

    ; Register form 0F 0D /r (mod=11) must not #UD.
    db 0x0F, 0x0D, 0xC0
    cmp qword [buf], rax
    jne fail_reg

    ; 0F 1F multi-byte NOP (Linux FineIBT: nopl 0x0(%rax,%rax,1)).
    ; Must consume ModRM/SIB and not #GP a non-canonical EA.
    xor ecx, ecx
    db 0x0F, 0x1F, 0x44, 0x08, 0x00 ; nopl 0x0(%rax,%rcx,1) with rcx=0
    mov rdx, 0x0000800000000000
    db 0x0F, 0x1F, 0x02             ; nopl [rdx] non-canonical
    cmp qword [buf], rax
    jne fail_1f

    xor eax, eax
    out 0xF4, al
.ok:
    hlt
    jmp .ok

fail_cpuid:
    mov al, 2
    jmp fail_out
fail_prefetchw:
    mov al, 3
    jmp fail_out
fail_prefetch:
    mov al, 4
    jmp fail_out
fail_reg:
    mov al, 5
    jmp fail_out
fail_18:
    mov al, 6
    jmp fail_out
fail_1f:
    mov al, 7
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
    dq 0

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
