//! Tests for transformation matrix operations

const std = @import("std");
const transformation_matrix = @import("transformation_matrix.zig");
const TransformationMatrix = transformation_matrix.TransformationMatrix;

test "identity matrix is unchanged by composition" {
    const identity = TransformationMatrix.init();
    const rotation = TransformationMatrix.rotation(90, 100, 200);

    const result = identity.compose(rotation);
    try std.testing.expectEqualSlices(f64, &rotation.data, &result.data);
}

test "H mirror + V mirror equals 180° rotation" {
    const page_w: f64 = 612.0;
    const page_h: f64 = 792.0;

    const h_mirror = TransformationMatrix.mirrorHorizontal(page_w);
    const v_mirror = TransformationMatrix.mirrorVertical(page_h);
    const hv_composed = h_mirror.compose(v_mirror);

    const rotation_180 = TransformationMatrix.rotation(180, page_w, page_h);

    // Matrices should be equivalent within floating-point epsilon
    const epsilon = 0.0001;
    for (hv_composed.data, rotation_180.data) |a, b| {
        try std.testing.expect(@abs(a - b) < epsilon);
    }
}

test "double mirror returns to identity" {
    const page_w: f64 = 612.0;
    const h_mirror = TransformationMatrix.mirrorHorizontal(page_w);
    const double_mirror = h_mirror.compose(h_mirror);

    try std.testing.expect(double_mirror.isIdentity());
}

test "four 90° rotations return to identity" {
    const page_w: f64 = 612.0;
    const page_h: f64 = 792.0;

    var matrix = TransformationMatrix.init();
    matrix = matrix.compose(TransformationMatrix.rotation(90, page_w, page_h));
    matrix = matrix.compose(TransformationMatrix.rotation(90, page_w, page_h));
    matrix = matrix.compose(TransformationMatrix.rotation(90, page_w, page_h));
    matrix = matrix.compose(TransformationMatrix.rotation(90, page_w, page_h));

    // Should detect identity despite floating-point rounding
    try std.testing.expect(matrix.isIdentity());
}

test "two 180° rotations return to identity" {
    const page_w: f64 = 612.0;
    const page_h: f64 = 792.0;

    var matrix = TransformationMatrix.init();
    matrix = matrix.compose(TransformationMatrix.rotation(180, page_w, page_h));
    matrix = matrix.compose(TransformationMatrix.rotation(180, page_w, page_h));

    try std.testing.expect(matrix.isIdentity());
}

test "double vertical mirror returns to identity" {
    const page_h: f64 = 792.0;
    const v_mirror = TransformationMatrix.mirrorVertical(page_h);

    var matrix = TransformationMatrix.init();
    matrix = matrix.compose(v_mirror);
    matrix = matrix.compose(v_mirror);

    try std.testing.expect(matrix.isIdentity());
}

test "90° + 270° rotation returns to identity" {
    const page_w: f64 = 612.0;
    const page_h: f64 = 792.0;

    var matrix = TransformationMatrix.init();
    matrix = matrix.compose(TransformationMatrix.rotation(90, page_w, page_h));
    matrix = matrix.compose(TransformationMatrix.rotation(270, page_w, page_h));

    try std.testing.expect(matrix.isIdentity());
}

test "identity matrix is recognized" {
    const identity = TransformationMatrix.init();
    try std.testing.expect(identity.isIdentity());
}

test "rotation matrix is not identity" {
    const rotation = TransformationMatrix.rotation(90, 100, 200);
    try std.testing.expect(!rotation.isIdentity());
}

test "mirror matrix is not identity" {
    const mirror = TransformationMatrix.mirrorHorizontal(612.0);
    try std.testing.expect(!mirror.isIdentity());
}

test "composition is associative" {
    const page_w: f64 = 612.0;
    const page_h: f64 = 792.0;

    const a = TransformationMatrix.rotation(90, page_w, page_h);
    const b = TransformationMatrix.mirrorHorizontal(page_w);
    const c = TransformationMatrix.mirrorVertical(page_h);

    // (a * b) * c should equal a * (b * c)
    const ab_c = a.compose(b).compose(c);
    const a_bc = a.compose(b.compose(c));

    const epsilon = 1e-10;
    for (ab_c.data, a_bc.data) |x, y| {
        try std.testing.expect(@abs(x - y) < epsilon);
    }
}

test "negative rotation (-90°) equals 270°" {
    const page_w: f64 = 612.0;
    const page_h: f64 = 792.0;

    const rot_neg90 = TransformationMatrix.rotation(-90, page_w, page_h);
    const rot_270 = TransformationMatrix.rotation(270, page_w, page_h);

    const epsilon = 1e-10;
    for (rot_neg90.data, rot_270.data) |a, b| {
        try std.testing.expect(@abs(a - b) < epsilon);
    }
}
