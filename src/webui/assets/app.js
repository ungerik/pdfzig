// pdfzig WebUI Client-Side JavaScript

// Generate unique client ID for cross-window synchronization
const clientId = generateClientId();

// DPI calculation and update
function calculateOptimalDPI() {
    const viewportHeight = window.innerHeight;
    const topBarHeight = 60;
    const bottomBarHeight = 50;
    const rowCount = 5;  // Target 5 rows of pages
    const pageMargin = 20;

    const availableHeight = viewportHeight - topBarHeight - bottomBarHeight;
    const pageHeight = (availableHeight / rowCount) - (pageMargin * 2);

    // Assume average page is US Letter (11 inches height)
    const targetDPI = (pageHeight / 11) * 72;

    // Clamp between 50-150 DPI
    return Math.max(50, Math.min(150, Math.round(targetDPI)));
}

function updateDPI() {
    const dpi = calculateOptimalDPI();

    fetch(`/api/settings/dpi/${dpi}`, {
        method: 'POST',
        headers: {
            'X-Client-ID': clientId
        }
    }).then(() => {
        // Trigger page reload
        htmx.trigger(document.body, 'pageUpdate');
    }).catch(err => {
        console.error('Failed to update DPI:', err);
    });
}

// Debounce function to limit resize events
function debounce(func, wait) {
    let timeout;
    return function(...args) {
        clearTimeout(timeout);
        timeout = setTimeout(() => func.apply(this, args), wait);
    };
}

// Initialize DPI on load and window resize
window.addEventListener('load', updateDPI);
window.addEventListener('resize', debounce(updateDPI, 500));

// Drag and drop for page reordering
let draggedElement = null;

document.addEventListener('dragstart', (e) => {
    if (e.target.classList.contains('page-card')) {
        draggedElement = e.target;
        e.target.style.opacity = '0.5';
    }
});

document.addEventListener('dragend', (e) => {
    if (e.target.classList.contains('page-card')) {
        e.target.style.opacity = '1';
        draggedElement = null;
    }
});

document.addEventListener('dragover', (e) => {
    e.preventDefault();  // Allow drop
});

document.addEventListener('drop', (e) => {
    e.preventDefault();
    const target = e.target.closest('.page-card');

    if (target && draggedElement && target !== draggedElement) {
        const sourceId = draggedElement.dataset.pageId;
        const targetId = target.dataset.pageId;

        fetch(`/api/pages/reorder/${sourceId}/${targetId}`, {
            method: 'POST',
            headers: {
                'X-Client-ID': clientId
            }
        }).then(response => {
            if (response.ok) {
                htmx.trigger(document.body, 'pageUpdate');
            } else {
                console.error('Reorder failed');
            }
        }).catch(err => {
            console.error('Reorder error:', err);
        });
    }
});

// File upload handling
const fileInput = document.getElementById('file-input');
if (fileInput) {
    fileInput.addEventListener('change', async (e) => {
        const files = e.target.files;
        if (!files || files.length === 0) return;

        for (const file of files) {
            const formData = new FormData();
            formData.append('pdf', file);

            try {
                const response = await fetch('/api/documents/upload', {
                    method: 'POST',
                    headers: {
                        'X-Client-ID': clientId
                    },
                    body: formData
                });

                if (!response.ok) {
                    console.error('Upload failed for:', file.name);
                }
            } catch (err) {
                console.error('Upload error:', err);
            }
        }

        // Clear input and trigger page update
        e.target.value = '';
        htmx.trigger(document.body, 'pageUpdate');
    });
}

// Modal handling
function openModal(imgSrc) {
    const modal = document.getElementById('modal');
    const modalImg = document.getElementById('modal-img');

    if (modal && modalImg) {
        modal.style.display = 'flex';
        modalImg.src = imgSrc;
    }
}

function closeModal() {
    const modal = document.getElementById('modal');
    if (modal) {
        modal.style.display = 'none';
    }
}

// Close modal on click
const closeBtn = document.querySelector('.close');
if (closeBtn) {
    closeBtn.addEventListener('click', closeModal);
}

// Close modal when clicking outside the image
const modal = document.getElementById('modal');
if (modal) {
    modal.addEventListener('click', (e) => {
        if (e.target === modal) {
            closeModal();
        }
    });
}

// Close modal on Escape key
document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        closeModal();
    }
});

// Page operation functions
function rotatePage(pageId, degrees) {
    // Find the card and add loading spinner immediately
    const card = document.querySelector(`.page-card[data-page-id="${pageId}"]`);
    if (!card) return;

    showLoadingSpinner(card);

    fetch(`/api/pages/${pageId}/rotate/${degrees}`, {
        method: 'POST',
        headers: {
            'X-Client-ID': clientId
        }
    }).then(response => {
        if (response.ok) {
            // Update just the thumbnail image source with new version
            updateThumbnail(card, pageId);
        } else {
            console.error('Rotation failed:', response.status);
            hideLoadingSpinner(card);
        }
    }).catch(err => {
        console.error('Rotation error:', err);
        hideLoadingSpinner(card);
    });
}

function mirrorPage(pageId, direction) {
    // Find the card and add loading spinner immediately
    const card = document.querySelector(`.page-card[data-page-id="${pageId}"]`);
    if (!card) return;

    showLoadingSpinner(card);

    fetch(`/api/pages/${pageId}/mirror/${direction}`, {
        method: 'POST',
        headers: {
            'X-Client-ID': clientId
        }
    }).then(response => {
        if (response.ok) {
            // Update just the thumbnail image source with new version
            updateThumbnail(card, pageId);
        } else {
            console.error('Mirror failed:', response.status);
            hideLoadingSpinner(card);
        }
    }).catch(err => {
        console.error('Mirror error:', err);
        hideLoadingSpinner(card);
    });
}

// Show loading spinner overlay
function showLoadingSpinner(card) {
    // Don't add if already present
    if (card.querySelector('.loading-overlay')) return;

    const overlay = document.createElement('div');
    overlay.className = 'loading-overlay';

    const spinner = document.createElement('div');
    spinner.className = 'loading-spinner';

    overlay.appendChild(spinner);
    card.appendChild(overlay);
}

// Hide loading spinner overlay
function hideLoadingSpinner(card) {
    const overlay = card.querySelector('.loading-overlay');
    if (overlay) {
        overlay.remove();
    }
}

// Update thumbnail image without replacing DOM
function updateThumbnail(card, pageId) {
    const img = card.querySelector('.page-thumbnail');
    if (!img) return;

    // Get current version from URL or use timestamp
    const timestamp = Date.now();
    const newSrc = `/api/pages/${pageId}/thumbnail?v=${timestamp}`;

    // Preload the new image
    const tempImg = new Image();
    tempImg.onload = () => {
        // Image loaded successfully, update the src
        img.src = newSrc;
        hideLoadingSpinner(card);

        // Mark page as modified (show blue border and edit indicator)
        card.setAttribute('data-modified', 'true');

        // Update document modified state
        const docId = pageId.split('-')[0];
        updateDocumentModifiedState(docId);

        // Update reset button state and clear button confirmation
        updateResetButtonState();
        updateClearButtonConfirmation();
    };
    tempImg.onerror = () => {
        console.error('Failed to load new thumbnail');
        hideLoadingSpinner(card);
    };
    tempImg.src = newSrc;
}

function deletePage(pageId) {
    const card = document.querySelector(`.page-card[data-page-id="${pageId}"]`);
    if (!card) return;

    // Check if page is already deleted
    const isDeleted = card.getAttribute('data-deleted') === 'true';

    if (isDeleted) {
        // Undelete: call revert endpoint
        showLoadingSpinner(card);

        fetch(`/api/pages/${pageId}/revert`, {
            method: 'POST',
            headers: {
                'X-Client-ID': clientId
            }
        }).then(response => {
            if (response.ok) {
                // Remove deleted and modified states
                card.setAttribute('data-deleted', 'false');
                card.setAttribute('data-modified', 'false');

                // Update delete button title back to "Delete"
                const deleteBtn = card.querySelector('.btn-red');
                if (deleteBtn) {
                    deleteBtn.setAttribute('title', 'Delete');
                }

                // Remove revert button if present
                const revertBtn = card.querySelector('.revert-btn');
                if (revertBtn) {
                    revertBtn.remove();
                }

                // Update document modified state
                const docId = pageId.split('-')[0];
                updateDocumentModifiedState(docId);

                // Reload thumbnail to show original state
                const img = card.querySelector('.page-thumbnail');
                if (img) {
                    const timestamp = Date.now();
                    const newSrc = `/api/pages/${pageId}/thumbnail?v=${timestamp}`;

                    const tempImg = new Image();
                    tempImg.onload = () => {
                        img.src = newSrc;
                        hideLoadingSpinner(card);
                        updateResetButtonState();
                        updateClearButtonConfirmation();
                    };
                    tempImg.onerror = () => {
                        console.error('Failed to load reverted thumbnail');
                        hideLoadingSpinner(card);
                    };
                    tempImg.src = newSrc;
                } else {
                    hideLoadingSpinner(card);
                }
            } else {
                console.error('Undelete failed:', response.status);
                hideLoadingSpinner(card);
            }
        }).catch(err => {
            console.error('Undelete error:', err);
            hideLoadingSpinner(card);
        });
    } else {
        // Delete: call delete endpoint
        fetch(`/api/pages/${pageId}/delete`, {
            method: 'POST',
            headers: {
                'X-Client-ID': clientId
            }
        }).then(response => {
            if (response.ok) {
                // Mark page as deleted and modified
                card.setAttribute('data-deleted', 'true');
                card.setAttribute('data-modified', 'true');

                // Update delete button title to "Undelete"
                const deleteBtn = card.querySelector('.btn-red');
                if (deleteBtn) {
                    deleteBtn.setAttribute('title', 'Undelete');
                }

                // Update document modified state
                const docId = pageId.split('-')[0];
                updateDocumentModifiedState(docId);

                // Update reset button state and clear button confirmation
                updateResetButtonState();
                updateClearButtonConfirmation();
            } else {
                console.error('Delete failed:', response.status);
            }
        }).catch(err => {
            console.error('Delete error:', err);
        });
    }
}

function revertPage(pageId) {
    const card = document.querySelector(`.page-card[data-page-id="${pageId}"]`);
    if (!card) return;

    showLoadingSpinner(card);

    fetch(`/api/pages/${pageId}/revert`, {
        method: 'POST',
        headers: {
            'X-Client-ID': clientId
        }
    }).then(response => {
        if (response.ok) {
            // Remove deleted and modified states
            card.setAttribute('data-deleted', 'false');
            card.setAttribute('data-modified', 'false');

            // Remove revert button if present
            const revertBtn = card.querySelector('.revert-btn');
            if (revertBtn) {
                revertBtn.remove();
            }

            // Update document modified state
            const docId = pageId.split('-')[0];
            updateDocumentModifiedState(docId);

            // Reload thumbnail to show original state
            const img = card.querySelector('.page-thumbnail');
            if (img) {
                const timestamp = Date.now();
                const newSrc = `/api/pages/${pageId}/thumbnail?v=${timestamp}`;

                const tempImg = new Image();
                tempImg.onload = () => {
                    img.src = newSrc;
                    hideLoadingSpinner(card);
                    updateResetButtonState();
                    updateClearButtonConfirmation();
                };
                tempImg.onerror = () => {
                    console.error('Failed to load reverted thumbnail');
                    hideLoadingSpinner(card);
                };
                tempImg.src = newSrc;
            } else {
                hideLoadingSpinner(card);
            }
        } else {
            console.error('Revert failed:', response.status);
            hideLoadingSpinner(card);
        }
    }).catch(err => {
        console.error('Revert error:', err);
        hideLoadingSpinner(card);
    });
}

// Server-Sent Events for cross-window synchronization
function setupSSE() {
    const eventSource = new EventSource('/api/events');

    eventSource.addEventListener('change', (e) => {
        const data = JSON.parse(e.data);

        // Only reload if change was from another client
        if (data.clientId !== clientId) {
            htmx.trigger(document.body, 'pageUpdate');
        }
    });

    eventSource.addEventListener('error', (e) => {
        console.error('SSE error:', e);
        // Reconnection is automatic
    });
}

// Initialize SSE after page load
window.addEventListener('load', setupSSE);

// Update reset button state based on modifications
function updateResetButtonState() {
    fetch('/api/documents/status')
        .then(response => response.json())
        .then(data => {
            const resetBtn = document.getElementById('reset-btn');
            if (resetBtn) {
                if (data.hasModifications) {
                    resetBtn.disabled = false;
                    resetBtn.style.opacity = '1';
                    resetBtn.style.cursor = 'pointer';
                } else {
                    resetBtn.disabled = true;
                    resetBtn.style.opacity = '0.5';
                    resetBtn.style.cursor = 'not-allowed';
                }
            }
        })
        .catch(err => console.error('Failed to update reset button:', err));
}

// Update reset button on page load and after any change
window.addEventListener('load', updateResetButtonState);
document.body.addEventListener('htmx:afterSwap', updateResetButtonState);

// Update clear button confirmation message based on modifications
function updateClearButtonConfirmation() {
    fetch('/api/documents/status')
        .then(response => response.json())
        .then(data => {
            const clearBtn = document.querySelector('button[hx-post="/api/clear"]');
            if (clearBtn) {
                if (data.hasModifications && data.documentCount > 0) {
                    clearBtn.setAttribute('hx-confirm', 'You have unsaved modifications. Remove all documents?');
                } else if (data.documentCount > 0) {
                    clearBtn.setAttribute('hx-confirm', 'Remove all documents?');
                } else {
                    clearBtn.removeAttribute('hx-confirm');
                }
            }
        })
        .catch(err => console.error('Failed to update clear button:', err));
}

// Update clear button on page load and after any change
window.addEventListener('load', updateClearButtonConfirmation);
document.body.addEventListener('htmx:afterSwap', updateClearButtonConfirmation);

// Update delete button titles based on page state
function updateDeleteButtonTitles() {
    document.querySelectorAll('.page-card').forEach(card => {
        const isDeleted = card.getAttribute('data-deleted') === 'true';
        const deleteBtn = card.querySelector('.btn-red');
        if (deleteBtn) {
            deleteBtn.setAttribute('title', isDeleted ? 'Undelete' : 'Delete');
        }
    });
}

// Update delete button titles on page load and after any change
window.addEventListener('load', updateDeleteButtonTitles);
document.body.addEventListener('htmx:afterSwap', updateDeleteButtonTitles);

// Update document modified state based on its pages
function updateDocumentModifiedState(docId) {
    // Find the document group
    const docGroup = document.querySelector(`.document-group[data-doc-id="${docId}"]`);
    if (!docGroup) return;

    // Check if any page in this document is modified
    const pages = docGroup.querySelectorAll('.page-card');
    let hasModifications = false;

    pages.forEach(card => {
        const pageDocId = card.getAttribute('data-page-id').split('-')[0];
        if (pageDocId === docId.toString()) {
            const isModified = card.getAttribute('data-modified') === 'true';
            if (isModified) {
                hasModifications = true;
            }
        }
    });

    // Update document group attribute
    docGroup.setAttribute('data-modified', hasModifications ? 'true' : 'false');
}

// Update all documents' modified states
function updateAllDocumentsModifiedState() {
    document.querySelectorAll('.document-group').forEach(docGroup => {
        const docId = docGroup.getAttribute('data-doc-id');
        if (docId) {
            updateDocumentModifiedState(docId);
        }
    });
}

// Update document modified states on page load and after any change
window.addEventListener('load', updateAllDocumentsModifiedState);
document.body.addEventListener('htmx:afterSwap', updateAllDocumentsModifiedState);

// Add client ID to all htmx requests
document.body.addEventListener('htmx:configRequest', (e) => {
    e.detail.headers['X-Client-ID'] = clientId;
});

// Generate a unique client ID
function generateClientId() {
    // Use crypto.randomUUID if available, otherwise fallback
    if (typeof crypto !== 'undefined' && crypto.randomUUID) {
        return crypto.randomUUID();
    }

    // Fallback UUID v4 generation
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        const r = Math.random() * 16 | 0;
        const v = c === 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}

// Download page or document choice
function downloadPageOrDocument(pageId, docId) {
    const pageOnly = confirm('Download only this page?\n\n(Cancel to download the whole document instead)');

    if (pageOnly) {
        // Download single page
        window.location.href = `/api/pages/${pageId}/download`;
    } else {
        // Download whole document
        window.location.href = `/api/documents/${docId}/download`;
    }
}

console.log('pdfzig WebUI initialized with client ID:', clientId);
