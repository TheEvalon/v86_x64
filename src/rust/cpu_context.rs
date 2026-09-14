use crate::cpu::memory;
use crate::prefix::{PREFIX_MASK_ADDRSIZE, PREFIX_MASK_OPSIZE};
use crate::state_flags::CachedStateFlags;

#[derive(Clone)]
pub struct CpuContext {
    pub eip: u32,
    pub prefixes: u8,
    pub rex_prefix: u8,
    pub cs_offset: u32,
    pub state_flags: CachedStateFlags,
    /// True when compiling a 64-bit CS block whose RIP is above 4GiB.
    /// `tlb_data`/`tlb_code` are 32-bit VA tables, so page-switch checks and
    /// compiled Jcc edges are unsafe there.
    pub high_rip: bool,
}

impl CpuContext {
    pub fn advance16(&mut self) {
        dbg_assert!(self.eip & 0xFFF < 0xFFE);
        self.eip += 2;
    }
    pub fn advance32(&mut self) {
        dbg_assert!(self.eip & 0xFFF < 0xFFC);
        self.eip += 4;
    }
    #[allow(unused)]
    pub fn advance_moffs(&mut self) {
        if self.asize_32() {
            self.advance32()
        }
        else {
            self.advance16()
        }
    }

    pub fn read_imm8(&mut self) -> u8 {
        dbg_assert!(self.eip & 0xFFF < 0xFFF);
        let v = memory::read8(self.eip) as u8;
        self.eip += 1;
        v
    }
    pub fn read_imm8s(&mut self) -> i8 { self.read_imm8() as i8 }
    pub fn read_imm16(&mut self) -> u16 {
        dbg_assert!(self.eip & 0xFFF < 0xFFE);
        let v = memory::read16(self.eip) as u16;
        self.eip += 2;
        v
    }
    pub fn read_imm32(&mut self) -> u32 {
        dbg_assert!(self.eip & 0xFFF < 0xFFC);
        let v = memory::read32s(self.eip) as u32;
        self.eip += 4;
        v
    }
    pub fn read_moffs(&mut self) -> u32 {
        if self.asize_32() {
            self.read_imm32()
        }
        else {
            self.read_imm16() as u32
        }
    }

    pub fn cpl3(&self) -> bool { self.state_flags.cpl3() }
    pub fn has_flat_segmentation(&self) -> bool { self.state_flags.has_flat_segmentation() }
    pub fn osize_32(&self) -> bool {
        self.state_flags.is_32() != (self.prefixes & PREFIX_MASK_OPSIZE != 0)
    }
    pub fn asize_32(&self) -> bool {
        // Match `is_asize_32()`: 64-bit CS never uses 16-bit addressing.
        // Default asize is 64-bit; 67h is 32-bit. The 32-bit JIT helpers and
        // ModRM decoder both treat "32-bit asize" as decode32 (disp32/SIB),
        // which is the 67h encoding. Flipping is_32 on 67h would decode16
        // (disp16) and slide into INT3 padding.
        if self.state_flags.is_64() {
            true
        }
        else {
            self.state_flags.is_32() != (self.prefixes & PREFIX_MASK_ADDRSIZE != 0)
        }
    }
    pub fn ssize_32(&self) -> bool { self.state_flags.ssize_32() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prefix::PREFIX_67;

    fn long_cs_ctx(prefixes: u8) -> CpuContext {
        CpuContext {
            eip: 0,
            prefixes,
            rex_prefix: 0,
            cs_offset: 0,
            state_flags: CachedStateFlags::of_u32(1 << 0 | 1 << 4),
            high_rip: true,
        }
    }

    #[test]
    fn asize_32_in_long_cs_ignores_67h() {
        assert!(long_cs_ctx(0).asize_32());
        assert!(long_cs_ctx(PREFIX_67).asize_32());
    }

    #[test]
    fn asize_32_in_prot32_still_flips_on_67h() {
        let mut cpu = long_cs_ctx(0);
        cpu.state_flags = CachedStateFlags::of_u32(1 << 0);
        cpu.high_rip = false;
        assert!(cpu.asize_32());
        cpu.prefixes = PREFIX_67;
        assert!(!cpu.asize_32());
    }
}
