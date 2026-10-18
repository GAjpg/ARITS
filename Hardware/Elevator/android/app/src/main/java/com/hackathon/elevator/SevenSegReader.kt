package com.hackathon.elevator

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * 七段数码管读数器 —— 纯 Kotlin、**零 Android 依赖**（所以能在 JVM 上直接单测）。
 *
 * 这是 `preview/floor_display_reader.html` 里那套算法的 1:1 移植。设计要点：
 *  - 不用通用 OCR、不训练模型；把"读数"当成几何题：归一化成栅格 → 与合成模板比 L1 误差。
 *  - **看不清就说看不清**：误差超门槛、或与"第二像的数字"差距太小 → 返回 null，绝不猜。
 *
 * 输入：灰度图（整幅照片，或已经裁好的"数字格"区域）。输出：0~9 或 null。
 *
 * ⚠️ 移植忠实度是靠"和网页对同一批图片、逐张比对结果"验证的，不是靠肉眼读代码。
 */
object SevenSegReader {

    // ---------- 可调门槛（现场标定时改这两个即可） ----------
    /** 匹配误差上限：超过就判"未识别"。由合成数据网格搜索标定。 */
    @JvmField var L1_MAX: Double = 0.28
    /** 与"次优的那个数字"的最小差距：太小说明两个数字都像 → 判"未识别"。 */
    @JvmField var MARGIN_MIN: Double = 0.008

    // ---------- 常量（与网页一字不差） ----------
    private const val GRID_H = 60          // 栅格固定高；宽按长宽比算（16~90）
    private const val ANGLE_MAX = 10       // 倾角搜索 ±10°
    private const val ANGLE_STEP = 2
    private const val SEG_ON = 0.45f       // 探针归一化亮度 > 此值 = 该段亮（仅用于输出七段码诊断）

    private val CELL_AR_SET = doubleArrayOf(0.44, 0.50, 0.56, 0.62)   // 数字格 宽/高
    private val THICK_SET = doubleArrayOf(0.10, 0.13, 0.16, 0.20, 0.24) // 笔画粗细

    private val SEGLIST = charArrayOf('a', 'b', 'c', 'd', 'e', 'f', 'g')

    /** 七段在归一化数字框(0~1)里的位置：[x, y, w, h]，顺序同 SEGLIST。 */
    private val SEG = arrayOf(
        doubleArrayOf(0.170, 0.035, 0.660, 0.130), // a 上
        doubleArrayOf(0.790, 0.110, 0.165, 0.350), // b 右上
        doubleArrayOf(0.790, 0.540, 0.165, 0.350), // c 右下
        doubleArrayOf(0.170, 0.835, 0.660, 0.130), // d 下
        doubleArrayOf(0.045, 0.540, 0.165, 0.350), // e 左下
        doubleArrayOf(0.045, 0.110, 0.165, 0.350), // f 左上
        doubleArrayOf(0.170, 0.435, 0.660, 0.130), // g 中
    )

    /** 标准七段码（下标 = 数字）。 */
    private val DIGIT_SEGS = arrayOf(
        "abcdef", "bc", "abged", "abgcd", "fgbc",
        "afgcd", "afgedc", "abc", "abcdefg", "abcfgd"
    )

    // ---------- 识别结果 ----------
    class Result(
        /** 0~9；**null = 未识别**（看不清就不猜） */
        val digit: Int?,
        val l1: Double,
        val margin: Double,
        val runnerUp: Int,
        /** 最像的那个数字，即使最终被拒识（诊断用） */
        val candidate: Int,
        val angle: Double,
        val thick: Double,
        val ar: Double,
        val pattern: String,
        /** null = 采纳了；否则是拒识原因 */
        val reason: String?,
        val perDigit: DoubleArray,
        val cw: Int,
        val ch: Int
    )

    // ================= 对外入口 =================

    /** RGBA（安卓 `Bitmap.getPixels` 的 ARGB_8888 打包 → R 在 16~23 位）→ 灰度。 */
    fun toGrayRgba(rgba: IntArray, w: Int, h: Int): FloatArray {
        val g = FloatArray(w * h)
        for (i in 0 until w * h) {
            val p = rgba[i]
            // 用 Double 算再存回 Float：与网页参考实现逐位一致（Float 中间积算会引入 ~1e-3 的偏差）
            g[i] = (0.299 * ((p shr 16) and 0xFF) + 0.587 * ((p shr 8) and 0xFF) + 0.114 * (p and 0xFF)).toFloat()
        }
        return g
    }

    /** RGBA → 灰度 → 识别。方便"上传照片"那条路。 */
    fun recognizeCellRgba(rgba: IntArray, w: Int, h: Int): Result =
        recognizeCellGray(toGrayRgba(rgba, w, h), w, h)

    /**
     * 主入口：已经裁好的"数字格"灰度图。
     *
     * 为什么用"数字格"而不是全图自动找框：自动找框时，窄的"1"被拉伸后宽度信息会丢，
     * 容易被读成"0"（读错 0~5%）；给定数字格后读错降到 0~2%，其余全是"未识别"。
     */
    fun recognizeCellGray(gray: FloatArray, w: Int, h: Int): Result {
        require(w > 0 && h > 0) { "w/h 必须 > 0" }
        require(gray.size >= w * h) { "灰度数组小于 w*h" }

        val th = otsu(gray, w * h)
        val med = medianOf(gray, w * h)
        val bright = med < 120                       // 亮底暗字 / 暗底亮字
        val ch = GRID_H
        val cw = max(16, min(90, Math.round(GRID_H.toDouble() * w / h).toInt()))
        val box = intArrayOf(0, 0, w - 1, h - 1)
        val lo = pctInBox(gray, w, box, 0.06)
        val hi = pctInBox(gray, w, box, 0.96)

        // 模板：同一栅格流程渲染 10 个数字 × 4 种数字格宽高比 × 5 种笔画粗细
        val tpl = ArrayList<Tpl>(10 * CELL_AR_SET.size * THICK_SET.size)
        for (ar in CELL_AR_SET) for (t in THICK_SET) for (d in 0..9) {
            tpl.add(Tpl(d, t, ar, tplGridCell(d, ar, t, cw, ch)))
        }

        var best: Best? = null
        val perDigit = DoubleArray(10) { Double.MAX_VALUE }
        var a = -ANGLE_MAX
        while (a <= ANGLE_MAX) {
            val grid = normalize(gray, w, h, box, a.toDouble(), lo, hi, bright, cw, ch)
            val r = classifyGrid(grid, tpl)
            if (best == null || r.best.l1 < best.l1) {
                best = r.best.also { it.grid = grid; it.a = a.toDouble() }
            }
            for (d in 0..9) if (r.perDigit[d] < perDigit[d]) perDigit[d] = r.perDigit[d]
            a += ANGLE_STEP
        }
        val b = best!!
        val d = decide(b, perDigit, b.grid, cw, ch)

        return Result(
            digit = if (d.accepted) b.digit else null,
            l1 = b.l1,
            margin = d.margin,
            runnerUp = d.runnerUp,
            candidate = b.digit,
            angle = b.a,
            thick = b.t,
            ar = b.ar,
            pattern = d.on,
            reason = if (d.accepted) null else if (b.l1 > L1_MAX) "匹配度不够" else "有多个数字同样像",
            perDigit = perDigit,
            cw = cw,
            ch = ch
        )
    }

    // ================= 内部 =================

    private class Tpl(val digit: Int, val t: Double, val ar: Double, val g: FloatArray)

    private class Best(var l1: Double, var digit: Int, var t: Double, var ar: Double) {
        var a: Double = 0.0
        lateinit var grid: FloatArray
    }

    private class Decision(val accepted: Boolean, val margin: Double, val runnerUp: Int, val on: String)

    /** 观测到的数字也被"紧贴包围盒"拉伸过，所以模板必须同样拉伸后再比（否则 "4" 会被读成 "9"）。 */
    private fun segsOf(digit: Int, ar: Double, h: Double, t: Double): Array<DoubleArray> {
        val barW = ar - 1.10 * t
        val half = h / 2 - 1.10 * t
        val s = HashMap<Char, DoubleArray>(8)
        s['a'] = doubleArrayOf(t * 0.55, 0.0, barW, t)
        s['d'] = doubleArrayOf(t * 0.55, h - t, barW, t)
        s['g'] = doubleArrayOf(t * 0.55, h / 2 - t / 2, barW, t)
        s['f'] = doubleArrayOf(0.0, t * 0.55, t, half)
        s['b'] = doubleArrayOf(ar - t, t * 0.55, t, half)
        s['e'] = doubleArrayOf(0.0, h / 2 + t * 0.55, t, half)
        s['c'] = doubleArrayOf(ar - t, h / 2 + t * 0.55, t, half)
        return Array(DIGIT_SEGS[digit].length) { s[DIGIT_SEGS[digit][it]]!! }
    }

    /** 在"数字格坐标系"里渲染模板（部署路径用这个）。 */
    private fun tplGridCell(digit: Int, ar: Double, t: Double, cw: Int, ch: Int): FloatArray {
        val segs = segsOf(digit, ar, 1.0, t)
        val grid = FloatArray(cw * ch)
        for (gy in 0 until ch) for (gx in 0 until cw) {
            val x = (gx + 0.5) / cw * ar
            val y = (gy + 0.5) / ch
            var hit = 0f
            for (s in segs) {
                if (x >= s[0] && x <= s[0] + s[2] && y >= s[1] && y <= s[1] + s[3]) { hit = 1f; break }
            }
            grid[gy * cw + gx] = hit
        }
        return grid
    }

    /** 把区域按"归一化灰度"采样成 cw×ch 栅格（可绕中心旋转；用灰度而非二值 → 抗泛光/反光）。 */
    private fun normalize(
        g: FloatArray, w: Int, h: Int, bb: IntArray, angleDeg: Double,
        lo: Int, hi: Int, bright: Boolean, cw: Int, ch: Int
    ): FloatArray {
        val out = FloatArray(cw * ch)
        val span = max(6, hi - lo).toDouble()
        val cx = (bb[0] + bb[2] + 1) / 2.0
        val cy = (bb[1] + bb[3] + 1) / 2.0
        val bw = (bb[2] - bb[0] + 1).toDouble()
        val bh = (bb[3] - bb[1] + 1).toDouble()
        val rad = angleDeg * Math.PI / 180.0
        val ca = cos(rad)
        val sa = sin(rad)
        for (gy in 0 until ch) {
            for (gx in 0 until cw) {
                val u = (gx + 0.5) / cw - 0.5
                val v = (gy + 0.5) / ch - 0.5
                val ru = u * ca - v * sa
                val rv = u * sa + v * ca
                val sx = cx + ru * bw
                val sy = cy + rv * bh
                var sum = 0.0
                var n = 0
                for (dy in -1..1) for (dx in -1..1) {
                    val px = Math.round(sx + dx).toInt()
                    val py = Math.round(sy + dy).toInt()
                    if (px in 0 until w && py in 0 until h) {
                        val vv = g[py * w + px].toDouble()
                        sum += if (bright) (vv - lo) / span else (hi - vv) / span
                        n++
                    }
                }
                out[gy * cw + gx] = if (n > 0) max(0.0, min(1.0, sum / n)).toFloat() else 0f
            }
        }
        return out
    }

    /** 逐像素 L1 误差（比"7 个探针"稳：探针只覆盖片段的一部分会抹平差异）。 */
    private class GridClass(val best: Best, val perDigit: DoubleArray)

    private fun classifyGrid(obs: FloatArray, tpls: List<Tpl>): GridClass {
        var best: Best? = null
        val perDigit = DoubleArray(10) { Double.MAX_VALUE }
        for (t in tpls) {
            val g = t.g
            var s = 0.0
            for (i in g.indices) s += abs(obs[i].toDouble() - calTpl(g[i]))
            s /= g.size
            if (s < perDigit[t.digit]) perDigit[t.digit] = s
            if (best == null || s < best.l1) best = Best(s, t.digit, t.t, t.ar)
        }
        return GridClass(best!!, perDigit)
    }

    private fun decide(best: Best, perDigit: DoubleArray, obs: FloatArray, cw: Int, ch: Int): Decision {
        var second = Double.MAX_VALUE
        var runnerUp = -1
        for (d in 0..9) if (d != best.digit && perDigit[d] < second) { second = perDigit[d]; runnerUp = d }
        val margin = second - best.l1
        val probes = readProbes(obs, cw, ch)
        val on = StringBuilder()
        for (k in 0..6) if (probes[k] > SEG_ON) on.append(SEGLIST[k])
        val accepted = best.l1 <= L1_MAX && margin >= MARGIN_MIN
        return Decision(accepted, margin, runnerUp, if (on.isEmpty()) "(none)" else on.toString())
    }

    /** 观测值 ≈ 0.83×理想覆盖 + 0.06（实测标定，来自合成数据回归）。 */
    private fun calTpl(v: Float): Double = 0.83 * v + 0.06

    private fun readProbes(grid: FloatArray, cw: Int, ch: Int): DoubleArray {
        val r = DoubleArray(7)
        for (k in 0..6) {
            val s = SEG[k]
            val x0 = floor(s[0] * cw).toInt()
            val x1 = min(cw, ceil((s[0] + s[2]) * cw).toInt())
            val y0 = floor(s[1] * ch).toInt()
            val y1 = min(ch, ceil((s[1] + s[3]) * ch).toInt())
            var sum = 0.0
            var n = 0
            for (y in y0 until y1) for (x in x0 until x1) { sum += grid[y * cw + x]; n++ }
            r[k] = if (n > 0) sum / n else 0.0
        }
        return r
    }

    // ---- 灰度统计（都用 |0 截断，与网页一致） ----

    private fun otsu(g: FloatArray, n: Int): Int {
        val hist = IntArray(256)
        for (i in 0 until n) {
            var v = g[i].toInt(); if (v < 0) v = 0; if (v > 255) v = 255
            hist[v]++
        }
        var sum = 0.0
        for (i in 0..255) sum += i * hist[i].toDouble()
        var sumB = 0.0; var wB = 0; var best = 0.0; var th = 127
        for (i in 0..255) {
            wB += hist[i]
            if (wB == 0) continue
            val wF = n - wB
            if (wF == 0) break
            sumB += i * hist[i].toDouble()
            val mB = sumB / wB
            val mF = (sum - sumB) / wF
            val bt = wB.toDouble() * wF * (mB - mF) * (mB - mF)
            if (bt > best) { best = bt; th = i }
        }
        return th
    }

    private fun medianOf(g: FloatArray, n: Int): Int {
        val h = IntArray(256)
        for (i in 0 until n) {
            var v = g[i].toInt(); if (v < 0) v = 0; if (v > 255) v = 255
            h[v]++
        }
        var acc = 0
        val half = n / 2.0
        for (i in 0..255) { acc += h[i]; if (acc >= half) return i }
        return 127
    }

    private fun pctInBox(g: FloatArray, w: Int, bb: IntArray, p: Double): Int {
        val h = IntArray(256)
        var n = 0
        for (y in bb[1]..bb[3]) for (x in bb[0]..bb[2]) {
            var v = g[y * w + x].toInt(); if (v < 0) v = 0; if (v > 255) v = 255
            h[v]++; n++
        }
        var acc = 0
        val tgt = n * p
        for (i in 0..255) { acc += h[i]; if (acc >= tgt) return i }
        return 255
    }
}
