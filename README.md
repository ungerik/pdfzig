# pdfzig

A fast, cross-platform PDF utility tool written in Zig, powered by PDFium.

## Features

- **Render** PDF pages to PNG or JPEG images at any DPI
- **Extract text** content from PDFs
- **Extract images** embedded in PDF pages
- **Extract attachments** embedded in PDFs with glob pattern filtering
- **Visual diff** - compare two PDFs visually, pixel by pixel
- **Display info** including metadata, page count, encryption status, attachments, and PDF version
- Support for **password-protected** PDFs
- **Multi-resolution output** - generate multiple image sizes in one pass

## Installation

### Requirements

- Zig 0.15.1 or later
- curl (for downloading PDFium binaries during build)

### Build

```bash
git clone https://github.com/ungerik/pdfzig.git
cd pdfzig
zig build
```

PDFium binaries are automatically downloaded for your platform on first build.

The executable and required library will be in `zig-out/bin/`.

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

```bash
# Print text to stdout
pdfzig extract_text document.pdf

# Save to file
pdfzig extract_text -o output.txt document.pdf

# Extract from specific pages
pdfzig extract_text -p 1-10 document.pdf
```

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
pdfzig visual_diff -d 300 doc1.pdf doc2.pdf

# Generate diff images showing differences
pdfzig visual_diff -o ./diffs doc1.pdf doc2.pdf

# Compare encrypted PDFs
pdfzig visual_diff -P secret1 -P secret2 enc1.pdf enc2.pdf
```

When `-o` is specified, grayscale diff images are created where each pixel's
brightness represents the average RGB difference (black = identical, white = maximum difference).

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

Attachments: 2
  invoice.xml [XML]
  data.json

XML files: 1 (use 'extract_attachments "*.xml"' to extract)
```

### Password-Protected PDFs

All commands support the `-P` flag for encrypted PDFs:

```bash
pdfzig info -P mypassword encrypted.pdf
pdfzig render -P mypassword encrypted.pdf
pdfzig extract_text -P mypassword encrypted.pdf
```

## Supported Platforms

| Platform | Architecture |
|----------|--------------|
| macOS    | arm64, x86_64 |
| Linux    | x86_64, arm64, arm |
| Windows  | x86_64, x86, arm64 |

## Dependencies

- [PDFium](https://pdfium.googlesource.com/pdfium/) - PDF rendering engine (auto-downloaded from [pdfium-binaries](https://github.com/bblanchon/pdfium-binaries))
- [zigimg](https://github.com/zigimg/zigimg) - PNG encoding
- [zstbi](https://github.com/zig-gamedev/zstbi) - JPEG encoding

## Development

```bash
# Build
zig build

# Run tests
zig build test

# Run directly
zig build run -- info document.pdf
```

## License

MIT License - see [LICENSE](LICENSE)

### Third-Party Licenses

This software uses PDFium (BSD-3-Clause/Apache-2.0), zigimg (MIT), and stb libraries (MIT/Public Domain). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details.
