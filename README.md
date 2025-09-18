# Ingot

Ingot is a lean, high-performance archiving tool written in Zig.

It forges directories and files into a single tar or zip archive at lightning speed, with deterministic output and minimal memory use.

---

## Features

- Create and extract `.tar` and `.zip` (including Zip64) archives
- Optional Deflate compression or stored (no-compress) mode
- Deterministic mode strips timestamps and metadata for reproducible builds
- Streaming I/O with zero-copy buffers for minimal allocations
- Low memory footprint even with large file trees
- Cross-platform support: Linux, macOS, and Windows

---

## Installation

1. Download zig version 0.15.1
2. Clone the repository and build

   ```bash
   git clone https://github.com/yourusername/ingot.git
   cd ingot
   zig build -Doptimize=ReleaseSafe
	 ```
