package com.hackathon.elevator

/**
 * 抗"扫描闪烁"（multiplexing）的多帧融合 —— 纯 Kotlin、零 Android 依赖。
 *
 * ## 为什么需要它
 * 电梯厅那种七段数码管不是所有段一直亮，而是**飞快轮流点亮**（每秒几百到几千次）。
 * 人眼因为余晖看成"全亮"，但相机一次曝光只抓到其中一小段：
 *   - 照片里有些段是暗的 → 那一段被当成"灭"
 *   - 于是 "8" 少了左边两竖 → 看起来正好是 "3"，**而且置信度很高**（不是"看不清"，是"读错"）
 *   - 这就是用户看到的"有些方块一闪一闪"
 *
 * 逐帧识别必然被这个坑到。解法是**看多帧再下结论**：
 * [FrameMedian] 逐像素取多帧中位数（先修图，再识别）；
 * [DigitVoter] 多帧的识别结果投票（后修结论）。
 * 两者互补：前者能救回"某个段偶尔没抓到"，后者能救回"整帧读错成别的数字"。
 *
 * ⚠️ 帧窗口要短（5 帧 @10fps ≈ 0.5s）。因为电梯真的换层时数字会变，
 * 窗口太长会把两个数字混在一起（"2"和"3"混成"8"）。
 */

/**
 * 逐像素取最近 k 帧的**最大值**。用来补回"某段这一帧没亮"的随机闪烁。
 *
 * 为什么是最大值而不是中位数：扫描驱动造成的失真**是单向的** —— 一段本来亮着，
 * 相机没抓到，它就只可能在这帧里**变暗**，绝不会变亮。所以"逐像素取最亮"能把
 * 漏掉的段补回来。中位数是对称的，补不回来（实测中位数反而更差）。
 */
class FrameMax(private val k: Int = 5) {
    init { require(k >= 1) { "k 必须 >= 1" } }

    private val buf = ArrayList<FloatArray>(k)
    private var w = -1
    private var h = -1

    /** 投入一帧灰度图；返回"最近这几帧逐像素最大值"。尺寸变化会自动清空重来。 */
    fun push(gray: FloatArray, width: Int, height: Int): FloatArray {
        if (width != w || height != h) { buf.clear(); w = width; h = height }
        buf.add(gray.copyOf())
        while (buf.size > k) buf.removeAt(0)
        val n = w * h
        val out = FloatArray(n)
        for (f in buf) for (i in 0 until n) if (f[i] > out[i]) out[i] = f[i]
        return out
    }

    fun reset() { buf.clear() }

    val frames: Int get() = buf.size
}

/**
 * 逐像素取最近 k 帧的中位数。用来抹掉"某段这一帧没亮"的随机闪烁。
 *
 * ⚠️ 实测在扫描驱动下**不如 [FrameMax]**：中位数是对称统计量，补不回单向下掉的段。
 * 保留它是因为它在"噪点/反光"这类上下都有的干扰下更稳，可用于对照与组合。
 */
class FrameMedian(private val k: Int = 5) {
    init { require(k >= 1) { "k 必须 >= 1" } }

    private val buf = ArrayList<FloatArray>(k)
    private var w = -1
    private var h = -1
    private var scratch = FloatArray(0)

    /** 投入一帧灰度图；返回"目前这几帧的中位数图"。尺寸变化会自动清空重来。 */
    fun push(gray: FloatArray, width: Int, height: Int): FloatArray {
        if (width != w || height != h) {
            buf.clear()
            w = width
            h = height
            scratch = FloatArray(k)
        }
        buf.add(gray.copyOf())          // 复制，避免调用方复用同一块 buffer
        while (buf.size > k) buf.removeAt(0)
        return median(w * h)
    }

    fun reset() { buf.clear() }

    /** 已积攒的帧数（不到 k 也能用，只是没那么稳）。 */
    val frames: Int get() = buf.size

    private fun median(n: Int): FloatArray {
        val out = FloatArray(n)
        val m = buf.size
        for (i in 0 until n) {
            for (j in 0 until m) scratch[j] = buf[j][i]
            // m 很小（<=5），插入排序比 sort() 更省
            for (a in 1 until m) {
                val v = scratch[a]
                var b = a - 1
                while (b >= 0 && scratch[b] > v) { scratch[b + 1] = scratch[b]; b-- }
                scratch[b + 1] = v
            }
            out[i] = if (m % 2 == 1) scratch[m / 2] else 0.5f * (scratch[m / 2 - 1] + scratch[m / 2])
        }
        return out
    }
}

/**
 * 多帧识别结果投票。要求同一个数字在最近 k 帧里出现 >= minAgree 次才采纳，
 * 否则返回 null（= 继续显示"看不清"，绝不猜）。
 */
class DigitVoter(private val k: Int = 5, private val minAgree: Int = 3) {
    init {
        require(k >= 1) { "k 必须 >= 1" }
        require(minAgree in 1..k) { "minAgree 必须在 1..k" }
    }

    private val buf = ArrayList<Int?>(k)
    private val counts = IntArray(10)

    /** 投入一帧的识别结果（null = 该帧看不清）；满足票数则返回数字，否则 null。 */
    fun push(digit: Int?): Int? {
        buf.add(digit)
        while (buf.size > k) buf.removeAt(0)
        if (buf.size < minAgree) return null
        counts.fill(0)
        for (d in buf) if (d != null) counts[d]++
        var best = -1
        var bestN = 0
        for (d in 0..9) if (counts[d] > bestN) { bestN = counts[d]; best = d }
        return if (bestN >= minAgree) best else null
    }

    fun reset() { buf.clear() }

    val frames: Int get() = buf.size
}
