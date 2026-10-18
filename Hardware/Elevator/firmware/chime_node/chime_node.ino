/* =====================================================================
 *  电梯【到站检测】节点 —— 可选加装件（ESP32 + 麦克风）  【新增，未定线实测】
 * =====================================================================
 *  一句话：现有两个按钮节点只能"按"，测不出轿厢在哪层。
 *          这个节点挂在井道边上，听电梯到站的"叮"声 → 播一条 CAR|xF 给手机。
 *          「轿厢现在在 2F」从此是**真数据**，不是模拟。
 *
 *  ★ 重要：本文件**不修改**也能跑通的 elevator_2F / elevator_3F。
 *    它是一个独立设备（广播名 CHIME-<楼层>），可以单独烧、单独试、单独扔。
 *    想省一块板子也可以把下面的 micProcess() 原样并进电梯节点里（见文末注释）。
 *
 *  接线（极简，一个麦克风模块 + 一个电容）：
 *    麦克风模块 OUT -> GPIO34   (ADC1_CH6，输入脚，不用作 DAC)
 *    麦克风模块 VCC -> 3V3
 *    麦克风模块 GND -> GND
 *    模块旁边并 1 个 10~47uF 电容到 GND（压电源纹波）
 *    推荐：MAX9814（自带 AGC + 偏置 1.25V，最省事）
 *    备选：MAX4466 / 驻极体 + LM386；便宜到 2~3 元
 *
 *  原理（不用 FFT、不用库）：
 *    4 kHz 采样 → 每 40 ms 一个窗口 → 算 RMS(多大声) 和 过零率(≈主频)
 *    电梯"叮"是 1~3 kHz 的短促纯音：RMS 突然冲到本底噪声的 3 倍以上、
 *    同时过零率落在 700~1900 Hz → 判为"叮"。连续 2 个窗口都命中才认，
 *    再加 3 秒不应期 → 说话/脚步声基本不会误触发。
 *
 *  ★ 关于频率：4 kHz 采样 → 奈奎斯特 2 kHz，**超过 2 kHz 的音会被混叠**。
 *    例如真实的 3 kHz "叮"会混叠成 1 kHz，仍落在带内 → 照样能报。
 *    所以 FREQ_HI_HZ 设 1900（略低于奈奎斯特）就够，不必写 5200。
 *
 *  ★ 现场标定（这一步必须做，代码里放的是保守初值）：
 *    办法一（推荐）：打开 preview/chime_calib.html（浏览器，用麦克风），
 *      它跑的是**和本文件一模一样**的 DSP，会直接告诉你要写的频带/倍数。
 *    办法二：打开串口 115200，站到电梯门口，看每 2 秒打印的"本底/最近 rms/freq"：
 *      本底 rms 通常 2~20；"叮"的那一刻 rms 会跳到 100~2000、freq 落在几十~两千。
 *      把 RMS_ON_FLOOR_MULT 调到"安静时绝不误报、叮的时候必报"为止；
 *      若误报来自说话声，把 FREQ_LO_HZ 提到 900~1200。
 *
 *  开发板：ESP32 Dev Module ｜ 分区：Huge APP ｜ 串口：115200
 * =====================================================================
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

// ====================== 【要改的配置】 ======================
#define FLOOR_NAME  "2F"        // 这块板子装在哪一层（另一块改成 "3F"）

#define MIC_PIN       34        // 麦克风 OUT（ADC1 通道脚）
#define LED_PIN        2        // 板载 LED，检测到"叮"时亮一下

#define SAMPLE_US        250    // 采样周期 = 4 kHz
#define WIN_SAMPLES      160    // 每窗口 40 ms
#define DINGS_TO_TRIGGER   2    // 连续几个窗口像"叮"才算数（抗误触发）
#define REFRACTORY_MS   3000    // 一次判定后 3 秒内不再判定
#define RMS_ON_FLOOR_MULT 3.0f  // 触发阈值 = 本底 × 这个倍数（现场调它）
#define RMS_ABS_MIN      14.0f  // 绝对下限，避免"极安静时本底太小"导致风吹草动就触发
#define FREQ_LO_HZ      700     // "叮"的频率下限
#define FREQ_HI_HZ     1900     // 上限。4kHz 采样奈奎斯特只有 2kHz，再高也测不到（3kHz 的叮会混叠成 1kHz，仍在带内）

// ====================== 【一般不用改】 ======================
#define SERVICE_UUID      "0000ffe0-0000-1000-8000-00805f9b34fb"
#define CMD_CHAR_UUID     "0000ffe1-0000-1000-8000-00805f9b34fb"
#define STATUS_CHAR_UUID  "0000ffe2-0000-1000-8000-00805f9b34fb"

static BLEServer*         pServer  = nullptr;
static BLECharacteristic* pStatus  = nullptr;

static volatile bool gRestartAdv = false;
struct CmdMsg { char text[24]; };
static QueueHandle_t cmdQueue = nullptr;

// ---------------- 回执/NOTIFY ----------------
static void publishStatus(const String& s) {
  if (!pStatus) return;
  pStatus->setValue((uint8_t*)s.c_str(), s.length());
  pStatus->notify();
  Serial.printf("[ble] → %s\n", s.c_str());
}

// ---------------- 麦克风处理（可整段搬到电梯节点里） ----------------
static unsigned long sLastSample = 0;
static float  sDcEma     = 2048.0f;      // ADC 直流偏置(麦克风静止电平)
static float  sSumSq     = 0.0f;
static int    sZc        = 0;            // 窗口内过零次数（上升沿 + 下降沿，都要算）
static float  sPrev      = 0.0f;
static int    sNSample   = 0;
static float  sNoiseFloor = 12.0f;       // 本底噪声(RMS)，静音时慢速跟踪
static int    sHitRun    = 0;
static unsigned long sLastDing = 0;
static unsigned long sLastPrint = 0;
static int    sDingCount = 0;
static float  sLastRms = 0, sLastFreq = 0;

static void micProcess(unsigned long nowUs, unsigned long nowMs) {
  if (nowUs - sLastSample < SAMPLE_US) return;
  sLastSample += SAMPLE_US;

  int v = analogRead(MIC_PIN);
  sDcEma += ((float)v - sDcEma) * 0.0015f;      // 慢速跟随直流，去掉偏置
  float x = (float)v - sDcEma;
  sSumSq += x * x;
  // ★ 过零：上升沿和下降沿都要数。
  //   （早先的版本只数了上升沿，却仍然用 freq=zc/(2*sec) 这个"数了上下沿"的公式，
  //     结果频率被算小一半 —— 1200 Hz 的叮会读成 600 Hz，低于 FREQ_LO_HZ 就永远不响。
  //     2026-10-17 用 preview/chime_calib.html 的离线自测抓出来的。）
  if ((sPrev < 0.0f && x >= 0.0f) || (sPrev >= 0.0f && x < 0.0f)) sZc++;
  sPrev = x;

  if (++sNSample < WIN_SAMPLES) return;

  // ---- 一个 40 ms 窗口结束，判定 ----
  float rms  = sqrtf(sSumSq / (float)WIN_SAMPLES);
  float sec  = (float)WIN_SAMPLES * SAMPLE_US * 1e-6f;
  float freq = (float)sZc / (2.0f * sec);       // 一个周期过零 2 次 → /2 即主频

  sLastRms = rms; sLastFreq = freq;

  bool loud = (rms > sNoiseFloor * RMS_ON_FLOOR_MULT) && (rms > RMS_ABS_MIN);
  bool tone = (freq >= FREQ_LO_HZ && freq <= FREQ_HI_HZ);

  if (loud && tone) {
    sHitRun++;
  } else {
    sHitRun = 0;
    if (!loud) sNoiseFloor += (rms - sNoiseFloor) * 0.08f;   // 只在安静时更新本底
    if (sNoiseFloor < 2.0f) sNoiseFloor = 2.0f;
  }

  if (sHitRun >= DINGS_TO_TRIGGER && (nowMs - sLastDing) > REFRACTORY_MS) {
    sLastDing = nowMs;
    sHitRun   = 0;
    sDingCount++;
    digitalWrite(LED_PIN, HIGH);
    Serial.printf("[ding] 检测到到站提示音 #%d  rms=%.0f freq=%.0fHz 本底=%.0f\n",
                  sDingCount, rms, freq, sNoiseFloor);
    // ★ 这就是"真实到站"：播给所有订阅的手机
    //   报文形状与按钮节点完全一致：<楼层>|<结果>，手机侧同一套解析
    publishStatus(String(FLOOR_NAME) + "|CAR:CHIME");
  }

  sNSample = 0; sSumSq = 0.0f; sZc = 0;
}

static void tickLed(unsigned long nowMs) {
  if (digitalRead(LED_PIN) && (nowMs - sLastDing) > 120) digitalWrite(LED_PIN, LOW);
}

// ---------------- 命令（和按钮节点同一套 UUID，方便复用手机侧代码） ----------------
static void handleCommand(const String& v) {
  if (v == "PING" || v == "?" || v == "STATUS") {
    publishStatus(String(FLOOR_NAME) + "|READY:" + String(sDingCount));
    return;
  }
  if (v == "FLOOR") {                      // 让手机主动问"车在哪层"
    publishStatus(String(FLOOR_NAME) + "|CAR:LAST");
    return;
  }
  if (v == "LEVEL") {                      // 现场调阈值用
    publishStatus(String(FLOOR_NAME) + "|LEVEL:rms=" + String((int)sLastRms) +
                  ",hz=" + String((int)sLastFreq) + ",floor=" + String((int)sNoiseFloor));
    return;
  }
  publishStatus(String(FLOOR_NAME) + "|ERR:BADCMD");
}

class ServerCb : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { BLEDevice::startAdvertising(); }
  void onDisconnect(BLEServer*) override { gRestartAdv = true; }
};

class CmdCb : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = String(c->getValue().c_str());
    v.trim(); v.toUpperCase();
    if (!v.length()) return;
    CmdMsg m{};
    v.substring(0, sizeof(m.text) - 1).toCharArray(m.text, sizeof(m.text));
    xQueueSend(cmdQueue, &m, 0);
  }
};

// ---------------- 初始化 ----------------
void setup() {
  Serial.begin(115200);
  delay(200);
  pinMode(LED_PIN, OUTPUT); digitalWrite(LED_PIN, LOW);
  pinMode(MIC_PIN, INPUT);
  Serial.printf("\n=== 到站检测节点启动：CHIME-%s (mic=GPIO%d) ===\n", FLOOR_NAME, MIC_PIN);

  cmdQueue = xQueueCreate(8, sizeof(CmdMsg));

  String devName = String("CHIME-") + FLOOR_NAME;
  BLEDevice::init(devName.c_str());
  BLEDevice::setPower(ESP_PWR_LVL_P9);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCb());
  BLEService* svc = pServer->createService(SERVICE_UUID);

  BLECharacteristic* pCmd = svc->createCharacteristic(
      CMD_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  pCmd->setCallbacks(new CmdCb());

  pStatus = svc->createCharacteristic(
      STATUS_CHAR_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pStatus->addDescriptor(new BLE2902());
  String ready = String(FLOOR_NAME) + "|CAR:BOOT";
  pStatus->setValue((uint8_t*)ready.c_str(), ready.length());
  svc->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("[ble] 广播中（CHIME-" FLOOR_NAME "），等待手机订阅...");
}

void loop() {
  unsigned long nowMs = millis();
  unsigned long nowUs = micros();

  micProcess(nowUs, nowMs);      // 4 kHz 采样（非阻塞，一次只取一个样）
  tickLed(nowMs);

  CmdMsg m;
  if (xQueueReceive(cmdQueue, &m, 0) == pdTRUE) handleCommand(String(m.text));

  if (gRestartAdv) { gRestartAdv = false; BLEDevice::startAdvertising(); }

  if (nowMs - sLastPrint > 2000) {   // 现场标定看的调试行
    sLastPrint = nowMs;
    Serial.printf("[状态] 本底=%.0f  最近 rms=%.0f freq=%.0fHz  已报%d次  连接=%u\n",
                  sNoiseFloor, sLastRms, sLastFreq, sDingCount,
                  pServer ? (unsigned)pServer->getConnectedCount() : 0);
  }
}

/* =====================================================================
 *  想省掉这块板子？把上面的 micProcess() / 相关静态变量 / setup 里的
 *  pinMode(MIC_PIN) 原样搬进 elevator_2F.ino，然后在 loop() 里加一行
 *  micProcess(micros(), millis()) 即可。注意：
 *    · 采样循环会占一点 CPU，一次只取一个样、不 delay，不会饿死 BLE；
 *    · 电梯"叮"和舵机动作是**两件事**：舵机回执 OK:UP 表示"我按下去了"，
 *      CAR|2F 表示"车到了" —— 手机侧要分别处理，不要混。
 * ===================================================================== */
