#![allow(non_snake_case)]

use crate::cpu::long_mode;
use crate::cpu::memory;
use crate::cpu_context::CpuContext;
use crate::gen;
use crate::modrm;
use crate::prefix::{
    PREFIX_66, PREFIX_67, PREFIX_F2, PREFIX_F3, PREFIX_MASK_ADDRSIZE, PREFIX_MASK_SEGMENT,
};
use crate::regs::{CS, DS, ES, FS, GS, SS};

#[derive(PartialEq, Eq)]
pub enum AnalysisType {
    Normal,
    BlockBoundary,
    Jump {
        offset: i32,
        is_32: bool,
        condition: Option<u8>,
    },
    STI,
}

pub struct Analysis {
    pub no_next_instruction: bool,
    pub absolute_jump: bool,
    pub ty: AnalysisType,
}

pub fn analyze_step(mut cpu: &mut CpuContext) -> Analysis {
    let mut analysis = Analysis {
        no_next_instruction: false,
        absolute_jump: false,
        ty: AnalysisType::Normal,
    };
    cpu.prefixes = 0;
    cpu.rex_prefix = 0;
    if cpu.state_flags.is_64() {
        return analyze_step_64(cpu, analysis);
    }
    let opcode = cpu.read_imm8() as u32 | (cpu.osize_32() as u32) << 8;
    gen::analyzer::analyzer(opcode, &mut cpu, &mut analysis);
    analysis
}

pub fn consume_legacy_prefixes_and_rex(cpu: &mut CpuContext) -> u8 {
    loop {
        let byte = cpu.read_imm8();
        match byte {
            0x26 => cpu.prefixes = cpu.prefixes & !PREFIX_MASK_SEGMENT | (ES as u8 + 1),
            0x2E => cpu.prefixes = cpu.prefixes & !PREFIX_MASK_SEGMENT | (CS as u8 + 1),
            0x36 => cpu.prefixes = cpu.prefixes & !PREFIX_MASK_SEGMENT | (SS as u8 + 1),
            0x3E => cpu.prefixes = cpu.prefixes & !PREFIX_MASK_SEGMENT | (DS as u8 + 1),
            0x64 => cpu.prefixes = cpu.prefixes & !PREFIX_MASK_SEGMENT | (FS as u8 + 1),
            0x65 => cpu.prefixes = cpu.prefixes & !PREFIX_MASK_SEGMENT | (GS as u8 + 1),
            0x66 => cpu.prefixes |= PREFIX_66,
            0x67 => cpu.prefixes |= PREFIX_67,
            0xF0 => {},
            0xF2 => cpu.prefixes |= PREFIX_F2,
            0xF3 => cpu.prefixes |= PREFIX_F3,
            0x40..=0x4F => {
                cpu.rex_prefix = byte;
                return cpu.read_imm8();
            },
            other => return other,
        }
    }
}

pub fn long_cs_needs_trampoline(cpu: &CpuContext) -> bool {
    let mut tmp = cpu.clone();
    tmp.prefixes = 0;
    tmp.rex_prefix = 0;
    let opcode = consume_legacy_prefixes_and_rex(&mut tmp);
    opcode_needs_long_trampoline(
        tmp.rex_prefix,
        opcode,
        peek_imm8(&tmp),
        peek_imm8_at(&tmp, 1),
        tmp.prefixes & PREFIX_MASK_ADDRSIZE != 0,
        tmp.prefixes,
    )
}

pub fn opcode_has_modrm(opcode: u8) -> bool {
    matches!(
        opcode,
        0x00..=0x03
            | 0x08..=0x0B
            | 0x10..=0x13
            | 0x18..=0x1B
            | 0x20..=0x23
            | 0x28..=0x2B
            | 0x30..=0x33
            | 0x38..=0x3B
            | 0x62
            | 0x63
            | 0x69
            | 0x6B
            | 0x80..=0x8F
            | 0xC0
            | 0xC1
            | 0xC4..=0xC7
            | 0xD0..=0xD3
            | 0xD8..=0xDF
            | 0xF6
            | 0xF7
            | 0xFE
            | 0xFF
    )
}

fn opcode_0f_whitelist_modrm(op: u8) -> bool {
    matches!(
        op,
        0x40..=0x4F
            | 0x90..=0x9F
            | 0xA3
            | 0xAB
            | 0xAF
            | 0xB0
            | 0xB1
            | 0xB3
            | 0xB6
            | 0xB7
            | 0xBB
            | 0xBC
            | 0xBD
            | 0xBE
            | 0xBF
            | 0xC0
            | 0xC1
    )
}

/// True when a 0F encoding in 64-bit CS must trampoline instead of using
/// the 32-bit `jit0f` table. Register-form CMOV/BSWAP/etc. are allowed;
/// REX/66/F2/F3, memory ModRM, Jcc, and system/SSE ops are not.
fn opcode_0f_needs_long_trampoline(op: u8, modrm: u8, prefixes: u8) -> bool {
    if prefixes & (PREFIX_66 | PREFIX_F2 | PREFIX_F3) != 0 {
        return true;
    }
    if (0xC8..=0xCF).contains(&op) {
        // BSWAP r32: 0F C8+rd, no ModRM byte.
        return false;
    }
    if !opcode_0f_whitelist_modrm(op) {
        return true;
    }
    modrm < 0xC0
}

pub fn opcode_needs_long_trampoline(
    rex: u8,
    opcode: u8,
    next: u8,
    next2: u8,
    addrsize_override: bool,
    prefixes: u8,
) -> bool {
    if opcode == 0x0F {
        if opcode_0f_needs_long_trampoline(next, next2, prefixes) {
            return true;
        }
    }
    else if long_mode::opcode_is_forced64(opcode as i32) {
        return true;
    }
    if rex != 0 {
        return true;
    }
    if matches!(
        opcode,
        0x6C..=0x6F | 0xA0..=0xA7 | 0xAA..=0xAF | 0xE0..=0xE3
    ) {
        // 64-bit string/LOOP use RSI/RDI/RCX; the 32-bit JIT helpers do not.
        return true;
    }
    // Non-REX memory operands still use 64-bit addressing in 64-bit CS
    // (`mov ebx, [rax]` with RAX above 4GiB). The 32-bit JIT helpers
    // read EAX and truncate. 67h keeps 32-bit asize, so those stay JIT.
    if !addrsize_override && opcode_has_modrm(opcode) && next < 0xC0 {
        return true;
    }
    false
}

fn peek_imm8(cpu: &CpuContext) -> u8 { peek_imm8_at(cpu, 0) }

fn peek_imm8_at(cpu: &CpuContext, off: u32) -> u8 {
    if (cpu.eip as u32 & 0xFFF) + off > 0xFFF {
        0
    }
    else {
        memory::read8(cpu.eip.wrapping_add(off)) as u8
    }
}

fn fixup_imm64_skip(cpu: &mut CpuContext, opcode: u8) {
    if cpu.rex_prefix & long_mode::REX_W != 0 && (0xB8..=0xBF).contains(&opcode) {
        if cpu.osize_32() {
            let _ = cpu.read_imm32();
        }
        else {
            let _ = cpu.read_imm16();
            let _ = cpu.read_imm32();
        }
    }
    if matches!(opcode, 0xA0..=0xA3) && cpu.prefixes & PREFIX_MASK_ADDRSIZE == 0 {
        let _ = cpu.read_imm32();
    }
}

fn analyze_step_64(cpu: &mut CpuContext, mut analysis: Analysis) -> Analysis {
    let opcode = consume_legacy_prefixes_and_rex(cpu);
    let trampoline = opcode_needs_long_trampoline(
        cpu.rex_prefix,
        opcode,
        peek_imm8(cpu),
        peek_imm8_at(cpu, 1),
        cpu.prefixes & PREFIX_MASK_ADDRSIZE != 0,
        cpu.prefixes,
    );
    gen::analyzer::analyzer(
        opcode as u32 | (cpu.osize_32() as u32) << 8,
        cpu,
        &mut analysis,
    );
    fixup_imm64_skip(cpu, opcode);
    if trampoline {
        analysis.ty = AnalysisType::BlockBoundary;
    }
    analysis
}

pub fn analyze_step_handle_prefix(cpu: &mut CpuContext, analysis: &mut Analysis) {
    gen::analyzer::analyzer(
        cpu.read_imm8() as u32 | (cpu.osize_32() as u32) << 8,
        cpu,
        analysis,
    )
}
pub fn analyze_step_handle_segment_prefix(
    segment: u32,
    cpu: &mut CpuContext,
    analysis: &mut Analysis,
) {
    dbg_assert!(segment <= 5);
    cpu.prefixes = cpu.prefixes & !PREFIX_MASK_SEGMENT | (segment as u8 + 1);
    analyze_step_handle_prefix(cpu, analysis)
}

pub fn instr16_0F_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    gen::analyzer0f::analyzer(cpu.read_imm8() as u32, cpu, analysis)
}
pub fn instr32_0F_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    gen::analyzer0f::analyzer(cpu.read_imm8() as u32 | 0x100, cpu, analysis)
}
pub fn instr_26_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    analyze_step_handle_segment_prefix(ES, cpu, analysis)
}
pub fn instr_2E_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    analyze_step_handle_segment_prefix(CS, cpu, analysis)
}
pub fn instr_36_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    analyze_step_handle_segment_prefix(SS, cpu, analysis)
}
pub fn instr_3E_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    analyze_step_handle_segment_prefix(DS, cpu, analysis)
}
pub fn instr_64_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    analyze_step_handle_segment_prefix(FS, cpu, analysis)
}
pub fn instr_65_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    analyze_step_handle_segment_prefix(GS, cpu, analysis)
}
pub fn instr_66_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    cpu.prefixes |= PREFIX_66;
    analyze_step_handle_prefix(cpu, analysis)
}
pub fn instr_67_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    cpu.prefixes |= PREFIX_67;
    analyze_step_handle_prefix(cpu, analysis)
}
pub fn instr_F0_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    // lock: Ignored
    analyze_step_handle_prefix(cpu, analysis)
}
pub fn instr_F2_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    cpu.prefixes |= PREFIX_F2;
    analyze_step_handle_prefix(cpu, analysis)
}
pub fn instr_F3_analyze(cpu: &mut CpuContext, analysis: &mut Analysis) {
    cpu.prefixes |= PREFIX_F3;
    analyze_step_handle_prefix(cpu, analysis)
}

pub fn modrm_analyze(ctx: &mut CpuContext, modrm_byte: u8) { modrm::skip(ctx, modrm_byte); }

#[cfg(test)]
mod tests {
    use super::*;

    fn needs(rex: u8, opcode: u8, next: u8, addrsize_override: bool) -> bool {
        opcode_needs_long_trampoline(rex, opcode, next, 0, addrsize_override, 0)
    }

    fn needs0f(rex: u8, op: u8, modrm: u8, prefixes: u8) -> bool {
        opcode_needs_long_trampoline(rex, 0x0F, op, modrm, false, prefixes)
    }

    #[test]
    fn trampoline_any_rex() {
        assert!(needs(long_mode::REX_W, 0x01, 0xC0, false));
        assert!(needs(0x40, 0x33, 0xC0, false));
    }

    #[test]
    fn trampoline_memory_modrm_in_long_cs() {
        assert!(opcode_has_modrm(0x8B));
        assert!(!opcode_has_modrm(0x75));
        assert!(needs(0, 0x8B, 0x05, false));
        assert!(needs(0, 0x8B, 0x18, false));
        assert!(needs(0, 0xC7, 0x44, false));
        assert!(!needs(0, 0x8B, 0x05, true));
        assert!(!needs(0, 0x8B, 0x18, true));
        assert!(!needs(0, 0x8B, 0xC3, false));
        assert!(needs(0, 0xE8, 0, false));
        assert!(needs(0, 0xA4, 0, false));
        assert!(needs(0, 0xAB, 0, false));
        assert!(needs(0, 0xE2, 0, false));
        assert!(!needs(0, 0x75, 0, false));
        assert!(!needs(0, 0x83, 0xC0, false));
    }

    #[test]
    fn trampoline_0f_whitelist_register_form() {
        // 0F 40 C3: CMOVO eax, ebx (register). 32-bit JIT.
        assert!(!needs0f(0, 0x40, 0xC3, 0));
        // 0F 40 05: CMOVO eax, [disp32]. 64-bit addressing.
        assert!(needs0f(0, 0x40, 0x05, 0));
        // 41 0F 40 C3: REX.B CMOVO.
        assert!(needs0f(0x41, 0x40, 0xC3, 0));
        // 0F 05: SYSCALL.
        assert!(needs0f(0, 0x05, 0, 0));
        // 0F CC: BSWAP esp encoding; C8–CF have no ModRM.
        assert!(!needs0f(0, 0xCC, 0, 0));
        assert!(!needs0f(0, 0xC8, 0x05, 0));
        assert!(needs0f(0, 0x40, 0xC3, PREFIX_66));
        assert!(needs0f(0, 0x40, 0xC3, PREFIX_F2));
        assert!(needs0f(0, 0x40, 0xC3, PREFIX_F3));
        assert!(needs0f(0, 0x80, 0, 0));
        assert!(needs0f(0, 0xA2, 0, 0));
        assert!(needs0f(0, 0xC7, 0xC1, 0));
        assert!(!needs0f(0, 0x44, 0xC3, 0));
        assert!(!needs0f(0, 0xA3, 0xD8, 0));
        assert!(needs0f(0, 0xA3, 0x18, 0));
        assert!(!needs0f(0, 0xB6, 0xC3, 0));
        assert!(!needs0f(0, 0x94, 0xC0, 0));
    }
}
