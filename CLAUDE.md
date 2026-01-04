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
./zig-out/bin/pdfzig info document.pdf
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

### Core Modules

- **src/main.zig** - CLI entry point with subcommand parsing (render, extract_text, extract_images, extract_attachments, visual_diff, info, rotate, delete, add, attach, detach, download_pdfium). Each command has its own argument struct and run function. Global option `-link <path>` loads PDFium from a specific path (version parsed from filename pattern `libpdfium_v{VERSION}.ext`).

- **src/pdfium.zig** - Idiomatic Zig bindings for PDFium. Key types:
  - `Document` - PDF document handle with metadata, attachment access, page deletion, and save functionality
  - `Page` - Page handle with rendering, rotation, and object iteration
  - `TextPage` - Text extraction with UTF-16LE to UTF-8 conversion
  - `Bitmap` - BGRA bitmap for rendering
  - `ImageObject` / `ImageObjectIterator` - Embedded image extraction
  - `Attachment` / `AttachmentIterator` - Embedded file attachment access

- **src/pdfium_loader.zig** - Runtime dynamic library loading infrastructure:
  - `PdfiumLib` struct with function pointers for all PDFium APIs
  - Version detection from filename pattern `libpdfium_v{BUILD}.{ext}`
  - `findBestPdfiumLibrary()` - finds highest version in executable directory

- **src/downloader.zig** - PDFium download and extraction:
  - Native Zig HTTP via `std.http.Client`
  - Native gzip decompression via `std.compress.flate.Decompress`
  - Native tar extraction via `std.tar.pipeToFileSystem`
  - SHA256 hash verification from GitHub API

- **src/renderer.zig** - Rendering coordination with page range parsing ("1-5,8,10-12" syntax)

- **src/image_writer.zig** - Image output using zigimg (PNG) and zstbi (JPEG). Handles BGRA→RGBA/RGB conversion. Supports filename templates with `{num}`, `{num0}`, `{basename}`, `{ext}` variables.

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

- **src/info_test.zig** - Integration tests using real PDFs from [py-pdf/sample-files](https://github.com/py-pdf/sample-files)
- **src/attachments_test.zig** - Tests using ZUGFeRD invoice PDFs from [ZUGFeRD/corpus](https://github.com/ZUGFeRD/corpus)
- Tests auto-download PDFs to `test-cache/` directory (gitignored) on first run
- All HTTP downloads use native Zig (no curl dependency)

## Key Implementation Details

- PDFium outputs BGRA; conversion to RGBA (PNG) or RGB (JPEG) happens in image_writer.zig
- PDFium uses UTF-16LE for text; conversion to UTF-8 is in pdfium.zig
- Page numbers in CLI are 1-based; PDFium API uses 0-based internally
- Multi-resolution output uses `-O DPI:FORMAT:QUALITY:TEMPLATE` syntax (can be repeated)
- Zig 0.15 uses `.c` calling convention (not `.C`)
- Uses `std.Io.Writer` and `std.Io.Reader` (new Zig 0.15 I/O interfaces)
- Uses `std.array_list.Managed(T).init(allocator)` (not `std.ArrayList(T).init(allocator)` which was deprecated in Zig 0.15)

## Change Rules

- When a command is changed or added, update README.md and CLAUDE.md
