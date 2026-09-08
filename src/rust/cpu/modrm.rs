use crate::cpu::cpu::*;
use crate::cpu::global_pointers::*;
use crate::paging::OrPageFault;
use crate::prefix;

const REX_B: u8 = 1 << 0;
const REX_X: u8 = 1 << 1;

pub unsafe fn resolve_modrm16(modrm_byte: i32) -> OrPageFault<i32> {
    match modrm_byte & !0o070 {
        0o000 => get_seg_prefix_ds(read_reg16(BX) + read_reg16(SI) & 0xFFFF),
        0o100 => get_seg_prefix_ds(read_reg16(BX) + read_reg16(SI) + read_imm8s()? & 0xFFFF),
        0o200 => get_seg_prefix_ds(read_reg16(BX) + read_reg16(SI) + read_imm16()? & 0xFFFF),
        0o001 => get_seg_prefix_ds(read_reg16(BX) + read_reg16(DI) & 0xFFFF),
        0o101 => get_seg_prefix_ds(read_reg16(BX) + read_reg16(DI) + read_imm8s()? & 0xFFFF),
        0o201 => get_seg_prefix_ds(read_reg16(BX) + read_reg16(DI) + read_imm16()? & 0xFFFF),
        0o002 => get_seg_prefix_ss(read_reg16(BP) + read_reg16(SI) & 0xFFFF),
        0o102 => get_seg_prefix_ss(read_reg16(BP) + read_reg16(SI) + read_imm8s()? & 0xFFFF),
        0o202 => get_seg_prefix_ss(read_reg16(BP) + read_reg16(SI) + read_imm16()? & 0xFFFF),
        0o003 => get_seg_prefix_ss(read_reg16(BP) + read_reg16(DI) & 0xFFFF),
        0o103 => get_seg_prefix_ss(read_reg16(BP) + read_reg16(DI) + read_imm8s()? & 0xFFFF),
        0o203 => get_seg_prefix_ss(read_reg16(BP) + read_reg16(DI) + read_imm16()? & 0xFFFF),
        0o004 => get_seg_prefix_ds(read_reg16(SI) & 0xFFFF),
        0o104 => get_seg_prefix_ds(read_reg16(SI) + read_imm8s()? & 0xFFFF),
        0o204 => get_seg_prefix_ds(read_reg16(SI) + read_imm16()? & 0xFFFF),
        0o005 => get_seg_prefix_ds(read_reg16(DI) & 0xFFFF),
        0o105 => get_seg_prefix_ds(read_reg16(DI) + read_imm8s()? & 0xFFFF),
        0o205 => get_seg_prefix_ds(read_reg16(DI) + read_imm16()? & 0xFFFF),
        0o006 => get_seg_prefix_ds(read_imm16()?),
        0o106 => get_seg_prefix_ss(read_reg16(BP) + read_imm8s()? & 0xFFFF),
        0o206 => get_seg_prefix_ss(read_reg16(BP) + read_imm16()? & 0xFFFF),
        0o007 => get_seg_prefix_ds(read_reg16(BX) & 0xFFFF),
        0o107 => get_seg_prefix_ds(read_reg16(BX) + read_imm8s()? & 0xFFFF),
        0o207 => get_seg_prefix_ds(read_reg16(BX) + read_imm16()? & 0xFFFF),
        _ => {
            dbg_assert!(false);
            std::hint::unreachable_unchecked()
        },
    }
}

pub unsafe fn resolve_modrm32_(modrm_byte: i32) -> OrPageFault<i32> {
    let r = (modrm_byte & 7) as u8;
    dbg_assert!(modrm_byte < 192);
    Ok(if r as i32 == 4 {
        if modrm_byte < 64 {
            resolve_sib(false)?
        }
        else {
            resolve_sib(true)? + if modrm_byte < 128 { read_imm8s()? } else { read_imm32s()? }
        }
    }
    else if r as i32 == 5 {
        if modrm_byte < 64 {
            get_seg_prefix_ds(read_imm32s()?)?
        }
        else {
            get_seg_prefix_ss(
                read_reg32(EBP) + if modrm_byte < 128 { read_imm8s()? } else { read_imm32s()? },
            )?
        }
    }
    else if modrm_byte < 64 {
        get_seg_prefix_ds(read_reg32(r as i32))?
    }
    else {
        get_seg_prefix_ds(
            read_reg32(r as i32) + if modrm_byte < 128 { read_imm8s()? } else { read_imm32s()? },
        )?
    })
}
unsafe fn resolve_sib(with_imm: bool) -> OrPageFault<i32> {
    let sib_byte = read_imm8()?;
    let r = sib_byte & 7;
    let m = sib_byte >> 3 & 7;
    let base;
    let seg;
    if r == 4 {
        base = read_reg32(ESP);
        seg = SS
    }
    else if r == 5 {
        if with_imm {
            base = read_reg32(EBP);
            seg = SS
        }
        else {
            base = read_imm32s()?;
            seg = DS
        }
    }
    else {
        base = read_reg32(r);
        seg = DS
    }
    let offset;
    if m == 4 {
        offset = 0
    }
    else {
        let s = sib_byte >> 6 & 3;
        offset = read_reg32(m) << s
    }
    Ok(get_seg_prefix(seg)? + base + offset)
}

pub unsafe fn resolve_modrm32(modrm_byte: i32) -> OrPageFault<i32> {
    match modrm_byte & !0o070 {
        0o000 => get_seg_prefix_ds(read_reg32(EAX)),
        0o100 => get_seg_prefix_ds(read_reg32(EAX) + read_imm8s()?),
        0o200 => get_seg_prefix_ds(read_reg32(EAX) + read_imm32s()?),
        0o001 => get_seg_prefix_ds(read_reg32(ECX)),
        0o101 => get_seg_prefix_ds(read_reg32(ECX) + read_imm8s()?),
        0o201 => get_seg_prefix_ds(read_reg32(ECX) + read_imm32s()?),
        0o002 => get_seg_prefix_ds(read_reg32(EDX)),
        0o102 => get_seg_prefix_ds(read_reg32(EDX) + read_imm8s()?),
        0o202 => get_seg_prefix_ds(read_reg32(EDX) + read_imm32s()?),
        0o003 => get_seg_prefix_ds(read_reg32(EBX)),
        0o103 => get_seg_prefix_ds(read_reg32(EBX) + read_imm8s()?),
        0o203 => get_seg_prefix_ds(read_reg32(EBX) + read_imm32s()?),
        0o004 => resolve_sib(false),
        0o104 => Ok(resolve_sib(true)? + read_imm8s()?),
        0o204 => Ok(resolve_sib(true)? + read_imm32s()?),
        0o005 => get_seg_prefix_ds(read_imm32s()?),
        0o105 => get_seg_prefix_ss(read_reg32(EBP) + read_imm8s()?),
        0o205 => get_seg_prefix_ss(read_reg32(EBP) + read_imm32s()?),
        0o006 => get_seg_prefix_ds(read_reg32(ESI)),
        0o106 => get_seg_prefix_ds(read_reg32(ESI) + read_imm8s()?),
        0o206 => get_seg_prefix_ds(read_reg32(ESI) + read_imm32s()?),
        0o007 => get_seg_prefix_ds(read_reg32(EDI)),
        0o107 => get_seg_prefix_ds(read_reg32(EDI) + read_imm8s()?),
        0o207 => get_seg_prefix_ds(read_reg32(EDI) + read_imm32s()?),
        _ => {
            dbg_assert!(false);
            std::hint::unreachable_unchecked()
        },
    }
}

fn default_seg_rm64(rm: i32) -> i32 {
    if rm == ESP || rm == EBP || rm == 12 || rm == 13 {
        SS
    }
    else {
        DS
    }
}

unsafe fn apply_asize64(ea: u64) -> u64 {
    if *prefixes & prefix::PREFIX_MASK_ADDRSIZE != 0 {
        ea as u32 as u64
    }
    else {
        ea
    }
}

unsafe fn linear_from_ea64(default_seg: i32, ea: u64, rip_rel: bool) -> OrPageFault<i32> {
    let base = if rip_rel {
        let p = *prefixes & prefix::PREFIX_MASK_SEGMENT;
        if p == FS as u8 + 1 || p == GS as u8 + 1 {
            get_seg(p as i32 - 1)? as u32 as u64
        }
        else {
            0
        }
    }
    else {
        get_seg_prefix(default_seg)? as u32 as u64
    };
    let linear = base.wrapping_add(ea);
    if linear >> 32 != 0 {
        dbg_log!("#gp 64-bit effective address {:x} exceeds 4G", linear);
        trigger_gp(0);
        return Err(());
    }
    Ok(linear as i32)
}

/// SIB in 64-bit CS. `mod_has_disp` is true for mod=01/10 (disp follows SIB).
/// When mod=00 and base=5, a disp32 is consumed here (no base, or R13 if REX.B).
unsafe fn resolve_sib64(mod_has_disp: bool) -> OrPageFault<(u64, i32)> {
    let sib_byte = read_imm8()?;
    let rex = *rex_prefix;
    let base_low = sib_byte & 7;
    let index_low = sib_byte >> 3 & 7;
    let scale = sib_byte >> 6 & 3;
    let base = base_low | if rex & REX_B != 0 { 8 } else { 0 };
    let index = index_low | if rex & REX_X != 0 { 8 } else { 0 };

    let (mut ea, seg) = if base_low == 5 && !mod_has_disp {
        let disp = read_imm32s()? as i64 as u64;
        if rex & REX_B != 0 {
            (read_reg64(13).wrapping_add(disp), SS)
        }
        else {
            (disp, DS)
        }
    }
    else {
        (read_reg64(base), default_seg_rm64(base))
    };

    if index_low != 4 || rex & REX_X != 0 {
        ea = ea.wrapping_add(read_reg64(index) << scale);
    }
    Ok((ea, seg))
}

/// 64-bit addressing: REX.B/X, SIB, RIP-relative (`mod=00, rm=101` without REX.B).
/// `67h` truncates the effective address to 32 bits. Linear addresses above 4G #GP.
pub unsafe fn resolve_modrm64(modrm_byte: i32) -> OrPageFault<i32> {
    dbg_assert!(modrm_byte < 0xC0);
    let rex = *rex_prefix;
    let rm_low = modrm_byte & 7;
    let modb = modrm_byte >> 6;
    let rm = rm_low | (rex & REX_B != 0) as i32 * 8;

    let (ea, seg, rip_rel) = if rm_low == 4 {
        let (mut ea, seg) = resolve_sib64(modb != 0)?;
        if modb == 1 {
            ea = ea.wrapping_add(read_imm8s()? as i64 as u64);
        }
        else if modb == 2 {
            ea = ea.wrapping_add(read_imm32s()? as i64 as u64);
        }
        (ea, seg, false)
    }
    else if rm_low == 5 && modb == 0 {
        let disp = read_imm32s()? as i64 as u64;
        if rex & REX_B != 0 {
            (read_reg64(13).wrapping_add(disp), SS, false)
        }
        else {
            // RIP of the next instruction. Immediates after the displacement are
            // not included (U6 guests use RIP-rel without a trailing immediate).
            ((get_real_eip() as u32 as u64).wrapping_add(disp), DS, true)
        }
    }
    else {
        let mut ea = read_reg64(rm);
        if modb == 1 {
            ea = ea.wrapping_add(read_imm8s()? as i64 as u64);
        }
        else if modb == 2 {
            ea = ea.wrapping_add(read_imm32s()? as i64 as u64);
        }
        (ea, default_seg_rm64(rm), false)
    };

    linear_from_ea64(seg, apply_asize64(ea), rip_rel)
}
