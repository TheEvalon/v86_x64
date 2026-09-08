# AMD64 Long Mode - Plan

artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
date: 2026-09-08

## Goal Capsule

v86 currently emulates a 32-bit Pentium 4-class CPU. 64-bit extensions are an
explicit non-feature. This work adds **IA-32e long mode** so a guest can leave
legacy protected mode, enable 4-level paging, and run 64-bit code.

**First Windows target:** Windows XP Professional x64 Edition (AMD64), not
Windows 2000 (no 64-bit release) and not Windows XP 64-Bit Edition (Itanium).

**This implementation unit** does not boot XP x64. It makes long-mode *entry*
and a small 64-bit instruction subset work, proven by a multiboot payload.
That is the necessary first step toward XP x64 and 64-bit Linux.

## Why this slice

XP x64 needs almost a full AMD64 CPU: 64-bit GPRs and RIP, REX, 4-level
paging, SYSENTER/SYSCALL, 16-byte IDT gates, NX, a plausible CPUID, and a
large instruction surface. Landing all of that at once is not reviewable.

The smallest proof that the CPU is no longer i386-only is:

1. CPUID advertises long mode.
2. `IA32_EFER` exists and `LME` + `CR4.PAE` + `CR0.PG` sets `LMA`.
3. Page walks become 4-level while `LMA` is set.
4. A far jump into a CS with L=1 runs 64-bit instructions.
5. A guest can compute a 64-bit result and report it.

JIT stays off in 64-bit CS. Compatibility mode (LMA=1, CS.L=0) keeps the
existing 32-bit interpreter.

## Product Contract

### In scope (this change)

- CPUID extended leaves `0x80000000`, `0x80000001` (LM + NX), `0x80000008`.
- `IA32_EFER` (`0xC0000080`): SCE/LME/NXE writable; LMA derived.
- Long-mode activation / deactivation rules on `CR0.PG`, `CR4.PAE`, EFER.LME.
- 4-level paging while LMA=1, 32-bit physical addresses, 2MB pages.
- Allow the NX PTE bit (do not crash). Enforcement can stay incomplete.
- CS.L: 64-bit code segment, default 32-bit operand size.
- Interpreter-only 64-bit path: REX, 64-bit GPRs (RAX–R15), core ALU/MOV/CMP.
- Multiboot integration test that enters long mode and checks a 64-bit ADD.
- Saved emulator state grows additively (old images still load).

### Out of scope (later units)

- Windows XP x64 or any 64-bit Linux kernel boot.
- 64-bit JIT.
- Virtual addresses above 4GB / canonical higher-half.
- Physical addresses above 4GB; 1GB pages; 5-level paging.
- SYSCALL/SYSRET, SWAPGS, 64-bit IDT (16-byte gates), IST.
- RIP-relative addressing, 67h→32-bit (not 16-bit) address size.
- FS/GS base MSRs actually used as 64-bit bases.
- Itanium, ARM, or software Windows 2000 "64-bit" (does not exist).

### Success criteria

- Existing 32-bit behaviour is unchanged for guests that never touch EFER.
- `tests/longmode/enter64` exits through port `0xF4` with status 0.
- A 32-bit PAE guest that sets NX in page tables no longer trips a debug
  assert.

## Current architecture (what has to move)

| Area | Today | Long mode needs |
|---|---|---|
| GPRs | 8 × 32-bit at WASM offset 64 | RAX–RDI high halves + R8–R15; 32-bit writes zero-extend |
| RIP | `i32` | Stay 32-bit until higher-half (code below 4GB) |
| Prefixes | 66/67/seg/rep | REX `40–4F` in 64-bit CS (not INC/DEC) |
| Paging | 32-bit + legacy PAE (4 cached PDPTEs) | 4-level PML4 walk when LMA; skip PDPTE cache |
| Huge pages | PAE 2MB requires CR4.PSE | IA-32e 2MB uses PDE.PS; CR4.PSE ignored |
| CPUID `80000000` | Returns `eax=5` (hides extended leaves) | `eax=0x80000008` |
| `EFER` | Missing (WRMSR panics in debug) | Required |
| JIT | Page-at-a-time wasm | Disabled while CS.L=1 |
| Operand size | CS.D/B → `is_32` | CS.L=1 ⇒ default opsize 32 even though D=0 |

Guest RAM stays a 32-bit physical map (WASM heap). 64-bit *virtual* addresses
in this slice must fit in 32 bits (identity-map the low 2MB+).

## Boot sequence we must honour

Same sequence as kvm-unit-tests `cstart64.S` and every AMD64 OS:

1. 32-bit protected mode, paging off (multiboot).
2. `lgdt` with a 64-bit code descriptor (`L=1`, `D=0`).
3. `CR4.PAE=1`.
4. `CR3` = PML4 (not a PAE PDPT).
5. `WRMSR EFER.LME=1` (illegal to change LME while PG=1).
6. `CR0.PG=1` → CPU sets `EFER.LMA`. Still compatibility mode until CS.L.
7. Far jump to 64-bit CS.
8. 64-bit code; interrupts off for this test.

## Implementation Units

### U1. CPUID + EFER + CR0/CR4/CR3 long-mode control

Advertise LM/NX. Implement EFER. Derive LMA. #GP on illegal combinations
(PG without PAE while LME, clearing PAE while LMA, toggling LME while PG).

### U2. 4-level page walk

When LMA, walk PML4→PDPT→PD→PT (or 2MB PDE). Keep 32-bit PA. Stop asserting
on NX. Do not load the 4-entry PDPTE cache in IA-32e.

### U3. CS.L and 64-bit GPR file

`is_64` in WASM CPU state. Overlay high 32 bits of RAX–RDI and R8–R15 below
the rustc `global-base` (offset 2048). `write_reg32` zero-extends.

### U4. 64-bit interpreter (REX + core ISA)

In 64-bit CS, skip JIT. Decode REX. `REX.W` ops: MOV r64,imm64; ADD/SUB/CMP
r64. Other opcodes fall through to the 32-bit table with `is_osize_32()`.
PUSH/POP/CALL/RET 64-bit stack is next; the first test does not need them.

### U5. `tests/longmode/enter64`

NASM multiboot binary + Node runner (port `0xF4`, same convention as
kvm-unit-tests). Fail on #UD/#GP/#PF.

## Later units (not this PR)

- U6: RIP-relative, 64-bit addressing, PUSH/POP/CALL/RET, 64-bit IDT.
- U7: SYSCALL/SYSRET, SWAPGS, FS/GS bases, NX enforcement on fetch.
- U8: 48-bit canonical VA / hashed TLB (higher-half kernels).
- U9: 64-bit JIT.
- U10: Tiny 64-bit Linux (buildroot) as the second OS target.
- U11: Windows XP Professional x64 (ACPI off / Standard PC, same as 32-bit NT).

## Risks

- Advertising extended CPUID can make a 32-bit PAE kernel enable NX. The NX
  assert must go before any OS image is run.
- `67h` in 64-bit mode is 32-bit addressing; today the 32-bit core treats it
  as 16-bit. Do not use `67h` in tests until that is fixed.
- State images: new fields are appended; missing fields mean "legacy 32-bit".
- Original upstream v86 does not accept AI-authored PRs; this fork is the
  integration branch for AMD64 work.
