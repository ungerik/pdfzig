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
    console.log('Updating DPI to:', dpi);

    fetch('/api/settings/dpi', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'X-Client-ID': clientId
        },
        body: JSON.stringify({ dpi })
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
        console.log('Reordering pages:', draggedElement.dataset.pageId, 'to', target.dataset.pageId);

        fetch('/api/pages/reorder', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-Client-ID': clientId
            },
            body: JSON.stringify({
                source: draggedElement.dataset.pageId,
                target: target.dataset.pageId
            })
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
            console.log('Uploading:', file.name);
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
    fetch(`/api/pages/${pageId}/rotate`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'X-Client-ID': clientId
        },
        body: JSON.stringify({ degrees })
    }).then(response => {
        if (response.ok) {
            htmx.trigger(document.body, 'pageUpdate');
        }
    });
}

function mirrorPage(pageId, direction) {
    fetch(`/api/pages/${pageId}/mirror`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'X-Client-ID': clientId
        },
        body: JSON.stringify({ direction })
    }).then(response => {
        if (response.ok) {
            htmx.trigger(document.body, 'pageUpdate');
        }
    });
}

function deletePage(pageId) {
    fetch(`/api/pages/${pageId}/delete`, {
        method: 'POST',
        headers: {
            'X-Client-ID': clientId
        }
    }).then(response => {
        if (response.ok) {
            htmx.trigger(document.body, 'pageUpdate');
        }
    });
}

function revertPage(pageId) {
    fetch(`/api/pages/${pageId}/revert`, {
        method: 'POST',
        headers: {
            'X-Client-ID': clientId
        }
    }).then(response => {
        if (response.ok) {
            htmx.trigger(document.body, 'pageUpdate');
        }
    });
}

// Server-Sent Events for cross-window synchronization
function setupSSE() {
    const eventSource = new EventSource('/api/events');

    eventSource.addEventListener('change', (e) => {
        const data = JSON.parse(e.data);
        console.log('Change notification:', data);

        // Only reload if change was from another client
        if (data.clientId !== clientId) {
            console.log('Reloading due to external change');
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

console.log('pdfzig WebUI initialized with client ID:', clientId);
