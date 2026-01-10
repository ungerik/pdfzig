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
- **src/pdf/** - Library-independent PDF metadata module (MetaData struct, XMP parsing, PDF/A detection)
- **src/pdfium/** - PDFium bindings and library management (memory-based loading)
- **src/pdfcontent/** - PDF content generation (images, text formatting)

### Core Modules

- **src/main.zig** - CLI entry point with subcommand parsing (render, extract_text, extract_images, extract_attachments, visual_diff, info, rotate, mirror, delete, add, create, attach, detach, download_pdfium). Global option `--link <path>` loads PDFium from a specific path.

- **src/pdf/metadata.zig** - Library-independent metadata extraction combining PDFium and XMP parsing:
  - `MetaData` - Generic metadata struct with standard PDF metadata and PDF/A conformance
  - `parseInfo()` - Main API that loads entire PDF into memory, extracts metadata from PDFium and XMP, returns combined result
  - `parsePdfA()` - Extract only PDF/A conformance from PDF byte stream
  - `PdfAConformance` - PDF/A conformance level (part 1-4, level a/b/u/e/f) with custom formatter

- **src/pdf/loader.zig** - PDF file loading utilities:
  - `loadPdfFile()` - Load entire PDF file into memory buffer

- **src/pdf/xmp.zig** - XMP metadata parser for PDF/A conformance detection:
  - `extractPdfAConformance()` - Parse PDF byte stream to find XMP packet and extract PDF/A conformance
  - Supports both element syntax (`<pdfaid:part>1</pdfaid:part>`) and attribute syntax (`pdfaid:part="1"`)
  - No XML library dependency - uses simple string matching (PDF/A spec requires XMP to be uncompressed/unencrypted)

- **src/pdfium/pdfium.zig** - Idiomatic Zig bindings for PDFium. Key types:
  - `Document` - PDF document handle with metadata, attachment access, page deletion, and save functionality. Owns the PDF buffer for the document's lifetime (loaded via `FPDF_LoadMemDocument`). The buffer is freed in `close()`.
  - `Page` - Page handle with rendering, rotation, and object iteration
  - `TextPage` - Text extraction with UTF-16LE to UTF-8 conversion
  - `Bitmap` - BGRA bitmap for rendering
  - `ImageObject` / `ImageObjectIterator` - Embedded image extraction
  - `Attachment` / `AttachmentIterator` - Embedded file attachment access
  - `ExtendedMetadata` - PDFium metadata with document properties (page count, PDF version, encryption)
  - `extractMetadataFromMemory()` - Extract metadata from PDF in memory buffer

- **src/pdfium/loader.zig** - Runtime dynamic library loading infrastructure:
  - `PdfiumLib` struct with function pointers for all PDFium APIs
  - Uses `FPDF_LoadMemDocument` exclusively - all PDFs loaded into memory first
  - Version detection from filename pattern `libpdfium_v{BUILD}.{ext}`
  - `findBestPdfiumLibrary()` - finds highest version in executable directory

- **src/pdfium/downloader.zig** - PDFium download and extraction:
  - Native Zig HTTP via `std.http.Client`
  - Native gzip decompression via `std.compress.flate.Decompress`
  - Native tar extraction via `std.tar.pipeToFileSystem`
  - SHA256 hash verification from GitHub API

- **src/pdfcontent/images.zig** - Image I/O using zigimg (PNG) and zstbi (JPEG). Handles BGRA→RGBA/RGB conversion. Supports filename templates with `{num}`, `{num0}`, `{basename}`, `{ext}` variables. Also provides `addImageToPage()` for adding images to PDF pages.

- **src/pdfcontent/textfmt.zig** - Text formatting and PDF text content generation. Provides `addTextToPage()` and `addJsonToPage()` for adding text content to PDF pages.

- **src/cmd/shared.zig** - Shared utilities for command implementations to reduce code duplication:
  - `exitWithError()` / `exitWithErrorMsg()` - Print error and exit with code 1
  - `requireInputPath()` - Validate input path or exit with error
  - `openDocumentOrExit()` - Open PDF with optional password, exit on error
  - `loadPageOrExit()` - Load page from document, exit on error
  - `parsePageRangesOrExit()` / `parsePageListOrExit()` - Parse page ranges with error handling
  - `createOutputDirectory()` - Create output directory or exit on error
  - `reportSaveSuccess()` - Report save success if output differs from input
  - `setupTempFileForInPlaceEdit()` / `completeTempFileEdit()` - Handle temp file creation and rename for in-place editing
  - `generatePageContentOrExit()` / `generatePageContentWithNumOrExit()` - Generate page content or exit on error

### WebUI

- **src/webui/** - Web interface for visual PDF editing and manipulation
  - **src/webui/assets/** - Static web assets (HTML, CSS, JS, favicons, icons)
    - `index.html` - Main HTML template with `{READONLY}` placeholder
    - `style.css` - CSS styling
    - `app.js` - JavaScript frontend code
    - `favicon.ico` and various PNG icons (16x16, 32x32, 48x48, apple-touch-icon, android-chrome)
    - `site.webmanifest` - PWA manifest
  - **src/webui/assets.zig** - Asset embedding using `@embedFile` directive
    - All assets are compiled directly into the executable binary
    - No external files needed at runtime
  - **src/webui/routes.zig** - HTTP request routing and static asset serving
    - Serves embedded assets with appropriate content types
    - Handles API routes for document manipulation
    - Template replacement for readonly mode flag
  - **src/webui/server.zig** - HTTP server implementation
  - **src/webui/state.zig** - Global state management for documents and pages
  - **src/webui/operations.zig** - PDF operations (rotate, mirror, delete, reorder)
  - **src/webui/page_renderer.zig** - Page thumbnail rendering with caching
  - **src/webui/error_page.zig** - Error page rendering

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

- **Memory-first loading**: All PDF operations load the entire file into memory first using `FPDF_LoadMemDocument`. This enables buffer reuse between PDFium and XMP parsing, and provides a foundation for future optimizations. `FPDF_LoadDocument` has been removed.
- **Document memory management**: The `Document` struct owns the PDF buffer for the document's lifetime. PDFium's `FPDF_LoadMemDocument` references the buffer without copying, so the buffer must remain valid until `FPDF_CloseDocument` is called. The `Document.close()` method frees both the PDFium handle and the owned buffer.
- **WebUI memory optimization**: WebUI keeps two copies of each PDF (`doc_original` with original bytes, `doc` for modifications). When downloading an unmodified document, the original bytes are served directly from `doc_original.pdf_buffer` without creating a new PDF, preserving the exact original file including signatures.
- **PDF/A detection**: Automatically detects PDF/A conformance by parsing XMP metadata directly from the PDF byte stream. Uses simple string matching (no XML library) since PDF/A requires XMP to be uncompressed and unencrypted.
- **Library-independent metadata**: The `src/pdf/` module provides a generic `MetaData` struct that combines PDFium metadata with XMP-derived PDF/A conformance, abstracting implementation details.
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
- Return all errors

## Markdown Rules

- Always pad markdown tables in README.md to align vertical lines

## Documentation Rules

- When a command is changed or added, update README.md and CLAUDE.md

## HTTP routes

- Encode simple request parameters in the URL path and avoid JSON body payloads
- Use JSON for complex requests or responses

## Version Control

- Don't create git commits automatically. Ask the user to create a commit.