import simd

func matrixRows(_ matrix: simd_float4x4) -> [[Double]] {
    (0..<4).map { row in (0..<4).map { column in Double(matrix[column][row]) } }
}

// Call only after validating dimensions and a rigid transform.
func matrixFromRows(_ rows: [[Double]]) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4(Float(rows[0][0]), Float(rows[1][0]), Float(rows[2][0]), Float(rows[3][0])),
        SIMD4(Float(rows[0][1]), Float(rows[1][1]), Float(rows[2][1]), Float(rows[3][1])),
        SIMD4(Float(rows[0][2]), Float(rows[1][2]), Float(rows[2][2]), Float(rows[3][2])),
        SIMD4(Float(rows[0][3]), Float(rows[1][3]), Float(rows[2][3]), Float(rows[3][3]))))
}
