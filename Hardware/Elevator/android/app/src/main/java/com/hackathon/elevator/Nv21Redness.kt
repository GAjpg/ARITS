package com.hackathon.elevator

/**
 * 相机帧(NV21) → 「红色强度」图。
 *
 * ## 为什么是「红色强度」
 * 电梯厅那个楼层屏是**红点阵**，周围是不锈钢/墙/蓝灯（轿厢里的屏是蓝的）。
 * 看亮度（Y）会被反光、灯光骗；可靠的判据是「这一块比周围更红」——
 * 也就是 `r - max(g, b)`：[DotMatrixReader] 用的就是它，非红的东西会掉到 0 附近。
 *
 * ## 为什么可以只看色度(U/V)
 * `r - max(g, b)` 里的 **Y 会抵消**（r 和 g/b 都含一样的 Y），所以直接从 NV21 的
 * 交错色度平面算就够了，不必把整幅 YUV 转成 RGB。
 * 系数用 BT.601（与 Android 相机/JPEG 一致），算出来与 [DotMatrixReader] 从 ARGB
 * 算的红色强度**同一量纲(0~255)**，所以那边的阈值可以原样沿用。
 *
 * 纯计算、零 Android 依赖，可离线单测。
 */
object Nv21Redness {

    /** R-G = 2.116·(V-128) + 0.344·(U-128) */
    private const val RG_V = 2.116f
    private const val RG_U = 0.344f

    /** R-B = 1.402·(V-128) - 1.772·(U-128) */
    private const val RB_V = 1.402f
    private const val RB_U = 1.772f

    /**
     * 把 NV21 图像写成红色强度图。
     *
     * @param nv21  NV21 数据（前面 w*h 个 Y，后面交错 VU）
     * @param w     图像宽
     * @param h     图像高
     * @param scale 降采样倍数：每 scale×scale 个像素合成 1 个，取其中**最红**的那个
     *              （取最大而不是平均：红点很小，平均会被旁边的不锈钢冲淡）
     * @param out   输出缓冲，至少 (w/scale)*(h/scale) 个
     * @return 输出宽度 ow（= ceil(w/scale)）
     */
    fun fill(nv21: ByteArray, w: Int, h: Int, scale: Int, out: FloatArray): Int {
        require(w > 0 && h > 0) { "图像尺寸非法: ${w}x$h" }
        require(scale >= 1) { "scale 必须 >= 1" }
        val ow = (w + scale - 1) / scale
        val oh = (h + scale - 1) / scale
        require(out.size >= ow * oh) { "输出缓冲太小：需要 ${ow * oh}，实际 ${out.size}" }

        val ySize = w * h
        val n = nv21.size

        for (oy in 0 until oh) {
            val y0 = oy * scale
            val y1 = minOf(y0 + scale, h)
            var oi = oy * ow
            for (ox in 0 until ow) {
                val x0 = ox * scale
                val x1 = minOf(x0 + scale, w)
                var best = 0f
                var y = y0
                while (y < y1) {
                    val row = ySize + (y shr 1) * w      // 色度是 2×2 一组，行号减半
                    var x = x0
                    while (x < x1) {
                        val ci = row + (x and 0x7FFFFFFE) // 取这一组左上角那个 (V,U)
                        if (ci + 1 < n) {
                            val cv = (nv21[ci].toInt() and 0xFF) - 128
                            val cu = (nv21[ci + 1].toInt() and 0xFF) - 128
                            val rg = RG_V * cv + RG_U * cu          // R - G
                            val rb = RB_V * cv - RB_U * cu          // R - B
                            val red = if (rg < rb) rg else rb       // R - max(G, B)
                            if (red > best) best = red
                        }
                        x++
                    }
                    y++
                }
                out[oi++] = if (best > 0f) best else 0f
            }
        }
        return ow
    }

    /**
     * 造一帧 NV21（给离线自测用）：把 ARGB 图按 BT.601 转成 YUV420SP。
     * 真机上不需要它。
     */
    fun fromArgb(argb: IntArray, w: Int, h: Int): ByteArray {
        val out = ByteArray(w * h * 3 / 2)
        for (y in 0 until h) {
            for (x in 0 until w) {
                val p = argb[y * w + x]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                val yy = (0.299f * r + 0.587f * g + 0.114f * b).toInt().coerceIn(0, 255)
                out[y * w + x] = yy.toByte()
            }
        }
        val base = w * h
        for (y in 0 until h step 2) {
            for (x in 0 until w step 2) {
                val p = argb[y * w + x]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                val u = (-0.169f * r - 0.331f * g + 0.500f * b + 128f).toInt().coerceIn(0, 255)
                val v = (0.500f * r - 0.419f * g - 0.081f * b + 128f).toInt().coerceIn(0, 255)
                val ci = base + (y / 2) * w + x
                if (ci + 1 < out.size) {        // 宽/高为奇数时最后一对色度会越界（真机预览尺寸都是偶数）
                    out[ci] = v.toByte()        // NV21：先 V
                    out[ci + 1] = u.toByte()    // 再 U
                }
            }
        }
        return out
    }
}
