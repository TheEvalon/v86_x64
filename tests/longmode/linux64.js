#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import url from "node:url";

const __dirname = url.fileURLToPath(new URL(".", import.meta.url));
const ROOT = path.join(__dirname, "../..");
const KERNEL = path.join(ROOT, "images/vmlinuz-x86_64");
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

const TEST_RELEASE_BUILD = +process.env.TEST_RELEASE_BUILD;
const { V86 } = await import(TEST_RELEASE_BUILD ? "../../build/libv86.mjs" : "../../src/main.js");

const TIMEOUT_MS = +process.env.LINUX64_TIMEOUT_MS || 600000;
const CMDLINE = "console=ttyS0,115200 earlyprintk=serial,ttyS0,115200 " +
    "acpi=off noapic nolapic nosmp nokaslr debug";

const emulator = new V86({
    bios: { url: path.join(ROOT, "bios/seabios.bin") },
    vga_bios: { url: path.join(ROOT, "bios/vgabios.bin") },
    bzimage: { url: KERNEL },
    cmdline: CMDLINE,
    autostart: true,
    memory_size: 128 * 1024 * 1024,
    acpi: false,
    disable_jit: +process.env.DISABLE_JIT,
    log_level: +process.env.LOG_LEVEL || 0,
});

let serial = "";
let finished = false;

function u64_from_pair(view)
{
    return (view[0] >>> 0) + (view[1] >>> 0) * 0x100000000;
}

function hex64(n)
{
    return "0x" + n.toString(16);
}

function dump_at(cpu, virt)
{
    const lo = virt | 0;
    try
    {
        const phys = cpu.translate_address_system_read(lo) >>> 0;
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

function dump_regs(cpu)
{
    const names = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi"];
    const parts = [];
    for(let i = 0; i < 8; i++)
    {
        const full = (cpu.reg32[i] >>> 0) + (cpu.reg_high32[i] >>> 0) * 0x100000000;
        parts.push(names[i] + "=" + hex64(full));
    }
    const efer = (cpu.efer[0] >>> 0) + (cpu.efer[1] >>> 0) * 0x100000000;
    parts.push("cs=" + hex64(cpu.sreg[1]));
    parts.push("ss=" + hex64(cpu.sreg[2]));
    parts.push("is_64=" + (cpu.is_64[0] | 0));
    parts.push("efer=" + hex64(efer));
    return parts.join(" ");
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
        finish(1, "linux64: unexpected " + what + " rip=" + hex64(rip) +
            " bytes=[" + dump_at(cpu, rip) + "] " + dump_regs(cpu));
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
    if(serial.includes("Linux version"))
    {
        console.log("linux64: pass (Linux version)");
        finish(0);
    }
});

setTimeout(() => {
    try
    {
        const cpu = emulator.v86.cpu;
        const rip = u64_from_pair(cpu.rip64);
        finish(1, "linux64: timed out after " + TIMEOUT_MS + "ms rip=" + hex64(rip) +
            " bytes=[" + dump_at(cpu, rip) + "] " + dump_regs(cpu));
    }
    catch(_e)
    {
        finish(1, "linux64: timed out after " + TIMEOUT_MS + "ms");
    }
}, TIMEOUT_MS);
