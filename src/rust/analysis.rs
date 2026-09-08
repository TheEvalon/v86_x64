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
        tmp.prefixes & PREFIX_MASK_ADDRSIZE != 0,
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

pub fn opcode_needs_long_trampoline(
    rex: u8,
    opcode: u8,
    next: u8,
    addrsize_override: bool,
) -> bool {
    if opcode == 0x0F {
        return true;
    }
    if long_mode::opcode_is_forced64(opcode as i32) {
        return true;
    }
    if rex & 0x0F != 0 {
        return true;
    }
    if matches!(opcode, 0xA0..=0xA3) {
        return true;
    }
    !addrsize_override && opcode_has_modrm(opcode) && next & 0xC7 == 0x05
}

fn peek_imm8(cpu: &CpuContext) -> u8 {
    if cpu.eip & 0xFFF == 0xFFF {
        0
    }
    else {
        memory::read8(cpu.eip) as u8
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
        cpu.prefixes & PREFIX_MASK_ADDRSIZE != 0,
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

    #[test]
    fn trampoline_rex_w_but_not_empty_rex() {
        assert!(opcode_needs_long_trampoline(
            long_mode::REX_W,
            0x01,
            0xC0,
            false
        ));
        assert!(!opcode_needs_long_trampoline(0x40, 0x33, 0xC0, false));
    }

    #[test]
    fn trampoline_rip_rel_modrm_and_forced64() {
        assert!(opcode_has_modrm(0x8B));
        assert!(!opcode_has_modrm(0x75));
        assert!(opcode_needs_long_trampoline(0, 0x8B, 0x05, false));
        assert!(!opcode_needs_long_trampoline(0, 0x8B, 0x05, true));
        assert!(!opcode_needs_long_trampoline(0, 0x8B, 0xC3, false));
        assert!(opcode_needs_long_trampoline(0, 0xE8, 0, false));
        assert!(!opcode_needs_long_trampoline(0, 0x75, 0, false));
        assert!(!opcode_needs_long_trampoline(0, 0x83, 0xC0, false));
    }
}
