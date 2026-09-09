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
    // Static ET_EXEC, no libc. Write the pass line first so linux64 still
    // succeeds if a later syscall fails. Extra getpid/uname/brk writes are
    // diagnostic only.
    const strings = [
        Buffer.from(message, "ascii"),
        Buffer.from("linux64-init: getpid\n", "ascii"),
        Buffer.from("linux64-init: uname\n", "ascii"),
        Buffer.from("linux64-init: brk\n", "ascii"),
    ];
    const MSG = 0, MSG_GETPID = 1, MSG_UNAME = 2, MSG_BRK = 3;
    const UTS_BUF = 400; // struct utsname is 6 * 65 = 390 bytes

    const chunks = [];
    const leas = [];
    const jumps = [];
    const labels = Object.create(null);
    let size = 0;

    function emit(bytes)
    {
        const buf = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
        chunks.push(buf);
        size += buf.length;
    }

    function mov_imm(reg, imm)
    {
        // REX.W mov r64, imm32 (sign-extended): 48 C7 C0+reg
        const b = Buffer.alloc(7);
        b[0] = 0x48;
        b[1] = 0xC7;
        b[2] = 0xC0 | (reg & 7);
        b.writeUInt32LE(imm >>> 0, 3);
        emit(b);
    }

    function lea_rsi(str_index)
    {
        leas.push({ off: size, str_index: str_index });
        emit([0x48, 0x8D, 0x35, 0x00, 0x00, 0x00, 0x00]);
    }

    function syscall()
    {
        emit([0x0F, 0x05]);
    }

    function write_str(str_index)
    {
        mov_imm(0, 1); // mov rax, 1 (write)
        mov_imm(7, 1); // mov rdi, 1 (stdout)
        lea_rsi(str_index);
        mov_imm(2, strings[str_index].length); // mov rdx, len
        syscall();
    }

    function jcc8(opcode, name)
    {
        jumps.push({ off: size, name: name });
        emit([opcode, 0x00]);
    }

    // 1. write(1, LINUX64_INIT_LINE + "\n") — existing pass bar, must be first.
    write_str(MSG);

    // 2. getpid (rax=39); success if pid > 0 (usually 1).
    mov_imm(0, 39);
    syscall();
    emit([0x48, 0x85, 0xC0]); // test rax, rax
    jcc8(0x7E, "skip_getpid"); // jle
    write_str(MSG_GETPID);
    labels.skip_getpid = size;

    // 3. uname (rax=63) into a stack buffer; sysname must start with "Linux".
    emit([0x48, 0x81, 0xEC,
        UTS_BUF & 0xFF, UTS_BUF >> 8 & 0xFF, 0x00, 0x00]); // sub rsp, UTS_BUF
    mov_imm(0, 63);
    emit([0x48, 0x89, 0xE7]); // mov rdi, rsp
    syscall();
    emit([0x48, 0x85, 0xC0]); // test rax, rax
    jcc8(0x75, "skip_uname"); // jnz
    emit([0x81, 0x3C, 0x24, 0x4C, 0x69, 0x6E, 0x75]); // cmp dword [rsp], "Linu"
    jcc8(0x75, "skip_uname"); // jne
    emit([0x80, 0x7C, 0x24, 0x04, 0x78]); // cmp byte [rsp+4], 'x'
    jcc8(0x75, "skip_uname"); // jne
    write_str(MSG_UNAME);
    labels.skip_uname = size;
    emit([0x48, 0x81, 0xC4,
        UTS_BUF & 0xFF, UTS_BUF >> 8 & 0xFF, 0x00, 0x00]); // add rsp, UTS_BUF

    // 4. brk(NULL) (rax=12); success if the returned break is not -4095..-1.
    mov_imm(0, 12);
    emit([0x48, 0x31, 0xFF]); // xor rdi, rdi
    syscall();
    emit([0x48, 0x3D, 0x01, 0xF0, 0xFF, 0xFF]); // cmp rax, -4095
    jcc8(0x73, "skip_brk"); // jae (unsigned IS_ERR)
    write_str(MSG_BRK);
    labels.skip_brk = size;

    // 5. exit(0)
    mov_imm(0, 60);
    emit([0x48, 0x31, 0xFF]); // xor rdi, rdi
    syscall();

    const body = Buffer.concat(chunks);
    if(body.length !== size)
    {
        throw new Error("init elf: size mismatch");
    }
    for(const j of jumps)
    {
        const target = labels[j.name];
        if(target === undefined)
        {
            throw new Error("init elf: missing label " + j.name);
        }
        const rel = target - (j.off + 2);
        if(rel < -128 || rel > 127)
        {
            throw new Error("init elf: jcc to " + j.name + " out of range (" + rel + ")");
        }
        body.writeInt8(rel, j.off + 1);
    }
    const str_off = [];
    let off = body.length;
    for(const s of strings)
    {
        str_off.push(off);
        off += s.length;
    }
    for(const lea of leas)
    {
        const disp = str_off[lea.str_index] - (lea.off + 7);
        body.writeInt32LE(disp, lea.off + 3);
    }
    const code = Buffer.concat([body, ...strings]);

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
