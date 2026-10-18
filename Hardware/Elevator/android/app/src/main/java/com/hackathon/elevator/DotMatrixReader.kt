package com.hackathon.elevator

import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 电梯外呼面板「数字」识别 —— 点阵字体版。
 *
 * 适用对象：暗底 + 红色点阵数码的楼层显示屏（实测为日立外呼面板，红点阵）。
 * 一块横长窗口里可能有多个数字位（例如两台电梯各一位），本类按「列空隙」把它们切开逐个识别。
 *
 * 之所以不能再按「七段数码管」做：真实面板的数字是一颗颗小方点拼成的标准点阵字，
 * 例如 "1" 顶上有一小撇、底下一横，七段的模板永远对不上。
 *
 * 处理流程（纯计算，可离线单测）：
 *   1. 在给定区域内计算"红色强度" = r - max(g, b)，用来压掉不锈钢 / 木纹 / 白字等背景；
 *   2. 以峰值的 30% 取阈值得到亮点掩码，按列投影找「大空隙」→ 切出每个数字位；
 *   3. 每个数字位取紧框，按宽高比推出点阵列数，重采样成 (列 × 7 行) 的 0/1 点阵；
 *   4. 与标准 5×7 点阵字模逐个算 IoU，取最高分；同时给出与第二名的差距作为置信度。
 *
 * 实测（用户真机照片，红点阵外呼面板）：同一窗口两个数字位都读出 '1'，
 * 得分 0.90 / 0.80，第二名仅 0.42 —— 区分度足够。
 *
 * 注意：单帧照片会因为 LED 扫描出现「有的方块消失」，识别前请先用
 * [LedFrameFusion.FrameMax] 把连续多帧按"每点取最亮"合成一帧。
 */
object DotMatrixReader {

    /** 红色掩码阈值：占峰值的比例 */
    const val RED_THR_RATIO = 0.30f

    /** 峰值红色强度低于此值视为"屏上没有亮点" */
    const val MIN_RED_PEAK = 25f

    /** 与字模的最低吻合度（低于此值认为"看不清"） */
    const val MIN_SCORE = 0.55

    /** 与第二名的差值下限（低于此值认为"不够确定"） */
    const val MIN_MARGIN = 0.10

    /** 点阵行数（真机面板字模为 7 行） */
    const val GRID_ROWS = 7

    // ------------------------------------------------------------------
    // 标准 5×7 点阵字模
    // ------------------------------------------------------------------
    private val FONT: Map<Char, Array<String>> = linkedMapOf(
        '0' to arrayOf(".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."),
        '1' to arrayOf("..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."),
        '2' to arrayOf(".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"),
        '3' to arrayOf(".###.", "#...#", "....#", "..##.", "....#", "#...#", ".###."),
        '4' to arrayOf("...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."),
        '5' to arrayOf("#####", "#....", "####.", "....#", "....#", "#...#", ".###."),
        '6' to arrayOf(".##..", "#....", "#....", "####.", "#...#", "#...#", ".###."),
        '7' to arrayOf("#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."),
        '8' to arrayOf(".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."),
        '9' to arrayOf(".###.", "#...#", "#...#", ".####", "....#", "....#", "..##."),
        'B' to arrayOf("####.", "#...#", "#...#", "####.", "#...#", "#...#", "####.")
    )

    private class Tpl(val ch: Char, val m: Array<BooleanArray>) {
        val cols: Int get() = m[0].size
        val rows: Int get() = m.size
    }

    /** 字模去掉空白边后的紧框版本（因为观测到的也是紧框） */
    private val TPLS: List<Tpl> = buildList {
        for ((ch, rows) in FONT) {
            var x0 = Int.MAX_VALUE; var x1 = -1; var y0 = Int.MAX_VALUE; var y1 = -1
            for (y in rows.indices) for (x in rows[y].indices) {
                if (rows[y][x] == '#') {
                    if (x < x0) x0 = x; if (x > x1) x1 = x
                    if (y < y0) y0 = y; if (y > y1) y1 = y
                }
            }
            val w = x1 - x0 + 1
            val h = y1 - y0 + 1
            add(Tpl(ch, Array(h) { yy -> BooleanArray(w) { xx -> rows[y0 + yy][x0 + xx] == '#' } }))
        }
    }

    /** 图像坐标下的矩形（含端点） */
    data class Box(val x0: Int, val y0: Int, val x1: Int, val y1: Int) {
        val w: Int get() = x1 - x0 + 1
        val h: Int get() = y1 - y0 + 1
    }

    /** 一个数字位的识别结果 */
    data class Result(val ch: Char, val score: Double, val runnerUp: Double, val box: Box) {
        /** 是否足够可信 */
        val confident: Boolean get() = score >= MIN_SCORE && (score - runnerUp) >= MIN_MARGIN
    }

    /**
     * 识别一帧里的数字。
     *
     * @param argb 图像像素，打包为 0xAARRGGBB
     * @param w    图像宽
     * @param h    图像高
     * @param roi  搜索区域（一般是屏幕上给用户的对准框）
     * @return 从左到右的数字位结果；没有读到东西时返回空列表
     */
    fun read(argb: IntArray, w: Int, h: Int, roi: Box): List<Result> {
        val rw = (roi.w).coerceAtLeast(0)
        val rh = (roi.h).coerceAtLeast(0)
        if (rw < 8 || rh < 8) return emptyList()
        if (roi.x0 < 0 || roi.y0 < 0 || roi.x1 >= w || roi.y1 >= h) return emptyList()

        // ---- 1) 红色强度 ----
        val red = FloatArray(rw * rh)
        var peak = 0f
        for (y in 0 until rh) {
            val rowBase = (roi.y0 + y) * w + roi.x0
            for (x in 0 until rw) {
                val p = argb[rowBase + x]
                val r = (p shr 16) and 0xFF
                val g = (p shr 8) and 0xFF
                val b = p and 0xFF
                val v = (r - max(g, b)).toFloat()
                red[y * rw + x] = v
                if (v > peak) peak = v
            }
        }
        if (peak < MIN_RED_PEAK) return emptyList()

        // ---- 2) 阈值 + 列投影 ----
        val thr = peak * RED_THR_RATIO
        val mask = BooleanArray(rw * rh)
        var mx0 = Int.MAX_VALUE; var mx1 = -1
        var my0 = Int.MAX_VALUE; var my1 = -1
        for (y in 0 until rh) {
            val base = y * rw
            for (x in 0 until rw) {
                if (red[base + x] >= thr) {
                    mask[base + x] = true
                    if (x < mx0) mx0 = x
                    if (x > mx1) mx1 = x
                    if (y < my0) my0 = y
                    if (y > my1) my1 = y
                }
            }
        }
        if (mx1 < 0) return emptyList()

        val colOn = IntArray(rw)
        for (y in 0 until rh) {
            val base = y * rw
            for (x in 0 until rw) if (mask[base + x]) colOn[x]++
        }

        // 把亮的列并成"游程"，间距小于 sepMin 的合并（一个数字内部的点间隙）
        // 大于 sepMin 的当成两个数字位分开
        val sepMin = max(6, ((mx1 - mx0 + 1) * 0.20f).roundToInt())
        val runs = ArrayList<IntArray>()
        var x = mx0
        while (x <= mx1) {
            if (colOn[x] == 0) { x++; continue }
            val c0 = x
            while (x <= mx1 && colOn[x] > 0) x++
            runs.add(intArrayOf(c0, x - 1))
        }
        val groups = ArrayList<IntArray>()
        for (r in runs) {
            val last = groups.lastOrNull()
            if (last != null && r[0] - last[1] - 1 < sepMin) last[1] = r[1]
            else groups.add(intArrayOf(r[0], r[1]))
        }

        // ---- 3) 每个数字位：紧框 → 采样 → 比字模 ----
        val out = ArrayList<Result>()
        for (g in groups) {
            val cx0 = g[0]; val cx1 = g[1]
            var gy0 = Int.MAX_VALUE; var gy1 = -1
            for (y in my0..my1) {
                val base = y * rw
                for (xx in cx0..cx1) if (mask[base + xx]) { if (y < gy0) gy0 = y; if (y > gy1) gy1 = y }
            }
            if (gy1 < 0) continue

            val bw = cx1 - cx0 + 1
            val bh = gy1 - gy0 + 1
            if (bw < 6 || bh < 12) continue

            val ar = bw.toDouble() / bh
            val base = (ar * GRID_ROWS).roundToInt()
            val candCols = intArrayOf(base - 1, base, base + 1).filter { it in 2..6 }.distinct()

            val perGlyph = HashMap<Char, Double>()
            for (cols in candCols) {
                val obs = BooleanArray(cols * GRID_ROWS)
                for (gy in 0 until GRID_ROWS) {
                    val ya = gy0 + gy * bh / GRID_ROWS
                    val yb = maxOf(ya + 1, gy0 + (gy + 1) * bh / GRID_ROWS)
                    for (gx in 0 until cols) {
                        val xa = cx0 + gx * bw / cols
                        val xb = maxOf(xa + 1, cx0 + (gx + 1) * bw / cols)
                        var tot = 0; var on = 0
                        var y = ya
                        while (y < yb) {
                            var xx = xa
                            while (xx < xb) { tot++; if (mask[y * rw + xx]) on++; xx++ }
                            y++
                        }
                        obs[gy * cols + gx] = tot > 0 && on.toDouble() / tot >= 0.5
                    }
                }
                for (t in TPLS) {
                    val s = iou(obs, stretch(t, cols, GRID_ROWS), cols * GRID_ROWS)
                    if (s > (perGlyph[t.ch] ?: -1.0)) perGlyph[t.ch] = s
                }
            }
            if (perGlyph.isEmpty()) continue

            val sorted = perGlyph.entries.sortedByDescending { it.value }
            val best = sorted[0]
            val second = sorted.getOrNull(1)?.value ?: 0.0
            out.add(
                Result(
                    ch = best.key,
                    score = best.value,
                    runnerUp = second,
                    box = Box(roi.x0 + cx0, roi.y0 + gy0, roi.x0 + cx1, roi.y0 + gy1)
                )
            )
        }
        return out
    }

    /** 把字模紧框拉伸到 cols × rows 的 0/1 点阵 */
    private fun stretch(t: Tpl, cols: Int, rows: Int): BooleanArray {
        val out = BooleanArray(cols * rows)
        for (gy in 0 until rows) {
            val sy = gy * t.rows / rows
            for (gx in 0 until cols) {
                val sx = gx * t.cols / cols
                out[gy * cols + gx] = t.m[sy][sx]
            }
        }
        return out
    }

    /** 两个同尺寸 0/1 点阵的交并比 */
    private fun iou(a: BooleanArray, b: BooleanArray, n: Int): Double {
        var inter = 0; var union = 0
        for (i in 0 until n) {
            val x = a[i]; val y = b[i]
            if (x || y) union++
            if (x && y) inter++
        }
        return if (union == 0) 0.0 else inter.toDouble() / union
    }
}
