#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import { LINUX64_INIT_LINE, write_linux64_initrd } from "./make-initrd.js";

const __dirname = url.fileURLToPath(new URL(".", import.meta.url));
const ROOT = path.join(__dirname, "../..");
const KERNEL = path.join(ROOT, "images/vmlinuz-x86_64");
const INITRD = path.join(ROOT, "images/linux64-initrd.cpio.gz");
const KERNEL_URLS = [
    "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/netboot/vmlinuz-virt",
    "https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux",
];

process.on("unhandledRejection", exn => { throw exn; });

function ensure_kernel()
{
    if(fs.existsSync(KERNEL) && fs.statSync(KERNEL).size > 1024 * 1024)
    {
        return;
    }
    fs.mkdirSync(path.dirname(KERNEL), { recursive: true });
    for(const src of KERNEL_URLS)
    {
        console.log("linux64: downloading " + src);
        const result = spawnSync("curl", ["-fL", "--retry", "3", "-o", KERNEL, src], {
            stdio: "inherit",
        });
        if(result.status === 0 && fs.existsSync(KERNEL) && fs.statSync(KERNEL).size > 1024 * 1024)
        {
            return;
        }
    }
    console.error("linux64: could not download an x86_64 bzImage");
    process.exit(1);
}

ensure_kernel();
write_linux64_initrd(INITRD);

const TEST_RELEASE_BUILD = +process.env.TEST_RELEASE_BUILD;
const { V86 } = await import(TEST_RELEASE_BUILD ? "../../build/libv86.mjs" : "../../src/main.js");

const TIMEOUT_MS = +process.env.LINUX64_TIMEOUT_MS || 600000;
const CMDLINE = "console=ttyS0,115200 earlyprintk=serial,ttyS0,115200 " +
    "acpi=off nosmp nokaslr debug rdinit=/init init=/init";

const emulator = new V86({
    bios: { url: path.join(ROOT, "bios/seabios.bin") },
    vga_bios: { url: path.join(ROOT, "bios/vgabios.bin") },
    bzimage: { url: KERNEL },
    initrd: { url: INITRD },
    cmdline: CMDLINE,
    autostart: true,
    memory_size: 128 * 1024 * 1024,
    acpi: false,
    apic: true,
    disable_jit: +process.env.DISABLE_JIT,
    log_level: +process.env.LOG_LEVEL || 0,
});

let serial = "";
let finished = false;
let saw_linux_version = false;
let saw_initramfs = false;
let saw_run_init = false;

function u64_from_pair(view)
{
    return BigInt(view[0] >>> 0) + (BigInt(view[1] >>> 0) << 32n);
}

function as_u64(n)
{
    return typeof n === "bigint" ? n : BigInt(n);
}

function hex64(n)
{
    return "0x" + as_u64(n).toString(16);
}

function rd64_phys(cpu, phys)
{
    let lo = 0, hi = 0;
    for(let i = 0; i < 4; i++)
    {
        lo |= cpu.mem8[phys + i] << (8 * i);
        hi |= cpu.mem8[phys + 4 + i] << (8 * i);
    }
    return BigInt(lo >>> 0) + (BigInt(hi >>> 0) << 32n);
}

function phys_of_virt(cpu, virt)
{
    const v = as_u64(virt);
    const cr3 = cpu.cr[3] >>> 0;
    const pml4i = Number((v >> 39n) & 0x1FFn);
    const pdpti = Number((v >> 30n) & 0x1FFn);
    const pdi = Number((v >> 21n) & 0x1FFn);
    const pti = Number((v >> 12n) & 0x1FFn);
    const pml4e = rd64_phys(cpu, cr3 + pml4i * 8);
    if(!(pml4e & 1n))
    {
        return null;
    }
    const pdpte = rd64_phys(cpu, Number(pml4e & 0xFFFFF000n) + pdpti * 8);
    if(!(pdpte & 1n))
    {
        return null;
    }
    if(pdpte & 0x80n)
    {
        return Number((pdpte & 0xFFFFC0000000n) + (v & 0x3FFFFFFFn));
    }
    const pde = rd64_phys(cpu, Number(pdpte & 0xFFFFF000n) + pdi * 8);
    if(!(pde & 1n))
    {
        return null;
    }
    if(pde & 0x80n)
    {
        return Number((pde & 0xFFE00000n) + (v & 0x1FFFFFn));
    }
    const pte = rd64_phys(cpu, Number(pde & 0xFFFFF000n) + pti * 8);
    if(!(pte & 1n))
    {
        return null;
    }
    return Number((pte & 0xFFFFF000n) + (v & 0xFFFn));
}

function dump_at(cpu, virt)
{
    try
    {
        const phys = phys_of_virt(cpu, virt);
        if(phys === null)
        {
            return "(unreadable)";
        }
        const bytes = [];
        for(let i = 0; i < 16; i++)
        {
            bytes.push(("0" + cpu.mem8[phys + i].toString(16)).slice(-2));
        }
        return bytes.join(" ");
    }
    catch(_e)
    {
        return "(unreadable)";
    }
}

function dump_idt_gate(cpu, vec)
{
    const virt = u64_from_pair(cpu.idtr_offset64) + BigInt(vec * 16);
    const phys = phys_of_virt(cpu, virt);
    if(phys === null)
    {
        return "vec" + vec + "=(unreadable)";
    }
    const bytes = [];
    for(let i = 0; i < 16; i++)
    {
        bytes.push(("0" + cpu.mem8[phys + i].toString(16)).slice(-2));
    }
    const low = (cpu.mem8[phys] | cpu.mem8[phys + 1] << 8 |
        cpu.mem8[phys + 2] << 16 | cpu.mem8[phys + 3] << 24) >>> 0;
    const mid = (cpu.mem8[phys + 4] | cpu.mem8[phys + 5] << 8 |
        cpu.mem8[phys + 6] << 16 | cpu.mem8[phys + 7] << 24) >>> 0;
    const hi = (cpu.mem8[phys + 8] | cpu.mem8[phys + 9] << 8 |
        cpu.mem8[phys + 10] << 16 | cpu.mem8[phys + 11] << 24) >>> 0;
    const ist = mid & 7;
    const type = (mid >>> 8) & 0x1F;
    const sel = (low >>> 16) & 0xFFFF;
    const off = BigInt(((low & 0xFFFF) | (mid & 0xFFFF0000)) >>> 0) + (BigInt(hi) << 32n);
    return "vec" + vec + "=[" + bytes.join(" ") + "] sel=" + hex64(sel) +
        " ist=" + ist + " type=" + type + " off=" + hex64(off);
}

function dump_qword(cpu, virt)
{
    const v = as_u64(virt);
    const phys = phys_of_virt(cpu, v);
    if(phys === null)
    {
        return "0x" + v.toString(16) + "=(unmapped)";
    }
    return "0x" + v.toString(16) + "=" + hex64(rd64_phys(cpu, phys));
}

function dump_page_walk(cpu, virt)
{
    const v = as_u64(virt);
    const cr3 = cpu.cr[3] >>> 0;
    const pml4i = Number((v >> 39n) & 0x1FFn);
    const pdpti = Number((v >> 30n) & 0x1FFn);
    const pdi = Number((v >> 21n) & 0x1FFn);
    const pti = Number((v >> 12n) & 0x1FFn);
    const pml4e = rd64_phys(cpu, cr3 + pml4i * 8);
    if(!(pml4e & 1n))
    {
        return "pml4[" + pml4i + "]=" + hex64(pml4e) + " !p";
    }
    const pdpte = rd64_phys(cpu, Number(pml4e & 0xFFFFF000n) + pdpti * 8);
    if(!(pdpte & 1n))
    {
        return "pml4e=" + hex64(pml4e) + " pdpt[" + pdpti + "]=" + hex64(pdpte) + " !p";
    }
    if(pdpte & 0x80n)
    {
        return "pml4e=" + hex64(pml4e) + " 1G pdpte=" + hex64(pdpte);
    }
    const pde = rd64_phys(cpu, Number(pdpte & 0xFFFFF000n) + pdi * 8);
    if(!(pde & 1n))
    {
        return "pml4e=" + hex64(pml4e) + " pdpte=" + hex64(pdpte) +
            " pd[" + pdi + "]=" + hex64(pde) + " !p";
    }
    if(pde & 0x80n)
    {
        return "2M pml4e=" + hex64(pml4e) + " pdpte=" + hex64(pdpte) + " pde=" + hex64(pde);
    }
    const pte = rd64_phys(cpu, Number(pde & 0xFFFFF000n) + pti * 8);
    return "4K pml4e=" + hex64(pml4e) + " pdpte=" + hex64(pdpte) +
        " pde=" + hex64(pde) + " pte=" + hex64(pte);
}

function dump_regs(cpu)
{
    const names = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi"];
    const parts = [];
    for(let i = 0; i < 8; i++)
    {
        const full = BigInt(cpu.reg32[i] >>> 0) + (BigInt(cpu.reg_high32[i] >>> 0) << 32n);
        parts.push(names[i] + "=" + hex64(full));
    }
    const rnames = ["r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"];
    for(let i = 0; i < 8; i++)
    {
        const full = BigInt(cpu.reg_r8[i * 2] >>> 0) + (BigInt(cpu.reg_r8[i * 2 + 1] >>> 0) << 32n);
        parts.push(rnames[i] + "=" + hex64(full));
    }
    const efer = u64_from_pair(cpu.efer);
    const cr2 = u64_from_pair(cpu.cr2_64);
    const idtr = u64_from_pair(cpu.idtr_offset64);
    const gdtr = u64_from_pair(cpu.gdtr_offset64);
    const prev = u64_from_pair(cpu.previous_rip64);
    parts.push("cs=" + hex64(cpu.sreg[1]));
    parts.push("ss=" + hex64(cpu.sreg[2]));
    parts.push("is_64=" + (cpu.is_64[0] | 0));
    parts.push("is_32=" + (cpu.is_32[0] | 0));
    parts.push("in_hlt=" + (cpu.in_hlt[0] | 0));
    parts.push("efer=" + hex64(efer));
    parts.push("cr2=" + hex64(cr2));
    parts.push("cr3=" + hex64(cpu.cr[3] >>> 0));
    parts.push("gdtr=" + hex64(gdtr) + "/" + hex64(cpu.gdtr_size[0] >>> 0));
    parts.push("idtr=" + hex64(idtr) + "/" + hex64(cpu.idtr_size[0] >>> 0));
    parts.push("flags=" + hex64(cpu.flags[0] >>> 0));
    parts.push("prev=" + hex64(prev));
    return parts.join(" ");
}

function dump_early_pgt(cpu)
{
    const cr3 = cpu.cr[3] >>> 0;
    const pml4_273 = rd64_phys(cpu, cr3 + 273 * 8);
    const pml4_511 = rd64_phys(cpu, cr3 + 511 * 8);
    const pml4_0 = rd64_phys(cpu, cr3);
    const next_early = dump_qword(cpu, 0xffffffff82eca004n);
    const recursion = dump_qword(cpu, 0xffffffff82eca000n);
    const page_offset = dump_qword(cpu, 0xffffffff821d25b8n);
    const pmd_flags = dump_qword(cpu, 0xffffffff8283d0c0n);
    const r12 = BigInt(cpu.reg_r8[8] >>> 0) + (BigInt(cpu.reg_r8[9] >>> 0) << 32n);
    const regs_ip = dump_qword(cpu, r12 + 0x80n);
    const regs_cs = dump_qword(cpu, r12 + 0x88n);
    const regs_orig = dump_qword(cpu, r12 + 0x78n);
    const regs_flags = dump_qword(cpu, r12 + 0x90n);
    const regs_sp = dump_qword(cpu, r12 + 0x98n);
    let fault_ip = 0n;
    try
    {
        const phys = phys_of_virt(cpu, r12 + 0x80n);
        if(phys !== null)
        {
            fault_ip = rd64_phys(cpu, phys);
        }
    }
    catch(_e) {}
    return "pml4[0]=" + hex64(pml4_0) +
        " pml4[273]=" + hex64(pml4_273) +
        " pml4[511]=" + hex64(pml4_511) +
        " " + next_early + " " + recursion +
        " " + page_offset + " " + pmd_flags +
        " regs=" + hex64(r12) +
        " " + regs_ip + " " + regs_cs + " " + regs_orig +
        " " + regs_flags + " " + regs_sp +
        " fault_bytes=[" + dump_at(cpu, fault_ip) + "]";
}

function dump_stack(cpu)
{
    const rsp = BigInt(cpu.reg32[4] >>> 0) + (BigInt(cpu.reg_high32[4] >>> 0) << 32n);
    const stack = [];
    for(let i = 0; i < 6; i++)
    {
        stack.push(dump_qword(cpu, rsp + BigInt(i * 8)));
    }
    return "stack=[" + stack.join(" ") + "]";
}

function finish(code, message)
{
    if(finished)
    {
        return;
    }
    finished = true;
    if(message)
    {
        console.error(message);
    }
    if(code !== 0)
    {
        console.error("linux64 serial:\n" + serial.slice(-4000));
    }
    try
    {
        emulator.destroy();
    }
    catch(_e)
    {}
    process.exit(code);
}

emulator.add_listener("emulator-loaded", function()
{
    const cpu0 = emulator.v86.cpu;
    const orig_main_loop = cpu0.main_loop.bind(cpu0);
    let ticks = 0;
    let last_log = Date.now();
    cpu0.main_loop = function()
    {
        ticks++;
        const now = Date.now();
        if(now - last_log >= 2000)
        {
            last_log = now;
            const rip = u64_from_pair(cpu0.rip64);
            console.error("linux64: ticks=" + ticks + " rip=" + hex64(rip) +
                " bytes=[" + dump_at(cpu0, rip) + "] " + dump_regs(cpu0));
        }
        return orig_main_loop();
    };

    emulator.cpu_exception_hook = function(n)
    {
        // Linux takes page faults, #NM (FPU), and probed #GPs. Deliver those.
        // #UD is a missing opcode. #DF is a nested-fault shutdown.
        if(n !== 6 && n !== 8)
        {
            return false;
        }
        const cpu = emulator.v86.cpu;
        const rip = u64_from_pair(cpu.previous_rip64);
        const what = n === 8 ? "#DF" : "#UD";
        const phys_hint = 0x1000000;
        const phys_bytes = [];
        for(let i = 0; i < 16; i++)
        {
            phys_bytes.push(("0" + cpu.mem8[phys_hint + i].toString(16)).slice(-2));
        }
        const cur = u64_from_pair(cpu.rip64);
        finish(1, "linux64: unexpected " + what + " previous_rip=" + hex64(rip) +
            " rip=" + hex64(cur) +
            " bytes=[" + dump_at(cpu, rip) + "] cur_bytes=[" + dump_at(cpu, cur) +
            "] phys1M=[" + phys_bytes.join(" ") + "] " +
            dump_regs(cpu) + " walk=" + dump_page_walk(cpu, rip) +
            " cr2walk=" + dump_page_walk(cpu, u64_from_pair(cpu.cr2_64)) +
            " " + dump_idt_gate(cpu, 8) + " " + dump_idt_gate(cpu, 13) +
            " " + dump_idt_gate(cpu, 14) +
            " " + dump_qword(cpu, 0xffffffff829803e8n) +
            " " + dump_qword(cpu, 0xffffffff8283d0c0n) +
            " " + dump_qword(cpu, 0xffffffff8283d030n) +
            " " + dump_qword(cpu, 0xffffffff82843980n) +
            " " + dump_stack(cpu));
        return true;
    };
});

emulator.add_listener("serial0-output-byte", function(byte)
{
    const chr = String.fromCharCode(byte);
    serial += chr;
    if(process.env.LINUX64_SERIAL)
    {
        process.stdout.write(chr);
    }
    if(!saw_linux_version && serial.includes("Linux version"))
    {
        saw_linux_version = true;
        console.error("linux64: reached Linux version, continuing");
    }
    if(!saw_initramfs && (serial.includes("Unpacking initramfs") ||
        serial.includes("Trying to unpack rootfs") ||
        serial.includes("Freeing initrd")))
    {
        saw_initramfs = true;
        console.error("linux64: initramfs unpacked, continuing");
    }
    if(!saw_run_init && serial.includes("Run /init as init process"))
    {
        saw_run_init = true;
        console.error("linux64: kernel execing /init, continuing");
    }
    // Pass on the first /init write. Later getpid/uname/brk lines are extra.
    if(serial.includes(LINUX64_INIT_LINE))
    {
        console.log("linux64: pass (" + LINUX64_INIT_LINE + ")");
        finish(0);
        return;
    }
    const missing_rootfs = [
        "VFS: Cannot open root device",
        "Unable to mount root",
        "No filesystem could mount root",
        "Kernel panic - not syncing: VFS",
    ].find(s => serial.includes(s));
    if(missing_rootfs)
    {
        finish(1, "linux64: initrd present but kernel never ran /init (" +
            missing_rootfs + ")");
        return;
    }
    const panic_at = serial.lastIndexOf("Kernel panic - not syncing");
    if(panic_at >= 0)
    {
        const rest = serial.slice(panic_at);
        const nl = rest.indexOf("\n");
        if(nl >= 0)
        {
            finish(1, "linux64: kernel panic: " + rest.slice(0, nl).trim());
        }
    }
});

setTimeout(() => {
    try
    {
        const cpu = emulator.v86.cpu;
        const rip = u64_from_pair(cpu.rip64);
        finish(1, "linux64: timed out after " + TIMEOUT_MS + "ms rip=" + hex64(rip) +
            " bytes=[" + dump_at(cpu, rip) + "] " + dump_regs(cpu) + " " + dump_stack(cpu) +
            " walk=" + dump_page_walk(cpu, rip) +
            " cr2walk=" + dump_page_walk(cpu, u64_from_pair(cpu.cr2_64)) +
            " " + dump_idt_gate(cpu, 13) + " " + dump_idt_gate(cpu, 14) +
            " " + dump_early_pgt(cpu));
    }
    catch(_e)
    {
        finish(1, "linux64: timed out after " + TIMEOUT_MS + "ms");
    }
}, TIMEOUT_MS);
