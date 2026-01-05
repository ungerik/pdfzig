#!/bin/bash
set -e

# Change to project root directory
cd "$(dirname "$0")/.."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== pdfzig Release Script ===${NC}\n"

# Get version from build.zig.zon
if [ -f "build.zig.zon" ]; then
    BUILD_VERSION=$(grep -o '\.version = "[^"]*"' build.zig.zon | head -1 | sed 's/\.version = "\(.*\)"/\1/')
    echo -e "${YELLOW}Version in build.zig.zon:${NC} $BUILD_VERSION"
else
    echo -e "${RED}Warning: build.zig.zon not found${NC}"
    BUILD_VERSION="unknown"
fi

echo ""

# List existing tags
echo -e "${YELLOW}Existing release tags:${NC}"
TAGS=$(git tag -l 'v*' --sort=-v:refname 2>/dev/null)
if [ -z "$TAGS" ]; then
    echo "  (no release tags found)"
else
    echo "$TAGS" | head -10 | while read tag; do
        echo "  $tag"
    done
    TAG_COUNT=$(echo "$TAGS" | wc -l | tr -d ' ')
    if [ "$TAG_COUNT" -gt 10 ]; then
        echo "  ... and $((TAG_COUNT - 10)) more"
    fi
fi

echo ""

# Ask for new version
echo -e "${YELLOW}Enter new version (e.g., 0.2.0) or press Enter to cancel:${NC}"
read -p "> v" NEW_VERSION

if [ -z "$NEW_VERSION" ]; then
    echo -e "${BLUE}Cancelled.${NC}"
    exit 0
fi

# Validate version format (basic check)
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    echo -e "${RED}Error: Invalid version format. Expected: X.Y.Z or X.Y.Z-suffix${NC}"
    exit 1
fi

TAG="v$NEW_VERSION"

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo -e "${RED}Error: Tag $TAG already exists${NC}"
    exit 1
fi

# Confirm tag creation
echo ""
echo -e "${YELLOW}Create tag ${GREEN}$TAG${YELLOW} on current commit?${NC}"
git log -1 --oneline
read -p "[y/N] " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Cancelled.${NC}"
    exit 0
fi

# Create the tag
git tag "$TAG"
echo -e "${GREEN}Created tag $TAG${NC}"

# Ask to push
echo ""
echo -e "${YELLOW}Push tag to origin? This will trigger the release workflow.${NC}"
read -p "[y/N] " PUSH_CONFIRM

if [[ "$PUSH_CONFIRM" =~ ^[Yy]$ ]]; then
    git push origin "$TAG"
    echo -e "${GREEN}Pushed $TAG to origin${NC}"
    echo ""
    echo -e "${BLUE}Release workflow started. Check:${NC}"
    echo "  https://github.com/$(git remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/' | sed 's/.*github.com[:/]\(.*\)/\1/')/actions"
else
    echo -e "${YELLOW}Tag created locally but not pushed.${NC}"
    echo "To push later: git push origin $TAG"
    echo "To delete:     git tag -d $TAG"
fi
