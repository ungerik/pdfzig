# webui Requirements

Create a plan for a new command called `webui` that serves a web interface for displaying and editing PDF files.
**Ask for clarification until all implementation details are clear.**

## High Level Overview

Serve a web interface for displaying and editing PDF files.
The PDF files are displayed as a list of page images in left to right flow order
without horizontal scrolling, continuing the next page on the next line.

## Tech Stack

- Web assets like HTML, CSS, JavaScript are rendered with Zig
- Use vanilla modern (as of 2025) JavaScript
- Use htmx served from CDN for updating the UI without reloading the page
- Ask me clarifying questions about versions of libraries to use

## CLI Arguments

- Command: `webui`
- `--port`: Specifies the port to listen on. Defaults to 8080
- `--readonly`: Read only mode, no editing allowed
- All following arguments are treated as file paths to PDF files to serve

## UI Design

- Use a clean, modern, minimalistic design with a focus on usability and accessibility.
- The background should be dark to contrast with mostly white PDF pages.
- Put shadows on the edges of the pages to give a sense of depth.
- Keep all generic functionality in a top bar, **no sidebar**
- Calulate the maximum height of page images so that multiple rows of pages can be displayed and page images being large enough to recognize their content (a typcial screen could display 5 rows of pages)
- All page images are scaled to fit the maximum height while maintaining their aspect ratio, except when the width exceeds twice the height, in which case the page image is scaled to fit the width while maintaining its aspect ratio
- If multiple PDF documents are displayed, then surround all pages of a PDF document per row with a background rectangle random color chosen from a palette of harmonizing darker colors. Use a border radius at the left side of the first page and the right side of the last page, use no border radius at line breaks between pages of the same PDF document.

## UI Functionality

- If no PDF was specified, display nothing else except a message with a button to upload a PDF file and make the whole page a drop area for uploading a PDF files.
- The top bar should have a button to upload PDF files.
- The upload button should support selecting multiple files at once.
- The top bar should have a button to download all documents in their modified state
- The top bar should have a button to reset all documents to their original state, ask for confirmation, or gray out if no documents were modified
- The top bar should have a button to remove all loaded documents, ask for confirmation if any documents were modified
- Display the PDF files as a list of page images in left to right flow order without horizontal scrolling, continuing the next page on the next line with `flex-wrap: wrap`
- For every page overlay **icon only** UI buttons to:
    - Rotate left, placed on the top left corner of the page
    - Rotate right, placed on the top right corner of the page
    - Mirror up-down, placed at the right side of the page
    - Mirror left-right, placed at the bottom of the page
    - Download, placed on the bottom of the page
    - Delete, placed on the top of the page
- Deleting a page does not remove it from the list of pages, but instead marks it as deleted and displays a strikethrough through the page image
- The order of pages can be changed by dragging and dropping them, including moving pages between PDF documents
- Every page that was modified should be highlighted and get a button on the bottom right corner of the page to revert the changes, a tooltip for the revert button displays the changes that will be reverted
- Page images should be clickable to view the page in a modal that fills the whole screen
- At the left and right side of the document container, add a button to download the entire document as a PDF file
- At the left and right side of the document container, add a button to mark all pages as deleted
- In the vertical space between two pages of the same document, place a vertical dotted line with the icon of scissors, clicking it will split the document into two documents at the page position of the click. Show that dotted line with icon only on mouse hover
- In readonly mode display a message about that mode in the top bar, and don't show any of the modification UI elements
- Show `Copyright (C) 2026 by Erik Unger` and a link to https://github.com/ungerik/pdfzig at the footer bar of the screen


## Server implementation details

- Load PDF files into memory and keep them in memory for further processing
- For every page, create a bitmap image in the size of the UI page image and keep it in memory
- For every page keep track of the changes that were made to the page to be able to display them in the UI and revert them
- When a page is modified, create a new bitmap image and keep it in memory along with the original bitmap image
- For modal view of a page, create a bitmap image in the size of the screen on request and don't keep it in memory
- For download of a page via UI button, create an in memory PDF file with just that page and don't keep it in memory
- Every page modification requested by the UI should be applied to the in memory copy of the PDF, then rendered to an update page image and displayed in the UI. Don't save the changes to the original PDF file
- Use PNG bitmaps for page images displayed in the UI

### Clarification needed:

When selecting a PDF to be loadedf rom the web UI, is it possible to detect if it is a file on the local file system of the server, or remote? If it's local, then we have the opportunity to save change directly to the file without going through a download and upload process.

What else am I missing from a technical side and what typical PDF operations are not specified here?
I want to support all functionality of the `pdfzig` command line tool via web UI.


