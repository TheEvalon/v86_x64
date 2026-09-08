Use the corresponding `make` target in the root directory to run a test. The
following list is roughtly sorted from most interesting/useful to least.

- [nasm](nasm/): Small unit tests written in assembly, which are run using gdb
  on the host.
- [longmode](longmode/): Enters IA-32e long mode from a multiboot payload and
  checks a 64-bit ADD, stack/RIP-relative ops, a 16-byte IDT,
  SYSCALL/SYSRET/SWAPGS, a canonical higher-half RIP, JIT of 32-bit-opsize
  ops in 64-bit CS, and REX/higher-half data (`make longmode-test`).
  `make linux64-test` boots a tiny x86_64 Linux bzImage until `Linux version`.
- [qemu](qemu/): Based on tests from qemu. Builds a Linux binary, which tests
  many CPU features, which are then compared to a run on qemu.
- [kvm-unit-test](kvm-unit-test/): Based on tests from the KVM project, tests
  various CPU features.
- [full](full/): Starts several OSes and checks if they boot correctly.
- [jit-paging](jit-paging/): Tests jit and paging interaction.
- [api](api/): Tests for several API functions of v86.
- [devices](devices/): Device tests.
- [rust](rust/): Rust unit test helpers.
- [expect](expect/): Expect tests for the jit output. Contains a set of
  asm+wasm files, where the jit is expected to produce the wasm file given the
  asm file.

The following environmental variables are respected by most tests if applicable:

- `TEST_RELEASE_BUILD=1`: Test the release build (libv86.js, v86.wasm) instead of the
  debug build (source files with v86-debug.wasm)
- `MAX_PARALLEL_TESTS=n`: Maximum number of tests to run in parallel. Defaults
  to the number of cores in your system or less.
- `TEST_NAME="…"`: Run only the specified test (only expect, full, nasm)
