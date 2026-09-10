#!/usr/bin/env node

// Opt-in Windows XP Professional x64 boot probe (U11).
// Not wired into `make longmode-test` / CI: the disk is a user-supplied image.
//
//   XP64_IMG=/path/to/disk.img node tests/longmode/xp64.js
//   node tests/longmode/xp64.js /path/to/disk.img
//
// Default search paths (gitignored): images/windows-xp-x64.img, images/xp64.img
//
// First pass bar: the guest sets EFER.LMA and CS.L (is_64) and survives a few
// seconds without #UD. That is NTLDR/winload entering long mode, not a desktop.

import fs from "node:fs";
import path from "node:path";
import url from "node:url";

const __dirname = url.fileURLToPath(new URL(".", import.meta.url));
const ROOT = path.join(__dirname, "../..");
const EFER_LMA = 1 << 10;
const EFER_LME = 1 << 8;

process.on("unhandledRejection", exn => { throw exn; });

const CANDIDATES = [
    process.env.XP64_IMG,
    process.argv[2],
    path.join(ROOT, "images/windows-xp-x64.img"),
    path.join(ROOT, "images/xp64.img"),
    path.join(ROOT, "images/winxp64.img"),
].filter(Boolean);

function resolve_image()
{
    for(const p of CANDIDATES)
    {
        if(fs.existsSync(p) && fs.statSync(p).size > 1024 * 1024)
        {
            return path.resolve(p);
        }
    }
    return null;
}

function probe_image(file)
{
    const fd = fs.openSync(file, "r");
    const size = fs.fstatSync(fd).size;
    const n = Math.min(size, 64 * 1024 * 1024);
    const buf = Buffer.alloc(n);
    fs.readSync(fd, buf, 0, n, 0);
    fs.closeSync(fd);

    const magic = buf.slice(0, 4).toString("latin1");
    if(magic === "QFI\xfb")
    {
        return { qcow2: true, size, hints: ["qcow2: convert with qemu-img convert -O raw"] };
    }

    const text = buf.toString("latin1");
    const hints = [];
    if(text.includes("AMD64"))
    {
        hints.push("string AMD64");
    }
    if(/ntkrnlmp/i.test(text))
    {
        hints.push("ntkrnlmp");
    }
    if(/ntoskrnl/i.test(text))
    {
        hints.push("ntoskrnl");
    }
    if(/ACPI Uniprocessor/i.test(text))
    {
        hints.push("ACPI Uniprocessor HAL (v86 first boot wants Standard PC)");
    }
    if(/Standard PC/i.test(text))
    {
        hints.push("Standard PC");
    }

    let pe_amd64 = 0;
    let pe_i386 = 0;
    for(let i = 0; i + 0x40 < buf.length; i++)
    {
        if(buf[i] !== 0x4D || buf[i + 1] !== 0x5A)
        {
            continue;
        }
        const e_lfanew = buf.readUInt32LE(i + 0x3C);
        const pe = i + e_lfanew;
        if(pe + 6 >= buf.length || buf[pe] !== 0x50 || buf[pe + 1] !== 0x45)
        {
            continue;
        }
        const machine = buf.readUInt16LE(pe + 4);
        if(machine === 0x8664)
        {
            pe_amd64++;
        }
        else if(machine === 0x14C)
        {
            pe_i386++;
        }
    }
    if(pe_amd64)
    {
        hints.push("PE AMD64 x" + pe_amd64);
    }
    if(pe_i386)
    {
        hints.push("PE i386 x" + pe_i386);
    }
    return { qcow2: false, size, pe_amd64, pe_i386, hints };
}

const IMAGE = resolve_image();
if(!IMAGE)
{
    console.error("xp64: no disk image. This cloud agent cannot see a QEMU disk on your machine.");
    console.error("Put a raw image at images/windows-xp-x64.img (gitignored) or:");
    console.error("  XP64_IMG=/path/to/disk.img node tests/longmode/xp64.js");
    console.error("If the QEMU file is qcow2: qemu-img convert -O raw in.qcow2 images/windows-xp-x64.img");
    console.error("Need Windows XP Professional x64 Edition, not 32-bit XP.");
    process.exit(2);
}

const probe = probe_image(IMAGE);
console.error("xp64: image " + IMAGE + " size=" + probe.size +
    (probe.hints.length ? " (" + probe.hints.join(", ") + ")" : ""));
if(probe.qcow2)
{
    console.error("xp64: qcow2 is not a v86 disk. Convert to raw first.");
    process.exit(2);
}
if(!probe.pe_amd64 && probe.pe_i386)
{
    console.error("xp64: this looks like 32-bit XP (i386 PE, no AMD64). U11 needs XP Professional x64.");
}

const TEST_RELEASE_BUILD = +process.env.TEST_RELEASE_BUILD;
const { V86 } = await import(TEST_RELEASE_BUILD ? "../../build/libv86.mjs" : "../../src/main.js");

const TIMEOUT_MS = +process.env.XP64_TIMEOUT_MS || 180000;
const HOLD_MS = +process.env.XP64_HOLD_MS || 5000;
// QEMU-installed XP x64 uses the ACPI HAL; Standard PC is XP64_ACPI=0.
const ACPI = process.env.XP64_ACPI !== "0";

const emulator = new V86({
    bios: { url: path.join(ROOT, "bios/seabios.bin") },
    vga_bios: { url: path.join(ROOT, "bios/vgabios.bin") },
    hda: { url: IMAGE, async: true },
    autostart: true,
    memory_size: (+process.env.XP64_MEMORY_MB || 512) * 1024 * 1024,
    acpi: ACPI,
    apic: ACPI,
    disable_jit: +process.env.DISABLE_JIT,
    log_level: +process.env.LOG_LEVEL || 0,
});

let serial = "";
let finished = false;
let saw_lme = false;
let saw_lma = false;
let saw_is_64 = false;
let hold_timer = null;

function u64_from_pair(view)
{
    return BigInt(view[0] >>> 0) + (BigInt(view[1] >>> 0) << 32n);
}

function hex64(n)
{
    const v = typeof n === "bigint" ? n : BigInt(n);
    return "0x" + v.toString(16);
}

function screen_text()
{
    try
    {
        return emulator.screen_adapter.get_text_screen().map(s => s.trimEnd()).join("\n").trimEnd();
    }
    catch(_e)
    {
        return "";
    }
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
    parts.push("cs=" + hex64(cpu.sreg[1]));
    parts.push("is_64=" + (cpu.is_64[0] | 0));
    parts.push("is_32=" + (cpu.is_32[0] | 0));
    parts.push("efer=" + hex64(u64_from_pair(cpu.efer)));
    parts.push("cr0=" + hex64(cpu.cr[0] >>> 0));
    parts.push("cr3=" + hex64(cpu.cr[3] >>> 0));
    parts.push("cr4=" + hex64(cpu.cr[4] >>> 0));
    parts.push("rip=" + hex64(u64_from_pair(cpu.rip64)));
    return parts.join(" ");
}

function finish(code, message)
{
    if(finished)
    {
        return;
    }
    finished = true;
    if(hold_timer)
    {
        clearTimeout(hold_timer);
    }
    if(message)
    {
        console.error(message);
    }
    const text = screen_text();
    if(text)
    {
        console.error("xp64 screen:\n" + text.slice(-4000));
    }
    if(serial.trim())
    {
        console.error("xp64 serial:\n" + serial.slice(-2000));
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
    let last_log = Date.now();
    cpu0.main_loop = function()
    {
        const efer = cpu0.efer[0] >>> 0;
        if(efer & EFER_LME && !saw_lme)
        {
            saw_lme = true;
            console.error("xp64: EFER.LME rip=" + hex64(u64_from_pair(cpu0.rip64)));
        }
        if(efer & EFER_LMA && !saw_lma)
        {
            saw_lma = true;
            console.error("xp64: EFER.LMA " + dump_regs(cpu0));
        }
        if(cpu0.is_64[0] && !saw_is_64)
        {
            saw_is_64 = true;
            console.error("xp64: CS.L " + dump_regs(cpu0));
            console.log("xp64: entered long mode");
            hold_timer = setTimeout(() => {
                finish(0, "xp64: pass (long mode held " + HOLD_MS + "ms)");
            }, HOLD_MS);
        }
        const now = Date.now();
        if(now - last_log >= 5000)
        {
            last_log = now;
            const text = screen_text().split("\n").filter(Boolean).slice(-6).join(" | ");
            console.error("xp64: " + dump_regs(cpu0) + (text ? " screen=[" + text + "]" : ""));
        }
        return orig_main_loop();
    };

    emulator.cpu_exception_hook = function(n)
    {
        if(n !== 6 && n !== 8)
        {
            return false;
        }
        const cpu = emulator.v86.cpu;
        const what = n === 8 ? "#DF" : "#UD";
        finish(1, "xp64: unexpected " + what + " " + dump_regs(cpu) +
            " prev=" + hex64(u64_from_pair(cpu.previous_rip64)));
        return true;
    };
});

emulator.add_listener("serial0-output-byte", function(byte)
{
    const chr = String.fromCharCode(byte);
    serial += chr;
    if(process.env.XP64_SERIAL)
    {
        process.stdout.write(chr);
    }
});

setTimeout(() => {
    try
    {
        const cpu = emulator.v86.cpu;
        const why = saw_is_64 ? "long mode seen but hold not finished" :
            saw_lma ? "LMA without CS.L" :
            saw_lme ? "LME without LMA" :
            "never reached long mode (32-bit XP, ACPI HAL, or NTLDR died)";
        finish(1, "xp64: timed out after " + TIMEOUT_MS + "ms (" + why + ") " + dump_regs(cpu));
    }
    catch(_e)
    {
        finish(1, "xp64: timed out after " + TIMEOUT_MS + "ms");
    }
}, TIMEOUT_MS);
