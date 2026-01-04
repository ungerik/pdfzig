#!/bin/sh
# Clean all cached data and build artifacts

set -e

cd "$(dirname "$0")"

echo "Cleaning build artifacts..."
rm -rf zig-out/
rm -rf .zig-cache/

echo "Cleaning test cache..."
rm -rf test-cache/

echo "Done."
