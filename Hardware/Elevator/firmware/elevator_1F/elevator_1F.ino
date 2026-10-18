/* =====================================================================
 *  电梯呼梯节点 —— 1F 板   (ESP32 + BLE)          【最终版 v8】
 * =====================================================================
 *  楼层：1F
 *
 *  ★ v8（本次改动）：按压转角 40° → 60° —— 从“垂直左偏 20°”摆到“垂直右偏 40°”（松开 90°→70°、按下仍 130°）。
 *
 *     这套件的传动 = 曲柄 + 长槽滑块（苏格兰轭），不是摆臂直接顶按钮。
 *     滑块 / 按钮行程 = R × (sinφ₂ − sinφ₁)，其中
 *     R = 曲柄上“舵机轴心 → 销钉轴心”的距离 ≈ 8.0mm
 *     （7.98，用程序把 STL 一层层切开量的，不是估的）。
 *     按下 = 滑块朝按钮方向（伸出）走；销钉在长槽里滑，
 *     长槽两端是【硬限位】—— 销钉绝不能顶到头，必须留余量。
 *
 *     v8 取 60°：按压终点沿用 v7 手测过的 130°（垂直右偏 40°），起点向左挪到 70°（垂直左偏 20°）。
 *     → 松开 70°、按下 130°（默认值；绝对角度必须现场标定，见下）
 *
 *     ⚠ 如果你的装配是往反方向转才压得到按钮，把 ANGLE_PRESS 改成 10。
 *        用串口标定（下面的 SP 命令）最省事，不用改代码重烧。
 *
 *  ★【串口现场标定】——只走串口，**不影响 App 的 BLE 命令**：
 *       ?        查看当前角度 / REST / PRESS / 存储值
 *       A70      两轴一起转到绝对角度 70°（找位置用，例：A125）
 *       +1 / -2  在当前角度上微调（找位置用）
 *       U / D / B  标定对象切到【上行】/【下行】/【两轴】（默认两轴）
 *       SR       把当前角度记成 REST（松开位）
 *       SP       把当前角度记成 PRESS（按下位）
 *       SAVE     存进 Flash，掉电不丢
 *       CLR      恢复出厂默认 70 / 130
 *       T        试跑一次：REST → PRESS → 停 0.6s → REST
 *     标定流程见《烧录说明.md》第五节。
 *
 *  接线：
 *    上行舵机 信号线 -> D13  (GPIO13)
 *    下行舵机 信号线 -> D12  (GPIO12)
 *    舵机 VCC -> 外部 5V 电源正极（禁止用 ESP32 的 3V3！）
 *    舵机 GND -> 外部 5V 负极，并与 ESP32 GND 共地
 *
 *  ★ 无第三方库：用 ESP32 核心自带 LEDC 出 50Hz，兼容 core 2.x / 3.x。
 *  ★ GPIO12 是 MTDI strapping 脚：若上电/烧录异常，先拔掉 D12 上的舵机
 *    信号线再烧录；或把 DOWN_PIN 改成 14/27（同时改 App 无关，只是换线）。
 *
 *  开发板：ESP32 Dev Module
 *  分区务必选：Huge APP (3MB No OTA/1MB SPIFFS)，否则 84% 吃满默认分区。
 *  串口：115200
 * =====================================================================
 */

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Preferences.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

// ====================== 【要改的配置】 ======================
#define FLOOR_NAME  "1F"        // 1F 板

// 舵机信号脚（按用户硬件：上行 D13 / 下行 D12）
#define UP_PIN      13
#define DOWN_PIN    12

/* ★ 角度（v8：按压 60°）
 *   松开 70° = 垂直左偏 20°（曲柄停位：销钉落在长槽内、离两端要留余量，别顶槽头）
 *   按下 130° = 垂直右偏 40°（v7 手测过的按压位；从松开位往右摆 60°）
 *   两个值都是【默认值】，现场标定后会存进 Flash 覆盖它们；
 *   方向反了改 ANGLE_PRESS=10（或用串口 SP 标定）。 */
#define ANGLE_REST  70          // 松开（收起）角度
#define ANGLE_PRESS 130         // 按下（伸出）角度  ← 现场标定
#define ANGLE_DELTA_LIMIT 65    // 与 REST 差超过 65° 提醒（太大可能顶到长槽尽头、憋舵机）

#define SWEEP_MS    350         // 摆过去/摆回来各用时(ms)；与演示视频/PPT 的 0.35s 口径一致
#define HOLD_MS     600         // 按住按钮时长(ms)

// ====================== 【一般不用改】 ======================
#define SERVICE_UUID      "0000ffe0-0000-1000-8000-00805f9b34fb"
#define CMD_CHAR_UUID     "0000ffe1-0000-1000-8000-00805f9b34fb"
#define STATUS_CHAR_UUID  "0000ffe2-0000-1000-8000-00805f9b34fb"

#define PWM_FREQ_HZ   50
#define PWM_RES_BITS  16
#define PERIOD_US     20000UL
#define DUTY_MAX      ((1UL << PWM_RES_BITS) - 1)

#define NUM_SERVOS    2
#define AXIS_UP       0
#define AXIS_DOWN     1

/* 每个舵机一条独立的时间驱动状态机：
 *   IDLE → OUT(伸出) → HOLD(按住) → IN(收回) → IDLE
 * 全程用 millis() 计步，loop 里绝不 delay —— 阻塞会让 BLE/串口/另一轴一起卡。 */
struct Axis {
  uint8_t     pin;
  const char* label;
  enum Phase : uint8_t { IDLE, OUT, HOLD, IN } phase;
  unsigned long t0;
  bool        pending;        // 有命令在等这一轴空闲
};

static Axis axes[NUM_SERVOS] = {
  { UP_PIN,   "UP",   Axis::IDLE, 0, false },
  { DOWN_PIN, "DOWN", Axis::IDLE, 0, false },
};

// 运行角度（初值 = 上面的默认值；setup 里会被 Flash 里的标定值覆盖）
static int gRest [NUM_SERVOS] = { ANGLE_REST,  ANGLE_REST  };
static int gPress[NUM_SERVOS] = { ANGLE_PRESS, ANGLE_PRESS };

static BLEServer*         pServer  = nullptr;
static BLECharacteristic* pCmd     = nullptr;
static BLECharacteristic* pStatus  = nullptr;

/* 跨任务共享：BLE 任务写、loop 任务读 → 必须 volatile */
static volatile bool gRestartAdv     = false;
static uint32_t      gLastConnCount  = 0xFFFFFFFF;   // 用于“连接数变化时打印一次”

struct CmdMsg { char text[24]; };
static QueueHandle_t cmdQueue = nullptr;

#if ESP_ARDUINO_VERSION_MAJOR < 3
static uint8_t sCh[NUM_SERVOS];
#endif

// ---------------- 舵机（原生 LEDC） ----------------
static void servoAttach(uint8_t i) {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(axes[i].pin, PWM_FREQ_HZ, PWM_RES_BITS);
#else
  sCh[i] = i;
  ledcSetup(sCh[i], PWM_FREQ_HZ, PWM_RES_BITS);
  ledcAttachPin(axes[i].pin, sCh[i]);
#endif
}

static void servoWrite(uint8_t i, int angle) {
  angle = constrain(angle, 0, 180);
  uint32_t us   = 500UL + (uint32_t)angle * 2000UL / 180UL;      // 500~2500us
  uint32_t duty = (uint32_t)((uint64_t)us * DUTY_MAX / PERIOD_US);
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(axes[i].pin, duty);
#else
  ledcWrite(sCh[i], duty);
#endif
}

// ---------------- 状态回执（NOTIFY） ----------------
/* 广播式回执：发给【所有】已订阅的手机。
 * 不再判断“是否有人连着”——notify() 内部会按 conn_id 跳过已断开的连接，
 * 所以多台手机同时连时，任何一台断开都不会影响其它手机收到回执。 */
static void publishStatus(const String& s) {
  if (!pStatus) return;
  String msg = String(FLOOR_NAME) + "|" + s;
  pStatus->setValue((uint8_t*)msg.c_str(), msg.length());
  pStatus->notify();
}

// ---------------- 时间驱动状态机 ----------------
static void stepAxes(unsigned long now) {
  for (uint8_t i = 0; i < NUM_SERVOS; i++) {
    Axis& a = axes[i];
    const int rest  = gRest[i];
    const int press = gPress[i];
    switch (a.phase) {
      case Axis::IDLE:
        if (a.pending) {                       // 显式可推进条件，不用复合 busy()
          a.pending = false;
          a.phase   = Axis::OUT;
          a.t0      = now;
          servoWrite(i, rest);
        }
        break;

      case Axis::OUT: {
        unsigned long dt = now - a.t0;
        if (dt >= SWEEP_MS) {
          servoWrite(i, press);
          a.phase = Axis::HOLD;
          a.t0    = now;
        } else {
          int ang = rest + (int)((long)(press - rest) * dt / SWEEP_MS);
          servoWrite(i, ang);
        }
        break;
      }

      case Axis::HOLD:
        if (now - a.t0 >= HOLD_MS) {
          a.phase = Axis::IN;
          a.t0    = now;
        }
        break;

      case Axis::IN: {
        unsigned long dt = now - a.t0;
        if (dt >= SWEEP_MS) {
          servoWrite(i, rest);
          a.phase = Axis::IDLE;
          publishStatus(String("OK:") + a.label);   // 动作真正做完才回执
        } else {
          int ang = press - (int)((long)(press - rest) * dt / SWEEP_MS);
          servoWrite(i, ang);
        }
        break;
      }
    }
  }
}

// ====================== 【串口现场标定】 ======================
/* 为什么必须现场标定：
 *   MG90S 的舵机齿是 25 齿 → 曲柄装到轴上时，每挪一齿就是 14.4°，
 *   齿轮孔与销钉的偏心 8mm，14.4° 就是 8×sin14.4° ≈ 2.0mm 的按钮位移。
 *   所以“装到理想位置”不可能靠手感，必须用下面的命令把绝对角度试出来。
 * 标定命令只走串口，App 的 BLE 命令完全不受影响。 */
static Preferences prefs;
static bool gSel[NUM_SERVOS] = { true, true };   // 标定对象（默认两轴一起）
static int  gJog = ANGLE_REST;                    // 当前手动角度

static void calPrint(const char* why) {
  Serial.printf("[标定] %s\n", why);
  Serial.printf("        当前角度=%d°  U: REST=%d PRESS=%d%s   D: REST=%d PRESS=%d%s\n",
                gJog,
                gRest[AXIS_UP],  gPress[AXIS_UP],
                (gSel[AXIS_UP]  ? " ←选中" : ""),
                gRest[AXIS_DOWN], gPress[AXIS_DOWN],
                (gSel[AXIS_DOWN] ? " ←选中" : ""));
}

static void calJogTo(int angle) {
  angle = constrain(angle, 0, 180);
  gJog  = angle;
  for (uint8_t i = 0; i < NUM_SERVOS; i++) {
    if (!gSel[i]) continue;
    axes[i].phase   = Axis::IDLE;      // 手动模式：让状态机让位
    axes[i].pending = false;
    servoWrite(i, angle);
  }
  calPrint("已转到指定角度（看机构，按钮帽应该刚好坐在面板口）");
}

static void calSetRest() {
  for (uint8_t i = 0; i < NUM_SERVOS; i++) if (gSel[i]) gRest[i] = gJog;
  calPrint("已把当前角度记为 REST（松开位）");
}

static void calSetPress() {
  for (uint8_t i = 0; i < NUM_SERVOS; i++) if (gSel[i]) gPress[i] = gJog;
  calPrint("已把当前角度记为 PRESS（按下位）");
  for (uint8_t i = 0; i < NUM_SERVOS; i++) {
    if (gSel[i] && abs(gPress[i] - gRest[i]) > ANGLE_DELTA_LIMIT)
      Serial.printf("        ⚠ 提醒：行程 %d° 超过 %d°（默认 60°），转角太大可能把销钉顶到长槽尽头"
                    "（硬限位）憋住舵机，请先手动确认槽内还有余量！\n",
                    abs(gPress[i] - gRest[i]), ANGLE_DELTA_LIMIT);
  }
}

static void calSave() {
  prefs.putInt("ru", gRest[AXIS_UP]);   prefs.putInt("pu", gPress[AXIS_UP]);
  prefs.putInt("rd", gRest[AXIS_DOWN]); prefs.putInt("pd", gPress[AXIS_DOWN]);
  calPrint("已存进 Flash（掉电不丢）");
}

static void calClear() {
  gRest[AXIS_UP] = gRest[AXIS_DOWN] = ANGLE_REST;
  gPress[AXIS_UP] = gPress[AXIS_DOWN] = ANGLE_PRESS;
  prefs.clear();
  calJogTo(ANGLE_REST);
  calPrint("已恢复出厂默认 70 / 130");
}

static void calHelp() {
  Serial.println("[标定] 串口命令（波特率 115200，行尾选“换行”）：");
  Serial.println("        ?        查看当前角度/设置");
  Serial.println("        A70      两轴转到绝对角度 70°（找位置用）");
  Serial.println("        +1 / -2  在当前角度上微调");
  Serial.println("        U / D / B  标定对象：上行 / 下行 / 两轴");
  Serial.println("        SR       当前角度 = 松开位(REST)");
  Serial.println("        SP       当前角度 = 按下位(PRESS)");
  Serial.println("        SAVE     存 Flash；CLR 恢复默认；T 试跑一次");
}

static void calRunTest() {
  for (uint8_t i = 0; i < NUM_SERVOS; i++) if (gSel[i]) axes[i].pending = true;
  calPrint("试跑一次：REST → PRESS → 停 0.6s → REST");
}

static void handleCal(const String& raw) {
  String v = raw; v.trim(); v.toUpperCase();
  if (v.length() == 0) return;

  if (v == "?" || v == "HELP") { calPrint("当前设置"); calHelp(); return; }
  if (v == "U") { gSel[AXIS_UP] = true;  gSel[AXIS_DOWN] = false; calPrint("标定对象 = 上行"); return; }
  if (v == "D") { gSel[AXIS_UP] = false; gSel[AXIS_DOWN] = true;  calPrint("标定对象 = 下行"); return; }
  if (v == "B") { gSel[AXIS_UP] = true;  gSel[AXIS_DOWN] = true;  calPrint("标定对象 = 两轴"); return; }
  if (v == "SR") { calSetRest();  return; }
  if (v == "SP") { calSetPress(); return; }
  if (v == "SAVE") { calSave();  return; }
  if (v == "CLR")  { calClear(); return; }
  if (v == "T")    { calRunTest(); return; }
  if (v[0] == 'A' && v.length() > 1) { calJogTo(v.substring(1).toInt()); return; }
  if ((v[0] == '+' || v[0] == '-') && v.length() > 1) {
    int d = v.substring(1).toInt();
    calJogTo(gJog + (v[0] == '+' ? d : -d));
    return;
  }
  Serial.println("[标定] 不认识的命令，打 ? 看帮助");
}

// 行缓冲读串口（非阻塞）
static void pollSerialCal() {
  static char buf[24];
  static uint8_t n = 0;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\r' || c == '\n') {
      if (n > 0) { buf[n] = 0; n = 0; handleCal(String(buf)); }
    } else if (n < sizeof(buf) - 1) {
      buf[n++] = c;
    }
  }
}

// ---------------- 严格命令解析（修 startsWith("UP") 误判） ----------------
static int8_t parseServoIndex(const String& v) {
  String digits;
  for (size_t i = 0; i < v.length(); i++) if (isDigit(v[i])) digits += v[i];
  if (digits.length() == 0) return -1;
  long n = digits.toInt();
  return (n >= 1 && n <= NUM_SERVOS) ? (int8_t)(n - 1) : (int8_t)-1;
}

static void handleCommand(const String& v) {
  if (v == "PING" || v == "?" || v == "STATUS") { publishStatus("OK"); return; }
  if (v == "ALL") {
    for (uint8_t i = 0; i < NUM_SERVOS; i++) axes[i].pending = true;
    publishStatus("OK:ALL");
    return;
  }
  if (v == "UP")   { axes[0].pending = true; return; }   // 严格等值，UPLOAD 不会中招
  if (v == "DOWN") { axes[1].pending = true; return; }
  if (v.startsWith("S") || v.startsWith("PRESS")) {
    int8_t idx = parseServoIndex(v);
    if (idx >= 0) { axes[idx].pending = true; return; }
  }
  publishStatus("ERR:BADCMD");
}

// ---------------- BLE 回调 ----------------
class ServerCb : public BLEServerCallbacks {
  void onConnect(BLEServer*) override {
    Serial.println("[ble] 有手机连接");
    // 连接后继续广播：① 手机可一边连着一边靠 RSSI 测距 ② 允许更多手机连进来
    BLEDevice::startAdvertising();
  }
  void onDisconnect(BLEServer*) override {
    gRestartAdv = true;             // 交给 loop 重启广播，回调里不 delay
    Serial.println("[ble] 有手机断开，稍后重新广播");
  }
};

class CmdCb : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = String(c->getValue().c_str());
    v.trim(); v.toUpperCase();
    if (v.length() == 0) return;
    Serial.printf("[ble] 命令: %s\n", v.c_str());

    CmdMsg m{};
    v.substring(0, sizeof(m.text) - 1).toCharArray(m.text, sizeof(m.text));
    if (xQueueSend(cmdQueue, &m, 0) != pdTRUE) {   // 修：不再静默丢弃
      Serial.println("[ble] 队列满，命令被拒");
      publishStatus("ERR:QUEUE_FULL");
    }
  }
};

// ---------------- 初始化 ----------------
void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.printf("\n=== 电梯节点启动：ELEV-%s ===  (固件 v8)\n", FLOOR_NAME);

  // 读 Flash 里的现场标定值（没有就用默认 70 / 130）
  prefs.begin("servo", false);
  gRest[AXIS_UP]    = prefs.getInt("ru", ANGLE_REST);
  gPress[AXIS_UP]   = prefs.getInt("pu", ANGLE_PRESS);
  gRest[AXIS_DOWN]  = prefs.getInt("rd", ANGLE_REST);
  gPress[AXIS_DOWN] = prefs.getInt("pd", ANGLE_PRESS);

  for (uint8_t i = 0; i < NUM_SERVOS; i++) {
    servoAttach(i);
    servoWrite(i, gRest[i]);
  }
  calPrint("上电：两轴已停在 REST（松开位）");
  Serial.println("       上电后确认：销钉在长槽里、离两端都有余量（别顶到槽头）。");
  calHelp();

  cmdQueue = xQueueCreate(8, sizeof(CmdMsg));

  String devName = String("ELEV-") + FLOOR_NAME;
  BLEDevice::init(devName.c_str());
  BLEDevice::setPower(ESP_PWR_LVL_P9);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCb());

  BLEService* svc = pServer->createService(SERVICE_UUID);

  pCmd = svc->createCharacteristic(
      CMD_CHAR_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  pCmd->setCallbacks(new CmdCb());

  pStatus = svc->createCharacteristic(
      STATUS_CHAR_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pStatus->addDescriptor(new BLE2902());
  String ready = String(FLOOR_NAME) + "|READY";
  pStatus->setValue((uint8_t*)ready.c_str(), ready.length());

  svc->start();

  // 广播：带上服务 UUID + 设备名（App 用名字解析 ELEV-<楼层>）
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);          // 名字放扫描响应里，App 读 scanRecord.deviceName
  BLEDevice::startAdvertising();

  Serial.println("[ble] 广播中，等待 App 连接...");
}

void loop() {
  // 0) 串口标定命令（非阻塞）
  pollSerialCal();

  // 1) 取命令（非阻塞）
  CmdMsg m;
  if (xQueueReceive(cmdQueue, &m, 0) == pdTRUE) handleCommand(String(m.text));

  // 2) 推进舵机状态机（非阻塞）
  stepAxes(millis());

  // 3) 断线后重启广播（不在 BLE 回调里 delay）
  if (gRestartAdv) {
    gRestartAdv = false;
    BLEDevice::startAdvertising();
  }

  // 4) 连接数变化时打印一行（方便排查“几台手机连着”）
  uint32_t cc = pServer ? pServer->getConnectedCount() : 0;
  if (cc != gLastConnCount) {
    gLastConnCount = cc;
    Serial.printf("[ble] 当前连接手机数：%u\n", (unsigned)cc);
  }

  delay(2);
}
