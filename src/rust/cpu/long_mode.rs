//! Interpreter path for 64-bit CS (IA-32e, CS.L=1).
//!
//! JIT is not used here. Default operand size is 32 bits (existing
//! interpreter table). Near stack ops are forced 64-bit. REX.W selects
//! 64-bit ALU/MOV plus RIP-relative and other memory operands.

use crate::cpu::cpu::*;
use crate::cpu::global_pointers::*;
use crate::cpu::misc_instr::{adjust_stack_reg, pop64, push64};
use crate::cpu::modrm::resolve_modrm64;
use crate::paging::OrPageFault;
use crate::prefix;

pub const REX_B: u8 = 1 << 0;
pub const REX_X: u8 = 1 << 1;
pub const REX_R: u8 = 1 << 2;
pub const REX_W: u8 = 1 << 3;

pub fn efer_compute_lma(lme: bool, paging: bool, pae: bool) -> bool { lme && paging && pae }

unsafe fn rex_w() -> bool { *rex_prefix & REX_W != 0 }
unsafe fn rex_r() -> i32 { ((*rex_prefix & REX_R) != 0) as i32 }
unsafe fn rex_b() -> i32 { ((*rex_prefix & REX_B) != 0) as i32 }

unsafe fn gpr_opcode(opcode: i32) -> i32 { (opcode & 7) | rex_b() << 3 }
unsafe fn gpr_rm(modrm: i32) -> i32 { (modrm & 7) | rex_b() << 3 }
unsafe fn gpr_reg(modrm: i32) -> i32 { (modrm >> 3 & 7) | rex_r() << 3 }

fn parity64(result: u64) -> bool {
    let mut p = result as u8;
    p ^= p >> 4;
    p ^= p >> 2;
    p ^= p >> 1;
    p & 1 == 0
}

unsafe fn set_arith_flags64(result: u64, cf: bool, of: bool, af: bool) {
    *flags_changed = 0;
    let mut f =
        *flags & !(FLAG_CARRY | FLAG_PARITY | FLAG_ADJUST | FLAG_ZERO | FLAG_SIGN | FLAG_OVERFLOW);
    if cf {
        f |= FLAG_CARRY;
    }
    if of {
        f |= FLAG_OVERFLOW;
    }
    if af {
        f |= FLAG_ADJUST;
    }
    if result == 0 {
        f |= FLAG_ZERO;
    }
    if result & 1 << 63 != 0 {
        f |= FLAG_SIGN;
    }
    if parity64(result) {
        f |= FLAG_PARITY;
    }
    *flags = f;
}

unsafe fn add64(a: u64, b: u64) -> u64 {
    let (res, cf) = a.overflowing_add(b);
    let of = (a ^ res) & (b ^ res) & 1 << 63 != 0;
    let af = (a ^ b ^ res) & 0x10 != 0;
    set_arith_flags64(res, cf, of, af);
    res
}

unsafe fn sub64(a: u64, b: u64) -> u64 {
    let (res, cf) = a.overflowing_sub(b);
    let of = (a ^ b) & (a ^ res) & 1 << 63 != 0;
    let af = (a ^ b ^ res) & 0x10 != 0;
    set_arith_flags64(res, cf, of, af);
    res
}

unsafe fn cmp64(a: u64, b: u64) { let _ = sub64(a, b); }

unsafe fn rm64_addr_val(modrm: i32) -> OrPageFault<(Option<i32>, u64)> {
    if modrm < 0xC0 {
        let addr = modrm_resolve(modrm)?;
        Ok((Some(addr), safe_read64s(addr)?))
    }
    else {
        Ok((None, read_reg64(gpr_rm(modrm))))
    }
}

unsafe fn rm64_write(modrm: i32, addr: Option<i32>, value: u64) -> OrPageFault<()> {
    if let Some(a) = addr {
        safe_write64(a, value)
    }
    else {
        write_reg64(gpr_rm(modrm), value);
        Ok(())
    }
}

unsafe fn load_rm64(modrm: i32) -> OrPageFault<u64> { Ok(rm64_addr_val(modrm)?.1) }

unsafe fn finish_instruction() {
    *prefixes = 0;
    *rex_prefix = 0;
}

unsafe fn run_legacy_opcode(opcode: i32) {
    run_instruction(opcode | (is_osize_32() as i32) << 8);
    finish_instruction();
}

unsafe fn dispatch_rex_w(opcode: i32) {
    match opcode {
        0x05 => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            let rax = add64(read_reg64(EAX), imm);
            write_reg64(EAX, rax);
        },
        0x2D => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            let rax = sub64(read_reg64(EAX), imm);
            write_reg64(EAX, rax);
        },
        0x3D => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            cmp64(read_reg64(EAX), imm);
        },
        0x01 | 0x03 | 0x29 | 0x2B | 0x31 | 0x33 | 0x09 | 0x0B | 0x21 | 0x23 | 0x39 | 0x3B => {
            let modrm = return_on_pagefault!(read_imm8());
            let reg = gpr_reg(modrm);
            let (addr, rm) = return_on_pagefault!(rm64_addr_val(modrm));
            let r = read_reg64(reg);
            let (to_reg, result) = match opcode {
                0x01 => (false, add64(rm, r)),
                0x03 => (true, add64(r, rm)),
                0x29 => (false, sub64(rm, r)),
                0x2B => (true, sub64(r, rm)),
                0x31 => {
                    let v = rm ^ r;
                    set_arith_flags64(v, false, false, false);
                    (false, v)
                },
                0x33 => {
                    let v = r ^ rm;
                    set_arith_flags64(v, false, false, false);
                    (true, v)
                },
                0x09 => {
                    let v = rm | r;
                    set_arith_flags64(v, false, false, false);
                    (false, v)
                },
                0x0B => {
                    let v = r | rm;
                    set_arith_flags64(v, false, false, false);
                    (true, v)
                },
                0x21 => {
                    let v = rm & r;
                    set_arith_flags64(v, false, false, false);
                    (false, v)
                },
                0x23 => {
                    let v = r & rm;
                    set_arith_flags64(v, false, false, false);
                    (true, v)
                },
                0x39 => {
                    cmp64(rm, r);
                    finish_instruction();
                    return;
                },
                0x3B => {
                    cmp64(r, rm);
                    finish_instruction();
                    return;
                },
                _ => {
                    trigger_ud();
                    return;
                },
            };
            if to_reg {
                write_reg64(reg, result);
            }
            else {
                let _ = rm64_write(modrm, addr, result);
            }
        },
        0x81 | 0x83 => {
            let modrm = return_on_pagefault!(read_imm8());
            let extra = modrm >> 3 & 7;
            let (addr, dst) = return_on_pagefault!(rm64_addr_val(modrm));
            let imm = if opcode == 0x83 {
                return_on_pagefault!(read_imm8s()) as i64 as u64
            }
            else {
                return_on_pagefault!(read_imm32s()) as i64 as u64
            };
            match extra {
                0 => {
                    let _ = rm64_write(modrm, addr, add64(dst, imm));
                },
                5 => {
                    let _ = rm64_write(modrm, addr, sub64(dst, imm));
                },
                7 => cmp64(dst, imm),
                _ => {
                    dbg_log!("unhandled 64-bit group1 extra={}", extra);
                    trigger_ud();
                    return;
                },
            }
        },
        0x89 => {
            let modrm = return_on_pagefault!(read_imm8());
            if modrm < 0xC0 {
                let addr = return_on_pagefault!(modrm_resolve(modrm));
                let _ = safe_write64(addr, read_reg64(gpr_reg(modrm)));
            }
            else {
                write_reg64(gpr_rm(modrm), read_reg64(gpr_reg(modrm)));
            }
        },
        0x8B => {
            let modrm = return_on_pagefault!(read_imm8());
            let value = return_on_pagefault!(load_rm64(modrm));
            write_reg64(gpr_reg(modrm), value);
        },
        0x8D => {
            let modrm = return_on_pagefault!(read_imm8());
            if modrm >= 0xC0 {
                trigger_ud();
                return;
            }
            let addr = return_on_pagefault!(resolve_modrm64(modrm));
            write_reg64(gpr_reg(modrm), addr);
        },
        0xB8..=0xBF => {
            let imm = return_on_pagefault!(read_imm64());
            write_reg64(gpr_opcode(opcode), imm);
        },
        0xC7 => {
            let modrm = return_on_pagefault!(read_imm8());
            if (modrm >> 3 & 7) != 0 {
                trigger_ud();
                return;
            }
            if modrm < 0xC0 {
                let addr = return_on_pagefault!(modrm_resolve(modrm));
                let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
                let _ = safe_write64(addr, imm);
            }
            else {
                let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
                write_reg64(gpr_rm(modrm), imm);
            }
        },
        _ => {
            dbg_log!("unimplemented REX.W opcode {:02x}", opcode);
            trigger_ud();
            return;
        },
    }
    finish_instruction();
}

unsafe fn jump_near64(target: u64) {
    if gp_if_noncanonical(target) {
        return;
    }
    set_rip(target);
}

unsafe fn dispatch_forced64(opcode: i32) {
    match opcode {
        0x50..=0x57 => {
            return_on_pagefault!(push64(read_reg64(gpr_opcode(opcode))));
        },
        0x58..=0x5F => {
            let r = gpr_opcode(opcode);
            let value = return_on_pagefault!(pop64());
            write_reg64(r, value);
        },
        0x68 => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            return_on_pagefault!(push64(imm));
        },
        0x6A => {
            let imm = return_on_pagefault!(read_imm8s()) as i64 as u64;
            return_on_pagefault!(push64(imm));
        },
        0x8F => {
            let modrm = return_on_pagefault!(read_imm8());
            if modrm >> 3 & 7 != 0 {
                trigger_ud();
                return;
            }
            if modrm < 0xC0 {
                let addr = return_on_pagefault!(modrm_resolve(modrm));
                let value = return_on_pagefault!(pop64());
                return_on_pagefault!(safe_write64(addr, value));
            }
            else {
                let value = return_on_pagefault!(pop64());
                write_reg64(gpr_rm(modrm), value);
            }
        },
        0x9C => {
            if *flags & FLAG_VM != 0 && getiopl() < 3 {
                trigger_gp(0);
                return;
            }
            return_on_pagefault!(push64((get_eflags() & 0xFCFFFF) as u32 as u64));
        },
        0x9D => {
            if *flags & FLAG_VM != 0 && getiopl() < 3 {
                trigger_gp(0);
                return;
            }
            let old_eflags = *flags;
            update_eflags(return_on_pagefault!(pop64()) as i32);
            if old_eflags & FLAG_INTERRUPT == 0 && *flags & FLAG_INTERRUPT != 0 {
                handle_irqs();
            }
        },
        0xC2 => {
            let imm16 = return_on_pagefault!(read_imm16());
            let ip = return_on_pagefault!(pop64());
            jump_near64(ip);
            adjust_stack_reg(imm16);
        },
        0xC3 => {
            let ip = return_on_pagefault!(pop64());
            jump_near64(ip);
        },
        0xC9 => {
            let rbp = read_reg64(EBP);
            if rbp >> 32 != 0 {
                dbg_log!("#gp leave rbp {:x} exceeds 4G", rbp);
                trigger_gp(0);
                return;
            }
            let new_rbp = return_on_pagefault!(safe_read64s(get_seg_ss() + rbp as i32));
            write_reg64(ESP, rbp.wrapping_add(8));
            write_reg64(EBP, new_rbp);
        },
        0xCA | 0xCB => {
            dbg_log!("far RET not implemented in 64-bit CS");
            trigger_ud();
        },
        0xCF => iretq(),
        0xE8 => {
            let rel = return_on_pagefault!(read_imm32s());
            return_on_pagefault!(push64(get_rip()));
            jump_near64(get_rip().wrapping_add(rel as i64 as u64));
        },
        0xE9 => {
            let rel = return_on_pagefault!(read_imm32s());
            jump_near64(get_rip().wrapping_add(rel as i64 as u64));
        },
        0xEB => {
            let rel = return_on_pagefault!(read_imm8s());
            jump_near64(get_rip().wrapping_add(rel as i64 as u64));
        },
        0xFF => {
            let saved_rip = get_rip();
            let modrm = return_on_pagefault!(read_imm8());
            let extra = modrm >> 3 & 7;
            match extra {
                2 => {
                    let target = return_on_pagefault!(load_rm64(modrm));
                    return_on_pagefault!(push64(get_rip()));
                    jump_near64(target);
                },
                4 => {
                    let target = return_on_pagefault!(load_rm64(modrm));
                    jump_near64(target);
                },
                6 => {
                    let value = return_on_pagefault!(load_rm64(modrm));
                    return_on_pagefault!(push64(value));
                },
                _ => {
                    set_rip(saved_rip);
                    run_legacy_opcode(opcode);
                    return;
                },
            }
        },
        _ => {
            trigger_ud();
        },
    }
}

fn opcode_is_forced64(opcode: i32) -> bool {
    matches!(
        opcode,
        0x50..=0x5F
            | 0x68
            | 0x6A
            | 0x8F
            | 0x9C
            | 0x9D
            | 0xC2
            | 0xC3
            | 0xC9
            | 0xCA
            | 0xCB
            | 0xCF
            | 0xE8
            | 0xE9
            | 0xEB
            | 0xFF
    )
}

unsafe fn dispatch_opcode(opcode: i32) {
    if !is_osize_32() {
        run_legacy_opcode(opcode);
        return;
    }
    if opcode_is_forced64(opcode) {
        dispatch_forced64(opcode);
        finish_instruction();
        return;
    }
    if rex_w() {
        dispatch_rex_w(opcode);
        return;
    }
    run_legacy_opcode(opcode);
}

/// Fetch prefixes + opcode at CS:RIP and execute one 64-bit-mode instruction.
pub unsafe fn run_one() {
    dbg_assert!(*is_64);
    *rex_prefix = 0;
    *prefixes = 0;

    loop {
        let byte = return_on_pagefault!(read_imm8());
        match byte {
            0x26 => {
                *prefixes = *prefixes & !prefix::PREFIX_MASK_SEGMENT | (ES as u8 + 1);
            },
            0x2E => {
                *prefixes = *prefixes & !prefix::PREFIX_MASK_SEGMENT | (CS as u8 + 1);
            },
            0x36 => {
                *prefixes = *prefixes & !prefix::PREFIX_MASK_SEGMENT | (SS as u8 + 1);
            },
            0x3E => {
                *prefixes = *prefixes & !prefix::PREFIX_MASK_SEGMENT | (DS as u8 + 1);
            },
            0x64 => {
                *prefixes = *prefixes & !prefix::PREFIX_MASK_SEGMENT | (FS as u8 + 1);
            },
            0x65 => {
                *prefixes = *prefixes & !prefix::PREFIX_MASK_SEGMENT | (GS as u8 + 1);
            },
            0x66 => *prefixes |= prefix::PREFIX_MASK_OPSIZE,
            0x67 => *prefixes |= prefix::PREFIX_MASK_ADDRSIZE,
            0xF0 => {},
            0xF2 => *prefixes |= prefix::PREFIX_REPNZ,
            0xF3 => *prefixes |= prefix::PREFIX_REPZ,
            0x40..=0x4F => {
                *rex_prefix = byte as u8;
                let opcode = return_on_pagefault!(read_imm8());
                if opcode == 0x0F {
                    let opcode = return_on_pagefault!(read_imm8());
                    run_instruction0f_32(opcode);
                    finish_instruction();
                    return;
                }
                dispatch_opcode(opcode);
                return;
            },
            0x0F => {
                let opcode = return_on_pagefault!(read_imm8());
                run_instruction0f_32(opcode);
                finish_instruction();
                return;
            },
            _ => {
                dispatch_opcode(byte);
                return;
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cpu::cpu::{IdtGate64, SegmentDescriptor};

    #[test]
    fn lma_requires_lme_pae_and_paging() {
        assert!(!efer_compute_lma(true, true, false));
        assert!(!efer_compute_lma(true, false, true));
        assert!(!efer_compute_lma(false, true, true));
        assert!(efer_compute_lma(true, true, true));
    }

    #[test]
    fn long_code_descriptor_has_l_not_d() {
        let long = SegmentDescriptor::of_u64(0x00AF_9B00_0000_FFFF);
        assert!(long.is_long());
        assert!(!long.is_32());
        assert!(long.is_executable());

        let compat = SegmentDescriptor::of_u64(0x00CF_9B00_0000_FFFF);
        assert!(!compat.is_long());
        assert!(compat.is_32());
    }

    #[test]
    fn idt_gate64_offset_concatenates_halves() {
        let gate = IdtGate64::of_u64s(0x9ABC_8E00_0008_DEF0, 0x0000_0000_1234_5678);
        assert_eq!(gate.offset(), 0x1234_5678_9ABC_DEF0);
        assert_eq!(gate.selector(), 0x0008);
        assert_eq!(gate.ist(), 0);
        assert!(gate.is_present());
        assert_eq!(gate.gate_type(), 0b110);
    }

    #[test]
    fn syscall_star_selectors_match_amd64() {
        let star = 0x0010_0008_0000_0000;
        let (kcs, kss, ucs, uss) = crate::cpu::cpu::syscall_star_selectors(star);
        assert_eq!(kcs, 0x08);
        assert_eq!(kss, 0x10);
        assert_eq!(ucs, 0x23);
        assert_eq!(uss, 0x1B);
    }

    #[test]
    fn canonical_va_is_48_bit() {
        use crate::cpu::cpu::is_canonical_va;
        assert!(is_canonical_va(0));
        assert!(is_canonical_va(0x0000_7FFF_FFFF_FFFF));
        assert!(!is_canonical_va(0x0000_8000_0000_0000));
        assert!(is_canonical_va(0xFFFF_8000_0000_0000));
        assert!(is_canonical_va(0xFFFF_FFFF_8000_0000));
        assert!(!is_canonical_va(0x0000_FFFF_8000_0000));
    }

    #[test]
    fn linux_minus_2gb_pml4_indices() {
        let va = 0xFFFF_FFFF_8000_0000u64;
        assert_eq!((va >> 39) & 0x1FF, 511);
        assert_eq!((va >> 30) & 0x1FF, 510);
        assert_eq!((va >> 21) & 0x1FF, 0);
    }
}
