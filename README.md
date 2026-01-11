# pdfzig

A fast, cross-platform PDF utility tool written in Zig, powered by PDFium.

## Features

- **Render** PDF pages to PNG or JPEG images at any DPI
- **Extract text** content from PDFs
- **Extract images** embedded in PDF pages
- **Extract attachments** embedded in PDFs with glob pattern filtering
- **Visual diff** - compare two PDFs visually, pixel by pixel
- **Display info** including metadata, page count, encryption status, PDF/A conformance, attachments, and PDF version
- **Rotate** pages by 90, 180, or 270 degrees
- **Mirror** pages horizontally or vertically
- **Delete** pages from PDFs
- **Add** new pages with optional image or text content
- **Create** new PDFs from multiple sources (PDFs, images, text files)
- **Attach** files as PDF attachments
- **Detach** (remove) attachments from PDFs
- Support for **password-protected** PDFs
- **Multi-resolution output** - generate multiple image sizes in one pass
- **Runtime PDFium linking** - download or link PDFium libraries dynamically

## Installation

### Requirements

- Zig 0.15.1 or later

### Build

```bash
git clone https://github.com/ungerik/pdfzig.git
cd pdfzig
zig build
```

### Download PDFium

After building, download the PDFium library for your platform:

```bash
# Download latest PDFium build
./zig-out/bin/pdfzig download_pdfium

# Or download a specific Chromium build version
./zig-out/bin/pdfzig download_pdfium 7606
```

PDFium is automatically downloaded on first use if not already present. The library is installed next to the pdfzig executable with the naming pattern `libpdfium_v{BUILD}.dylib` (macOS), `libpdfium_v{BUILD}.so` (Linux), or `pdfium_v{BUILD}.dll` (Windows).

Downloads are verified using SHA256 checksums from the GitHub release API to ensure authenticity and integrity.

The executable will be in `zig-out/bin/`.

## Usage

### Render PDF to Images

```bash
# Render all pages to PNG at 150 DPI (default)
pdfzig render document.pdf

# Render to a specific directory
pdfzig render document.pdf ./output

# Render at 300 DPI
pdfzig render -O 300:png:0:page_{num}.png document.pdf

# Render specific pages
pdfzig render -p 1-5,10 document.pdf

# Multi-resolution: full-size PNG + JPEG thumbnail
pdfzig render -O 300:png:0:{basename}_{num0}.png -O 72:jpeg:85:thumb_{num}.jpg document.pdf
```

Output specification format: `DPI:FORMAT:QUALITY:TEMPLATE`
- **DPI**: Resolution (e.g., 72, 150, 300)
- **FORMAT**: `png` or `jpeg`/`jpg`
- **QUALITY**: JPEG quality 1-100 (ignored for PNG, use 0)
- **TEMPLATE**: Filename with variables `{num}`, `{num0}`, `{basename}`, `{ext}`

### Extract Text

Extract text content from PDF pages in plain text or structured JSON format. By default, pages are separated by a single newline. Add custom separators with template variables and escape sequences using `--page-separator`.

```bash
# Print text to stdout
pdfzig extract_text document.pdf

# Save to file
pdfzig extract_text -o output.txt document.pdf

# Extract from specific pages
pdfzig extract_text -p 1-10 document.pdf

# Extract as JSON with formatting information
pdfzig extract_text --format json document.pdf

# Save JSON to file
pdfzig extract_text -f json -o output.json document.pdf

# Add page separator with page number
pdfzig extract_text --page-separator "--- Page {{PAGE_NO}} ---" document.pdf

# Separator with escape sequences (multiple newlines)
pdfzig extract_text --page-separator '\n\n=== Page {{PAGE_NO}} ===\n\n' document.pdf
```

#### JSON Output Format

When using `--format json`, the output contains structured text blocks with formatting information:

```json
{
  "pages": [
    {
      "page": 1,
      "width": 595.28,
      "height": 841.89,
      "blocks": [
        {
          "text": "Hello World",
          "bbox": {"left": 72.0, "top": 750.0, "right": 150.0, "bottom": 738.0},
          "font": "Helvetica",
          "size": 12.0,
          "weight": 400,
          "italic": false,
          "color": "#000000"
        }
      ]
    }
  ]
}
```

Each text block contains:
- **text**: The text content
- **bbox**: Bounding box with `left`, `top`, `right`, `bottom` coordinates (in PDF points)
- **font**: Font name (or `null` if unavailable)
- **size**: Font size in points
- **weight**: Font weight (400 = normal, 700 = bold, -1 = unavailable)
- **italic**: Whether the text is italic
- **color**: CSS-compatible hex color (`#rrggbb` or `#rrggbbaa` with alpha)

### Extract Embedded Images

```bash
# Extract all images as PNG
pdfzig extract_images document.pdf

# Extract to specific directory as JPEG
pdfzig extract_images -f jpeg -Q 90 document.pdf ./images

# Extract from specific pages
pdfzig extract_images -p 1-5 document.pdf
```

### Extract Attachments

```bash
# Extract all attachments
pdfzig extract_attachments document.pdf

# Extract only XML files using glob pattern
pdfzig extract_attachments document.pdf "*.xml"

# Extract to specific directory
pdfzig extract_attachments document.pdf "*.xml" ./xml-output

# List all attachments without extracting
pdfzig extract_attachments -l document.pdf

# List only JSON files
pdfzig extract_attachments -l document.pdf "*.json"
```

Pattern syntax: `*` matches any characters, `?` matches a single character

### Visual Diff

Compare two PDFs visually by rendering and comparing pixels:

```bash
# Compare two PDFs (exit code 0 = identical, 1 = different)
pdfzig visual_diff original.pdf modified.pdf

# Compare at higher resolution (default: 150 DPI)
pdfzig visual_diff -r 300 doc1.pdf doc2.pdf

# Generate diff images showing differences
pdfzig visual_diff -o ./diffs doc1.pdf doc2.pdf

# Use RGB mode for per-channel color diffs
pdfzig visual_diff -o ./diffs --colors rgb doc1.pdf doc2.pdf

# Use gray mode (average diff) instead of contrast mode
pdfzig visual_diff -o ./diffs --colors gray doc1.pdf doc2.pdf

# Invert colors (white = identical, black = max difference)
pdfzig visual_diff -o ./diffs --invert doc1.pdf doc2.pdf

# Compare encrypted PDFs
pdfzig visual_diff -P secret1 -P secret2 enc1.pdf enc2.pdf
```

When `-o` is specified, diff images are created showing pixel differences.
Output files are named `diff_page1.png`, `diff_page2.png`, etc.

Color modes (`--colors`):
- **contrast** (default): Grayscale where values are scaled so the maximum difference appears as white
- **gray**: Grayscale where each pixel's brightness is the average RGB difference
- **rgb**: Per-channel RGB differences shown as color values

Use `--invert` to flip colors so identical pixels are white and differences are black.

### Display PDF Information

```bash
pdfzig info document.pdf
```

Output example:
```
File: document.pdf
Pages: 10
PDF Version: 1.7
Encrypted: No

Metadata:
  Title: My Document
  Author: John Doe
  Creator: LaTeX
  Producer: pdfTeX-1.40.23
  Creation Date: D:20240101120000+00'00'
  PDF/A: PDF/A-1b

Attachments: 2
  invoice.xml [XML]
  data.json

XML files: 1 (use 'extract_attachments "*.xml"' to extract)
```

The `PDF/A` field is automatically detected from XMP metadata and displays the conformance level (e.g., PDF/A-1b, PDF/A-2u, PDF/A-3a). This field is only shown for PDF/A-compliant documents.

Use `--json` for machine-readable output with per-page dimensions:
```bash
pdfzig info --json document.pdf
```

### Rotate Pages

```bash
# Rotate all pages 90 degrees clockwise
pdfzig rotate document.pdf 90

# Rotate specific pages 180 degrees
pdfzig rotate -p 1,3,5 document.pdf 180

# Rotate and save to a different file
pdfzig rotate -o rotated.pdf document.pdf 270

# Use aliases: right (90°) and left (-90°)
pdfzig rotate document.pdf right
pdfzig rotate document.pdf left
```

Supported angles: `90`, `180`, `270` (clockwise), or `left`/`right`

### Mirror Pages

```bash
# Mirror all pages horizontally (left-right flip)
pdfzig mirror document.pdf

# Mirror vertically (up-down flip)
pdfzig mirror --updown document.pdf

# Mirror specific pages
pdfzig mirror -p 1,3,5 document.pdf

# Mirror both horizontally and vertically
pdfzig mirror --leftright --updown document.pdf

# Save to a different file
pdfzig mirror -o mirrored.pdf document.pdf
```

### Delete Pages

```bash
# Delete page 5
pdfzig delete document.pdf 5

# Delete pages 1, 3, and 5-10
pdfzig delete document.pdf 1,3,5-10

# Delete and save to a different file
pdfzig delete -o trimmed.pdf document.pdf 1-3

# Delete all pages (replaces with one empty page of same size as first page)
pdfzig delete document.pdf
```

### Add Pages

```bash
# Add an empty page at the end
pdfzig add document.pdf

# Add an empty page at position 3
pdfzig add -p 3 document.pdf

# Add a page with an image (scaled to fit)
pdfzig add document.pdf image.png

# Add a page with text content
pdfzig add document.pdf notes.txt

# Add a page with formatted text from JSON (same format as extract_text --format json)
pdfzig add document.pdf content.json

# Specify page size using standard names
pdfzig add -s A4 document.pdf
pdfzig add -s Letter document.pdf

# Use landscape orientation (append 'L')
pdfzig add -s A4L document.pdf

# Specify size with units
pdfzig add -s 210x297mm document.pdf
pdfzig add -s 8.5x11in document.pdf
```

Supported page sizes: A0-A8, B0-B6, C4-C6, Letter, Legal, Tabloid, Ledger, Executive, Folio, Quarto, Statement

Supported units: `mm`, `cm`, `in`/`inch`, `pt` (points, default)

### Create PDF

Create a new PDF from multiple sources (PDFs, images, text files):

```bash
# Merge two PDFs
pdfzig create -o combined.pdf doc1.pdf doc2.pdf

# Import only specific pages from a PDF
pdfzig create -o excerpt.pdf -p 1-5,10 document.pdf

# Create from mixed sources: image cover + PDF content
pdfzig create -o book.pdf cover.png content.pdf

# Insert blank pages using :blank
pdfzig create -o padded.pdf :blank document.pdf :blank

# Combine everything: blank + image + PDF pages + text
pdfzig create -o report.pdf :blank logo.png -p 1-3 intro.pdf notes.txt

# Specify page size for images and text (default: A4)
pdfzig create -s Letter -o output.pdf image.png notes.txt
```

Source types:
- **PDF files**: Import pages (all pages or use `-p` for specific pages)
- **Images**: PNG, JPEG, BMP - creates a page with the image scaled to fit
- **Text files**: Creates a page with the text content
- **JSON files**: Creates pages with formatted text blocks (same format as `extract_text --format json`)
- **`:blank`**: Inserts a blank page

#### Standard PDF Fonts

When using JSON files for text input, fonts are mapped to the PDF Standard Base 14 Fonts which are guaranteed to be available in all PDF viewers:

| Font Family  | Variants                               |
|--------------|----------------------------------------|
| Helvetica    | Regular, Bold, Oblique, Bold-Oblique   |
| Courier      | Regular, Bold, Oblique, Bold-Oblique   |
| Times        | Roman, Bold, Italic, Bold-Italic       |
| Symbol       | Regular                                |
| ZapfDingbats | Regular                                |

Font names in JSON are matched using these rules:
- Names containing "Courier" or "Mono" → Courier
- Names containing "Times" or "Serif" → Times
- All other names → Helvetica (default sans-serif)
- Bold/Italic variants are selected based on `weight` (≥600) and `italic` fields

### Attach Files

```bash
# Attach a file to the PDF
pdfzig attach document.pdf invoice.xml

# Attach multiple files
pdfzig attach document.pdf file1.json file2.xml

# Attach files matching a glob pattern
pdfzig attach -g "*.xml" document.pdf

# Save to a different file
pdfzig attach -o with_attachments.pdf document.pdf data.json
```

### Detach (Remove) Attachments

```bash
# Remove attachment by index
pdfzig detach -i 0 document.pdf

# Remove attachments matching a glob pattern
pdfzig detach -g "*.xml" document.pdf

# Save to a different file
pdfzig detach -o clean.pdf -g "*.tmp" document.pdf
```

### Use a Specific PDFium Library

The `--link` global option loads PDFium from a specific path instead of the default location:

```bash
# Use a specific PDFium library for a command
pdfzig --link /path/to/libpdfium.dylib info document.pdf

# Works with any command
pdfzig --link /usr/local/lib/libpdfium.dylib render document.pdf
```

The version number is automatically parsed from filenames matching the pattern `libpdfium_v{VERSION}.dylib` (or `.so`/`.dll` on other platforms).

### Password-Protected PDFs

All commands support the `-P` flag for encrypted PDFs:

```bash
pdfzig info -P mypassword encrypted.pdf
pdfzig render -P mypassword encrypted.pdf
pdfzig extract_text -P mypassword encrypted.pdf
```

### Page Selection

Many commands support the `-p` option to select specific pages. If not specified, the command operates on all pages.

Page selection syntax:
- Single page: `-p 5`
- Multiple pages: `-p 1,3,5`
- Page range: `-p 1-10`
- Combined: `-p 1-5,8,10-12`

Commands supporting `-p`: `render`, `extract_text`, `extract_images`, `rotate`, `mirror`, `create`

## Supported Platforms

| Platform | Architecture       |
|----------|--------------------|
| macOS    | arm64, x86_64      |
| Linux    | x86_64, arm64, arm |
| Windows  | x86_64, x86, arm64 |

## Dependencies

- [PDFium](https://pdfium.googlesource.com/pdfium/) - PDF rendering engine (dynamically loaded at runtime from [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries))
- [zigimg](https://github.com/zigimg/zigimg) - PNG encoding
- [zstbi](https://github.com/zig-gamedev/zstbi) - JPEG encoding

## Development

```bash
# Build
zig build

# Run tests
zig build test --summary all

# Run directly
zig build run -- info document.pdf

# Check source code formatting
zig build fmt

# Fix source code formatting
zig build fmt-fix

# Remove build artifacts and caches (zig-out/, .zig-cache/, test-cache/)
zig build clean

# Build for all supported platforms (outputs to zig-out/<target-triple>/)
zig build all
```

### Cross-Compilation Targets

The `zig build all` command builds for all supported platforms:

| Platform | Architecture | Output Directory               |
|----------|--------------|--------------------------------|
| macOS    | x86_64       | `zig-out/x86_64-macos-none/`   |
| macOS    | arm64        | `zig-out/aarch64-macos-none/`  |
| Linux    | x86_64       | `zig-out/x86_64-linux-gnu/`    |
| Linux    | arm64        | `zig-out/aarch64-linux-gnu/`   |
| Linux    | arm          | `zig-out/arm-linux-gnueabihf/` |
| Windows  | x86_64       | `zig-out/x86_64-windows-gnu/`  |
| Windows  | x86          | `zig-out/x86-windows-gnu/`     |
| Windows  | arm64        | `zig-out/aarch64-windows-gnu/` |

### Build Options

| Option                    | Description                                                    |
|---------------------------|----------------------------------------------------------------|
| `-Ddownload-pdfium`       | Download PDFium library for target platform(s)                 |
| `-Doptimize=ReleaseFast`  | Build with optimizations for speed                             |
| `-Doptimize=ReleaseSmall` | Build with optimizations for size                              |
| `-Doptimize=ReleaseSafe`  | Build with optimizations and runtime safety checks             |
| `-Dtarget=<triple>`       | Cross-compile for a specific target (e.g., `x86_64-linux-gnu`) |

Examples:

```bash
# Build with PDFium library included
zig build -Ddownload-pdfium

# Build optimized release with PDFium
zig build -Doptimize=ReleaseFast -Ddownload-pdfium

# Build for all platforms with PDFium libraries included
zig build all -Ddownload-pdfium

# Cross-compile for Linux with PDFium
zig build -Dtarget=x86_64-linux-gnu -Ddownload-pdfium
```

### Testing

Run the test suite:

```bash
# Run all tests except network-dependent tests
zig build test --summary all

# Run all tests including network-dependent tests (downloads test PDFs)
RUN_NETWORK_TESTS=1 zig build test --summary all
```

#### Test Types

**Unit Tests** (always run):
- CLI argument parsing
- Color parsing
- Font mapping
- PDF/A conformance parsing
- Page range parsing

**PDFium Tests** (always run):
- Golden file tests (render, rotate, mirror operations)
- PDF roundtrip tests (create PDF → extract text)
- Requires: PDFium library (auto-downloads if missing) + local test files in `test-files/input/`

**Network Tests** (require `RUN_NETWORK_TESTS=1`):
- Integration tests using sample PDFs from [py-pdf/sample-files](https://github.com/py-pdf/sample-files)
- Integration tests using ZUGFeRD invoices from [ZUGFeRD/corpus](https://github.com/ZUGFeRD/corpus)
- Requires: PDFium library + network access
- Test PDFs are cached in `test-cache/` directory (gitignored)

#### Golden File Testing

Visual regression tests compare PDF operations against reference "golden files":

```bash
# Generate/regenerate golden files
zig build generate-golden-files

# Delete and regenerate all golden files
zig build generate-golden-files -Dclean

# Run tests (golden file tests always run)
zig build test
```

Golden files are stored in `test-files/expected/` and checked into git. Tests use pixel-level PNG comparison (not byte-level) to handle minor rendering variations across platforms.

## License

MIT License - see [LICENSE](LICENSE)

### Third-Party Licenses

This software uses PDFium (BSD-3-Clause/Apache-2.0), zigimg (MIT), and stb libraries (MIT/Public Domain). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.
