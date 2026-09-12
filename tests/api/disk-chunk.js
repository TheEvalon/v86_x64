#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { buffer_from_object } from "../../src/buffer.js";

process.on("unhandledRejection", exn => { throw exn; });

const SIZE = 1024 * 1024;
const CHUNK = 256 * 1024;
const tmp = path.join(os.tmpdir(), "v86-disk-chunk-" + process.pid + ".bin");

function fill(buf)
{
    for(let i = 0; i < buf.length; i++)
    {
        buf[i] = i & 0xFF;
    }
}

function get(buf, offset, len)
{
    return new Promise(resolve => buf.get(offset, len, resolve));
}

function expect_sync(buf, offset, len, label)
{
    let result;
    buf.get(offset, len, function(block)
    {
        result = block;
    });
    if(!result)
    {
        throw new Error(label + ": expected cached synchronous read");
    }
    return result;
}

const bytes = Buffer.alloc(SIZE);
fill(bytes);
fs.writeFileSync(tmp, bytes);

try
{
    const coalesced = buffer_from_object({
        url: tmp,
        size: SIZE,
        async: true,
        fixed_chunk_size: CHUNK,
    });

    const first = await get(coalesced, 4096, 4096);
    if(first.length !== 4096)
    {
        throw new Error("first read length " + first.length);
    }
    if(first[0] !== (4096 & 0xFF) || first[4095] !== ((4096 + 4095) & 0xFF))
    {
        throw new Error("first read contents");
    }

    const cached = expect_sync(coalesced, 8192, 256, "same 256KiB chunk");
    if(cached[0] !== (8192 & 0xFF))
    {
        throw new Error("cached contents");
    }

    const miss = await get(coalesced, CHUNK, 256);
    if(miss[0] !== (CHUNK & 0xFF))
    {
        throw new Error("next chunk contents");
    }
    expect_sync(coalesced, CHUNK + 256, 256, "second chunk after miss");

    const exact = buffer_from_object({
        url: tmp,
        size: SIZE,
        async: true,
    });
    await get(exact, 4096, 4096);
    let neighbour_sync = false;
    exact.get(8192, 256, function()
    {
        neighbour_sync = true;
    });
    if(neighbour_sync)
    {
        throw new Error("without fixed_chunk_size, neighbour read must not be cached");
    }
    await get(exact, 8192, 256);

    console.log("ok disk-chunk");
}
finally
{
    fs.unlinkSync(tmp);
}
