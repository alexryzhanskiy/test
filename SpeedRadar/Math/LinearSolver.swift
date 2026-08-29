import Foundation

/// Dense linear algebra helpers used by the calibration and trajectory fits.
///
/// The systems solved here are tiny (at most 8x8), so a straightforward
/// Gaussian elimination with partial pivoting is both fast enough and easier to
/// reason about than pulling in a larger dependency.
enum LinearSolver {

    /// Solves `A x = b` for a square, row-major matrix `A` of size `n x n`.
    /// Returns `nil` when the system is singular to working precision.
    static func solve(matrix: [Double], vector: [Double], size n: Int) -> [Double]? {
        precondition(matrix.count == n * n)
        precondition(vector.count == n)

        var a = matrix
        var b = vector

        for pivot in 0..<n {
            // Partial pivoting keeps the elimination numerically stable.
            var maxRow = pivot
            var maxValue = abs(a[pivot * n + pivot])
            for row in (pivot + 1)..<n {
                let value = abs(a[row * n + pivot])
                if value > maxValue {
                    maxValue = value
                    maxRow = row
                }
            }
            guard maxValue > 1e-12 else { return nil }

            if maxRow != pivot {
                for column in 0..<n {
                    a.swapAt(pivot * n + column, maxRow * n + column)
                }
                b.swapAt(pivot, maxRow)
            }

            let pivotValue = a[pivot * n + pivot]
            for row in (pivot + 1)..<n {
                let factor = a[row * n + pivot] / pivotValue
                guard factor != 0 else { continue }
                for column in pivot..<n {
                    a[row * n + column] -= factor * a[pivot * n + column]
                }
                b[row] -= factor * b[pivot]
            }
        }

        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for column in (row + 1)..<n {
                sum -= a[row * n + column] * x[column]
            }
            x[row] = sum / a[row * n + row]
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }

    /// Least-squares solution of an over-determined system via normal equations.
    ///
    /// - Parameters:
    ///   - rows: Each row of the design matrix `A`, all of length `unknowns`.
    ///   - values: The right-hand side `b`, one entry per row.
    ///   - unknowns: Number of unknowns (columns of `A`).
    static func leastSquares(rows: [[Double]], values: [Double], unknowns n: Int) -> [Double]? {
        guard rows.count == values.count, rows.count >= n else { return nil }

        var ata = [Double](repeating: 0, count: n * n)
        var atb = [Double](repeating: 0, count: n)

        for (row, value) in zip(rows, values) {
            precondition(row.count == n)
            for i in 0..<n {
                atb[i] += row[i] * value
                for j in 0..<n {
                    ata[i * n + j] += row[i] * row[j]
                }
            }
        }

        return solve(matrix: ata, vector: atb, size: n)
    }
}
