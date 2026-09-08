#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import url from "node:url";

const __dirname = url.fileURLToPath(new URL(".", import.meta.url));

process.on("unhandledRejection", exn => { throw exn; });

const ALL_TESTS = ["enter64", "stack64", "idt64", "syscall64", "higher64"];
const requested = process.argv.slice(2);

if(requested.length === 0)
{
    let failed = 0;
    for(const name of ALL_TESTS)
    {
        const result = spawnSync(process.execPath, [process.argv[1], name], {
            stdio: "inherit",
            env: process.env,
        });
        if(result.status !== 0)
        {
            failed = result.status || 1;
        }
    }
    process.exit(failed);
}

const TEST_RELEASE_BUILD = +process.env.TEST_RELEASE_BUILD;
const { V86 } = await import(TEST_RELEASE_BUILD ? "../../build/libv86.mjs" : "../../src/main.js");

const TIMEOUT_MS = 15000;
const name = requested[0];
const IMAGE = path.join(__dirname, name + ".bin");

if(!fs.existsSync(IMAGE))
{
    console.error("long mode " + name + ": missing " + IMAGE);
    process.exit(1);
}

const emulator = new V86({
    autostart: false,
    memory_size: 32 * 1024 * 1024,
    disable_jit: +process.env.DISABLE_JIT,
    log_level: 0,
});

let finished = false;

function finish(code, message) {
    if(finished) {
        return;
    }
    finished = true;
    if(message) {
        console.error(message);
    }
    process.exit(code);
}

emulator.add_listener("emulator-loaded", function() {
    const cpu = emulator.v86.cpu;

    emulator.cpu_exception_hook = function(n) {
        const names = { 0: "DE", 6: "UD", 13: "GP", 14: "PF" };
        finish(1, "long mode " + name + ": unexpected exception #" + n + " (" + (names[n] || "?") + ")");
        return true;
    };

    // load_multiboot registers a 0xF4 write that throws "HALT"; overwrite after.
    cpu.load_multiboot(fs.readFileSync(IMAGE).buffer);

    cpu.io.register_write_consecutive(0xF4, {},
        function(value) {
            if(value === 0) {
                console.log("long mode " + name + ": pass");
                finish(0);
            }
            else {
                finish(1, "long mode " + name + ": guest reported failure (" + value + ")");
            }
        },
        function() {},
        function() {},
        function() {});

    emulator.run();
});

setTimeout(() => {
    finish(1, "long mode " + name + ": timed out");
}, TIMEOUT_MS);
