// pdfzig WebUI Client-Side JavaScript

// Generate unique session ID for this browser window
const sessionId = crypto.randomUUID();

// Helper: Fetch and parse JSON with proper error checking
async function fetchJSON(url, options = {}) {
    const response = await fetch(url, {
        ...options,
        headers: {
            'X-Session-ID': sessionId,
            ...options.headers
        }
    });

    if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    return await response.json();
}

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
            'X-Session-ID': sessionId
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

// =============================================================================
// Matrix Math Functions for PDF Transformations
// =============================================================================

/**
 * Calculate rotation matrix for given degrees and dimensions
 * @param {number} degrees - Rotation angle (90, 180, 270, or -90)
 * @param {number} width - Current width
 * @param {number} height - Current height
 * @returns {number[]} - 6-element array [a, b, c, d, e, f] representing PDF matrix
 */
function calculateRotationMatrix(degrees, width, height) {
    const rad = degrees * Math.PI / 180;
    const cos = Math.cos(rad);
    const sin = Math.sin(rad);

    // Calculate translation to keep content in positive quadrant
    let tx = 0, ty = 0;
    if (degrees === 90 || degrees === -270) {
        tx = height;
    } else if (degrees === 180 || degrees === -180) {
        tx = width;
        ty = height;
    } else if (degrees === 270 || degrees === -90) {
        ty = width;
    }

    return [cos, sin, -sin, cos, tx, ty];
}

/**
 * Calculate mirror matrix for given direction and dimensions
 * @param {string} direction - 'updown' or 'leftright'
 * @param {number} width - Current width
 * @param {number} height - Current height
 * @returns {number[]} - 6-element array [a, b, c, d, e, f] representing PDF matrix
 */
function calculateMirrorMatrix(direction, width, height) {
    if (direction === 'updown') {
        // Vertical mirror: flip around horizontal axis
        return [1, 0, 0, -1, 0, height];
    } else {
        // Horizontal mirror: flip around vertical axis
        return [-1, 0, 0, 1, width, 0];
    }
}

/**
 * Multiply two transformation matrices
 * @param {number[]} m1 - First matrix [a, b, c, d, e, f]
 * @param {number[]} m2 - Second matrix [a, b, c, d, e, f]
 * @returns {number[]} - Result matrix [a, b, c, d, e, f]
 */
function multiplyMatrices(m1, m2) {
    return [
        m1[0]*m2[0] + m1[2]*m2[1],           // a
        m1[1]*m2[0] + m1[3]*m2[1],           // b
        m1[0]*m2[2] + m1[2]*m2[3],           // c
        m1[1]*m2[2] + m1[3]*m2[3],           // d
        m1[0]*m2[4] + m1[2]*m2[5] + m1[4],   // e
        m1[1]*m2[4] + m1[3]*m2[5] + m1[5]    // f
    ];
}

/**
 * Transform dimensions using a matrix
 * @param {number[]} matrix - Transformation matrix [a, b, c, d, e, f]
 * @param {number} width - Original width
 * @param {number} height - Original height
 * @returns {{width: number, height: number}} - Transformed dimensions
 */
function transformDimensions(matrix, width, height) {
    // Transform rectangle corners and find bounding box
    const corners = [
        [0, 0],
        [width, 0],
        [0, height],
        [width, height]
    ];

    const transformed = corners.map(([x, y]) => [
        matrix[0]*x + matrix[2]*y + matrix[4],
        matrix[1]*x + matrix[3]*y + matrix[5]
    ]);

    const xs = transformed.map(p => p[0]);
    const ys = transformed.map(p => p[1]);

    return {
        width: Math.max(...xs) - Math.min(...xs),
        height: Math.max(...ys) - Math.min(...ys)
    };
}

// =============================================================================
// Version State Management
// =============================================================================

// Global state per page: pageId -> version history array
const pageVersionStates = new Map();
// pageId -> current version index
const pageCurrentVersion = new Map();
// pageId -> original dimensions
const pageOriginalDimensions = new Map();
// pageId -> pending operation flag (prevents concurrent operations)
const pagePendingOperations = new Map();

/**
 * Initialize page state from server data
 * @param {string} pageId - Page identifier (e.g., "0-1")
 * @param {Array} versionHistory - Array of version state objects
 * @param {number} currentVersion - Current version index
 * @param {number} originalWidth - Original page width
 * @param {number} originalHeight - Original page height
 */
function initializePageState(pageId, versionHistory, currentVersion, originalWidth, originalHeight) {
    pageVersionStates.set(pageId, versionHistory);
    pageCurrentVersion.set(pageId, currentVersion);
    pageOriginalDimensions.set(pageId, { width: originalWidth, height: originalHeight });
    applyTransformToElement(pageId);
}

/**
 * Get current transformation matrix for a page
 * @param {string} pageId - Page identifier
 * @returns {number[]} - Current matrix [a, b, c, d, e, f]
 */
function getCurrentMatrix(pageId) {
    const history = pageVersionStates.get(pageId);
    const version = pageCurrentVersion.get(pageId);
    if (!history || version === undefined) {
        return [1, 0, 0, 1, 0, 0]; // Identity matrix
    }
    return history[version].matrix;
}

/**
 * Get current state for a page
 * @param {string} pageId - Page identifier
 * @returns {Object|null} - Current version state object
 */
function getCurrentState(pageId) {
    const history = pageVersionStates.get(pageId);
    const version = pageCurrentVersion.get(pageId);
    if (!history || version === undefined) {
        return null;
    }
    return history[version];
}

/**
 * Apply CSS transform to page thumbnail element
 * @param {string} pageId - Page identifier
 */
function applyTransformToElement(pageId) {
    const pageCardOuter = document.querySelector(`.page-card-outer[data-page-id="${pageId}"]`);
    if (!pageCardOuter) return;

    const pageCardInner = pageCardOuter.querySelector('.page-card-inner');
    const imgElement = pageCardOuter.querySelector('.page-thumbnail');
    if (!pageCardInner || !imgElement) return;

    const matrix = getCurrentMatrix(pageId);
    const state = getCurrentState(pageId);
    const originalDims = pageOriginalDimensions.get(pageId);

    if (!state || !originalDims) return;

    // Wait for image to load to get actual dimensions
    if (!imgElement.complete || imgElement.naturalWidth === 0) {
        imgElement.onload = () => applyTransformToElement(pageId);
        return;
    }

    // Get original image dimensions (always unrotated)
    const imgWidth = imgElement.offsetWidth || imgElement.width;
    const imgHeight = imgElement.offsetHeight || imgElement.height;

    if (imgWidth === 0 || imgHeight === 0) return;

    // Calculate scale factor from original PDF dimensions to thumbnail size
    const scaleFactor = imgWidth / originalDims.width;

    // Apply the full transformation matrix using CSS matrix()
    // PDF matrix [a, b, c, d, e, f] maps to CSS matrix(a, b, c, d, tx, ty)
    // We ignore the translation components (e, f) and apply them via centering
    const cssMatrix = `matrix(${matrix[0]}, ${matrix[1]}, ${matrix[2]}, ${matrix[3]}, 0, 0)`;

    // Inner container sized to original (unrotated) thumbnail dimensions
    pageCardInner.style.width = `${imgWidth}px`;
    pageCardInner.style.height = `${imgHeight}px`;
    pageCardInner.style.position = 'absolute';
    pageCardInner.style.left = '50%';
    pageCardInner.style.top = '50%';
    pageCardInner.style.transform = `translate(-50%, -50%) ${cssMatrix}`;
    pageCardInner.style.transformOrigin = 'center';

    // Calculate outer container dimensions from transformed bounding box
    // Transform the four corners of the image rectangle and find bounding box
    const corners = [
        [0, 0],
        [imgWidth, 0],
        [0, imgHeight],
        [imgWidth, imgHeight]
    ];

    const transformedCorners = corners.map(([x, y]) => {
        // Apply matrix transformation (ignoring translation since we center)
        const tx = matrix[0] * x + matrix[2] * y;
        const ty = matrix[1] * x + matrix[3] * y;
        return [tx, ty];
    });

    const xs = transformedCorners.map(p => p[0]);
    const ys = transformedCorners.map(p => p[1]);

    const outerWidth = Math.abs(Math.max(...xs) - Math.min(...xs));
    const outerHeight = Math.abs(Math.max(...ys) - Math.min(...ys));

    pageCardOuter.style.width = `${outerWidth}px`;
    pageCardOuter.style.height = `${outerHeight}px`;

    // Update deleted state
    pageCardOuter.setAttribute('data-deleted', state.deleted ? 'true' : 'false');
    pageCardOuter.setAttribute('data-modified', pageCurrentVersion.get(pageId) > 0 ? 'true' : 'false');

    // Remove no-transition class after first transform (enable animations for subsequent changes)
    // Use requestAnimationFrame to ensure styles are applied before removing the class
    requestAnimationFrame(() => {
        pageCardOuter.classList.remove('no-transition');
        pageCardInner.classList.remove('no-transition');
    });
}

// Drag and drop for page reordering
let draggedElement = null;

document.addEventListener('dragstart', (e) => {
    const pageCard = e.target.closest('.page-card-outer');
    if (pageCard) {
        draggedElement = pageCard;
        pageCard.style.opacity = '0.5';
    }
});

document.addEventListener('dragend', (e) => {
    const pageCard = e.target.closest('.page-card-outer');
    if (pageCard) {
        pageCard.style.opacity = '1';
        draggedElement = null;
    }
});

document.addEventListener('dragover', (e) => {
    e.preventDefault();  // Allow drop
});

document.addEventListener('drop', (e) => {
    e.preventDefault();
    const target = e.target.closest('.page-card-outer');

    if (target && draggedElement && target !== draggedElement) {
        const sourceId = draggedElement.dataset.pageId;
        const targetId = target.dataset.pageId;

        fetch(`/api/pages/reorder/${sourceId}/${targetId}`, {
            method: 'POST',
            headers: {
                'X-Session-ID': sessionId
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
                        'X-Session-ID': sessionId
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
const closeBtn = document.querySelector('#modal .close');
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

/**
 * Get page state for an operation, returning null if not ready
 * @param {string} pageId - Page identifier
 * @returns {Object|null} - Page state or null if not initialized
 */
function getPageStateForOperation(pageId) {
    const card = document.querySelector(`.page-card-outer[data-page-id="${pageId}"]`);
    if (!card) return null;

    const history = pageVersionStates.get(pageId);
    const currentVersion = pageCurrentVersion.get(pageId);
    const originalDims = pageOriginalDimensions.get(pageId);

    if (!history || currentVersion === undefined || !originalDims) {
        console.error('Page state not initialized for:', pageId);
        return null;
    }

    return { card, history, currentVersion, originalDims, currentState: history[currentVersion] };
}

/**
 * Apply a page transformation and sync with server
 * @param {string} pageId - Page identifier
 * @param {Object} params - Operation parameters
 * @param {number[]} params.transformMatrix - Transformation matrix to apply
 * @param {string} params.operation - Operation description
 * @param {Object} params.requestBody - Additional request body fields
 * @param {string} params.errorMessage - Error message to show on failure
 */
async function applyPageTransformation(pageId, params) {
    // Check if operation is already pending for this page (prevent race conditions)
    if (pagePendingOperations.get(pageId)) {
        console.log('Operation already in progress for page:', pageId);
        return;
    }

    const state = getPageStateForOperation(pageId);
    if (!state) return;

    const { card, history, currentVersion, originalDims, currentState } = state;
    const { transformMatrix, operation, requestBody, errorMessage } = params;

    // Mark operation as pending
    pagePendingOperations.set(pageId, true);

    // Calculate new matrix locally
    const newMatrix = multiplyMatrices(currentState.matrix, transformMatrix);
    const newDims = transformDimensions(newMatrix, originalDims.width, originalDims.height);

    // Create new version state
    const newState = {
        version: currentVersion + 1,
        operation: operation,
        matrix: newMatrix,
        width: newDims.width,
        height: newDims.height,
        deleted: currentState.deleted
    };

    showLoadingSpinner(card);

    try {
        const response = await fetch(`/api/pages/${pageId}/operation`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-Session-ID': sessionId
            },
            body: JSON.stringify({
                ...requestBody,
                expected_version: currentVersion,
                new_state: newState
            })
        });

        const data = await response.json();

        if (data.success) {
            history.push(newState);
            pageCurrentVersion.set(pageId, newState.version);
            applyTransformToElement(pageId);

            // Update version in DOM
            card.setAttribute('data-version', data.version);
            card.setAttribute('data-modified', 'true');

            // Add reset button if not present
            ensureResetButtonExists(pageId);

            const docId = pageId.split('-')[0];
            setDocumentModifiedState(docId, data.document_modified);

            updateResetButtonState();
            updateClearButtonConfirmation();
        } else {
            console.error('Operation rejected by server');
            showErrorMessage(errorMessage);
        }
    } catch (err) {
        console.error('Operation error:', err);
        showErrorMessage(errorMessage);
    } finally {
        // Clear pending flag
        pagePendingOperations.delete(pageId);
        hideLoadingSpinner(card);
    }
}

async function rotatePage(pageId, degrees) {
    const state = getPageStateForOperation(pageId);
    if (!state) return;

    const rotationMatrix = calculateRotationMatrix(degrees, state.currentState.width, state.currentState.height);
    const operation = `rotate ${degrees}° ${degrees > 0 ? 'CW' : 'CCW'}`;

    await applyPageTransformation(pageId, {
        transformMatrix: rotationMatrix,
        operation: operation,
        requestBody: { type: 'rotate', degrees: degrees },
        errorMessage: 'Failed to rotate page. Please try again.'
    });
}

async function mirrorPage(pageId, direction) {
    const state = getPageStateForOperation(pageId);
    if (!state) return;

    const mirrorMatrix = calculateMirrorMatrix(direction, state.currentState.width, state.currentState.height);
    const operation = `mirror ${direction === 'updown' ? 'vertical' : 'horizontal'}`;

    await applyPageTransformation(pageId, {
        transformMatrix: mirrorMatrix,
        operation: operation,
        requestBody: { type: 'mirror', direction: direction },
        errorMessage: 'Failed to mirror page. Please try again.'
    });
}

// Show loading spinner overlay
function showLoadingSpinner(card) {
    // Don't add if already present
    if (card.querySelector('.loading-overlay')) return;

    const overlay = document.createElement('div');
    overlay.className = 'loading-overlay';
    overlay.setAttribute('role', 'status');
    overlay.setAttribute('aria-label', 'Loading');

    const spinner = document.createElement('div');
    spinner.className = 'loading-spinner';
    spinner.setAttribute('aria-hidden', 'true');

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

// Show error message to user
function showErrorMessage(message) {
    // Create toast notification
    const toast = document.createElement('div');
    toast.setAttribute('role', 'alert');
    toast.style.cssText = `
        position: fixed;
        top: 20px;
        right: 20px;
        background: #d32f2f;
        color: white;
        padding: 15px 20px;
        border-radius: 6px;
        box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
        z-index: 10000;
        animation: slideInRight 0.3s ease-out;
        max-width: 400px;
    `;
    toast.textContent = message;

    document.body.appendChild(toast);

    // Auto-remove after 5 seconds
    setTimeout(() => {
        toast.style.opacity = '0';
        toast.style.transition = 'opacity 0.3s';
        setTimeout(() => toast.remove(), 300);
    }, 5000);
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

async function deletePage(pageId) {
    // Check if operation is already pending for this page
    if (pagePendingOperations.get(pageId)) {
        console.log('Operation already in progress for page:', pageId);
        return;
    }

    const card = document.querySelector(`.page-card-outer[data-page-id="${pageId}"]`);
    if (!card) return;

    const history = pageVersionStates.get(pageId);
    const currentVersion = pageCurrentVersion.get(pageId);

    if (!history || currentVersion === undefined) {
        console.error('Page state not initialized for:', pageId);
        return;
    }

    // Mark operation as pending
    pagePendingOperations.set(pageId, true);

    const currentState = history[currentVersion];

    // Check if page is already deleted
    const isDeleted = currentState.deleted;

    // Create new version state with toggled deleted flag
    const newState = {
        version: currentVersion + 1,
        operation: isDeleted ? 'undelete' : 'delete',
        matrix: currentState.matrix,
        width: currentState.width,
        height: currentState.height,
        deleted: !isDeleted
    };

    // Show loading spinner
    showLoadingSpinner(card);

    try {
        // Send to server for validation and persistence
        const response = await fetch(`/api/pages/${pageId}/operation`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'X-Session-ID': sessionId
            },
            body: JSON.stringify({
                type: 'delete',
                expected_version: currentVersion,
                new_state: newState
            })
        });

        const data = await response.json();

        if (data.success) {
            // Server accepted - update local state
            history.push(newState);
            pageCurrentVersion.set(pageId, newState.version);

            // Update UI - mark as deleted or undeleted
            card.setAttribute('data-deleted', newState.deleted ? 'true' : 'false');
            card.setAttribute('data-modified', newState.version > 0 ? 'true' : 'false');
            card.setAttribute('data-version', data.version);

            // Add reset button if modified
            if (newState.version > 0) {
                ensureResetButtonExists(pageId);
            }

            // Update delete button title
            const deleteBtn = card.querySelector('.btn-red');
            if (deleteBtn) {
                deleteBtn.setAttribute('title', newState.deleted ? 'Undelete' : 'Delete');
            }

            // Update document modified state
            const docId = pageId.split('-')[0];
            setDocumentModifiedState(docId, data.document_modified);

            // Update UI state
            updateResetButtonState();
            updateClearButtonConfirmation();
        } else {
            console.error('Delete operation rejected by server');
            showErrorMessage('Failed to delete/undelete page. Please try again.');
        }
    } catch (err) {
        console.error('Delete error:', err);
        showErrorMessage('Failed to delete/undelete page. Please try again.');
    } finally {
        // Clear pending flag
        pagePendingOperations.delete(pageId);
        hideLoadingSpinner(card);
    }
}

async function revertPage(pageId) {
    // Check if operation is already pending for this page
    if (pagePendingOperations.get(pageId)) {
        console.log('Operation already in progress for page:', pageId);
        return;
    }

    const card = document.querySelector(`.page-card-outer[data-page-id="${pageId}"]`);
    if (!card) return;

    // Mark operation as pending
    pagePendingOperations.set(pageId, true);

    // Store previous state for rollback
    const history = pageVersionStates.get(pageId);
    const currentVersion = pageCurrentVersion.get(pageId);
    const previousHistory = history ? [...history] : null;
    const previousVersion = currentVersion;
    const inner = card.querySelector('.page-card-inner');
    const previousInnerStyles = inner ? {
        transform: inner.style.transform,
        width: inner.style.width,
        height: inner.style.height,
        position: inner.style.position,
        left: inner.style.left,
        top: inner.style.top,
        transformOrigin: inner.style.transformOrigin
    } : null;
    const previousOuterStyles = {
        width: card.style.width,
        height: card.style.height
    };
    const wasDeleted = card.getAttribute('data-deleted') === 'true';
    const wasModified = card.getAttribute('data-modified') === 'true';

    // Apply reset immediately (optimistic update)
    pageVersionStates.delete(pageId);
    pageCurrentVersion.delete(pageId);

    // Reset all transform-related styles on inner element
    if (inner) {
        inner.style.transform = '';
        inner.style.width = '';
        inner.style.height = '';
        inner.style.position = '';
        inner.style.left = '';
        inner.style.top = '';
        inner.style.transformOrigin = '';
    }

    // Reset outer element dimensions
    card.style.width = '';
    card.style.height = '';

    card.setAttribute('data-deleted', 'false');
    card.setAttribute('data-modified', 'false');

    showLoadingSpinner(card);

    try {
        const response = await fetch(`/api/pages/${pageId}/revert/0`, {
            method: 'POST',
            headers: {
                'X-Session-ID': sessionId
            }
        });

        const data = await response.json();

        if (data.success) {
            // Server accepted - update version and remove buttons
            card.setAttribute('data-version', data.version);

            const resetBtn = card.querySelector('.btn-orange');
            if (resetBtn) {
                resetBtn.remove();
            }
            const revertBtn = card.querySelector('.revert-btn');
            if (revertBtn) {
                revertBtn.remove();
            }

            // Update document modified state
            const docId = pageId.split('-')[0];
            setDocumentModifiedState(docId, data.document_modified);

            // Reload thumbnail to show original state
            const img = card.querySelector('.page-thumbnail');
            if (img) {
                const timestamp = Date.now();
                const newSrc = `/api/pages/${pageId}/thumbnail?v=${timestamp}`;

                const tempImg = new Image();
                tempImg.onload = async () => {
                    img.src = newSrc;

                    // Reinitialize page state from server after reset
                    try {
                        const listData = await fetchJSON('/api/pages/list-json');

                        // Find this specific page and reinitialize its state
                        for (const doc of listData.documents) {
                            for (const page of doc.pages) {
                                if (page.id === pageId) {
                                    const originalVersion = page.version_history[0];
                                    if (originalVersion) {
                                        initializePageState(
                                            page.id,
                                            page.version_history,
                                            page.current_version,
                                            originalVersion.width,
                                            originalVersion.height
                                        );
                                    }
                                    break;
                                }
                            }
                        }
                    } catch (err) {
                        console.error('Failed to reinitialize page state after reset:', err);
                    }

                    // Clear pending flag
                    pagePendingOperations.delete(pageId);
                    hideLoadingSpinner(card);
                    updateResetButtonState();
                    updateClearButtonConfirmation();
                };
                tempImg.onerror = () => {
                    console.error('Failed to load reverted thumbnail');
                    // Clear pending flag
                    pagePendingOperations.delete(pageId);
                    hideLoadingSpinner(card);
                };
                tempImg.src = newSrc;
            } else {
                // Clear pending flag
                pagePendingOperations.delete(pageId);
                hideLoadingSpinner(card);
            }
        } else {
            // Server rejected - rollback to previous state
            console.error('Revert rejected by server');
            rollbackRevertState();
            showErrorMessage('Failed to reset page. Please try again.');
        }
    } catch (err) {
        console.error('Revert error:', err);
        rollbackRevertState();
        showErrorMessage('Failed to reset page. Please try again.');
    }

    function rollbackRevertState() {
        if (previousHistory) {
            pageVersionStates.set(pageId, previousHistory);
        }
        if (previousVersion !== undefined) {
            pageCurrentVersion.set(pageId, previousVersion);
        }
        if (inner && previousInnerStyles) {
            inner.style.transform = previousInnerStyles.transform;
            inner.style.width = previousInnerStyles.width;
            inner.style.height = previousInnerStyles.height;
            inner.style.position = previousInnerStyles.position;
            inner.style.left = previousInnerStyles.left;
            inner.style.top = previousInnerStyles.top;
            inner.style.transformOrigin = previousInnerStyles.transformOrigin;
        }
        card.style.width = previousOuterStyles.width;
        card.style.height = previousOuterStyles.height;
        card.setAttribute('data-deleted', wasDeleted ? 'true' : 'false');
        card.setAttribute('data-modified', wasModified ? 'true' : 'false');
        // Clear pending flag
        pagePendingOperations.delete(pageId);
        hideLoadingSpinner(card);
    }
}

// Reset page to initial state (same as revert - deletes all history and transformations)
function resetPage(pageId) {
    // Reset is the same as revert - both reset to version 0
    revertPage(pageId);
}

// Ensure reset button exists for a modified page
function ensureResetButtonExists(pageId) {
    const card = document.querySelector(`.page-card-outer[data-page-id="${pageId}"]`);
    if (!card) return;

    const overlay = card.querySelector('.page-overlay');
    if (!overlay) return;

    // Check if reset button already exists
    if (overlay.querySelector('.btn-orange')) return;

    // Create reset button
    const resetBtn = document.createElement('button');
    resetBtn.className = 'btn btn-round btn-orange btn-top-center';
    resetBtn.title = 'Reset to original';
    resetBtn.setAttribute('aria-label', 'Reset to original');
    resetBtn.onclick = function(e) {
        e.stopPropagation();
        resetPage(pageId);
    };
    resetBtn.innerHTML = '<svg class="icon icon-lg" fill="none" stroke="currentColor" stroke-width="2.5" viewBox="0 0 24 24" aria-hidden="true"><path stroke-linecap="round" stroke-linejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0l3.181 3.183a8.25 8.25 0 0013.803-3.7M4.031 9.865a8.25 8.25 0 0113.803-3.7l3.181 3.182m0-4.991v4.99" /></svg>';

    // Insert button after rotate-right button (or at beginning if not found)
    const rotateRightBtn = overlay.querySelector('.btn-top-right');
    if (rotateRightBtn) {
        rotateRightBtn.insertAdjacentElement('afterend', resetBtn);
    } else {
        overlay.insertBefore(resetBtn, overlay.firstChild);
    }
}


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
    document.querySelectorAll('.page-card-outer').forEach(card => {
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

// Update document modified state from backend response
function setDocumentModifiedState(docId, isModified) {
    // Find the document group
    const docGroup = document.querySelector(`.document-group[data-doc-id="${docId}"]`);
    if (!docGroup) return;

    // Update document group attribute
    docGroup.setAttribute('data-modified', isModified ? 'true' : 'false');
}

// Update document modified state based on its pages
function updateDocumentModifiedState(docId) {
    // Find the document group
    const docGroup = document.querySelector(`.document-group[data-doc-id="${docId}"]`);
    if (!docGroup) return;

    // Check if any page in this document is modified
    const pages = docGroup.querySelectorAll('.page-card-outer');
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
    e.detail.headers['X-Session-ID'] = sessionId;
});

// Download page or document choice with modal dialog
function downloadPageOrDocument(pageId, docId) {
    // Create modal overlay
    const modal = document.createElement('div');
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');
    modal.setAttribute('aria-labelledby', 'download-modal-title');
    modal.style.cssText = `
        position: fixed;
        top: 0;
        left: 0;
        width: 100%;
        height: 100%;
        background: rgba(0, 0, 0, 0.6);
        display: flex;
        align-items: center;
        justify-content: center;
        z-index: 10000;
        animation: fadeIn 0.2s ease-in;
    `;

    // Create modal content
    const modalContent = document.createElement('div');
    modalContent.style.cssText = `
        background: #2a2a2a;
        border-radius: 8px;
        padding: 30px;
        max-width: 500px;
        width: 90%;
        box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5);
        position: relative;
        animation: slideIn 0.3s ease-out;
    `;

    modalContent.innerHTML = `
        <style>
            @keyframes fadeIn {
                from { opacity: 0; }
                to { opacity: 1; }
            }
            @keyframes slideIn {
                from { transform: translateY(-20px); opacity: 0; }
                to { transform: translateY(0); opacity: 1; }
            }
        </style>
        <h2 id="download-modal-title" style="margin: 0 0 20px 0; color: #fff; font-size: 24px;">Download Options</h2>
        <p style="color: #ccc; margin: 0 0 30px 0; line-height: 1.6; font-size: 15px;">
            Choose what you'd like to download:
        </p>

        <div style="display: flex; flex-direction: column; gap: 15px;">
            <button id="download-page-only" style="
                padding: 15px 20px;
                background: #4a9eff;
                color: white;
                border: none;
                border-radius: 6px;
                font-size: 16px;
                font-weight: 500;
                cursor: pointer;
                transition: background 0.2s;
                text-align: left;
            ">
                <div style="font-weight: 600; margin-bottom: 5px;">📄 Download This Page Only</div>
                <div style="font-size: 13px; opacity: 0.9;">Save only the currently selected page as a PDF</div>
            </button>

            <button id="download-document" style="
                padding: 15px 20px;
                background: #5a5a5a;
                color: white;
                border: none;
                border-radius: 6px;
                font-size: 16px;
                font-weight: 500;
                cursor: pointer;
                transition: background 0.2s;
                text-align: left;
            ">
                <div style="font-weight: 600; margin-bottom: 5px;">📚 Download Entire Document</div>
                <div style="font-size: 13px; opacity: 0.9;">Save all pages in the document as a PDF</div>
            </button>
        </div>

        <button id="cancel-download" style="
            margin-top: 20px;
            padding: 10px;
            background: transparent;
            color: #888;
            border: none;
            font-size: 14px;
            cursor: pointer;
            width: 100%;
            transition: color 0.2s;
        ">Cancel</button>
    `;

    modal.appendChild(modalContent);
    document.body.appendChild(modal);

    // Add hover effects
    const pageBtn = modalContent.querySelector('#download-page-only');
    const docBtn = modalContent.querySelector('#download-document');
    const cancelBtn = modalContent.querySelector('#cancel-download');

    pageBtn.addEventListener('mouseenter', () => pageBtn.style.background = '#3a8eef');
    pageBtn.addEventListener('mouseleave', () => pageBtn.style.background = '#4a9eff');

    docBtn.addEventListener('mouseenter', () => docBtn.style.background = '#6a6a6a');
    docBtn.addEventListener('mouseleave', () => docBtn.style.background = '#5a5a5a');

    cancelBtn.addEventListener('mouseenter', () => cancelBtn.style.color = '#fff');
    cancelBtn.addEventListener('mouseleave', () => cancelBtn.style.color = '#888');

    // Close modal function
    function closeModal() {
        modal.style.opacity = '0';
        setTimeout(() => modal.remove(), 200);
    }

    // Button handlers
    pageBtn.addEventListener('click', () => {
        closeModal();
        window.location.href = `/api/pages/${pageId}/download`;
    });

    docBtn.addEventListener('click', () => {
        closeModal();
        window.location.href = `/api/documents/${docId}/download`;
    });

    cancelBtn.addEventListener('click', closeModal);

    // Close on background click
    modal.addEventListener('click', (e) => {
        if (e.target === modal) closeModal();
    });

    // Close on Escape key
    const escHandler = (e) => {
        if (e.key === 'Escape') {
            closeModal();
            document.removeEventListener('keydown', escHandler);
        }
    };
    document.addEventListener('keydown', escHandler);
}

// Preload images before htmx swaps to prevent visual collapse
document.body.addEventListener('htmx:beforeSwap', (evt) => {
    // Only process page card swaps
    if (!evt.detail.target || !evt.detail.target.classList.contains('page-card-outer')) {
        return;
    }

    // Parse the response HTML to find images
    const parser = new DOMParser();
    const doc = parser.parseFromString(evt.detail.serverResponse, 'text/html');
    const images = doc.querySelectorAll('img.page-thumbnail');

    if (images.length === 0) {
        return;
    }

    // Prevent the default swap
    evt.preventDefault();

    // Preload all images before allowing the swap
    const imageLoadPromises = Array.from(images).map(img => {
        return new Promise((resolve) => {
            const preloadImg = new Image();
            preloadImg.onload = () => resolve();
            preloadImg.onerror = () => resolve(); // Continue even if image fails
            preloadImg.src = img.src;

            // Timeout after 3 seconds
            setTimeout(() => resolve(), 3000);
        });
    });

    // Wait for images to load, then perform the swap manually
    Promise.all(imageLoadPromises).then(() => {
        // Manually swap the content
        const newContent = doc.body.firstElementChild;
        if (newContent && evt.detail.target) {
            const oldElement = evt.detail.target;
            const parent = oldElement.parentElement;

            // Insert new element before old one
            parent.insertBefore(newContent, oldElement);

            // Remove old element
            oldElement.remove();

            // CRITICAL: Tell htmx to process the new element so hx-* attributes work
            htmx.process(newContent);
        }
    });
});

// =============================================================================
// Page Loading and Initialization
// =============================================================================

/**
 * Load pages from server and initialize version states
 */
async function loadPagesAndInitialize() {
    try {
        const data = await fetchJSON('/api/pages/list-json');

        // Iterate through documents and pages
        for (const doc of data.documents) {
            for (const page of doc.pages) {
                // Get original dimensions from version history (version 0)
                const originalVersion = page.version_history[0];
                if (!originalVersion) {
                    console.error('No original version for page:', page.id);
                    continue;
                }

                // Initialize page state
                initializePageState(
                    page.id,
                    page.version_history,
                    page.current_version,
                    originalVersion.width,
                    originalVersion.height
                );
            }
        }

        console.log('Initialized version states for', pageVersionStates.size, 'pages');
    } catch (err) {
        console.error('Failed to load and initialize pages:', err);
    }
}

// Load and initialize on page load
window.addEventListener('load', () => {
    // Check if we're using the new JSON API by looking for page cards
    const pageCards = document.querySelectorAll('.page-card-outer');
    if (pageCards.length > 0) {
        loadPagesAndInitialize();

        // Add reset buttons to already-modified pages
        pageCards.forEach(card => {
            const isModified = card.getAttribute('data-modified') === 'true';
            if (isModified) {
                const pageId = card.getAttribute('data-page-id');
                if (pageId) {
                    ensureResetButtonExists(pageId);
                }
            }
        });
    }
});

// Re-initialize after htmx swaps (when pages are dynamically added)
document.body.addEventListener('htmx:afterSwap', () => {
    loadPagesAndInitialize();
});

console.log('pdfzig WebUI initialized with session ID:', sessionId);
