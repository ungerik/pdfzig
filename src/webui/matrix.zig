//! PDF transformation matrix operations
//! Based on PDFium's FS_MATRIX structure for non-destructive transformations

const std = @import("std");

/// PDF transformation matrix (2D affine transformation)
/// Represents: [a c e]
///             [b d f]
///             [0 0 1]
/// Transforms point (x, y) to (ax + cy + e, bx + dy + f)
pub const Matrix = struct {
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    e: f64,
    f: f64,

    /// Identity matrix (no transformation)
    pub const identity = Matrix{ .a = 1, .b = 0, .c = 0, .d = 1, .e = 0, .f = 0 };

    /// Multiply two matrices: result = m1 × m2
    /// This composes transformations: apply m1 first, then m2
    pub fn multiply(m1: Matrix, m2: Matrix) Matrix {
        return .{
            .a = m1.a * m2.a + m1.b * m2.c,
            .b = m1.a * m2.b + m1.b * m2.d,
            .c = m1.c * m2.a + m1.d * m2.c,
            .d = m1.c * m2.b + m1.d * m2.d,
            .e = m1.e * m2.a + m1.f * m2.c + m2.e,
            .f = m1.e * m2.b + m1.f * m2.d + m2.f,
        };
    }

    /// Create rotation matrix for 90-degree increments
    /// @param degrees: Rotation angle (0, 90, 180, 270, or -90)
    /// @param width: Current page width
    /// @param height: Current page height
    pub fn rotation(degrees: i32, width: f64, height: f64) Matrix {
        const normalized = @mod(degrees, 360);
        return switch (normalized) {
            90, -270 => .{ .a = 0, .b = 1, .c = -1, .d = 0, .e = height, .f = 0 },
            180, -180 => .{ .a = -1, .b = 0, .c = 0, .d = -1, .e = width, .f = height },
            270, -90 => .{ .a = 0, .b = -1, .c = 1, .d = 0, .e = 0, .f = width },
            else => identity,
        };
    }

    /// Create horizontal mirror matrix (flip left-right)
    /// @param width: Current page width
    pub fn mirrorHorizontal(width: f64) Matrix {
        return .{ .a = -1, .b = 0, .c = 0, .d = 1, .e = width, .f = 0 };
    }

    /// Create vertical mirror matrix (flip up-down)
    /// @param height: Current page height
    pub fn mirrorVertical(height: f64) Matrix {
        return .{ .a = 1, .b = 0, .c = 0, .d = -1, .e = 0, .f = height };
    }

    /// Check if matrix is identity (no transformation)
    pub fn isIdentity(self: Matrix) bool {
        const epsilon = 1e-6;
        return @abs(self.a - 1.0) < epsilon and
            @abs(self.b) < epsilon and
            @abs(self.c) < epsilon and
            @abs(self.d - 1.0) < epsilon and
            @abs(self.e) < epsilon and
            @abs(self.f) < epsilon;
    }

    /// Calculate resulting dimensions after applying this matrix
    /// Returns the bounding box of the transformed page
    pub fn transformDimensions(self: Matrix, width: f64, height: f64) struct { width: f64, height: f64 } {
        // Transform all four corners and find bounding box
        const corners = [_][2]f64{
            .{ 0, 0 },
            .{ width, 0 },
            .{ width, height },
            .{ 0, height },
        };

        var min_x = std.math.floatMax(f64);
        var max_x = std.math.floatMin(f64);
        var min_y = std.math.floatMax(f64);
        var max_y = std.math.floatMin(f64);

        for (corners) |corner| {
            const x = corner[0];
            const y = corner[1];
            const tx = self.a * x + self.c * y + self.e;
            const ty = self.b * x + self.d * y + self.f;

            min_x = @min(min_x, tx);
            max_x = @max(max_x, tx);
            min_y = @min(min_y, ty);
            max_y = @max(max_y, ty);
        }

        return .{
            .width = max_x - min_x,
            .height = max_y - min_y,
        };
    }
};

test "identity matrix" {
    const m = Matrix.identity;
    try std.testing.expect(m.isIdentity());

    const dims = m.transformDimensions(612, 792);
    try std.testing.expectEqual(612.0, dims.width);
    try std.testing.expectEqual(792.0, dims.height);
}

test "rotation 90 degrees" {
    const m = Matrix.rotation(90, 612, 792);
    const dims = m.transformDimensions(612, 792);

    // After 90° rotation, width and height are swapped
    try std.testing.expectApproxEqAbs(792.0, dims.width, 0.001);
    try std.testing.expectApproxEqAbs(612.0, dims.height, 0.001);
}

test "mirror horizontal" {
    const m = Matrix.mirrorHorizontal(612);
    const dims = m.transformDimensions(612, 792);

    // Mirroring doesn't change dimensions
    try std.testing.expectEqual(612.0, dims.width);
    try std.testing.expectEqual(792.0, dims.height);
}

test "matrix multiplication - rotate then mirror" {
    const rotate = Matrix.rotation(90, 612, 792);
    const mirror = Matrix.mirrorHorizontal(792); // Use rotated width
    const combined = Matrix.multiply(rotate, mirror);

    // Should not be identity
    try std.testing.expect(!combined.isIdentity());
}

test "double rotation returns to identity" {
    const rotate180a = Matrix.rotation(180, 612, 792);
    const rotate180b = Matrix.rotation(180, 612, 792);
    const combined = Matrix.multiply(rotate180a, rotate180b);

    // Two 180° rotations should return to identity
    try std.testing.expect(combined.isIdentity());
}
