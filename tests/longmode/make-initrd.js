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
    // succeeds if a later syscall fails. Extra getpid/gettid/uname/brk/mmap/
    // arch_prctl/clock_gettime/munmap writes are diagnostic only.
    const strings = [
        Buffer.from(message, "ascii"),
        Buffer.from("linux64-init: getpid\n", "ascii"),
        Buffer.from("linux64-init: uname\n", "ascii"),
        Buffer.from("linux64-init: brk\n", "ascii"),
        Buffer.from("linux64-init: mmap\n", "ascii"),
        Buffer.from("linux64-init: archprctl\n", "ascii"),
        Buffer.from("linux64-init: gettid\n", "ascii"),
        Buffer.from("linux64-init: clock\n", "ascii"),
        Buffer.from("linux64-init: munmap\n", "ascii"),
    ];
    const MSG = 0, MSG_GETPID = 1, MSG_UNAME = 2, MSG_BRK = 3, MSG_MMAP = 4, MSG_ARCHPRCTL = 5, MSG_GETTID = 6, MSG_CLOCK = 7, MSG_MUNMAP = 8;
    const UTS_BUF = 400; // struct utsname is 6 * 65 = 390 bytes

    const chunks = [];
    const leas = [];
    const jumps = [];
    const jumps32 = [];
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

    function mov_imm_hi(reg, imm)
    {
        // REX.WB mov r8-r15, imm32 (sign-extended): 49 C7 C0+reg
        // 4th syscall arg is r10, not rcx.
        const b = Buffer.alloc(7);
        b[0] = 0x49;
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

    function jmp32(name)
    {
        jumps32.push({ off: size, name: name });
        emit([0xE9, 0x00, 0x00, 0x00, 0x00]);
    }

    function is_err_jae32(skip)
    {
        // cmp rax, -4095; jb ok; jmp skip. Keeps the success path in jcc8 range.
        emit([0x48, 0x3D, 0x01, 0xF0, 0xFF, 0xFF]);
        const ok = skip + "_ok_" + size;
        jcc8(0x72, ok); // jb (unsigned below => not IS_ERR)
        jmp32(skip);
        labels[ok] = size;
    }

    // 1. write(1, LINUX64_INIT_LINE + "\n") — existing pass bar, must be first.
    write_str(MSG);

    // 2. getpid (rax=39) then gettid (rax=186). Single-threaded /init must
    //    have tid == pid and pid > 0. Save pid in r12 across gettid.
    mov_imm(0, 39);
    syscall();
    emit([0x48, 0x85, 0xC0]); // test rax, rax
    jcc8(0x7E, "skip_getpid"); // jle
    emit([0x49, 0x89, 0xC4]); // mov r12, rax
    write_str(MSG_GETPID);
    mov_imm(0, 186);
    syscall();
    emit([0x4C, 0x39, 0xE0]); // cmp rax, r12
    jcc8(0x75, "skip_getpid"); // jne
    write_str(MSG_GETTID);
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

    // 5. mmap(NULL, 4096, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)
    //    (rax=9). Success if the mapping is not -4095..-1 and a store round-trips.
    mov_imm(0, 9);          // mov rax, 9 (mmap)
    mov_imm(7, 0);          // mov rdi, 0 (addr)
    mov_imm(6, 4096);       // mov rsi, 4096 (length)
    mov_imm(2, 3);          // mov rdx, PROT_READ|PROT_WRITE
    mov_imm_hi(2, 0x22);    // mov r10, MAP_PRIVATE|MAP_ANONYMOUS
    mov_imm_hi(0, -1);      // mov r8, -1 (fd)
    mov_imm_hi(1, 0);       // mov r9, 0 (offset)
    syscall();
    is_err_jae32("skip_mmap");
    emit([0xC6, 0x00, 0xA5]); // mov byte [rax], 0xA5
    emit([0x80, 0x38, 0xA5]); // cmp byte [rax], 0xA5
    jcc8(0x74, "mmap_store_ok"); // je
    jmp32("skip_mmap");
    labels.mmap_store_ok = size;
    emit([0x48, 0x89, 0xC3]); // mov rbx, rax
    write_str(MSG_MMAP);

    // 6. arch_prctl(ARCH_SET_FS, map) then load [fs:0]; ARCH_GET_FS round-trip.
    //    (rax=158). Uses the mmap page so a kernel WRMSR of IA32_FS_BASE is
    //    visible as a 64-bit FS-prefix load. Diagnostic only.
    mov_imm(0, 158);        // mov rax, 158 (arch_prctl)
    mov_imm(7, 0x1002);     // mov rdi, ARCH_SET_FS
    emit([0x48, 0x89, 0xDE]); // mov rsi, rbx
    syscall();
    is_err_jae32("skip_archprctl");
    emit([0x31, 0xC0]);     // xor eax, eax
    emit([0x64, 0x8A, 0x00]); // mov al, [fs:rax]
    emit([0x3C, 0xA5]);     // cmp al, 0xA5
    jcc8(0x74, "fsload_ok"); // je
    jmp32("skip_archprctl");
    labels.fsload_ok = size;
    mov_imm(0, 158);
    mov_imm(7, 0x1003);     // mov rdi, ARCH_GET_FS
    emit([0x48, 0x8D, 0x73, 0x08]); // lea rsi, [rbx+8]
    syscall();
    is_err_jae32("skip_archprctl");
    emit([0x48, 0x3B, 0x5B, 0x08]); // cmp rbx, [rbx+8]
    jcc8(0x74, "getfs_ok"); // je
    jmp32("skip_archprctl");
    labels.getfs_ok = size;
    write_str(MSG_ARCHPRCTL);
    labels.skip_archprctl = size;

    // 7. clock_gettime(CLOCK_MONOTONIC, map+16) (rax=228). tv_sec >= 0 and
    //    tv_nsec in [0, 999999999]. Uses the mmap page; skipped if mmap failed.
    mov_imm(0, 228);
    mov_imm(7, 1); // CLOCK_MONOTONIC
    emit([0x48, 0x8D, 0x73, 0x10]); // lea rsi, [rbx+16]
    syscall();
    is_err_jae32("skip_clock");
    emit([0x48, 0x8B, 0x43, 0x18]); // mov rax, [rbx+24] (tv_nsec)
    emit([0x48, 0x3D, 0xFF, 0xC9, 0x9A, 0x3B]); // cmp rax, 999999999
    jcc8(0x77, "skip_clock"); // ja
    emit([0x48, 0x83, 0x7B, 0x10, 0x00]); // cmp qword [rbx+16], 0 (tv_sec)
    jcc8(0x7C, "skip_clock"); // jl
    write_str(MSG_CLOCK);
    labels.skip_clock = size;

    // 8. munmap(map, 4096) (rax=11). rbx still holds the mmap address.
    mov_imm(0, 11);
    emit([0x48, 0x89, 0xDF]); // mov rdi, rbx
    mov_imm(6, 4096);         // mov rsi, 4096
    syscall();
    is_err_jae32("skip_munmap");
    write_str(MSG_MUNMAP);
    labels.skip_munmap = size;
    labels.skip_mmap = size;

    // 9. exit(0)
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
    for(const j of jumps32)
    {
        const target = labels[j.name];
        if(target === undefined)
        {
            throw new Error("init elf: missing label " + j.name);
        }
        const rel = target - (j.off + 5);
        body.writeInt32LE(rel, j.off + 1);
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
