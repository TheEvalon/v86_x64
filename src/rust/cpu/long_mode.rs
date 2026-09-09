//! Interpreter path for 64-bit CS (IA-32e, CS.L=1).
//!
//! Default operand size is 32 bits (existing interpreter table). Near stack
//! ops are forced 64-bit. REX.W selects 64-bit ALU/MOV plus RIP-relative and
//! other memory operands. 32-bit-opsize ops in low 4GB may run through the
//! existing JIT; 64-bit-only encodings trampoline back here.

use crate::cpu::arith::{cmp16, cmp32, cmp8};
use crate::cpu::cpu::*;
use crate::cpu::global_pointers::*;
use crate::cpu::memory;
use crate::cpu::misc_instr::{
    adjust_stack_reg, get_stack_pointer, getcf, getzf, pop64, push64, test_b, test_be, test_l,
    test_le, test_o, test_p, test_s, test_z,
};
use crate::cpu::modrm::{resolve_lea64, resolve_modrm64};
use crate::jit;
use crate::page::Page;
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

unsafe fn adc64(a: u64, b: u64) -> u64 {
    let c = getcf() as u64;
    let (s1, o1) = a.overflowing_add(b);
    let (res, o2) = s1.overflowing_add(c);
    let cf = o1 || o2;
    let of = (a ^ res) & (b ^ res) & 1 << 63 != 0;
    let af = (a ^ b ^ res) & 0x10 != 0;
    set_arith_flags64(res, cf, of, af);
    res
}

unsafe fn sbb64(a: u64, b: u64) -> u64 {
    let c = getcf() as u64;
    let (s1, o1) = a.overflowing_sub(b);
    let (res, o2) = s1.overflowing_sub(c);
    let cf = o1 || o2;
    let of = (a ^ b) & (a ^ res) & 1 << 63 != 0;
    let af = (a ^ b ^ res) & 0x10 != 0;
    set_arith_flags64(res, cf, of, af);
    res
}

unsafe fn logic64(v: u64) -> u64 {
    set_arith_flags64(v, false, false, false);
    v
}

unsafe fn inc64(a: u64) -> u64 {
    let cf = getcf();
    let res = add64(a, 1);
    *flags = *flags & !FLAG_CARRY | cf as i32;
    res
}

unsafe fn dec64(a: u64) -> u64 {
    let cf = getcf();
    let res = sub64(a, 1);
    *flags = *flags & !FLAG_CARRY | cf as i32;
    res
}

unsafe fn shift_count64(count: i32) -> u32 { (count as u32) & 63 }

unsafe fn shl64(a: u64, count: i32) -> u64 {
    let n = shift_count64(count);
    if n == 0 {
        return a;
    }
    let res = a << n;
    let cf = a >> (64 - n) & 1 != 0;
    let of = n == 1 && (res >> 63 != 0) != cf;
    set_arith_flags64(res, cf, of, false);
    res
}

unsafe fn shr64(a: u64, count: i32) -> u64 {
    let n = shift_count64(count);
    if n == 0 {
        return a;
    }
    let res = a >> n;
    let cf = a >> (n - 1) & 1 != 0;
    let of = n == 1 && a >> 63 != 0;
    set_arith_flags64(res, cf, of, false);
    res
}

unsafe fn sar64(a: u64, count: i32) -> u64 {
    let n = shift_count64(count);
    if n == 0 {
        return a;
    }
    let res = ((a as i64) >> n) as u64;
    let cf = a >> (n - 1) & 1 != 0;
    set_arith_flags64(res, cf, false, false);
    res
}

unsafe fn rol64(a: u64, count: i32) -> u64 {
    let n = shift_count64(count);
    if n == 0 {
        return a;
    }
    let res = a.rotate_left(n);
    let cf = res & 1 != 0;
    let of = n == 1 && (res >> 63 != 0) != cf;
    *flags_changed = 0;
    *flags = *flags & !(FLAG_CARRY | FLAG_OVERFLOW) | cf as i32 | (of as i32) << 11;
    res
}

unsafe fn ror64(a: u64, count: i32) -> u64 {
    let n = shift_count64(count);
    if n == 0 {
        return a;
    }
    let res = a.rotate_right(n);
    let cf = res >> 63 != 0;
    let of = n == 1 && (res >> 63 != 0) != ((res >> 62) & 1 != 0);
    *flags_changed = 0;
    *flags = *flags & !(FLAG_CARRY | FLAG_OVERFLOW) | cf as i32 | (of as i32) << 11;
    res
}

unsafe fn rcl64(a: u64, count: i32) -> u64 {
    let n = shift_count64(count);
    if n == 0 {
        return a;
    }
    let cf_in = getcf() as u128;
    let val = a as u128 | cf_in << 64;
    let rotated = (val << n | val >> (65 - n)) & ((1u128 << 65) - 1);
    let res = rotated as u64;
    let cf = (rotated >> 64) & 1 != 0;
    let of = n == 1 && (res >> 63 != 0) != cf;
    *flags_changed = 0;
    *flags = *flags & !(FLAG_CARRY | FLAG_OVERFLOW) | cf as i32 | (of as i32) << 11;
    res
}

unsafe fn rcr64(a: u64, count: i32) -> u64 {
    let n = shift_count64(count);
    if n == 0 {
        return a;
    }
    let cf_in = getcf() as u128;
    let val = a as u128 | cf_in << 64;
    let rotated = (val >> n | val << (65 - n)) & ((1u128 << 65) - 1);
    let res = rotated as u64;
    let cf = (rotated >> 64) & 1 != 0;
    let of = n == 1 && (res >> 63 != 0) != ((res >> 62) & 1 != 0);
    *flags_changed = 0;
    *flags = *flags & !(FLAG_CARRY | FLAG_OVERFLOW) | cf as i32 | (of as i32) << 11;
    res
}

unsafe fn test64(a: u64, b: u64) { let _ = logic64(a & b); }

unsafe fn bsf64(old: u64, src: u64) -> u64 {
    *flags_changed = 0;
    if src == 0 {
        *flags |= FLAG_ZERO;
        old
    }
    else {
        *flags &= !FLAG_ZERO;
        src.trailing_zeros() as u64
    }
}

unsafe fn bsr64(old: u64, src: u64) -> u64 {
    *flags_changed = 0;
    if src == 0 {
        *flags |= FLAG_ZERO;
        old
    }
    else {
        *flags &= !FLAG_ZERO;
        63 - src.leading_zeros() as u64
    }
}

unsafe fn popcnt64(v: u64) -> u64 {
    *flags_changed = 0;
    *flags &= !FLAGS_ALL;
    if v != 0 {
        v.count_ones() as u64
    }
    else {
        *flags |= FLAG_ZERO;
        0
    }
}

unsafe fn bt64_flags(base: u64, bit: u64) {
    *flags_changed &= !FLAG_CARRY;
    if base & 1 << (bit & 63) != 0 {
        *flags |= FLAG_CARRY;
    }
    else {
        *flags &= !FLAG_CARRY;
    }
}

unsafe fn mul64(src: u64) {
    let a = read_reg64(EAX);
    let prod = (a as u128) * (src as u128);
    write_reg64(EAX, prod as u64);
    write_reg64(EDX, (prod >> 64) as u64);
    let hi = (prod >> 64) != 0;
    set_arith_flags64(prod as u64, hi, hi, false);
}

unsafe fn imul64_ax(src: u64) {
    let prod = (read_reg64(EAX) as i64 as i128) * (src as i64 as i128);
    write_reg64(EAX, prod as u64);
    write_reg64(EDX, (prod >> 64) as u64);
    let hi = (prod as u64) as i64 >> 63 != (prod >> 64) as i64;
    set_arith_flags64(prod as u64, hi, hi, false);
}

unsafe fn imul64_reg(a: u64, b: u64) -> u64 {
    let prod = (a as i64 as i128) * (b as i64 as i128);
    let res = prod as u64;
    let hi = (res as i64) >> 63 != (prod >> 64) as i64;
    set_arith_flags64(res, hi, hi, false);
    res
}

unsafe fn div64(src: u64) {
    if src == 0 {
        trigger_de();
        return;
    }
    let num = (read_reg64(EDX) as u128) << 64 | read_reg64(EAX) as u128;
    let q = num / src as u128;
    if q > u64::MAX as u128 {
        trigger_de();
        return;
    }
    write_reg64(EAX, q as u64);
    write_reg64(EDX, (num % src as u128) as u64);
}

unsafe fn idiv64(src: u64) {
    if src == 0 {
        trigger_de();
        return;
    }
    let num = (read_reg64(EDX) as i64 as i128) << 64 | read_reg64(EAX) as u128 as i128;
    let d = src as i64 as i128;
    if d == 0 {
        trigger_de();
        return;
    }
    let q = num / d;
    if q > i64::MAX as i128 || q < i64::MIN as i128 {
        trigger_de();
        return;
    }
    write_reg64(EAX, q as u64);
    write_reg64(EDX, (num % d) as u64);
}

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
    *pending_linear64 = 0;
    current_interp_opcode = 0;
    current_interp_0f = false;
}

fn is_hint_nop(opcode: i32) -> bool { matches!(opcode, 0x18 | 0x19 | 0x1C | 0x1D | 0x1E | 0x1F) }

/// 0F 18–1F are prefetch / multi-byte NOPs. They must not read memory or
/// #GP a non-canonical EA (Linux FineIBT uses `nopl 0x0(%rax,%rax,1)`).
unsafe fn dispatch_hint_nop() {
    let modrm = return_on_pagefault!(read_imm8());
    if modrm < 0xC0 {
        let _ = return_on_pagefault!(resolve_lea64(modrm));
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum String64 {
    Movs,
    Stos,
    Lods,
    Scas,
    Cmps,
    Ins,
    Outs,
}

unsafe fn string_read(addr: u64, width: i64) -> OrPageFault<u64> {
    *pending_linear64 = addr;
    match width {
        1 => Ok(safe_read8(addr as i32)? as u32 as u64),
        2 => Ok(safe_read16(addr as i32)? as u32 as u64),
        4 => Ok(safe_read32s(addr as i32)? as u32 as u64),
        8 => safe_read64s(addr as i32),
        _ => Ok(0),
    }
}

unsafe fn string_write(addr: u64, width: i64, v: u64) -> OrPageFault<()> {
    *pending_linear64 = addr;
    match width {
        1 => safe_write8(addr as i32, v as i32),
        2 => safe_write16(addr as i32, v as i32),
        4 => safe_write32(addr as i32, v as i32),
        8 => safe_write64(addr as i32, v),
        _ => Ok(()),
    }
}

unsafe fn string_cmp(width: i64, a: u64, b: u64) {
    match width {
        1 => cmp8(a as i32, b as i32),
        2 => cmp16(a as i32, b as i32),
        4 => cmp32(a as i32, b as i32),
        8 => cmp64(a, b),
        _ => {},
    }
}

unsafe fn string_ax(width: i64) -> u64 {
    match width {
        1 => read_reg8(AL) as u32 as u64,
        2 => read_reg16(AX) as u32 as u64,
        4 => read_reg32(EAX) as u32 as u64,
        8 => read_reg64(EAX),
        _ => 0,
    }
}

unsafe fn string_set_ax(width: i64, v: u64) {
    match width {
        1 => write_reg8(AL, v as i32),
        2 => write_reg16(AX, v as i32),
        4 => write_reg32(EAX, v as i32),
        8 => write_reg64(EAX, v),
        _ => {},
    }
}

unsafe fn string64(kind: String64, width: i64) {
    let asize32 = *prefixes & prefix::PREFIX_MASK_ADDRSIZE != 0;
    let dir = if *flags & FLAG_DIRECTION != 0 { -width } else { width };
    let rep = *prefixes & prefix::PREFIX_MASK_REP != 0;
    let mut rcx = if rep {
        if asize32 {
            read_reg32(ECX) as u32 as u64
        }
        else {
            read_reg64(ECX)
        }
    }
    else {
        1
    };
    if rcx == 0 {
        return;
    }
    let mut rsi = if asize32 { read_reg32(ESI) as u32 as u64 } else { read_reg64(ESI) };
    let mut rdi = if asize32 { read_reg32(EDI) as u32 as u64 } else { read_reg64(EDI) };
    let rax = string_ax(width);
    let repz = *prefixes & prefix::PREFIX_REPZ != 0;
    let repnz = *prefixes & prefix::PREFIX_REPNZ != 0;
    let page_of = |a: u64| a & !0xFFF;
    let mut cmp_stop = false;

    // Linux BSS/heap clears are `rep stosq` of 0. Do a whole page with memset
    // so a multi-megabyte REP does not block the JS event loop.
    if kind == String64::Stos && rep && dir > 0 {
        let splat = rax as u8;
        let splat_ok = match width {
            1 => true,
            2 => rax & 0xFFFF == splat as u64 * 0x0101,
            4 => rax & 0xFFFF_FFFF == splat as u64 * 0x0101_0101,
            8 => rax == splat as u64 * 0x0101_0101_0101_0101,
            _ => false,
        };
        if splat_ok && rdi & (width as u64 - 1) == 0 {
            let max_bytes = (0x1000 - (rdi & 0xFFF)).min(rcx.saturating_mul(width as u64));
            let n = max_bytes / width as u64;
            if n > 0 {
                *pending_linear64 = rdi;
                match translate_address_write_and_can_skip_dirty(rdi as i32) {
                    Ok((phys, skip)) => {
                        let nbytes = (n * width as u64) as u32;
                        if !memory::in_mapped_range(phys) && (phys & 0xFFF) + nbytes <= 0x1000 {
                            if !skip {
                                jit::jit_dirty_page(Page::page_of(phys));
                            }
                            memory::memset_no_mmap_or_dirty_check(phys, splat, nbytes);
                            rdi = rdi.wrapping_add(n * width as u64);
                            rcx -= n;
                        }
                    },
                    Err(()) => return,
                }
            }
        }
    }

    if kind == String64::Movs
        && rep
        && dir > 0
        && rdi & (width as u64 - 1) == 0
        && rsi & (width as u64 - 1) == 0
    {
        let max_bytes = (0x1000 - (rdi & 0xFFF))
            .min(0x1000 - (rsi & 0xFFF))
            .min(rcx.saturating_mul(width as u64));
        let n = max_bytes / width as u64;
        if n > 0 {
            *pending_linear64 = rsi;
            let src = match translate_address_read(rsi as i32) {
                Ok(p) => p,
                Err(()) => return,
            };
            *pending_linear64 = rdi;
            match translate_address_write_and_can_skip_dirty(rdi as i32) {
                Ok((dst, skip)) => {
                    let nbytes = (n * width as u64) as u32;
                    if !memory::in_mapped_range(src)
                        && !memory::in_mapped_range(dst)
                        && (src & 0xFFF) + nbytes <= 0x1000
                        && (dst & 0xFFF) + nbytes <= 0x1000
                    {
                        if !skip {
                            jit::jit_dirty_page(Page::page_of(dst));
                        }
                        memory::memcpy_no_mmap_or_dirty_check(src, dst, nbytes);
                        rsi = rsi.wrapping_add(n * width as u64);
                        rdi = rdi.wrapping_add(n * width as u64);
                        rcx -= n;
                    }
                },
                Err(()) => return,
            }
        }
    }

    if matches!(kind, String64::Ins | String64::Outs) {
        let port = read_reg16(DX);
        if !test_privileges_for_io(port, width as i32) {
            return;
        }
    }

    let start_rdi_page = page_of(rdi);
    let start_rsi_page = page_of(rsi);
    let mut slow = 0u32;
    const MAX_SLOW: u32 = 256;
    while rcx > 0 && slow < MAX_SLOW {
        if matches!(
            kind,
            String64::Movs | String64::Stos | String64::Scas | String64::Cmps | String64::Ins
        ) && page_of(rdi) != start_rdi_page
        {
            break;
        }
        if matches!(
            kind,
            String64::Movs | String64::Lods | String64::Cmps | String64::Outs
        ) && page_of(rsi) != start_rsi_page
        {
            break;
        }
        match kind {
            String64::Movs => {
                let v = return_on_pagefault!(string_read(rsi, width));
                return_on_pagefault!(string_write(rdi, width, v));
                rsi = rsi.wrapping_add(dir as u64);
                rdi = rdi.wrapping_add(dir as u64);
            },
            String64::Stos => {
                return_on_pagefault!(string_write(rdi, width, rax));
                rdi = rdi.wrapping_add(dir as u64);
            },
            String64::Lods => {
                string_set_ax(width, return_on_pagefault!(string_read(rsi, width)));
                rsi = rsi.wrapping_add(dir as u64);
            },
            String64::Scas => {
                string_cmp(width, rax, return_on_pagefault!(string_read(rdi, width)));
                rdi = rdi.wrapping_add(dir as u64);
            },
            String64::Cmps => {
                let a = return_on_pagefault!(string_read(rsi, width));
                let b = return_on_pagefault!(string_read(rdi, width));
                string_cmp(width, a, b);
                rsi = rsi.wrapping_add(dir as u64);
                rdi = rdi.wrapping_add(dir as u64);
            },
            String64::Ins => {
                *pending_linear64 = rdi;
                return_on_pagefault!(writable_or_pagefault(rdi as i32, width as i32));
                let port = read_reg16(DX);
                let v = match width {
                    1 => io_port_read8(port) as u32 as u64,
                    2 => io_port_read16(port) as u32 as u64,
                    _ => io_port_read32(port) as u32 as u64,
                };
                return_on_pagefault!(string_write(rdi, width, v));
                rdi = rdi.wrapping_add(dir as u64);
            },
            String64::Outs => {
                let port = read_reg16(DX);
                let v = return_on_pagefault!(string_read(rsi, width));
                match width {
                    1 => io_port_write8(port, v as i32),
                    2 => io_port_write16(port, v as i32),
                    _ => io_port_write32(port, v as i32),
                }
                rsi = rsi.wrapping_add(dir as u64);
            },
        }
        rcx -= 1;
        slow += 1;
        if matches!(kind, String64::Scas | String64::Cmps) && (repz || repnz) {
            let z = getzf();
            if repz && !z || repnz && z {
                cmp_stop = true;
                break;
            }
        }
    }
    if asize32 {
        if matches!(
            kind,
            String64::Movs | String64::Lods | String64::Cmps | String64::Outs
        ) {
            write_reg32(ESI, rsi as i32);
        }
        if matches!(
            kind,
            String64::Movs | String64::Stos | String64::Scas | String64::Cmps | String64::Ins
        ) {
            write_reg32(EDI, rdi as i32);
        }
        if rep {
            write_reg32(ECX, rcx as i32);
        }
    }
    else {
        if matches!(
            kind,
            String64::Movs | String64::Lods | String64::Cmps | String64::Outs
        ) {
            write_reg64(ESI, rsi);
        }
        if matches!(
            kind,
            String64::Movs | String64::Stos | String64::Scas | String64::Cmps | String64::Ins
        ) {
            write_reg64(EDI, rdi);
        }
        if rep {
            write_reg64(ECX, rcx);
        }
    }
    if rep && rcx > 0 && !cmp_stop {
        set_rip(*previous_rip);
        after_block_boundary();
    }
}

unsafe fn dispatch_string64(opcode: i32) {
    let width = if matches!(opcode, 0x6C | 0x6E | 0xA4 | 0xA6 | 0xAA | 0xAC | 0xAE) {
        1
    }
    else if matches!(opcode, 0x6D | 0x6F) {
        // INS/OUTS ignore REX.W; 66h selects word vs dword.
        if is_osize_32() {
            4
        }
        else {
            2
        }
    }
    else if rex_w() {
        8
    }
    else if is_osize_32() {
        4
    }
    else {
        2
    };
    let kind = match opcode {
        0x6C | 0x6D => String64::Ins,
        0x6E | 0x6F => String64::Outs,
        0xA4 | 0xA5 => String64::Movs,
        0xA6 | 0xA7 => String64::Cmps,
        0xAA | 0xAB => String64::Stos,
        0xAC | 0xAD => String64::Lods,
        _ => String64::Scas,
    };
    string64(kind, width);
}

unsafe fn dispatch_loop64(opcode: i32) {
    let rel = return_on_pagefault!(read_imm8s());
    let asize32 = *prefixes & prefix::PREFIX_MASK_ADDRSIZE != 0;
    if opcode == 0xE3 {
        let cx = if asize32 { read_reg32(ECX) as u32 as u64 } else { read_reg64(ECX) };
        if cx == 0 {
            jump_near64(get_rip().wrapping_add(rel as i64 as u64));
        }
        return;
    }
    let rcx = if asize32 {
        let c = (read_reg32(ECX) as u32).wrapping_sub(1);
        write_reg32(ECX, c as i32);
        c as u64
    }
    else {
        let c = read_reg64(ECX).wrapping_sub(1);
        write_reg64(ECX, c);
        c
    };
    let zf = getzf();
    let take = match opcode {
        0xE0 => rcx != 0 && !zf,
        0xE1 => rcx != 0 && zf,
        0xE2 => rcx != 0,
        _ => false,
    };
    if take {
        jump_near64(get_rip().wrapping_add(rel as i64 as u64));
    }
}

unsafe fn run_legacy_opcode(opcode: i32) {
    run_instruction(opcode | (is_osize_32() as i32) << 8);
    finish_instruction();
}

unsafe fn dispatch_rex_w(opcode: i32) {
    current_interp_opcode = opcode as u32 | 0x100;
    current_interp_0f = false;
    match opcode {
        0x05 => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            let rax = add64(read_reg64(EAX), imm);
            write_reg64(EAX, rax);
        },
        0x0D => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            write_reg64(EAX, logic64(read_reg64(EAX) | imm));
        },
        0x15 => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            write_reg64(EAX, adc64(read_reg64(EAX), imm));
        },
        0x1D => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            write_reg64(EAX, sbb64(read_reg64(EAX), imm));
        },
        0x25 => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            write_reg64(EAX, logic64(read_reg64(EAX) & imm));
        },
        0x2D => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            let rax = sub64(read_reg64(EAX), imm);
            write_reg64(EAX, rax);
        },
        0x35 => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            write_reg64(EAX, logic64(read_reg64(EAX) ^ imm));
        },
        0x3D => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            cmp64(read_reg64(EAX), imm);
        },
        0x01 | 0x03 | 0x09 | 0x0B | 0x11 | 0x13 | 0x19 | 0x1B | 0x21 | 0x23 | 0x29 | 0x2B
        | 0x31 | 0x33 | 0x39 | 0x3B => {
            let modrm = return_on_pagefault!(read_imm8());
            let reg = gpr_reg(modrm);
            let (addr, rm) = return_on_pagefault!(rm64_addr_val(modrm));
            let r = read_reg64(reg);
            let (to_reg, result) = match opcode {
                0x01 => (false, add64(rm, r)),
                0x03 => (true, add64(r, rm)),
                0x09 => (false, logic64(rm | r)),
                0x0B => (true, logic64(r | rm)),
                0x11 => (false, adc64(rm, r)),
                0x13 => (true, adc64(r, rm)),
                0x19 => (false, sbb64(rm, r)),
                0x1B => (true, sbb64(r, rm)),
                0x21 => (false, logic64(rm & r)),
                0x23 => (true, logic64(r & rm)),
                0x29 => (false, sub64(rm, r)),
                0x2B => (true, sub64(r, rm)),
                0x31 => (false, logic64(rm ^ r)),
                0x33 => (true, logic64(r ^ rm)),
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
                1 => {
                    let _ = rm64_write(modrm, addr, logic64(dst | imm));
                },
                2 => {
                    let _ = rm64_write(modrm, addr, adc64(dst, imm));
                },
                3 => {
                    let _ = rm64_write(modrm, addr, sbb64(dst, imm));
                },
                4 => {
                    let _ = rm64_write(modrm, addr, logic64(dst & imm));
                },
                5 => {
                    let _ = rm64_write(modrm, addr, sub64(dst, imm));
                },
                6 => {
                    let _ = rm64_write(modrm, addr, logic64(dst ^ imm));
                },
                7 => cmp64(dst, imm),
                _ => {
                    dbg_log!("unhandled 64-bit group1 extra={}", extra);
                    trigger_ud();
                    return;
                },
            }
        },
        0x69 | 0x6B => {
            let modrm = return_on_pagefault!(read_imm8());
            let src = return_on_pagefault!(load_rm64(modrm));
            let imm = if opcode == 0x6B {
                return_on_pagefault!(read_imm8s()) as i64 as u64
            }
            else {
                return_on_pagefault!(read_imm32s()) as i64 as u64
            };
            write_reg64(gpr_reg(modrm), imul64_reg(src, imm));
        },
        0x85 => {
            let modrm = return_on_pagefault!(read_imm8());
            test64(
                return_on_pagefault!(load_rm64(modrm)),
                read_reg64(gpr_reg(modrm)),
            );
        },
        0x87 => {
            let modrm = return_on_pagefault!(read_imm8());
            let (addr, rm) = return_on_pagefault!(rm64_addr_val(modrm));
            let r = gpr_reg(modrm);
            let tmp = read_reg64(r);
            write_reg64(r, rm);
            let _ = rm64_write(modrm, addr, tmp);
        },
        0x89 => {
            let modrm = return_on_pagefault!(read_imm8());
            if modrm < 0xC0 {
                let addr = return_on_pagefault!(modrm_resolve(modrm));
                return_on_pagefault!(safe_write64(addr, read_reg64(gpr_reg(modrm))));
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
            let addr = return_on_pagefault!(resolve_lea64(modrm));
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
        0x90..=0x97 => {
            let r = gpr_opcode(opcode);
            if r != EAX {
                let a = read_reg64(EAX);
                write_reg64(EAX, read_reg64(r));
                write_reg64(r, a);
            }
        },
        0x98 => {
            write_reg64(EAX, read_reg32(EAX) as i64 as u64);
        },
        0x99 => {
            write_reg64(EDX, ((read_reg64(EAX) as i64) >> 63) as u64);
        },
        0xA5 => string64(String64::Movs, 8),
        0xA7 => string64(String64::Cmps, 8),
        0xAB => string64(String64::Stos, 8),
        0xAD => string64(String64::Lods, 8),
        0xAF => string64(String64::Scas, 8),
        0xA1 => {
            let addr = return_on_pagefault!(read_moffs());
            write_reg64(EAX, return_on_pagefault!(safe_read64s(addr)));
        },
        0xA3 => {
            let addr = return_on_pagefault!(read_moffs());
            return_on_pagefault!(safe_write64(addr, read_reg64(EAX)));
        },
        0xA9 => {
            let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
            test64(read_reg64(EAX), imm);
        },
        0xC1 | 0xD1 | 0xD3 => {
            let modrm = return_on_pagefault!(read_imm8());
            let extra = modrm >> 3 & 7;
            let (addr, dst) = return_on_pagefault!(rm64_addr_val(modrm));
            let count = if opcode == 0xC1 {
                return_on_pagefault!(read_imm8())
            }
            else if opcode == 0xD1 {
                1
            }
            else {
                read_reg8(CL)
            };
            let res = match extra {
                0 => rol64(dst, count),
                1 => ror64(dst, count),
                2 => rcl64(dst, count),
                3 => rcr64(dst, count),
                4 | 6 => shl64(dst, count),
                5 => shr64(dst, count),
                7 => sar64(dst, count),
                _ => {
                    dbg_log!("unhandled 64-bit group2 extra={}", extra);
                    trigger_ud();
                    return;
                },
            };
            let _ = rm64_write(modrm, addr, res);
        },
        0xF7 => {
            let modrm = return_on_pagefault!(read_imm8());
            let extra = modrm >> 3 & 7;
            match extra {
                0 | 1 => {
                    let dst = return_on_pagefault!(load_rm64(modrm));
                    let imm = return_on_pagefault!(read_imm32s()) as i64 as u64;
                    test64(dst, imm);
                },
                2 => {
                    let (addr, dst) = return_on_pagefault!(rm64_addr_val(modrm));
                    let _ = rm64_write(modrm, addr, !dst);
                },
                3 => {
                    let (addr, dst) = return_on_pagefault!(rm64_addr_val(modrm));
                    let _ = rm64_write(modrm, addr, sub64(0, dst));
                },
                4 => mul64(return_on_pagefault!(load_rm64(modrm))),
                5 => imul64_ax(return_on_pagefault!(load_rm64(modrm))),
                6 => div64(return_on_pagefault!(load_rm64(modrm))),
                7 => idiv64(return_on_pagefault!(load_rm64(modrm))),
                _ => {
                    trigger_ud();
                    return;
                },
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

/// Shared CS checks for 64-bit far JMP and far RET. Does not #GP when
/// RPL > CPL: JMP applies that restriction, RETF treats it as outer return.
unsafe fn lookup_cs_64(selector: i32) -> Option<(SegmentSelector, SegmentDescriptor)> {
    let cs_selector = SegmentSelector::of_u16(selector as u16);
    let info = match return_on_pagefault!(lookup_segment_selector(cs_selector), None) {
        Ok((desc, _)) => desc,
        Err(SelectorNullOrInvalid::IsNull) => {
            trigger_gp(0);
            return None;
        },
        Err(SelectorNullOrInvalid::OutsideOfTableLimit) => {
            trigger_gp(selector & !3);
            return None;
        },
    };
    if info.is_system() || !info.is_executable() {
        trigger_gp(selector & !3);
        return None;
    }
    if cs_selector.rpl() < *cpl {
        trigger_gp(selector & !3);
        return None;
    }
    if info.is_dc() && info.dpl() > cs_selector.rpl() {
        trigger_gp(selector & !3);
        return None;
    }
    if !info.is_dc() && info.dpl() != cs_selector.rpl() {
        trigger_gp(selector & !3);
        return None;
    }
    if !info.is_present() {
        trigger_np(selector & !3);
        return None;
    }
    Some((cs_selector, info))
}

unsafe fn apply_cs_64(selector: i32, info: SegmentDescriptor) {
    update_cs_from_descriptor(info);
    *segment_is_null.offset(CS as isize) = false;
    *segment_limits.offset(CS as isize) = info.effective_limit();
    *segment_access_bytes.offset(CS as isize) = info.access_byte();
    *segment_offsets.offset(CS as isize) = info.base();
    *sreg.offset(CS as isize) = selector as u16;
}

/// Far JMP: same-privilege CS load. Jumping to a less-privileged
/// (higher RPL) non-conforming CS is #GP, not an inter-privilege transfer.
unsafe fn load_cs_64(selector: i32) -> bool {
    let (cs_selector, info) = match lookup_cs_64(selector) {
        Some(v) => v,
        None => return false,
    };
    if cs_selector.rpl() > *cpl {
        dbg_log!("far jump to outer privilege is #gp in 64-bit");
        trigger_gp(selector & !3);
        return false;
    }
    apply_cs_64(selector, info);
    true
}

/// SS checks for an inter-privilege far return, matching `iretq`.
/// Null SS is valid only when returning to CPL0.
unsafe fn validate_ss_64(new_ss: i32, new_cpl: u8) -> bool {
    let ss_selector = SegmentSelector::of_u16(new_ss as u16);
    if ss_selector.is_null() {
        if new_cpl != 0 {
            dbg_log!("#gp retf64 null ss at cpl={}", new_cpl);
            trigger_gp(0);
            return false;
        }
        return true;
    }
    let ss_descriptor = match return_on_pagefault!(lookup_segment_selector(ss_selector), false) {
        Ok((desc, _)) => desc,
        Err(SelectorNullOrInvalid::IsNull) => {
            dbg_log!("#gp retf64 null ss");
            trigger_gp(0);
            return false;
        },
        Err(SelectorNullOrInvalid::OutsideOfTableLimit) => {
            dbg_log!("#gp retf64 invalid ss {:x}", new_ss);
            trigger_gp(new_ss & !3);
            return false;
        },
    };
    if ss_descriptor.is_system()
        || ss_selector.rpl() != new_cpl
        || !ss_descriptor.is_writable()
        || ss_descriptor.dpl() != new_cpl
    {
        dbg_log!("#gp retf64 invalid ss {:x}", new_ss);
        trigger_gp(new_ss & !3);
        return false;
    }
    if !ss_descriptor.is_present() {
        dbg_log!("#ss retf64 non-present ss {:x}", new_ss);
        trigger_ss(new_ss & !3);
        return false;
    }
    true
}

unsafe fn null_data_segs_below_cpl() {
    for reg in [ES, DS, FS, GS] {
        let access = *segment_access_bytes.offset(reg as isize);
        let dpl = access >> 5 & 3;
        let executable = access & 8 == 8;
        let conforming = access & 4 == 4;
        if dpl < *cpl && !(executable && conforming) {
            *segment_is_null.offset(reg as isize) = true;
            *sreg.offset(reg as isize) = 0;
        }
    }
}

unsafe fn retf64(stack_adjust: i32) {
    let rsp0 = read_reg64(ESP);
    if gp_if_noncanonical(rsp0) {
        return;
    }
    return_on_pagefault!(readable_or_pagefault(get_stack_pointer(0), 16));
    *pending_linear64 = rsp0;
    let new_rip = return_on_pagefault!(safe_read64s(rsp0 as i32));
    let new_cs = return_on_pagefault!(safe_read64s(rsp0.wrapping_add(8) as i32)) as u16 as i32;

    let (cs_selector, cs_descriptor) = match lookup_cs_64(new_cs) {
        Some(v) => v,
        None => return,
    };

    if !cs_descriptor.is_long() && new_rip as u32 > cs_descriptor.effective_limit() {
        dbg_log!("#gp retf64 rip above cs limit");
        trigger_gp(new_cs & !3);
        return;
    }

    let new_cpl = cs_selector.rpl();
    let privilege_change = new_cpl != *cpl;

    let (new_rsp, new_ss) = if privilege_change {
        return_on_pagefault!(readable_or_pagefault(get_stack_pointer(0), 32));
        *pending_linear64 = rsp0;
        let new_rsp = return_on_pagefault!(safe_read64s(rsp0.wrapping_add(16) as i32));
        let new_ss = return_on_pagefault!(safe_read64s(rsp0.wrapping_add(24) as i32)) as u16 as i32;
        if gp_if_noncanonical(new_rsp) {
            return;
        }
        if !validate_ss_64(new_ss, new_cpl) {
            return;
        }
        (new_rsp, new_ss)
    }
    else {
        (rsp0.wrapping_add(16), 0)
    };

    if !is_canonical_va(new_rip) {
        dbg_log!("#gp retf64 rip {:x} non-canonical", new_rip);
        trigger_gp(0);
        return;
    }

    if privilege_change {
        *cpl = new_cpl;
        cpl_changed();
    }

    apply_cs_64(new_cs, cs_descriptor);
    *instruction_pointer = new_rip as i32 + get_seg_cs();
    if *is_64 {
        set_rip(new_rip.wrapping_add(get_seg_cs() as u32 as u64));
    }

    if privilege_change {
        if !switch_seg(SS, new_ss) {
            return;
        }
        null_data_segs_below_cpl();
    }
    write_reg64(ESP, new_rsp.wrapping_add(stack_adjust as i64 as u64));
    update_state_flags();
}

unsafe fn jmp_far64(addr: i32) {
    let target = return_on_pagefault!(safe_read64s(addr));
    *pending_linear64 = virt64_from_i32(addr).wrapping_add(8);
    let sel = return_on_pagefault!(safe_read16(addr.wrapping_add(8)));
    if !load_cs_64(sel) {
        return;
    }
    jump_near64(target);
}

/// ENTER in 64-bit CS: always a 64-bit stack op (Intel operand size 64).
unsafe fn enter64(size: i32, mut nesting: i32) {
    nesting &= 31;
    let frame_temp = read_reg64(ESP).wrapping_sub(8);
    if gp_if_noncanonical(frame_temp) {
        return;
    }

    if nesting > 0 {
        let mut tmp_rbp = read_reg64(EBP);
        for _ in 1..nesting {
            tmp_rbp = tmp_rbp.wrapping_sub(8);
            if gp_if_noncanonical(tmp_rbp) {
                return;
            }
            *pending_linear64 = tmp_rbp;
            let fp = return_on_pagefault!(safe_read64s(tmp_rbp as i32));
            return_on_pagefault!(push64(fp));
        }
        return_on_pagefault!(push64(frame_temp));
    }

    *pending_linear64 = frame_temp;
    return_on_pagefault!(safe_write64(frame_temp as i32, read_reg64(EBP)));
    write_reg64(EBP, frame_temp);
    let new_rsp = frame_temp.wrapping_sub(size as u64);
    if gp_if_noncanonical(new_rsp) {
        return;
    }
    write_reg64(ESP, new_rsp);
}

unsafe fn dispatch_forced64(opcode: i32) {
    current_interp_opcode = opcode as u32 | 0x100;
    current_interp_0f = false;
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
        0xC8 => {
            let size = return_on_pagefault!(read_imm16());
            let nesting = return_on_pagefault!(read_imm8());
            enter64(size, nesting);
        },
        0xC9 => {
            let rbp = read_reg64(EBP);
            if gp_if_noncanonical(rbp) {
                return;
            }
            *pending_linear64 = rbp;
            let new_rbp = return_on_pagefault!(safe_read64s(rbp as i32));
            write_reg64(ESP, rbp.wrapping_add(8));
            write_reg64(EBP, new_rbp);
        },
        0xCA => {
            let imm16 = return_on_pagefault!(read_imm16());
            retf64(imm16);
        },
        0xCB => retf64(0),
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
                0 | 1 => {
                    if !rex_w() {
                        set_rip(saved_rip);
                        run_legacy_opcode(opcode);
                        return;
                    }
                    let (addr, dst) = return_on_pagefault!(rm64_addr_val(modrm));
                    let res = if extra == 0 { inc64(dst) } else { dec64(dst) };
                    let _ = rm64_write(modrm, addr, res);
                },
                2 => {
                    let target = return_on_pagefault!(load_rm64(modrm));
                    // #GP before pushing the return address: a non-canonical
                    // target after push underflows a just-emptied kernel stack.
                    if gp_if_noncanonical(target) {
                        return;
                    }
                    return_on_pagefault!(push64(get_rip()));
                    set_rip(target);
                },
                4 => {
                    let target = return_on_pagefault!(load_rm64(modrm));
                    jump_near64(target);
                },
                6 => {
                    let value = return_on_pagefault!(load_rm64(modrm));
                    return_on_pagefault!(push64(value));
                },
                3 | 5 => {
                    if modrm >= 0xC0 {
                        trigger_ud();
                        return;
                    }
                    let addr = return_on_pagefault!(modrm_resolve(modrm));
                    if extra == 3 {
                        let ret_cs = *sreg.offset(CS as isize) as u64;
                        let ret_rip = get_rip();
                        return_on_pagefault!(push64(ret_cs));
                        return_on_pagefault!(push64(ret_rip));
                    }
                    jmp_far64(addr);
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

pub fn opcode_is_forced64(opcode: i32) -> bool {
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
            | 0xC8
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

/// REX.W does not select a 64-bit operand for these one-byte opcodes.
/// Architecturally the W bit is ignored; they must not `#UD`.
pub fn opcode_ignores_rex_w(opcode: i32) -> bool {
    matches!(
        opcode,
        0x00
            | 0x02
            | 0x04
            | 0x08
            | 0x0A
            | 0x0C
            | 0x10
            | 0x12
            | 0x14
            | 0x18
            | 0x1A
            | 0x1C
            | 0x20
            | 0x22
            | 0x24
            | 0x28
            | 0x2A
            | 0x2C
            | 0x30
            | 0x32
            | 0x34
            | 0x38
            | 0x3A
            | 0x3C
            | 0x70..=0x7F
            | 0x80
            | 0x84
            | 0x86
            | 0x88
            | 0x8A
            | 0x8C
            | 0x8E
            | 0x9B
            | 0x9E
            | 0x9F
            | 0xA0
            | 0xA2
            | 0xA8
            | 0xB0..=0xB7
            | 0xC0
            | 0xC6
            | 0xCC
            | 0xCD
            | 0xD0
            | 0xD2
            | 0xD7
            | 0xE4..=0xE7
            | 0xEC..=0xEF
            | 0xF4
            | 0xF5
            | 0xF6
            | 0xF8..=0xFD
            | 0xFE
    )
}

unsafe fn dispatch_movsxd() {
    let modrm = return_on_pagefault!(read_imm8());
    let src = if modrm < 0xC0 {
        let addr = return_on_pagefault!(modrm_resolve(modrm));
        return_on_pagefault!(safe_read32s(addr)) as i64 as u64
    }
    else {
        read_reg32(gpr_rm(modrm)) as i64 as u64
    };
    if rex_w() {
        write_reg64(gpr_reg(modrm), src);
    }
    else {
        write_reg32(gpr_reg(modrm), src as i32);
    }
    finish_instruction();
}

unsafe fn dispatch_rex_legacy(opcode: i32) -> bool {
    match opcode {
        0xB0..=0xB7 => {
            let imm = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            write_reg8(gpr_opcode(opcode), imm);
            finish_instruction();
            true
        },
        0xB8..=0xBF => {
            let imm = match read_imm32s() {
                Ok(o) => o,
                Err(()) => return true,
            };
            write_reg32(gpr_opcode(opcode), imm);
            finish_instruction();
            true
        },
        0x90..=0x97 => {
            let r = gpr_opcode(opcode);
            if r != EAX {
                let a = read_reg32(EAX);
                write_reg32(EAX, read_reg32(r));
                write_reg32(r, a);
            }
            finish_instruction();
            true
        },
        0x9E | 0x9F => {
            // SAHF/LAHF always use AH. Any REX prefix would make write_reg8(AH)
            // update SPL instead; W (and R/X/B) are ignored for these opcodes.
            *rex_prefix = 0;
            run_legacy_opcode(opcode);
            true
        },
        _ => false,
    }
}

fn cmov64_cond(opcode: i32) -> bool {
    unsafe {
        match opcode & 0xF {
            0 => test_o(),
            1 => !test_o(),
            2 => test_b(),
            3 => !test_b(),
            4 => test_z(),
            5 => !test_z(),
            6 => test_be(),
            7 => !test_be(),
            8 => test_s(),
            9 => !test_s(),
            10 => test_p(),
            11 => !test_p(),
            12 => test_l(),
            13 => !test_l(),
            14 => test_le(),
            15 => !test_le(),
            _ => false,
        }
    }
}

unsafe fn load_rm8(modrm: i32) -> OrPageFault<i32> {
    if modrm < 0xC0 {
        let addr = modrm_resolve(modrm)?;
        safe_read8(addr)
    }
    else {
        Ok(read_reg8(gpr_rm(modrm)))
    }
}

unsafe fn load_rm16(modrm: i32) -> OrPageFault<i32> {
    if modrm < 0xC0 {
        let addr = modrm_resolve(modrm)?;
        safe_read16(addr)
    }
    else {
        Ok(read_reg16(gpr_rm(modrm)))
    }
}

/// REX.W 0F C7 /1 m128: CMPXCHG16B. Register form is #UD; misaligned is #GP(0).
unsafe fn cmpxchg16b_mem(addr: i32) {
    if *pending_linear64 & 15 != 0 {
        trigger_gp(0);
        return;
    }
    return_on_pagefault!(writable_or_pagefault(addr, 16));
    let m = return_on_pagefault!(safe_read128s(addr));
    let low = m.u64[0];
    let high = m.u64[1];
    if read_reg64(EAX) == low && read_reg64(EDX) == high {
        *flags |= FLAG_ZERO;
        let _ = safe_write128(
            addr,
            reg128 {
                u64: [read_reg64(EBX), read_reg64(ECX)],
            },
        );
    }
    else {
        *flags &= !FLAG_ZERO;
        write_reg64(EAX, low);
        write_reg64(EDX, high);
    }
    *flags_changed &= !FLAG_ZERO;
}

unsafe fn dispatch_rex_w_0f(opcode: i32) {
    current_interp_opcode = opcode as u32 | 0x100;
    current_interp_0f = true;
    match opcode {
        0x40..=0x4F => {
            let modrm = return_on_pagefault!(read_imm8());
            let src = return_on_pagefault!(load_rm64(modrm));
            if cmov64_cond(opcode) {
                write_reg64(gpr_reg(modrm), src);
            }
        },
        0x6E | 0x7E => {
            // F3 0F 7E is MOVQ xmm, xmm/m64; do not take the GPR form.
            if *prefixes & (prefix::PREFIX_F2 | prefix::PREFIX_REPZ) != 0 {
                run_instruction0f_32(opcode);
            }
            else {
                let modrm = return_on_pagefault!(read_imm8());
                let xmm = *prefixes & prefix::PREFIX_MASK_OPSIZE != 0;
                if opcode == 0x6E {
                    let src = return_on_pagefault!(load_rm64(modrm));
                    if xmm {
                        write_xmm128_2(gpr_reg(modrm), src, 0);
                    }
                    else {
                        write_mmx_reg64(modrm >> 3 & 7, src);
                        transition_fpu_to_mmx();
                    }
                }
                else {
                    let val =
                        if xmm { read_xmm64s(gpr_reg(modrm)) } else { read_mmx64s(modrm >> 3 & 7) };
                    let (addr, _) = return_on_pagefault!(rm64_addr_val(modrm));
                    return_on_pagefault!(rm64_write(modrm, addr, val));
                    if !xmm {
                        transition_fpu_to_mmx();
                    }
                }
            }
        },
        0xA3 | 0xAB | 0xB3 | 0xBB => {
            let modrm = return_on_pagefault!(read_imm8());
            let bit = read_reg64(gpr_reg(modrm));
            if modrm < 0xC0 {
                let base = return_on_pagefault!(resolve_modrm64(modrm));
                let addr = base.wrapping_add((bit as i64 >> 3) as u64);
                *pending_linear64 = addr;
                let byte = return_on_pagefault!(safe_read8(addr as i32)) as u64;
                let b = bit & 7;
                *flags_changed &= !FLAG_CARRY;
                if byte & 1 << b != 0 {
                    *flags |= FLAG_CARRY;
                }
                else {
                    *flags &= !FLAG_CARRY;
                }
                let new = match opcode {
                    0xA3 => byte,
                    0xAB => byte | 1 << b,
                    0xB3 => byte & !(1 << b),
                    _ => byte ^ 1 << b,
                };
                if opcode != 0xA3 {
                    *pending_linear64 = addr;
                    let _ = safe_write8(addr as i32, new as i32);
                }
            }
            else {
                let r = gpr_rm(modrm);
                let val = read_reg64(r);
                bt64_flags(val, bit);
                let b = bit & 63;
                let new = match opcode {
                    0xA3 => val,
                    0xAB => val | 1 << b,
                    0xB3 => val & !(1 << b),
                    _ => val ^ 1 << b,
                };
                if opcode != 0xA3 {
                    write_reg64(r, new);
                }
            }
        },
        0xA4 | 0xA5 | 0xAC | 0xAD => {
            let modrm = return_on_pagefault!(read_imm8());
            let (addr, dst) = return_on_pagefault!(rm64_addr_val(modrm));
            let src = read_reg64(gpr_reg(modrm));
            let count = if opcode == 0xA4 || opcode == 0xAC {
                return_on_pagefault!(read_imm8())
            }
            else {
                read_reg8(CL)
            };
            let n = shift_count64(count);
            let res = if n == 0 {
                dst
            }
            else if opcode == 0xA4 || opcode == 0xA5 {
                let r = dst << n | src >> (64 - n);
                let cf = dst >> (64 - n) & 1 != 0;
                let of = n == 1 && (r >> 63 != 0) != cf;
                set_arith_flags64(r, cf, of, false);
                r
            }
            else {
                let r = dst >> n | src << (64 - n);
                let cf = dst >> (n - 1) & 1 != 0;
                let of = n == 1 && (dst >> 63 != 0);
                set_arith_flags64(r, cf, of, false);
                r
            };
            let _ = rm64_write(modrm, addr, res);
        },
        0xAF => {
            let modrm = return_on_pagefault!(read_imm8());
            let r = gpr_reg(modrm);
            let src = return_on_pagefault!(load_rm64(modrm));
            write_reg64(r, imul64_reg(read_reg64(r), src));
        },
        0xB1 => {
            let modrm = return_on_pagefault!(read_imm8());
            let (addr, rm) = return_on_pagefault!(rm64_addr_val(modrm));
            let rax = read_reg64(EAX);
            cmp64(rax, rm);
            if *flags & FLAG_ZERO != 0 {
                let _ = rm64_write(modrm, addr, read_reg64(gpr_reg(modrm)));
            }
            else {
                write_reg64(EAX, rm);
            }
        },
        0xB8 => {
            if *prefixes & prefix::PREFIX_REPZ == 0 {
                trigger_ud();
                return;
            }
            let modrm = return_on_pagefault!(read_imm8());
            let src = return_on_pagefault!(load_rm64(modrm));
            write_reg64(gpr_reg(modrm), popcnt64(src));
        },
        0xBE => {
            let modrm = return_on_pagefault!(read_imm8());
            let v = return_on_pagefault!(load_rm8(modrm)) as i8 as i64 as u64;
            write_reg64(gpr_reg(modrm), v);
        },
        0xBF => {
            let modrm = return_on_pagefault!(read_imm8());
            let v = return_on_pagefault!(load_rm16(modrm)) as i16 as i64 as u64;
            write_reg64(gpr_reg(modrm), v);
        },
        0xBA => {
            let modrm = return_on_pagefault!(read_imm8());
            let extra = modrm >> 3 & 7;
            if extra < 4 {
                trigger_ud();
                return;
            }
            // Imm8 follows the full ModRM address (disp8/disp32/SIB). Reading it
            // first turns RIP-relative `btsq $63, m64` into a bogus canonical
            // hole VA (Linux `early_pmd_flags` -> #PF with an empty IDT -> #DF).
            let (addr, val) = return_on_pagefault!(rm64_addr_val(modrm));
            let imm = return_on_pagefault!(read_imm8()) as u64;
            bt64_flags(val, imm);
            let b = imm & 63;
            let new = match extra {
                4 => val,
                5 => val | 1 << b,
                6 => val & !(1 << b),
                _ => val ^ 1 << b,
            };
            if extra != 4 {
                let _ = rm64_write(modrm, addr, new);
            }
        },
        0xBC => {
            let modrm = return_on_pagefault!(read_imm8());
            let r = gpr_reg(modrm);
            let src = return_on_pagefault!(load_rm64(modrm));
            write_reg64(r, bsf64(read_reg64(r), src));
        },
        0xBD => {
            let modrm = return_on_pagefault!(read_imm8());
            let r = gpr_reg(modrm);
            let src = return_on_pagefault!(load_rm64(modrm));
            write_reg64(r, bsr64(read_reg64(r), src));
        },
        0xC1 => {
            let modrm = return_on_pagefault!(read_imm8());
            let (addr, rm) = return_on_pagefault!(rm64_addr_val(modrm));
            let r = gpr_reg(modrm);
            let tmp = read_reg64(r);
            write_reg64(r, rm);
            let _ = rm64_write(modrm, addr, add64(rm, tmp));
        },
        0xC7 => {
            let modrm = return_on_pagefault!(read_imm8());
            match modrm >> 3 & 7 {
                1 => {
                    if modrm >= 0xC0 {
                        trigger_ud();
                        return;
                    }
                    let addr = return_on_pagefault!(modrm_resolve(modrm));
                    cmpxchg16b_mem(addr);
                },
                6 => {
                    // rdrand r64: memory form is #UD. Pack two 32-bit draws.
                    if modrm < 0xC0 {
                        trigger_ud();
                        return;
                    }
                    let lo = js::get_rand_int() as u32 as u64;
                    let hi = js::get_rand_int() as u32 as u64;
                    write_reg64(gpr_rm(modrm), lo | hi << 32);
                    *flags &= !FLAGS_ALL;
                    *flags |= FLAG_CARRY;
                    *flags_changed = 0;
                },
                _ => {
                    trigger_ud();
                    return;
                },
            }
        },
        0xC8..=0xCF => {
            let r = gpr_opcode(opcode);
            write_reg64(r, read_reg64(r).swap_bytes());
        },
        _ => {
            run_instruction0f_32(opcode);
        },
    }
    finish_instruction();
}

unsafe fn dispatch_opcode(opcode: i32) {
    current_interp_opcode = opcode as u32 | 0x100;
    current_interp_0f = false;
    // Intel SDM: these one-byte opcodes are invalid in 64-bit mode.
    if matches!(
        opcode,
        0x06 | 0x07
            | 0x0E
            | 0x16
            | 0x17
            | 0x1E
            | 0x1F
            | 0x27
            | 0x2F
            | 0x37
            | 0x3F
            | 0x60
            | 0x61
            | 0x62
            | 0x82
            | 0x9A
            | 0xCE
            | 0xD4
            | 0xD5
            | 0xD6
            | 0xEA
    ) {
        trigger_ud();
        return;
    }
    if opcode == 0x63 {
        dispatch_movsxd();
        return;
    }
    if matches!(opcode, 0x6C..=0x6F | 0xA4..=0xA7 | 0xAA..=0xAF) {
        dispatch_string64(opcode);
        finish_instruction();
        return;
    }
    if matches!(opcode, 0xE0..=0xE3) {
        dispatch_loop64(opcode);
        finish_instruction();
        return;
    }
    if !is_osize_32() {
        run_legacy_opcode(opcode);
        return;
    }
    if opcode_is_forced64(opcode) {
        dispatch_forced64(opcode);
        finish_instruction();
        return;
    }
    if rex_w() && !opcode_ignores_rex_w(opcode) {
        dispatch_rex_w(opcode);
        return;
    }
    if *rex_prefix != 0 && dispatch_rex_legacy(opcode) {
        return;
    }
    run_legacy_opcode(opcode);
}

/// Fetch prefixes + opcode at CS:RIP and execute one 64-bit-mode instruction.
pub unsafe fn run_one() {
    dbg_assert!(*is_64);
    *rex_prefix = 0;
    *prefixes = 0;
    *pending_linear64 = 0;
    current_interp_opcode = 0;
    current_interp_0f = false;

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
                    if is_hint_nop(opcode) {
                        dispatch_hint_nop();
                        finish_instruction();
                    }
                    else if rex_w() {
                        dispatch_rex_w_0f(opcode);
                    }
                    else {
                        run_instruction0f_32(opcode);
                        finish_instruction();
                    }
                    return;
                }
                dispatch_opcode(opcode);
                return;
            },
            0x0F => {
                let opcode = return_on_pagefault!(read_imm8());
                if is_hint_nop(opcode) {
                    dispatch_hint_nop();
                    finish_instruction();
                }
                else if rex_w() {
                    dispatch_rex_w_0f(opcode);
                }
                else {
                    run_instruction0f_32(opcode);
                    finish_instruction();
                }
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
    fn idt_gate64_ist_field() {
        let gate = IdtGate64::of_u64s(0x9ABC_EE01_0008_DEF0, 0);
        assert_eq!(gate.ist(), 1);
        assert_eq!(gate.dpl(), 3);
        assert_eq!(gate.gate_type(), 0b110);
    }

    #[test]
    fn tss64_stack_offsets() {
        assert_eq!(crate::cpu::cpu::tss64_rsp_offset(0), 0x04);
        assert_eq!(crate::cpu::cpu::tss64_rsp_offset(1), 0x0C);
        assert_eq!(crate::cpu::cpu::tss64_rsp_offset(2), 0x14);
        assert_eq!(crate::cpu::cpu::tss64_ist_offset(1), 0x24);
        assert_eq!(crate::cpu::cpu::tss64_ist_offset(2), 0x2C);
        assert_eq!(crate::cpu::cpu::tss64_ist_offset(7), 0x54);
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

    #[test]
    fn linux_kernel_map_is_pd_index_8() {
        let va = 0xFFFF_FFFF_8100_0000u64;
        assert_eq!((va >> 39) & 0x1FF, 511);
        assert_eq!((va >> 30) & 0x1FF, 510);
        assert_eq!((va >> 21) & 0x1FF, 8);
    }

    #[test]
    fn forced64_includes_near_call_and_push() {
        assert!(opcode_is_forced64(0xE8));
        assert!(opcode_is_forced64(0x50));
        assert!(opcode_is_forced64(0xC3));
        assert!(opcode_is_forced64(0xC8));
        assert!(opcode_is_forced64(0xCA));
        assert!(opcode_is_forced64(0xCB));
        assert!(opcode_is_forced64(0xFF));
        assert!(!opcode_is_forced64(0x01));
        assert!(!opcode_is_forced64(0x75));
        assert!(!opcode_is_forced64(0x83));
    }

    #[test]
    fn opcode_ignores_rex_w_on_byte_and_size_independent_ops() {
        assert!(opcode_ignores_rex_w(0x88));
        assert!(opcode_ignores_rex_w(0x04));
        assert!(opcode_ignores_rex_w(0x74));
        assert!(opcode_ignores_rex_w(0x9E));
        assert!(opcode_ignores_rex_w(0xB0));
        assert!(opcode_ignores_rex_w(0xFE));
        assert!(!opcode_ignores_rex_w(0x89));
        assert!(!opcode_ignores_rex_w(0x05));
        assert!(!opcode_ignores_rex_w(0x90));
        assert!(!opcode_ignores_rex_w(0xB8));
        assert!(!opcode_ignores_rex_w(0xC3));
    }
}
