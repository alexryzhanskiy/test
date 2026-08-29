import CoreGraphics
import Foundation

/// A 3-component vector of doubles used for homogeneous image/court coordinates
/// and for 3D points expressed in the court or camera frame.
struct Vec3: Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = Vec3(0, 0, 0)

    var lengthSquared: Double { x * x + y * y + z * z }
    var length: Double { lengthSquared.squareRoot() }

    var normalized: Vec3 {
        let l = length
        guard l > .ulpOfOne else { return self }
        return self / l
    }

    /// Perspective divide. Returns `nil` when the point is on (or behind) the
    /// camera's principal plane, where the division is not meaningful.
    var dehomogenized: CGPoint? {
        guard abs(z) > 1e-12 else { return nil }
        return CGPoint(x: x / z, y: y / z)
    }

    func dot(_ other: Vec3) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: Vec3) -> Vec3 {
        Vec3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }

    static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    static func * (lhs: Vec3, rhs: Double) -> Vec3 {
        Vec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    static func * (lhs: Double, rhs: Vec3) -> Vec3 { rhs * lhs }

    static func / (lhs: Vec3, rhs: Double) -> Vec3 {
        Vec3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
    }

    static prefix func - (value: Vec3) -> Vec3 { Vec3(-value.x, -value.y, -value.z) }
}

/// A row-major 3x3 matrix.
///
/// Row-major storage is used deliberately: every formula in this project is
/// written the way it appears in the multiple-view-geometry literature, and
/// keeping the memory layout in the same order avoids transposition mistakes.
struct Mat3: Equatable {
    /// Nine elements, row-major: `[m00, m01, m02, m10, ...]`.
    private(set) var elements: [Double]

    init(_ elements: [Double]) {
        precondition(elements.count == 9, "Mat3 requires exactly 9 elements")
        self.elements = elements
    }

    init(rows r0: Vec3, _ r1: Vec3, _ r2: Vec3) {
        self.init([r0.x, r0.y, r0.z, r1.x, r1.y, r1.z, r2.x, r2.y, r2.z])
    }

    init(columns c0: Vec3, _ c1: Vec3, _ c2: Vec3) {
        self.init([
            c0.x, c1.x, c2.x,
            c0.y, c1.y, c2.y,
            c0.z, c1.z, c2.z,
        ])
    }

    static let identity = Mat3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    subscript(row: Int, column: Int) -> Double {
        get { elements[row * 3 + column] }
        set { elements[row * 3 + column] = newValue }
    }

    func row(_ index: Int) -> Vec3 {
        Vec3(self[index, 0], self[index, 1], self[index, 2])
    }

    func column(_ index: Int) -> Vec3 {
        Vec3(self[0, index], self[1, index], self[2, index])
    }

    var transposed: Mat3 {
        Mat3(columns: row(0), row(1), row(2))
    }

    var determinant: Double {
        self[0, 0] * (self[1, 1] * self[2, 2] - self[1, 2] * self[2, 1])
            - self[0, 1] * (self[1, 0] * self[2, 2] - self[1, 2] * self[2, 0])
            + self[0, 2] * (self[1, 0] * self[2, 1] - self[1, 1] * self[2, 0])
    }

    /// Classical adjugate inverse. Returns `nil` for singular matrices.
    var inverted: Mat3? {
        let det = determinant
        guard abs(det) > 1e-14 else { return nil }
        let invDet = 1.0 / det
        var result = Mat3.identity
        result[0, 0] = (self[1, 1] * self[2, 2] - self[1, 2] * self[2, 1]) * invDet
        result[0, 1] = (self[0, 2] * self[2, 1] - self[0, 1] * self[2, 2]) * invDet
        result[0, 2] = (self[0, 1] * self[1, 2] - self[0, 2] * self[1, 1]) * invDet
        result[1, 0] = (self[1, 2] * self[2, 0] - self[1, 0] * self[2, 2]) * invDet
        result[1, 1] = (self[0, 0] * self[2, 2] - self[0, 2] * self[2, 0]) * invDet
        result[1, 2] = (self[0, 2] * self[1, 0] - self[0, 0] * self[1, 2]) * invDet
        result[2, 0] = (self[1, 0] * self[2, 1] - self[1, 1] * self[2, 0]) * invDet
        result[2, 1] = (self[0, 1] * self[2, 0] - self[0, 0] * self[2, 1]) * invDet
        result[2, 2] = (self[0, 0] * self[1, 1] - self[0, 1] * self[1, 0]) * invDet
        return result
    }

    static func * (lhs: Mat3, rhs: Mat3) -> Mat3 {
        var result = Mat3.identity
        for r in 0..<3 {
            for c in 0..<3 {
                result[r, c] =
                    lhs[r, 0] * rhs[0, c] + lhs[r, 1] * rhs[1, c] + lhs[r, 2] * rhs[2, c]
            }
        }
        return result
    }

    static func * (lhs: Mat3, rhs: Vec3) -> Vec3 {
        Vec3(lhs.row(0).dot(rhs), lhs.row(1).dot(rhs), lhs.row(2).dot(rhs))
    }

    static func * (lhs: Mat3, rhs: Double) -> Mat3 {
        Mat3(lhs.elements.map { $0 * rhs })
    }

    /// Applies the matrix as a 2D projective transform.
    func project(_ point: CGPoint) -> CGPoint? {
        (self * Vec3(Double(point.x), Double(point.y), 1)).dehomogenized
    }
}
