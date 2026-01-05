# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

pdfzig is a Zig CLI tool that uses PDFium to work with PDF files. It supports rendering pages to PNG/JPEG images, extracting text, extracting embedded images, extracting attachments, visual diff comparison, and displaying PDF metadata.

## Build Commands

```bash
zig build              # Build the executable
zig build run -- <args>  # Build and run with arguments
zig build test         # Run unit tests
zig build clean        # Remove build artifacts and caches (zig-out/, .zig-cache/, test-cache/)
zig build fmt          # Check source code formatting
zig build fmt-fix      # Fix source code formatting
zig build all          # Build for all supported platforms (cross-compile)
zig build all -Ddownload-pdfium # Build for all platforms and download matching PDFium libs
```

Cross-compilation targets for `zig build all`:
- macOS: x86_64, aarch64
- Linux: x86_64, aarch64, arm (gnueabihf)
- Windows: x86_64, x86, aarch64

Outputs are placed in `zig-out/<target-triple>/` (e.g., `zig-out/x86_64-linux-gnu/pdfzig`).

Run the built executable directly:
```bash
./zig-out/bin/pdfzig download_pdfium        # Download PDFium library (auto-runs on first use)
./zig-out/bin/pdfzig render document.pdf
./zig-out/bin/pdfzig extract_text document.pdf
./zig-out/bin/pdfzig extract_images document.pdf ./output
./zig-out/bin/pdfzig extract_attachments document.pdf
./zig-out/bin/pdfzig visual_diff doc1.pdf doc2.pdf
./zig-out/bin/pdfzig visual_diff -o ./diffs --colors rgb doc1.pdf doc2.pdf
./zig-out/bin/pdfzig visual_diff -o ./diffs --invert doc1.pdf doc2.pdf
./zig-out/bin/pdfzig info document.pdf
./zig-out/bin/pdfzig info --json document.pdf       # JSON output with per-page dimensions
./zig-out/bin/pdfzig rotate 90 document.pdf             # Rotate all pages 90° clockwise
./zig-out/bin/pdfzig rotate -p 1-3 180 document.pdf     # Rotate pages 1-3 by 180°
./zig-out/bin/pdfzig rotate -o rotated.pdf 270 doc.pdf  # Output to different file
./zig-out/bin/pdfzig delete -p 1 document.pdf           # Delete first page
./zig-out/bin/pdfzig delete -p 2-5 -o trimmed.pdf doc.pdf  # Delete pages 2-5, save to new file
./zig-out/bin/pdfzig add document.pdf                   # Add empty page at end
./zig-out/bin/pdfzig add document.pdf image.png         # Add page with image
./zig-out/bin/pdfzig attach document.pdf file.xml       # Attach file to PDF
./zig-out/bin/pdfzig detach -i 0 document.pdf           # Remove first attachment
./zig-out/bin/pdfzig -link /path/to/libpdfium.dylib info doc.pdf  # Use specific PDFium library
```

## Architecture

### Directory Structure

- **src/main.zig** - CLI entry point with subcommand dispatch
- **src/cli_parsing.zig** - CLI argument parsing utilities and shared types
- **src/cmd/** - Command implementations (one file per command)
- **src/pdfium/** - PDFium bindings and library management
- **src/pdfcontent/** - PDF content generation (images, text formatting)

### Core Modules

- **src/main.zig** - CLI entry point with subcommand parsing (render, extract_text, extract_images, extract_attachments, visual_diff, info, rotate, mirror, delete, add, create, attach, detach, download_pdfium). Global option `--link <path>` loads PDFium from a specific path.

- **src/pdfium/pdfium.zig** - Idiomatic Zig bindings for PDFium. Key types:
  - `Document` - PDF document handle with metadata, attachment access, page deletion, and save functionality
  - `Page` - Page handle with rendering, rotation, and object iteration
  - `TextPage` - Text extraction with UTF-16LE to UTF-8 conversion
  - `Bitmap` - BGRA bitmap for rendering
  - `ImageObject` / `ImageObjectIterator` - Embedded image extraction
  - `Attachment` / `AttachmentIterator` - Embedded file attachment access

- **src/pdfium/loader.zig** - Runtime dynamic library loading infrastructure:
  - `PdfiumLib` struct with function pointers for all PDFium APIs
  - Version detection from filename pattern `libpdfium_v{BUILD}.{ext}`
  - `findBestPdfiumLibrary()` - finds highest version in executable directory

- **src/pdfium/downloader.zig** - PDFium download and extraction:
  - Native Zig HTTP via `std.http.Client`
  - Native gzip decompression via `std.compress.flate.Decompress`
  - Native tar extraction via `std.tar.pipeToFileSystem`
  - SHA256 hash verification from GitHub API

- **src/pdfcontent/images.zig** - Image I/O using zigimg (PNG) and zstbi (JPEG). Handles BGRA→RGBA/RGB conversion. Supports filename templates with `{num}`, `{num0}`, `{basename}`, `{ext}` variables. Also provides `addImageToPage()` for adding images to PDF pages.

- **src/pdfcontent/textfmt.zig** - Text formatting and PDF text content generation. Provides `addTextToPage()` and `addJsonToPage()` for adding text content to PDF pages.

### Dependencies

- **PDFium** - Downloaded at runtime from bblanchon/pdfium-binaries. Dynamically loaded via `std.DynLib`. Library named `libpdfium_v{BUILD}.dylib/so/dll`.
- **zigimg** - PNG encoding
- **zstbi** - JPEG encoding (stb_image_write bindings)

### Runtime Library Loading

- PDFium is NOT linked at build time
- On first use, if no library found, auto-downloads latest from GitHub
- Multiple versions can coexist; highest version is selected
- Library installed to same directory as executable
- Downloads verified via SHA256 hash from GitHub release API

## Testing

- **src/cmd/info_test.zig** - Integration tests using real PDFs from [py-pdf/sample-files](https://github.com/py-pdf/sample-files)
- **src/cmd/extract_attachments_test.zig** - Tests using ZUGFeRD invoice PDFs from [ZUGFeRD/corpus](https://github.com/ZUGFeRD/corpus)
- Tests auto-download PDFs to `test-cache/` directory (gitignored) on first run
- All HTTP downloads use native Zig (no curl dependency)

## Key Implementation Details

- PDFium outputs BGRA; conversion to RGBA (PNG) or RGB (JPEG) happens in pdfcontent/images.zig
- PDFium uses UTF-16LE for text; conversion to UTF-8 is in pdfium/pdfium.zig
- Page numbers in CLI are 1-based; PDFium API uses 0-based internally
- Multi-resolution output uses `-O DPI:FORMAT:QUALITY:TEMPLATE` syntax (can be repeated)
- Zig 0.15 uses `.c` calling convention (not `.C`)
- Uses `std.Io.Writer` and `std.Io.Reader` (new Zig 0.15 I/O interfaces)
- Uses `std.array_list.Managed(T).init(allocator)` (not `std.ArrayList(T).init(allocator)` which was deprecated in Zig 0.15)

## Zig Code Rules

- **ALWAYS** use `std.array_list.Managed(T).init(allocator)` instead of deprecated `std.ArrayList(T).init(allocator)`
- **ALWAYS** use `std.fs.File.stdout()` instead of deprecated `std.io.getStdOut()`

## Markdown Rules

- Always pad markdown tables in README.md to align vertical lines

## Documentation Rules

- When a command is changed or added, update README.md and CLAUDE.md
