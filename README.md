# BatteryGlass

一款轻量、优雅的 macOS 菜单栏电池监测应用，以 macOS 27 为基准开发，使用系统 Liquid Glass（流体玻璃）材质，并在 macOS 14/15 上自动降级为原生毛玻璃。

## 功能

- 常驻菜单栏（不占用 Dock）：自定义闪电徽章图标，随充电/放电/低电量变色，不显示百分比，与系统电池图标明显区分
- 主窗口：启动时显示仪表盘窗口，双击应用可重新打开
- 桌面小组件：常驻桌面层级的紧凑电池卡片（默认开启，可拖动、悬停关闭、设置中可重置位置）
- 实时数据（IOKit，2 Hz 采样，资源占用低）：
  - 电量百分比与充电/放电剩余时间
  - 循环次数（cycle count）
  - 健康度（FullChargeCapacity / DesignCapacity）
- 实时功率，精确到 0.1 W：电池供电时显示电池充放电功率（带正负号），
  适配器供电时显示当前系统功率（无符号），接入 PowerTelemetryData 遥测
- 系统功耗（PowerTelemetryData.SystemLoad，即系统自身消耗，不含电池充电）
- 电源分配（外接电源时）：给电池充电功率 / 系统直供功率 / 适配器输出合计
  （直供 = SystemLoad；适配器输出 = 直供 + 充电功率）
  - 电池温度（°C）、电压（V）
  - 电源适配器状态、功率、电压、电流、名称
- 可视化：
  - KPI 卡片：电量 / 实时功率 / 循环次数 / 电池健康（统一玻璃模块，等高布局）
  - 功率趋势数值卡（近 2 分钟峰值 / 平均功率）
  - 电源分配卡（外接电源时）：给电池 / 系统直供 / 适配器输出
  - 指标行：温度 / 电压 / 系统功耗 / 适配器
  - “实时 / 历史”分段控件与页面切换动画（液态玻璃高亮胶囊 + 滑动/缩放/模糊过渡）
- 历史记录：
  - 今日功率曲线、循环次数记录（健康度以实时卡片展示）
  - 每 5 秒持久化到 `~/Library/Application Support/BatteryGlass/history.json`
- 低电量通知：可自定义阈值（10–50%），本地通知，无网络
- 深色/浅色模式自适应，无需任何网络权限

## 系统要求与适配

- 标准：macOS 27（本机 SDK 已验证，Swift 6.4 / macOS 27 SDK）
- 兼容：macOS 14/15，Liquid Glass API 自动降级为 `.ultraThinMaterial` / `.regularMaterial`
- 设计说明：菜单栏常驻应用（`LSUIElement = true`，无 Dock 图标）+ 启动时显示主窗口；双击 `.app` 可打开仪表盘

## 构建与运行

需要 Xcode Command Line Tools（含 macOS 27 SDK），或完整 Xcode。

```bash
./script/build_and_run.sh          # 打包并启动
./script/build_and_run.sh --verify # 启动并确认进程存在
./script/build_and_run.sh --logs   # 启动并跟随日志
```

脚本会执行 `swift build`、生成 `dist/BatteryGlass.app`（含 Info.plist、ad-hoc 签名），再用 `open -n` 启动。

也可以直接用 Xcode 打开 `Package.swift` 运行。

## 项目结构

```
Sources/BatteryGlass/
├── App/                 # @main 入口、AppDelegate（accessory 策略）
├── Models/              # BatterySnapshot、PowerSample、HistorySample
├── Services/            # BatteryMonitor（IOKit）、NotificationService
│                        # DesktopWidgetController（桌面小组件窗口）
├── Stores/              # AppSettings、BatteryHistoryStore
├── Support/             # 格式化、配色、Liquid Glass 修饰器
└── Views/               # 面板、环形仪表、波形、历史图表、设置
script/build_and_run.sh  # 一键构建/运行/验证
scripts/generate_icon.swift  # 重新生成应用图标（矢量绘制 → AppIcon.icns）
Resources/  # AppIcon.iconset 与 AppIcon.icns
design-system/batteryglass/  # ui-ux-pro-max 设计系统（MASTER.md）
.codex/environments/     # Codex Run 按钮配置
```

## 数据来源

- `IOPowerSources`（IOPSCopyPowerSourcesInfo / IOPSGetPowerSourceDescription / IOPSGetTimeRemainingEstimate）：状态、容量、剩余时间、适配器
- `AppleSmartBattery`（IOServiceMatching + IORegistryEntryCreateCFProperties）：`CycleCount`、`BatteryData.DesignCapacity`、`BatteryData.FullChargeCapacity`、`Voltage`、`InstantAmperage`、`Temperature`、`AdapterDetails`、`PowerTelemetryData`
- 功率 = 电压(V) × 电流(A)，来自 `InstantAmperage`（充电为正、放电为负）
- 当电量计电流为 0 时，回退到 `PowerTelemetryData.BatteryPower`（mW）并按充放状态决定正负

## UI 设计系统

面板与窗口 UI 依据 `ui-ux-pro-max` 技能重做，采用 **Executive Dashboard** 模式：
4 个大号 KPI 卡片（电量/功率/循环/健康）+ 功率趋势数值卡 + 紧凑指标行，
交通灯状态色（绿/琥珀/红）、蓝色数据色、8pt 间距栅格、等宽数字排版、
轮廓图标且状态永不只靠颜色传达、150–300ms 微交互、reduced-motion 降级。
设计系统基准见 `design-system/batteryglass/MASTER.md`。

状态栏图标与应用图标为同一视觉语言：渐变圆角徽章 + 白色闪电，与系统电池图标完全不同。

## 流体玻璃动画参数调节

所有动效参数集中在两处：

### 设置界面（运行时可调，持久化到 UserDefaults）

- **玻璃浓度** `animationIntensity`（0.1–1.0）：控制流体层透明度（`0.30 + 0.45 × 浓度`）、光泽高光强度（`0.16 × 浓度`）、能量光点速度
- **流动速度** `animationSpeed`（0.3–2.0）：所有相位动画的时间倍率

### 代码级参数（`Views/FluidGlassBackground.swift`、`Views/PowerWaveformView.swift`、`Views/EnergyRingView.swift`）

| 参数 | 位置 | 作用 |
| --- | --- | --- |
| `phase * 9` 与 `angle + 230` | FluidGlassBackground | 主色带旋转速度与角度跨度 |
| `offset x/y: sin(phase*0.35)*48`、`cos(phase*0.27)*40` | FluidGlassBackground | 次级光斑漂移幅度 |
| `blur(radius: 34 / 46)` | FluidGlassBackground | 流体柔化程度 |
| `sin(phase * 0.22)` 高光端点 | FluidGlassBackground | 光泽折射扫动周期 |
| `sin(phase * 0.8)` 的 shimmer 位置 | PowerWaveformView | 波形光泽流动速度 |
| `40 + 60 × intensity` | EnergyRingView.EnergyFlowDot | 能量环光点角速度 |

调节建议：想让玻璃更“液态”可提高 `intensity` 并减小 blur；想要更沉稳可把 `speed` 调到 0.5 左右。60 fps 动画只在面板可见时运行（`TimelineView` 生命周期），面板关闭后零开销。

## 已知说明

- 未做沙盒/公证（本地开发构建）；如需上架或分发，需完整 Xcode 做签名与公证。
- 首次启用低电量通知时会请求系统通知权限。
- 桌面小组件是应用内悬浮窗口（位于桌面图标层级之上、普通窗口之下），
  不是系统 WidgetKit 小组件；系统小组件需要 Xcode 的 App Extension 工程支持。
