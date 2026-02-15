//! Transformation matrix for PDF page transformations
//! Uses 2D affine transformation matrices to represent rotations, mirrors, and their compositions

const std = @import("std");
const pdfium = @import("../pdfium/pdfium.zig");

/// 2D Affine Transformation Matrix
/// Represents transformations as: [a c e]
///                                 [b d f]
///                                 [0 0 1]
/// Transforms point (x, y) to (ax + cy + e, bx + dy + f)
pub const TransformationMatrix = struct {
    /// Matrix elements: [a, b, c, d, e, f]
    /// PDFium uses this order for FPDFPageObj_Transform
    data: [6]f64,

    /// Identity matrix (no transformation)
    pub const identity = TransformationMatrix{ .data = .{ 1, 0, 0, 1, 0, 0 } };

    /// Create identity matrix
    pub fn init() TransformationMatrix {
        return identity;
    }

    /// Create rotation matrix for 90-degree increments
    /// @param degrees: Rotation angle (0, 90, 180, 270)
    /// @param page_width: PDF page width in points
    /// @param page_height: PDF page height in points
    pub fn rotation(degrees: i32, page_width: f64, page_height: f64) TransformationMatrix {
        // Normalize degrees to 0-360 range
        const normalized = @mod(degrees, 360);

        return switch (normalized) {
            90 => .{ .data = .{ 0, 1, -1, 0, page_height, 0 } },
            180 => .{ .data = .{ -1, 0, 0, -1, page_width, page_height } },
            270 => .{ .data = .{ 0, -1, 1, 0, 0, page_width } },
            -90 => .{ .data = .{ 0, -1, 1, 0, 0, page_width } }, // Same as 270
            -180 => .{ .data = .{ -1, 0, 0, -1, page_width, page_height } }, // Same as 180
            -270 => .{ .data = .{ 0, 1, -1, 0, page_height, 0 } }, // Same as 90
            else => identity,
        };
    }

    /// Create horizontal mirror matrix (flip left-right)
    /// @param page_width: PDF page width in points
    pub fn mirrorHorizontal(page_width: f64) TransformationMatrix {
        return .{ .data = .{ -1, 0, 0, 1, page_width, 0 } };
    }

    /// Create vertical mirror matrix (flip up-down)
    /// @param page_height: PDF page height in points
    pub fn mirrorVertical(page_height: f64) TransformationMatrix {
        return .{ .data = .{ 1, 0, 0, -1, 0, page_height } };
    }

    /// Compose two transformation matrices via matrix multiplication
    /// Returns: self × other (apply self first, then other)
    /// @param other: Matrix to compose with
    pub fn compose(self: TransformationMatrix, other: TransformationMatrix) TransformationMatrix {
        const a1 = self.data[0];
        const b1 = self.data[1];
        const c1 = self.data[2];
        const d1 = self.data[3];
        const e1 = self.data[4];
        const f1 = self.data[5];

        const a2 = other.data[0];
        const b2 = other.data[1];
        const c2 = other.data[2];
        const d2 = other.data[3];
        const e2 = other.data[4];
        const f2 = other.data[5];

        // Matrix multiplication formula for 2D affine transforms
        return .{
            .data = .{
                a1 * a2 + c1 * b2, // a
                b1 * a2 + d1 * b2, // b
                a1 * c2 + c1 * d2, // c
                b1 * c2 + d1 * d2, // d
                a1 * e2 + c1 * f2 + e1, // e
                b1 * e2 + d1 * f2 + f1, // f
            },
        };
    }

    /// Apply transformation to PDFium page object
    /// @param obj: PDFium page object to transform
    pub fn applyToObject(self: TransformationMatrix, obj: pdfium.PageObject) void {
        obj.transform(
            self.data[0],
            self.data[1],
            self.data[2],
            self.data[3],
            self.data[4],
            self.data[5],
        );
    }

    /// Check if matrix is identity (no transformation) within floating-point tolerance
    /// Uses epsilon to handle accumulated floating-point errors from matrix composition
    pub fn isIdentity(self: TransformationMatrix) bool {
        // Epsilon chosen to handle typical floating-point errors
        // After 4× 90° rotation, errors are typically < 1e-12
        // After 10× compositions, errors typically < 1e-9
        // 1e-6 provides comfortable margin
        const epsilon = 1e-6; // 0.000001 tolerance

        return @abs(self.data[0] - 1.0) < epsilon and // a ≈ 1
            @abs(self.data[1]) < epsilon and // b ≈ 0
            @abs(self.data[2]) < epsilon and // c ≈ 0
            @abs(self.data[3] - 1.0) < epsilon and // d ≈ 1
            @abs(self.data[4]) < epsilon and // e ≈ 0
            @abs(self.data[5]) < epsilon; // f ≈ 0
    }
};

/// Transformation operation types
pub const TransformationOp = enum {
    rotate_left, // -90° (or +270°)
    rotate_right, // +90°
    rotate_180, // +180°
    mirror_horizontal, // flip left-right
    mirror_vertical, // flip up-down
};

/// Apply a transformation operation to an existing matrix
/// @param current_matrix: Current transformation state
/// @param op: Operation to apply
/// @param page_width: PDF page width in points
/// @param page_height: PDF page height in points
/// @return: New matrix with operation composed
pub fn applyOp(
    current_matrix: TransformationMatrix,
    op: TransformationOp,
    page_width: f64,
    page_height: f64,
) TransformationMatrix {
    const op_matrix = switch (op) {
        .rotate_left => TransformationMatrix.rotation(-90, page_width, page_height),
        .rotate_right => TransformationMatrix.rotation(90, page_width, page_height),
        .rotate_180 => TransformationMatrix.rotation(180, page_width, page_height),
        .mirror_horizontal => TransformationMatrix.mirrorHorizontal(page_width),
        .mirror_vertical => TransformationMatrix.mirrorVertical(page_height),
    };

    // Compose: new_matrix = current_matrix × op_matrix
    return current_matrix.compose(op_matrix);
}
