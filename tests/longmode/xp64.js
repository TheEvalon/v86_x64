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
import zlib from "node:zlib";

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
let logged_fa80_pf = false;
let logged_rsp_drop = false;
let pf_count = 0;
let last_screenshot_score = -1;

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
    const pml4e = rd64_phys(cpu, cr3 + Number((v >> 39n) & 0x1FFn) * 8);
    if(!(pml4e & 1n))
    {
        return null;
    }
    const pdpte = rd64_phys(cpu, Number(pml4e & 0xFFFFF000n) + Number((v >> 30n) & 0x1FFn) * 8);
    if(!(pdpte & 1n))
    {
        return null;
    }
    if(pdpte & 0x80n)
    {
        return Number((pdpte & 0xFFFFC0000000n) + (v & 0x3FFFFFFFn));
    }
    const pde = rd64_phys(cpu, Number(pdpte & 0xFFFFF000n) + Number((v >> 21n) & 0x1FFn) * 8);
    if(!(pde & 1n))
    {
        return null;
    }
    if(pde & 0x80n)
    {
        return Number((pde & 0xFFE00000n) + (v & 0x1FFFFFn));
    }
    const pte = rd64_phys(cpu, Number(pde & 0xFFFFF000n) + Number((v >> 12n) & 0x1FFn) * 8);
    if(!(pte & 1n))
    {
        return null;
    }
    return Number((pte & 0xFFFFF000n) + (v & 0xFFFn));
}

function pte_selfmap_va(virt)
{
    // Windows IA-32e self-map: PML4[0x1ED] recursively maps the tables.
    return 0xFFFFF68000000000n + ((as_u64(virt) >> 12n) << 3n);
}

function walk_virt(cpu, virt)
{
    const v = as_u64(virt);
    const cr3 = cpu.cr[3] >>> 0;
    const i4 = Number((v >> 39n) & 0x1FFn);
    const i3 = Number((v >> 30n) & 0x1FFn);
    const i2 = Number((v >> 21n) & 0x1FFn);
    const i1 = Number((v >> 12n) & 0x1FFn);
    const pml4e = rd64_phys(cpu, cr3 + i4 * 8);
    if(!(pml4e & 1n))
    {
        return "pml4[" + i4.toString(16) + "]=" + hex64(pml4e) + " np";
    }
    const pdpte = rd64_phys(cpu, Number(pml4e & 0xFFFFF000n) + i3 * 8);
    if(!(pdpte & 1n))
    {
        return "pml4e=" + hex64(pml4e) + " pdpt[" + i3.toString(16) + "]=" + hex64(pdpte) + " np";
    }
    if(pdpte & 0x80n)
    {
        const phys = Number((pdpte & 0xFFFFC0000000n) + (v & 0x3FFFFFFFn));
        return "1GB pml4e=" + hex64(pml4e) + " pdpte=" + hex64(pdpte) + " phys=" + hex64(phys);
    }
    const pde = rd64_phys(cpu, Number(pdpte & 0xFFFFF000n) + i2 * 8);
    if(!(pde & 1n))
    {
        return "pml4e=" + hex64(pml4e) + " pdpte=" + hex64(pdpte) +
            " pd[" + i2.toString(16) + "]=" + hex64(pde) + " np";
    }
    if(pde & 0x80n)
    {
        const phys = Number((pde & 0xFFE00000n) + (v & 0x1FFFFFn));
        return "2MB pml4e=" + hex64(pml4e) + " pdpte=" + hex64(pdpte) +
            " pde=" + hex64(pde) + " phys=" + hex64(phys);
    }
    const pte = rd64_phys(cpu, Number(pde & 0xFFFFF000n) + i1 * 8);
    const phys = (pte & 1n) ? Number((pte & 0xFFFFF000n) + (v & 0xFFFn)) : null;
    return "4K pml4e=" + hex64(pml4e) + " pdpte=" + hex64(pdpte) +
        " pde=" + hex64(pde) + " pte=" + hex64(pte) +
        (phys === null ? " np" : " phys=" + hex64(phys));
}

function dump_pml4(cpu)
{
    const cr3 = cpu.cr[3] >>> 0;
    const parts = [];
    for(let i = 0; i < 512; i++)
    {
        const e = rd64_phys(cpu, cr3 + i * 8);
        if(e & 1n)
        {
            parts.push("[" + i.toString(16) + "]=" + hex64(e) + (e & 0x80n ? "PS" : ""));
        }
    }
    return "cr3=" + hex64(cr3) + " " + (parts.join(" ") || "(empty)");
}

function dump_gdt_cs(cpu)
{
    try
    {
        const base = u64_from_pair(cpu.gdtr_offset64);
        const cs = cpu.sreg[1] >>> 0;
        const phys = phys_of_virt(cpu, base + BigInt(cs & ~7));
        if(phys === null)
        {
            return "gdtr=" + hex64(base) + " cs=" + hex64(cs) + " unmapped";
        }
        return "gdtr=" + hex64(base) + " lim=" + hex64(cpu.gdtr_size[0] >>> 0) +
            " cs=" + hex64(cs) +
            " desc=" + hex64(rd64_phys(cpu, phys)) +
            " " + hex64(rd64_phys(cpu, phys + 8));
    }
    catch(_e)
    {
        return "(gdt unreadable)";
    }
}

function dump_tss(cpu)
{
    try
    {
        const base = u64_from_pair(cpu.tr_base64);
        const phys = phys_of_virt(cpu, base);
        if(phys === null)
        {
            return "tr=" + hex64(cpu.sreg[6]) + " tr_base=" + hex64(base) + " unmapped";
        }
        return "tr=" + hex64(cpu.sreg[6]) +
            " tr_base=" + hex64(base) +
            " rsp0=" + hex64(rd64_phys(cpu, phys + 4)) +
            " ist1=" + hex64(rd64_phys(cpu, phys + 0x24));
    }
    catch(_e)
    {
        return "(tss unreadable)";
    }
}

function dump_idt_vec(cpu, vec)
{
    try
    {
        const base = u64_from_pair(cpu.idtr_offset64);
        const phys = phys_of_virt(cpu, base + BigInt(vec * 16));
        if(phys === null)
        {
            return "idt[" + vec.toString(16) + "] unmapped";
        }
        const b = cpu.mem8;
        const p = phys;
        const selector = b[p + 2] | b[p + 3] << 8;
        const ist = b[p + 4] & 7;
        const type = b[p + 5];
        const offset = BigInt(b[p] | b[p + 1] << 8 | b[p + 6] << 16 | b[p + 7] << 24) +
            (BigInt(b[p + 8]) << 32n) + (BigInt(b[p + 9]) << 40n) +
            (BigInt(b[p + 10]) << 48n) + (BigInt(b[p + 11]) << 56n);
        return "idt[" + vec.toString(16) + "] sel=" + hex64(selector) +
            " type=" + hex64(type) + " ist=" + ist + " offset=" + hex64(offset);
    }
    catch(_e)
    {
        return "idt[" + vec.toString(16) + "] unreadable";
    }
}

function crc32_png(buf)
{
    if(typeof zlib.crc32 === "function")
    {
        return zlib.crc32(buf) >>> 0;
    }
    let c = ~0;
    for(let i = 0; i < buf.length; i++)
    {
        c ^= buf[i];
        for(let j = 0; j < 8; j++)
        {
            c = (c >>> 1) ^ (0xEDB88320 & -(c & 1));
        }
    }
    return (~c) >>> 0;
}

function encode_png(width, height, rgba)
{
    function chunk(tag, data)
    {
        const t = Buffer.from(tag);
        const payload = Buffer.concat([t, data]);
        const len = Buffer.alloc(4);
        len.writeUInt32BE(data.length);
        const crc = Buffer.alloc(4);
        crc.writeUInt32BE(crc32_png(payload));
        return Buffer.concat([len, payload, crc]);
    }
    const raw = Buffer.alloc((width * 4 + 1) * height);
    for(let y = 0; y < height; y++)
    {
        raw[y * (width * 4 + 1)] = 0;
        rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
    }
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(width, 0);
    ihdr.writeUInt32BE(height, 4);
    ihdr[8] = 8;
    ihdr[9] = 6;
    return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        chunk("IHDR", ihdr),
        chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
        chunk("IEND", Buffer.alloc(0)),
    ]);
}

const CGA16 = [
    [0x00, 0x00, 0x00], [0x00, 0x00, 0xAA], [0x00, 0xAA, 0x00], [0x00, 0xAA, 0xAA],
    [0xAA, 0x00, 0x00], [0xAA, 0x00, 0xAA], [0xAA, 0x55, 0x00], [0xAA, 0xAA, 0xAA],
    [0x55, 0x55, 0x55], [0x55, 0x55, 0xFF], [0x55, 0xFF, 0x55], [0x55, 0xFF, 0xFF],
    [0xFF, 0x55, 0x55], [0xFF, 0x55, 0xFF], [0xFF, 0xFF, 0x55], [0xFF, 0xFF, 0xFF],
];

function palette_rgb(pal, index, fallback)
{
    const color = pal[index] >>> 0;
    const rgb = [color >>> 16 & 0xFF, color >>> 8 & 0xFF, color & 0xFF];
    if(rgb[0] | rgb[1] | rgb[2])
    {
        return rgb;
    }
    return fallback || rgb;
}

function render_vga_text_rgba()
{
    try
    {
        const vga = emulator.v86.cpu.devices.vga;
        if(!vga || vga.graphical_mode)
        {
            return null;
        }
        const cols = vga.max_cols || 80;
        const rows = vga.max_rows || 25;
        const cw = 8;
        const ch = ((vga.max_scan_line || 0x0F) & 0x1F) + 1;
        const width = cols * cw;
        const height = rows * ch;
        const rgba = Buffer.alloc(width * height * 4, 0);
        const mem = vga.vga_memory;
        const font = vga.plane2;
        const pal = vga.vga256_palette;
        const dac_map = vga.dac_map;
        const dac_mask = vga.dac_mask === undefined ? 0xFF : vga.dac_mask;
        const row_offset = Math.max(0, ((vga.offset_register || cols / 2) * 2 - cols) * 2);
        let addr = (vga.start_address || 0) << 1;
        for(let row = 0; row < rows; row++)
        {
            for(let col = 0; col < cols; col++)
            {
                const chr = mem[addr] || 0;
                const attr = mem[addr | 1] || 0;
                const fg_i = dac_mask & dac_map[attr & 0xF];
                const bg_i = dac_mask & dac_map[attr >> 4 & 0xF];
                const fg = palette_rgb(pal, fg_i, CGA16[attr & 0xF]);
                const bg = palette_rgb(pal, bg_i, CGA16[attr >> 4 & 0xF]);
                for(let py = 0; py < ch; py++)
                {
                    const bits = font[(chr << 5) + py] || 0;
                    for(let px = 0; px < cw; px++)
                    {
                        const on = bits & (0x80 >> px);
                        const o = ((row * ch + py) * width + (col * cw + px)) * 4;
                        const rgb = on ? fg : bg;
                        rgba[o] = rgb[0];
                        rgba[o + 1] = rgb[1];
                        rgba[o + 2] = rgb[2];
                        rgba[o + 3] = 255;
                    }
                }
                addr += 2;
            }
            addr += row_offset;
        }
        return { width, height, rgba };
    }
    catch(_e)
    {
        return null;
    }
}

function render_text_rgba(lines)
{
    const cols = Math.max(80, ...lines.map(s => s.length));
    const rows = Math.max(25, lines.length);
    const cw = 8, ch = 16;
    const width = cols * cw;
    const height = rows * ch;
    const rgba = Buffer.alloc(width * height * 4, 0);
    for(let i = 0; i < rgba.length; i += 4)
    {
        rgba[i + 3] = 255;
    }
    for(let y = 0; y < rows; y++)
    {
        const line = lines[y] || "";
        for(let x = 0; x < cols; x++)
        {
            const code = (line.charCodeAt(x) || 32) & 0xFF;
            if(code === 32)
            {
                continue;
            }
            for(let py = 1; py < ch - 1; py++)
            {
                const rowbit = glyph_row(code, py);
                for(let px = 1; px < cw - 1; px++)
                {
                    if((rowbit >> (7 - px)) & 1)
                    {
                        const o = ((y * ch + py) * width + (x * cw + px)) * 4;
                        rgba[o] = rgba[o + 1] = rgba[o + 2] = 0xC0;
                        rgba[o + 3] = 255;
                    }
                }
            }
        }
    }
    return { width, height, rgba };
}

function glyph_row(code, py)
{
    const gy = py >> 1;
    if(code >= 48 && code <= 57)
    {
        const bits = [0x3E, 0x06, 0x3C, 0x3C, 0x12, 0x3E, 0x3E, 0x20, 0x3E, 0x3E];
        const n = bits[code - 48];
        if(gy === 0 || gy === 6)
        {
            return n;
        }
        if(gy === 3 && (code === 50 || code === 51 || code === 52 || code === 53 || code === 56 || code === 57))
        {
            return 0x3E;
        }
        return (code & 1 ? 0x22 : 0x20) | ((code & 2) ? 0x02 : 0);
    }
    if((code >= 65 && code <= 90) || (code >= 97 && code <= 122))
    {
        const u = code & ~32;
        if(gy === 0)
        {
            return 0x3E;
        }
        if(gy === 3 && u !== 73 && u !== 84)
        {
            return 0x3E;
        }
        if(gy === 6 && u !== 73)
        {
            return 0x22;
        }
        return 0x22;
    }
    if(code === 46)
    {
        return gy === 6 ? 0x08 : 0;
    }
    if(code === 58)
    {
        return gy === 2 || gy === 5 ? 0x08 : 0;
    }
    if(code === 45)
    {
        return gy === 3 ? 0x3E : 0;
    }
    return gy & 1 ? 0x2A : 0x14;
}

function grab_vga_rgba()
{
    try
    {
        const vga = emulator.v86.cpu.devices.vga;
        if(!vga || !vga.graphical_mode)
        {
            return null;
        }
        vga.screen_fill_buffer();
        const w = vga.screen_width || vga.svga_width;
        const h = vga.screen_height || vga.svga_height;
        if(!w || !h || vga.dest_buffet_offset === undefined)
        {
            return null;
        }
        const src = new Uint8ClampedArray(
            emulator.v86.cpu.wasm_memory.buffer,
            vga.dest_buffet_offset,
            4 * w * h
        );
        let nonzero = 0;
        for(let i = 0; i < src.length; i += 16)
        {
            if(src[i] || src[i + 1] || src[i + 2])
            {
                nonzero++;
            }
        }
        if(!nonzero)
        {
            return null;
        }
        return { width: w, height: h, rgba: Buffer.from(src) };
    }
    catch(_e)
    {
        return null;
    }
}

function save_boot_screenshot(label)
{
    const out = process.env.XP64_SCREENSHOT ||
        path.join("/opt/cursor/artifacts", "xp64_boot_screen.png");
    const dest = label ? out.replace(/\.png$/i, "_" + label + ".png") : out;
    try
    {
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        try
        {
            emulator.v86.cpu.devices.vga.complete_redraw();
            emulator.v86.cpu.devices.vga.screen_fill_buffer();
        }
        catch(_e)
        {}
        const gfx = grab_vga_rgba();
        const vga_font = render_vga_text_rgba();
        const vga_info = dump_vga(emulator.v86.cpu);
        const text = screen_text() || (vga_info.split("vga_text:\n")[1] || "");
        let font_ok = false;
        try
        {
            const font = emulator.v86.cpu.devices.vga.plane2;
            for(let i = 32 * 32; i < 127 * 32 && font; i++)
            {
                if(font[i])
                {
                    font_ok = true;
                    break;
                }
            }
        }
        catch(_e)
        {}
        const img = gfx || (font_ok && vga_font) || render_text_rgba(text ? text.split("\n") : [""]);
        fs.writeFileSync(dest, encode_png(img.width, img.height, img.rgba));
        const txt_out = dest.replace(/\.png$/i, ".txt");
        fs.writeFileSync(txt_out, (text || "(blank text screen)") + "\n" + vga_info + "\n");
        console.error("xp64 screenshot: " + dest + " " + img.width + "x" + img.height +
            (gfx ? " graphical" : " text"));
        return dest;
    }
    catch(e)
    {
        console.error("xp64 screenshot failed: " + e);
        return null;
    }
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
        return "phys=" + hex64(phys) + " [" + bytes.join(" ") + "]";
    }
    catch(_e)
    {
        return "(unreadable)";
    }
}

function dump_pic(cpu)
{
    try
    {
        const m = new Uint8Array(cpu.wasm_memory.buffer, cpu.get_pic_addr_master(), 16);
        const s = new Uint8Array(cpu.wasm_memory.buffer, cpu.get_pic_addr_slave(), 16);
        return "master mask=" + hex64(m[0]) + " map=" + hex64(m[1]) +
            " isr=" + hex64(m[2]) + " irr=" + hex64(m[3]) +
            " slave mask=" + hex64(s[0]) + " map=" + hex64(s[1]) +
            " isr=" + hex64(s[2]) + " irr=" + hex64(s[3]);
    }
    catch(e)
    {
        return "(pic " + e + ")";
    }
}

function dump_stack_words(cpu, virt, count)
{
    const parts = [];
    for(let i = 0; i < count; i++)
    {
        const va = as_u64(virt) + BigInt(i * 8);
        const phys = phys_of_virt(cpu, va);
        if(phys === null)
        {
            parts.push(hex64(va) + "=unmapped");
            continue;
        }
        parts.push(hex64(va) + "=" + hex64(rd64_phys(cpu, phys)));
    }
    return parts.join(" ");
}

function dump_vga(cpu)
{
    try
    {
        const vga = cpu.devices.vga;
        const mem = vga.vga_memory;
        let nonzero = 0;
        let printable = 0;
        const cols = vga.max_cols || 80;
        const rows = [];
        let addr = (vga.start_address || 0) << 1;
        for(let r = 0; r < (vga.max_rows || 25); r++)
        {
            let line = "";
            for(let c = 0; c < cols; c++)
            {
                const chr = mem[addr] || 0;
                const attr = mem[addr | 1] || 0;
                if(chr)
                {
                    nonzero++;
                }
                if(attr)
                {
                    nonzero++;
                }
                if(chr >= 32 && chr < 127)
                {
                    printable++;
                    line += String.fromCharCode(chr);
                }
                else
                {
                    line += chr ? "." : " ";
                }
                addr += 2;
            }
            rows.push(line.replace(/\s+$/g, ""));
        }
        let font_nz = 0;
        const font = vga.plane2;
        if(font)
        {
            for(let i = 0; i < 256 * 32; i++)
            {
                if(font[i])
                {
                    font_nz++;
                }
            }
        }
        const hex0 = [];
        for(let i = 0; i < 32; i++)
        {
            hex0.push(("0" + mem[i].toString(16)).slice(-2));
        }
        return "graphical=" + (+vga.graphical_mode) +
            " svga=" + (+vga.svga_enabled) +
            " attr=" + hex64(vga.attribute_mode >>> 0) +
            " crtc=" + hex64(vga.crtc_mode >>> 0) +
            " cols=" + (vga.max_cols || 0) +
            " rows=" + (vga.max_rows || 0) +
            " start=" + hex64(vga.start_address >>> 0) +
            " text_nz=" + nonzero +
            " printable=" + printable +
            " font_nz=" + font_nz +
            " mem0=" + hex0.join(" ") +
            "\nvga_text:\n" + rows.filter(Boolean).join("\n");
    }
    catch(e)
    {
        return "(vga " + e + ")";
    }
}

function dump_stack_ptes(cpu)
{
    const parts = [];
    for(let off = 0; off <= 0x8000; off += 0x1000)
    {
        const va = 0xFFFFF80000300000n + BigInt(off);
        parts.push(hex64(va) + " " + walk_virt(cpu, va));
    }
    return parts.join("\n");
}

function scan_irq_frames(cpu)
{
    const top = 0xFFFFF80000308000n;
    const bot = 0xFFFFF80000300000n;
    let frames = 0;
    let sample = [];
    for(let va = top - 40n; va >= bot; va -= 8n)
    {
        const phys = phys_of_virt(cpu, va);
        if(phys === null)
        {
            continue;
        }
        const cs = rd64_phys(cpu, phys + 8);
        const ss = rd64_phys(cpu, phys + 32);
        if(cs === 0x10n && ss === 0x18n)
        {
            frames++;
            if(sample.length < 6)
            {
                sample.push(hex64(va) + " rip=" + hex64(rd64_phys(cpu, phys)) +
                    " rsp=" + hex64(rd64_phys(cpu, phys + 24)));
            }
        }
    }
    return "irq_frames=" + frames + (sample.length ? " " + sample.join(" ; ") : "");
}

function dump_apic(cpu)
{
    try
    {
        const apic = new Int32Array(cpu.wasm_memory.buffer, cpu.get_apic_addr(), 46);
        return "tpr=" + hex64(apic[13] >>> 0) +
            " svr=" + hex64(apic[40] >>> 0) +
            " lvt_timer=" + hex64(apic[8] >>> 0) +
            " lint0=" + hex64(apic[10] >>> 0) +
            " init=" + hex64(apic[3] >>> 0);
    }
    catch(e)
    {
        return "(apic " + e + ")";
    }
}

function dump_ioapic(cpu)
{
    try
    {
        const io = new Int32Array(cpu.wasm_memory.buffer, cpu.get_ioapic_addr(), 52);
        const redtbl = [];
        for(let i = 0; i < 24; i++)
        {
            if((io[i] >>> 0) & 0x10000)
            {
                continue;
            }
            redtbl.push("irq" + i + "=" + hex64(io[i] >>> 0));
        }
        return "irr=" + hex64(io[50] >>> 0) +
            " irq_value=" + hex64(io[51] >>> 0) +
            " unmasked=[" + redtbl.join(" ") + "]";
    }
    catch(e)
    {
        return "(ioapic " + e + ")";
    }
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
    const rnames = ["r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"];
    for(let i = 0; i < 8; i++)
    {
        const full = BigInt(cpu.reg_r8[i * 2] >>> 0) + (BigInt(cpu.reg_r8[i * 2 + 1] >>> 0) << 32n);
        parts.push(rnames[i] + "=" + hex64(full));
    }
    parts.push("cs=" + hex64(cpu.sreg[1]));
    parts.push("ss=" + hex64(cpu.sreg[2]));
    parts.push("is_64=" + (cpu.is_64[0] | 0));
    parts.push("in_hlt=" + (cpu.in_hlt[0] | 0));
    parts.push("if=" + ((cpu.flags[0] >>> 9) & 1));
    parts.push("flags=" + hex64(cpu.flags[0] >>> 0));
    parts.push("efer=" + hex64(u64_from_pair(cpu.efer)));
    parts.push("cr0=" + hex64(cpu.cr[0] >>> 0));
    parts.push("cr2=" + hex64(u64_from_pair(cpu.cr2_64)));
    parts.push("cr3=" + hex64(cpu.cr[3] >>> 0));
    parts.push("cr4=" + hex64(cpu.cr[4] >>> 0));
    parts.push("gs_base=" + hex64(u64_from_pair(cpu.msr_gs_base)));
    parts.push("rip=" + hex64(u64_from_pair(cpu.rip64)));
    parts.push("insns=" + (cpu.instruction_counter[0] >>> 0));
    parts.push("apic_en=" + (cpu.apic_enabled[0] | 0));
    return parts.join(" ");
}

function dump_stuck(cpu)
{
    const rip = u64_from_pair(cpu.rip64);
    const cr2 = u64_from_pair(cpu.cr2_64);
    const rax = BigInt(cpu.reg32[0] >>> 0) + (BigInt(cpu.reg_high32[0] >>> 0) << 32n);
    const rdi = BigInt(cpu.reg32[7] >>> 0) + (BigInt(cpu.reg_high32[7] >>> 0) << 32n);
    const walks = [
        ["rip", rip],
        ["cr2", cr2],
        ["rax", rax],
        ["rdi", rdi],
        ["fa80:2000", 0xFFFFFA8000002000n],
        ["fa80:0c20", 0xFFFFFA8000000C20n],
        ["selfmap-pte", pte_selfmap_va(0xFFFFFA8000002000n)],
        ["ntoskrnl", 0xFFFFF80001000000n],
        ["gdt", 0xFFFFF80000300000n],
        ["pcr-stack", 0xFFFFF80000308000n],
    ].map(([name, va]) => name + " " + walk_virt(cpu, va)).join("\n");
    return dump_regs(cpu) +
        "\nrip_bytes=" + dump_at(cpu, rip) +
        "\n" + dump_gdt_cs(cpu) +
        "\n" + dump_tss(cpu) +
        "\n" + dump_idt_vec(cpu, 14) +
        "\n" + dump_idt_vec(cpu, 0xD1) +
        "\n" + dump_pml4(cpu) +
        "\n" + walks +
        "\napic=" + dump_apic(cpu) +
        "\nioapic=" + dump_ioapic(cpu) +
        "\npic=" + dump_pic(cpu) +
        "\n" + scan_irq_frames(cpu) +
        "\npf_count=" + pf_count +
        "\nstack_ptes:\n" + dump_stack_ptes(cpu) +
        "\nvga=" + dump_vga(cpu) +
        "\ngdt_mem=" + dump_stack_words(cpu, 0xFFFFF80000300000n, 8) +
        "\nrsp_mem=" + dump_stack_words(cpu, BigInt(cpu.reg32[4] >>> 0) + (BigInt(cpu.reg_high32[4] >>> 0) << 32n), 8);
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
    try
    {
        console.error("xp64 dump:\n" + dump_stuck(emulator.v86.cpu));
    }
    catch(e)
    {
        console.error("xp64 dump failed: " + e);
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
        save_boot_screenshot();
    }
    catch(e)
    {
        console.error("xp64 screenshot failed: " + e);
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
        if(cpu0.is_64[0] && !logged_rsp_drop)
        {
            const rsp = BigInt(cpu0.reg32[4] >>> 0) + (BigInt(cpu0.reg_high32[4] >>> 0) << 32n);
            if(rsp >= 0xFFFFF80000300000n && rsp < 0xFFFFF80000304000n)
            {
                logged_rsp_drop = true;
                console.error("xp64: PCR stack entered GDT pages\n" + dump_stuck(cpu0));
            }
        }
        if(cpu0.is_64[0] && !saw_is_64)
        {
            saw_is_64 = true;
            console.error("xp64: CS.L " + dump_regs(cpu0));
            console.log("xp64: entered long mode");
            try
            {
                save_boot_screenshot("lma");
            }
            catch(_e)
            {}
            hold_timer = setTimeout(() => {
                finish(0, "xp64: pass (long mode held " + HOLD_MS + "ms)");
            }, HOLD_MS);
        }
        const now = Date.now();
        if(now - last_log >= 2000)
        {
            last_log = now;
            const text = screen_text().split("\n").filter(Boolean).slice(-6).join(" | ");
            console.error("xp64: " + dump_regs(cpu0) +
                " pf=" + pf_count + (text ? " screen=[" + text + "]" : ""));
            try
            {
                const info = dump_vga(cpu0);
                const score = (info.match(/printable=([0-9]+)/) || [0, "0"])[1] | 0;
                if(score > last_screenshot_score)
                {
                    last_screenshot_score = score;
                    save_boot_screenshot("live");
                }
            }
            catch(_e)
            {}
        }
        return orig_main_loop();
    };

    emulator.cpu_exception_hook = function(n)
    {
        const cpu = emulator.v86.cpu;
        if(n === 14)
        {
            pf_count++;
            if(n === 14 && !logged_fa80_pf)
            {
                const cr2 = u64_from_pair(cpu.cr2_64);
                if((cr2 >> 32n) === 0xFFFFFA80n)
                {
                    logged_fa80_pf = true;
                    console.error("xp64: first session-pool #PF #" + pf_count +
                        " cr2=" + hex64(cr2) + "\n" + dump_stuck(cpu));
                }
            }
            return false;
        }
        if(n !== 6 && n !== 8)
        {
            return false;
        }
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
