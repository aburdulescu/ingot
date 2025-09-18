# ingot

[!](./ingot.png)

ingot is a lean, high-performance archiving tool written in Zig.

It bundles directories and files into a single tar or zip archive at lightning speed, with deterministic output and minimal memory use.

## Features

- Create and extract `.tar` and `.zip` archives
- Optional Deflate compression or stored (no-compress) mode
- Deterministic mode strips timestamps and metadata for reproducible builds
- Streaming I/O with zero-copy buffers for minimal allocations
- Low memory footprint even with large file trees
- Cross-platform support: Linux, macOS, and Windows
- Can be embedded as a library or CLI in Rust, Go, Python, or Zig projects — no need for shelling out to tar.

## Performance goals

|Task|tar/zip|ingot|
|----|-------|-----|
| Pack 10K small files | 3–6 s | < 1 s |
| Extract 1 GB tar | 4–7 s | < 2 s |
| Memory usage | > 100 MB| < 50 MB|

## Why it’s not just reinventing the wheel

It's not a full replacement for tar or zip. It's a specialized, high-performance subset that:

- Covers 90% of real-world use cases
- Is safer, faster, and easier to embed
- Has predictable behavior and minimal flags
- Can be audited, cross-compiled, and extended

It’s like comparing ripgrep to grep, or fd to find. Same idea — less surface, more speed.
