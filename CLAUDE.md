# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

pdfzig is a Zig CLI tool that uses PDFium to work with PDF files. It supports rendering pages to PNG/JPEG images, extracting text, extracting embedded images, and displaying PDF metadata.

## Build Commands

```bash
zig build              # Build (auto-downloads PDFium binaries on first run)
zig build run -- <args>  # Build and run with arguments
zig build test         # Run unit tests
```

Run the built executable directly:
```bash
./zig-out/bin/pdfzig render document.pdf
./zig-out/bin/pdfzig extract-text document.pdf
./zig-out/bin/pdfzig extract-images document.pdf ./output
./zig-out/bin/pdfzig info document.pdf
```

## Architecture

### Core Modules

- **src/main.zig** - CLI entry point with subcommand parsing (render, extract-text, extract-images, info). Each command has its own argument struct and run function.

- **src/pdfium.zig** - Idiomatic Zig bindings for PDFium C API. Key types:
  - `Document` - PDF document handle with metadata extraction
  - `Page` - Page handle with rendering and object iteration
  - `TextPage` - Text extraction with UTF-16LE to UTF-8 conversion
  - `Bitmap` - BGRA bitmap for rendering
  - `ImageObject` / `ImageObjectIterator` - Embedded image extraction

- **src/renderer.zig** - Rendering coordination with page range parsing ("1-5,8,10-12" syntax)

- **src/image_writer.zig** - Image output using zigimg (PNG) and zstbi (JPEG). Handles BGRA→RGBA/RGB conversion. Supports filename templates with `{num}`, `{num0}`, `{basename}`, `{ext}` variables.

### Dependencies

- **PDFium** - Auto-downloaded per platform during build from bblanchon/pdfium-binaries. Dynamically linked and installed alongside executable.
- **zigimg** - PNG encoding
- **zstbi** - JPEG encoding (stb_image_write bindings)

### Build System Notes

- PDFium is downloaded to `.zig-cache/pdfium/` on first build
- On macOS, `install_name_tool` fixes the dylib for rpath loading
- The PDFium library is installed to `zig-out/bin/` alongside the executable
- Requires Zig 0.15.0+

## Testing

- **src/info_test.zig** - Integration tests using real PDFs from [py-pdf/sample-files](https://github.com/py-pdf/sample-files)
- Tests auto-download PDFs to `test-cache/` directory (gitignored) on first run
- Covers: page count, encryption detection, metadata retrieval, image object detection

## Key Implementation Details

- PDFium outputs BGRA; conversion to RGBA (PNG) or RGB (JPEG) happens in image_writer.zig
- PDFium uses UTF-16LE for text; conversion to UTF-8 is in pdfium.zig
- Page numbers in CLI are 1-based; PDFium API uses 0-based internally
- Multi-resolution output uses `-O DPI:FORMAT:QUALITY:TEMPLATE` syntax (can be repeated)
