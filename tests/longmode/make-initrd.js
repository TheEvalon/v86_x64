#!/usr/bin/env node
// Build a gzipped newc initramfs with a static x86_64 /init (no libc).
// Generated at test time so CI does not need extra packages or a committed blob.

import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import zlib from "node:zlib";

export const LINUX64_INIT_LINE = "linux64-init: userspace";

const S_IFDIR = 0o040000;
const S_IFCHR = 0o020000;
const S_IFREG = 0o100000;

function hex8(n)
{
    return (n >>> 0).toString(16).padStart(8, "0");
}

function pad4(length)
{
    return (4 - (length & 3)) & 3;
}

function newc_entry(name, data, mode, extras)
{
    const name_buf = Buffer.from(name + "\0", "ascii");
    const filesize = data.length;
    const nlink = extras && extras.nlink !== undefined ? extras.nlink : 1;
    const rdevmajor = extras && extras.rdevmajor || 0;
    const rdevminor = extras && extras.rdevminor || 0;
    const ino = extras && extras.ino || 1;
    const header =
        "070701" +
        hex8(ino) +
        hex8(mode) +
        hex8(0) +
        hex8(0) +
        hex8(nlink) +
        hex8(0) +
        hex8(filesize) +
        hex8(0) +
        hex8(0) +
        hex8(rdevmajor) +
        hex8(rdevminor) +
        hex8(name_buf.length) +
        hex8(0);
    if(header.length !== 110)
    {
        throw new Error("newc header length " + header.length);
    }
    const name_pad = Buffer.alloc(pad4(110 + name_buf.length));
    const data_pad = Buffer.alloc(pad4(filesize));
    return Buffer.concat([Buffer.from(header, "ascii"), name_buf, name_pad, data, data_pad]);
}

function make_static_init_elf(message)
{
    const msg = Buffer.from(message, "ascii");
    const chunks = [];
    chunks.push(Buffer.from([0x48, 0xC7, 0xC0, 0x01, 0x00, 0x00, 0x00])); // mov rax, 1 (write)
    chunks.push(Buffer.from([0x48, 0xC7, 0xC7, 0x01, 0x00, 0x00, 0x00])); // mov rdi, 1 (stdout)
    const lea_at = Buffer.concat(chunks).length;
    chunks.push(Buffer.from([0x48, 0x8D, 0x35, 0x00, 0x00, 0x00, 0x00])); // lea rsi, [rip+disp]
    const rdx = Buffer.alloc(7);
    rdx[0] = 0x48; rdx[1] = 0xC7; rdx[2] = 0xC2;
    rdx.writeUInt32LE(msg.length, 3);
    chunks.push(rdx); // mov rdx, len
    chunks.push(Buffer.from([0x0F, 0x05])); // syscall
    chunks.push(Buffer.from([0x48, 0xC7, 0xC0, 0x3C, 0x00, 0x00, 0x00])); // mov rax, 60 (exit)
    chunks.push(Buffer.from([0x48, 0x31, 0xFF])); // xor rdi, rdi
    chunks.push(Buffer.from([0x0F, 0x05])); // syscall
    const body = Buffer.concat(chunks);
    const disp = body.length - (lea_at + 7);
    body.writeInt32LE(disp, lea_at + 3);
    const code = Buffer.concat([body, msg]);

    const ehsize = 64;
    const phsize = 56;
    const headers = ehsize + phsize;
    const file_size = headers + code.length;
    const load_addr = 0x400000;
    const entry = load_addr + headers;
    const elf = Buffer.alloc(file_size);

    elf[0] = 0x7F; elf[1] = 0x45; elf[2] = 0x4C; elf[3] = 0x46;
    elf[4] = 2;
    elf[5] = 1;
    elf[6] = 1;
    elf.writeUInt16LE(2, 16);     // ET_EXEC
    elf.writeUInt16LE(0x3E, 18);  // EM_X86_64
    elf.writeUInt32LE(1, 20);
    elf.writeBigUInt64LE(BigInt(entry), 24);
    elf.writeBigUInt64LE(64n, 32);
    elf.writeUInt16LE(64, 52);
    elf.writeUInt16LE(56, 54);
    elf.writeUInt16LE(1, 56);

    const p = 64;
    elf.writeUInt32LE(1, p);              // PT_LOAD
    elf.writeUInt32LE(5, p + 4);          // PF_R | PF_X
    elf.writeBigUInt64LE(BigInt(load_addr), p + 16);
    elf.writeBigUInt64LE(BigInt(load_addr), p + 24);
    elf.writeBigUInt64LE(BigInt(file_size), p + 32);
    elf.writeBigUInt64LE(BigInt(file_size), p + 40);
    elf.writeBigUInt64LE(0x1000n, p + 48);

    code.copy(elf, headers);
    return elf;
}

export function make_linux64_initrd()
{
    const elf = make_static_init_elf(LINUX64_INIT_LINE + "\n");
    const empty = Buffer.alloc(0);
    const cpio = Buffer.concat([
        newc_entry("dev", empty, S_IFDIR | 0o755, { nlink: 2, ino: 1 }),
        newc_entry("dev/console", empty, S_IFCHR | 0o600, {
            ino: 2, rdevmajor: 5, rdevminor: 1,
        }),
        newc_entry("init", elf, S_IFREG | 0o755, { ino: 3 }),
        newc_entry("TRAILER!!!", empty, 0, { ino: 0, nlink: 1 }),
    ]);
    const gz = zlib.gzipSync(cpio, { level: 9 });
    if(gz[0] !== 0x1F || gz[1] !== 0x8B)
    {
        throw new Error("linux64 initrd: gzip magic missing");
    }
    return gz;
}

export function write_linux64_initrd(out_path)
{
    const buf = make_linux64_initrd();
    fs.mkdirSync(path.dirname(out_path), { recursive: true });
    fs.writeFileSync(out_path, buf);
    return buf;
}

const this_file = url.fileURLToPath(import.meta.url);
if(process.argv[1] && path.resolve(process.argv[1]) === this_file)
{
    const out = process.argv[2] || "linux64-initrd.cpio.gz";
    write_linux64_initrd(out);
    console.log("wrote " + out + " (" + fs.statSync(out).size + " bytes)");
}
