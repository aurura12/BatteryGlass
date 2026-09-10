# Changelog

记录本项目每次修改的内容。格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，按时间倒序排列。

## [2026-09-10]

### 修复
- 修复安装替换不可回滚的问题：`install_app.sh` 先把旧 App rename 到备份路径再让新 bundle 就位，任何一步失败都恢复旧 App，避免安装目录被清空；`install_app_test.sh` 新增 staging 移动失败时的回滚用例。
- 修复登录项 `.notFound` 被等同于 `.notRegistered` 的问题：该状态也可能是服务异常或非有效 App bundle，现独立为 `.notFound`——仍允许用户发起首次注册，但 `systemLaunchAtLoginEnabled()` 返回 nil，不再在启动时用 false 覆盖已保存的开关状态。
- 修复单实例保护的时序漏洞：把实例接管前移到 `BatteryGlassApp.init` 构造核心对象之前（提取为 `AppInstanceGuard`），避免旧实例尚未退出时新实例已启动定时器并写盘导致的双进程并发写同一文件。
- 修复改分辨率或切换显示器后桌面小组件可能停留在屏幕外的问题：监听屏幕参数变化，窗口不再与任何屏幕可见区相交时移回默认位置。
- 修复「减弱动态」（`accessibilityReduceMotion`）只覆盖流体背景的问题：页面切换与分段控件胶囊滑动现在也会降级为无位移/无弹簧效果。
- 修复菜单栏充电时恒显满电图标的问题：电量图标现在始终按真实电量显示，充电状态另用一个小闪电标识（系统仅有 `battery.100percent.bolt` 一个带闪电变体）。
- 修复插电但电池仍在放电（混合供电）时电源分配卡把真实放电显示成「+0.0 W」的问题：电池侧改为显示放电功率（红色负值），不再掩盖电池放电。
- 修复历史导出 JSON 与存储格式不一致的问题：`HistoryExporter.jsonString` 提升到 v4 并导出 `sleepIntervals`，设置页导出时传入睡眠边界，避免备份丢失短睡眠区间。
- 修复开机自启动开关在首次注册前因 `SMAppService.mainApp` 返回 `.notFound` 而被错误禁用的问题。

### 新增
- 为历史页三个图表补充无障碍标签与概要值（每日耗电量、今日功率曲线、电池健康趋势），便于 VoiceOver 播报。

### 修改
- 优化历史页性能：今日样本与功率曲线数据按样本集合记忆化，避免面板 2Hz 重渲染时反复全量过滤与抽样（`TodaySamplesCache` / `PowerChartDataCache`）。
- 统一电源术语：电源分配卡的「系统估算」改为「系统直供」，功率趋势卡副标题改为准确的「适配器输入功率 / 电池放电功率」，与 README 口径一致。
- 设置窗口高度由固定 800 调整为 640，避免在可见高度较小的屏幕上超出屏幕（超出内容由表单滚动）。
- 修复文档漂移：`CODEBUDDY.md` 补全睡眠边界通知（`sleepIntervalStarted/Ended`）、history payload 版本更新为 v4（含 `sleepIntervals`）、删除对不存在的 `EnergyRingView.swift` / `PowerWaveformView.swift` 的引用、修正 `HistoryExporter` 职责描述；`README.md` 移除已废弃的「主窗口」描述、更新历史页功能说明、修正项目结构与脚本清单。
- 修正 `CODEBUDDY.md`：`LoginItemService` 现基于 `SMAppService.mainApp`（非 `SMLoginItemSetEnabled`），并记录 `.notFound → .notRegistered` 首次注册前不得禁用开关的语义。
- 更新 `CODEBUDDY.md`：补充电源状态判定（`BatteryDischargeConfirmation`）与「充满还需/剩余时间」链路（`TimeRemainingEstimator` / `ChargeRateTracker` / `TimeRemainingSmoother`）、遥测校准持久化（`PowerTelemetryCalibrationStore`）、`HistoryExporter`、单实例保护、脚本命令与完整测试类地图。
- 将应用收敛为纯菜单栏模式：移除主窗口 Scene、主窗口启动设置和 Dock reopen 路径；保留菜单栏面板、设置窗口与桌面小组件。

### 重构
- 清理死代码：删除 `FluidGlassBackground` 中未使用的 `state` 参数（同步更新 `DashboardView` 调用），删除生产代码未使用的 `HistoryExporter.csvString(samples:)` 单参重载与 `BatteryHistoryStore.samplesForDay(_:)`，并把 CSV 字段断言迁移到扩展格式。

## [2026-09-09]

### 修复
- 修复构建脚本只更新 `dist/BatteryGlass.app`、没有同步到 `/Applications` 的问题：现在构建完成后会替换安装目录中的应用，并从安装路径启动；新增 App bundle 安装替换测试。

## [2026-09-06]

### 修复
- 修正耗电量口径说明与实现：每日耗电统计的是用户从电源侧消耗的电，插电时使用适配器输入；只有连续确认“插电但电池仍放电”时，才把电池放电作为第二个独立来源加入，不把 `SystemLoad` 当作主指标。
- 修复短睡眠被普通样本梯形插值虚构计量的问题：低于 60 秒的睡眠记录为未知并阻断插值，恰好 60 秒及以上的睡眠区间与 `SleepSegment` 不重复计量。
- 修复无有效墙上能量计数器时的插电睡眠回退分支：区分充入电池能量、适配器直供和确认的电池放电，缺少来源时不把缺失误当成零；所有回退结果明确标记为估算。

### 新增
- 增加按机型与 macOS 版本保存的遥测计数器校准链路，记录保存到 `~/Library/Application Support/BatteryGlass/power-calibration.json`。校准需要同一时间窗口的实体插座电表读数；没有校准记录时继续使用系数 1.0，并标记为未校准。
- 历史文件新增睡眠边界持久化字段，兼容 v2/v3 文件。新精度逻辑只向前生效，旧每日汇总不迁移、不强行重算。

## [2026-09-05]

### 修复
- 修复「充满还需/剩余时间」兜底公式在 Apple Silicon 上把 IOPS 的 0-100 归一化容量当作 mAh 使用（`currentCapacityMAh/maxCapacityMAh` 被 88/100 污染），导致剩余时间被算成十几秒到几分钟的荒谬值。估算入口改为纯函数 `TimeRemainingEstimator`，直接消费 SmartBattery 侧真 mAh（`RemainingCapacity` / `FccComp2`·`AppleRawMaxCapacity`）与可靠 percent，不再读取被污染的容量快照字段；结果域校验 [60s, 48h]，越界显示 "--"（BatteryMonitor.swift、新增 `Models/TimeRemainingEstimator.swift`）。
- 修复系统估计缺失/无效时充电剩余时间仍用瞬时电流线性外推、数值抖动大的问题：改为短窗实测 percent 斜率外推——`ChargeRateTracker` 仅记录充电爬升点、10 分钟滑窗、首尾斜率，并拦截 1% 步进噪声、明显回退与唤醒补跳；相邻爬升点之间速率同样不得超过限速，防止单段陡升被整体均值稀释后漏过（唤醒补跳污染）（新增 `Models/ChargeRateTracker.swift`）。
- 修复放电态剩余时间同类单位 bug：兜底改为真 mAh `RemainingCapacity` ÷ 放电电流。
- 修复估算值随 2Hz 刷新跳变：新增 `TimeRemainingSmoother`（EMA 平滑、首值直通、状态切换复位、nil 即清空、上下界钳制）（新增 `Models/TimeRemainingSmoother.swift`）。
- 修复桌面小组件充电时文案误显示「剩余 X」（实际为充满所需时间）：按 `snapshot.state` 区分，「充电中」显示「充满还需 X」，与主面板文案统一（DesktopWidgetView.swift）。
- 修复 Apple Silicon 上 IOPS 的 Current/Max Capacity（0-100 归一化值）被当作 mAh 存入快照容量字段的问题，统一快照容量为真 mAh 语义：SmartBattery（gas gauge）真值优先（RemainingCapacity / FccComp2·AppleRawMaxCapacity），IOPS 值仅当量级 >500（真 mAh，如 Intel）且 SmartBattery 缺失时才兜底。此前 88/100 归一值使睡眠能耗计量被低估数十倍并造成插电待机模式判定抖动、HealthKpiCard 显示「满充 100 / 设计 8694 mAh」。新增 `resolvedCapacityMAh` 纯函数，删除旧的 `resolvedMaxCapacity`（BatteryMonitor.swift）。
- 修复 Apple Silicon 上 SmartBattery `RemainingCapacity` 缺失时当前容量读不到的问题：新增 `resolvedCurrentCapacityMAh`，回退到顶层 `AppleRawCurrentCapacity`（实测本机 6726 mAh）；「充满还需/剩余时间」估算输入同步受益（此前 AS 放电/充电容量兜底分支因 current=0 不可用）（BatteryMonitor.swift）。

### 新增
- `TimeRemainingEstimatorTests`（15 用例）/ `ChargeRateTrackerTests`（8 用例）/ `TimeRemainingSmootherTests`（5 用例）：覆盖充电/放电各分支防御顺序、「归一化容量污染不再产出荒谬值」回归用例、斜率窗口过期与噪声拦截、EMA 平滑与状态复位。
- `resolvedCapacityMAh` 四象限用例（SmartBattery 优先 / AS 归一化被拒 / Intel mAh 兜底 / 双真源取 SmartBattery）、`resolvedCurrentCapacityMAh` 键回退链用例（BatteryMonitorIOPSParsingTests、BatteryMonitorSmartBatteryTests）。

## [2026-09-04]

### 新增
- 单实例保护：启动时检测同 bundle 的既有实例，终止旧实例并等待其 flush 落盘后由新实例接管；无法终止时激活对方并退出自己。避免多进程并发写 history.json 与 power-diagnostics.jsonl（如 build_and_run.sh 每次 `open -n` 重复运行时叠出多个实例，造成历史互相覆盖、诊断行交错损坏）（BatteryGlassApp.swift，新增 `enforceSingleInstance()`）。

### 修改
- 更新 CODEBUDDY.md 架构文档与当前代码对齐：补充全部通知名清单（Extensions.swift）、待机（睡眠）补测数据流、能耗计量纯函数集群（EnergyCalculator / SleepEnergyCalculator / PowerTelemetryEnergy / DailySummary / DailyEnergySummaryPolicy / EnergyAggregator 及对应测试）、LoginItemService 与 NotificationService 的职责；刷新 BatteryMonitor 纯函数清单与 history.json payload 版本（v2 → v3：samples + dailySummaries + sleepSegments）。

## [2026-09-01]

### 修复
- 修复今日功率曲线跨天后时间窗口错乱的问题：`@State scrollPosition` 只在视图首次创建时初始化，应用跨天持续运行后样本换成新一天但滑块位置停留在昨天（用户曾滚离末尾时自动跟随不成立），图表窗口会停留在昨天的时间点显示空白/错位。现按日期给今日功率曲线加 `id`，跨天后强制重建视图并重置滑块（HistoryView.swift）。
- 修复遥测功率回退时的强制解包隐患：`s.telemetryPowerW!` 是全项目唯一强制解包点，改为局部常量后再参与运算（BatteryMonitor.swift）。
- 修复状态判定与功率符号数据源不一致的问题：`resolveState` 的电流判定原来只用电量计/IOPS 原始值，电量计电流为 0 而遥测 BatteryPower 为负（放电）时会把"放电中"误判为"已接通电源"。现与 `refresh()` 统一为三级回退（电量计 → 遥测功率/电压 → IOPS）（BatteryMonitor.swift）。
- 修复历史数据 JSON 导出版本落后的问题：导出版本由 2 升至 3，与 history.json 一致并包含待机区间（SleepSegment），未来导入不丢睡眠段能耗（HistoryExporter.swift、SettingsView.swift、HistoryExporterTests.swift）。
- 修复电池健康趋势图 y 轴上限固定 100% 的问题：新电池健康度可能超过 100%（满充容量高于设计容量），数据点会被裁剪到绘图区外，现上限随数据动态扩展（HistoryView.swift）。
- 修复启动恢复时当天待机区间能量可能被覆盖丢失的问题：诊断日志回填触发全量重算今日耗电量时，重算值不含待机区间能量，会覆盖当天已累计的睡眠段耗电量。现重算后补回与今天有交集的待机区间能量（仅补今日份额，避免昨日重复累加）（BatteryHistoryStore.swift，新增 `restoreSleepEnergy(forToday:)`）。
- 修复电量计电流为 0、回退遥测 BatteryPower 时丢弃实测符号、按状态猜测正负的问题：`signedMW` 已解析带符号功率（充电正/放电负），现直接采用实测符号，避免刚插电仍在放电、充满停充微放等瞬时状态错位时功率符号显示错误（BatteryMonitor.swift）。
- 修复"清空历史数据"后采样节流状态未重置的问题：清空后 5 秒内（且循环/健康度无变化时）新样本会被节流跳过。现清空时一并重置 `lastRecord`/`lastCycleCount`/`lastHealth`，立即恢复记录（BatteryHistoryStore.swift）。
- 修复登录项处于"待批准"状态时再次操作开关无引导的问题：系统状态为 requiresApproval 且用户期望开启时，返回 needsApproval 让设置页弹出「到系统设置批准」引导，不再静默无效（LoginItemService.swift）。
- 修复历史每日汇总加载后未按日期排序的问题：`suffix(lastDays/90/30)` 等依赖升序的取数在旧文件/异常顺序下可能取错日期范围，加载时统一按日期排序（BatteryHistoryStore.swift）。
- 修复 CSV 导出数值格式化依赖系统 locale 的问题：系统 locale 使用逗号小数分隔符（如 de_DE/fr_FR）时 `String(format:)` 输出 "3,5" 会破坏 CSV 列结构，现统一使用 POSIX locale 格式化数值（HistoryExporter.swift）。

### 修改
- README 数据来源说明同步：电量计电流为 0 时回退遥测 BatteryPower，功率符号直接采用遥测实测值，不再“按充放状态决定正负”。
- 待机能耗统计改为优先使用 `PowerTelemetryData.AccumulatedWallEnergyEstimate` 的累计差值；接电但电池仍放电时同时计入可观测的电池放电能量，计数器不可用时回退到带“估算”标记的电量差/维持功耗结果。诊断日志保留原始计数器，便于用插座电表校准各机型的计数器单位。

## [2026-08-31]

### 新增
- 待机能耗补测：监听系统睡眠/唤醒，唤醒后按「电量差法」补测待机期间电脑从电源（插座或电池）消耗的能量并计入每日耗电量——不插电待机取电池放电量，插电待机取充入电量 + 唤醒后延迟采样的系统维持功耗估算（插电充满停充时仅记维持功耗）；history.json 升 v3 持久化待机区间（SleepSegment），重启后仍可见（BatteryMonitor.swift、BatteryHistoryStore.swift、SleepSegment.swift、SleepEnergyCalculator.swift、Extensions.swift）。
- 今日功率曲线如实显示待机缺口：样本间隔超 5 分钟或落在待机区间内时断开连线、不再线性插值成虚假功率，缺口处叠加浅色背景与「待机 X · 平均 Y W（估算）」标注；待机缺口内悬停不吸附两端样本，避免误读（HistoryView.swift，新增 `PowerChartSegmentation` 纯函数）。
- 新增 `SleepEnergyCalculatorTests`（9 用例：放电/充电/充满停充/噪声钳制/短待机忽略/跨天能量拆分）、`PowerChartSegmentationTests`（7 用例：缺口分段/待机区间过滤）；`HistoryPersistenceTests` 增加 v2 兼容与 v3 往返用例。
- 菜单栏图标可显示百分比或剩余时间（设置 → 通用 → 菜单栏图标），未检测到电池时显示 "--"（MenuBarLabel.swift、Formatters.swift、AppSettings.swift）。
- 新增"启动时显示主窗口"开关：关闭后启动仅保留菜单栏图标与桌面小组件，不弹主窗口（BatteryGlassApp.swift）。
- 历史数据导出：设置页"数据与历史"新增导出菜单（CSV/JSON）。CSV 含表头（时间/功率/消耗功率/电量/循环次数/健康度），JSON 与 history.json 结构一致（HistoryExporter.swift、SettingsView.swift）。
- 外接电源变化通知：适配器接入/断开时发送本地通知（含当前电量），需在设置 → 提醒 中开启（BatteryMonitor.swift、NotificationService.swift）。
- 电池健康趋势图：历史页新增健康度折线图（近 90 天，取每日最小健康度），线条颜色随健康度状态变化（HistoryView.swift）。
- 每日耗电量图表支持"按日/按周/按月"分组查看，指标区随分组显示"周期均/总计"（EnergyAggregator.swift、HistoryView.swift）。
- 桌面小组件新增尺寸选项（紧凑/大尺寸），大尺寸额外显示温度/电压/健康度/循环次数（DesktopWidgetView.swift、DesktopWidgetController.swift、AppSettings.swift）。
- 开机自启动：设置页新增"开机自启动"开关，通过 `SMAppService.mainApp` 注册/注销系统登录项（macOS 13+），启动时用系统实际状态同步开关；注册需系统批准时弹窗引导到「系统设置 → 通用 → 登录项」，未通过 .app 包运行时禁用开关并提示（LoginItemService.swift、AppSettings.swift、SettingsView.swift、BatteryGlassApp.swift）。
- `LoginItemServiceTests` 新增 7 个用例覆盖 enabled/notRegistered/requiresApproval/unavailable 状态 × 期望开关组合；新增 `EnergyAggregatorTests`（5 用例）、`HistoryExporterTests`（3 用例）；`BatteryFormattersTests` 增加菜单栏时间与坐标轴标签用例。

### 修复
- 修复 Apple Silicon 上电池健康趋势长期无数据的问题：健康度依赖满充容量/设计容量，但原实现只读 Intel 键位（`BatteryData["FullChargeCapacity"]`），Apple Silicon 该键缺失导致健康度恒为 nil。现按键位回退解析设计容量（`BatteryData.DesignCapacity` → 顶层 `DesignCapacity` → `NominalChargeCapacity`）与满充容量（`BatteryData.FullChargeCapacity` → `FccComp2` → 顶层 `AppleRawMaxCapacity`）（BatteryMonitor.swift，新增 `resolvedDesignCapacityMAh`/`resolvedFullChargeCapacityMAh` 纯函数及 `BatteryMonitorSmartBatteryTests` 9 用例）。
- 修复待机能耗补测在睡眠前后插拔状态变化时归属错误的问题：待机模式现以睡眠前的供电状态为准（睡眠期间的实际供电状态），睡前插电、唤醒时拔电的充电待机不再被当作电池放电丢弃；睡前未插电、唤醒后插电的场景因放电量被充电掩盖而保守丢弃区间（SleepEnergyCalculator.swift，新增 2 个插拔状态变化用例）。
- 修复今日功率曲线在待机（系统睡眠）缺口处用线性插值把缺口两端直接连成一条虚假功率线的问题，缺口现断开显示（HistoryView.swift）。
- 修正 IOPS 当前供电来源的 Core Foundation ownership 处理，并忽略 NaN/∞ 系统功率遥测，避免异常数据污染功耗显示（BatteryMonitor.swift）。
- 修复 IOPS 的剩余时间字段按分钟返回却被当作秒使用的问题，避免剩余时间显示缩短 60 倍（BatteryMonitor.swift）。
- 修复未检测到电池时菜单栏 tooltip 与辅助功能标签仍显示 0% 的问题，统一显示为 --（BatterySnapshot.swift、MenuBarLabel.swift）。
- 修复通知权限被拒后设置开关仍保持开启、重新授权流程不一致的问题（NotificationService.swift、SettingsView.swift）。
- 修复 CSV 导出只包含当前保留采样的问题，现在同时导出完整每日汇总，保留长期历史信息（HistoryExporter.swift、SettingsView.swift）。
- 修复历史能耗按周/按月分组时标题仍显示“每日耗电量”的问题（EnergyAggregator.swift、HistoryView.swift）。
- 修复"接通电源 + 电池放电"（重负载边缘态）时系统功耗被错误显示为适配器输入的问题：系统功耗的适配器总输入覆盖仅在非放电状态生效，放电时改用 SystemLoad 或电池放电功率，避免数值偏低（BatteryMonitor.swift，新增 `resolvedSystemPowerW` 纯函数）。
- 修复拔电后电池 0 电流（满电待机）时系统功耗沿用陈旧的适配器值的问题：供电方式变化后不再沿用上次值，改为 nil（BatteryMonitor.swift）。
- 修复未检测到电池（unknown 状态）时实时功率卡/桌面小组件显示 "+0.0 W"、电量显示 "0%"、菜单栏图标变红的问题：无数据时显示 "--"、隐藏单位，图标降级为灰色（BatterySnapshot.swift、LiveDashboardView.swift、DesktopWidgetView.swift、BatteryStyling.swift）。
- "清空历史数据"增加确认对话框，避免误触清空全部历史（SettingsView.swift）。
- 低电量通知权限被拒时（含此前已被拒绝的情况）在设置界面弹出提示，不再静默失效（NotificationService.swift、SettingsView.swift）。
- 低电量阈值从 UserDefaults 加载时钳制到 10–50 的合法范围，避免存储值越界导致低电量误判（AppSettings.swift）。
- 功率趋势卡在无采样数据时显示 "--" 而非 "+0.0 W"，且去掉恒为正的 "+" 号（LiveDashboardView.swift）。
- 今日功率曲线 hover 提示改为跟随鼠标并钳制在图表范围内（HistoryView.swift）。
- 每日耗电量柱状图 tooltip 锚点 x 坐标钳制在绘图区内，悬停首末柱子时不再溢出卡片（HistoryView.swift）。
- 充电时电量卡文案由"剩余 X"改为"充满还需 X"（LiveDashboardView.swift）。
- 电池健康度低于 60%/80% 时分别显示红/琥珀色，不再恒为绿色（BatteryStyling.swift、LiveDashboardView.swift）。
- 历史页"每日耗电量"明细列表只渲染最近 30 天，避免长期使用后"全部"范围渲染数千行（HistoryView.swift）。
- README 动效参数表与实际代码对齐：移除已不存在的 EnergyRingView/PowerWaveformView 引用，blur 与透明度公式改为实际值。

### 新增
- `EnergyConsumptionTests` 增加 6 个用例覆盖 `resolvedSystemPowerW`：放电状态不被适配器输入覆盖、放电时 SystemLoad 优先、插电时取"适配器输入 − 充电功率"、拔电后不沿用旧值、电池供电无数据时沿用上次值、unknown 状态功率文本显示 "--"。
- `AppSettingsTests` 新增阈值钳制用例；`PowerChartInteractionTests` 新增 tooltip 锚点边缘钳制用例。

## [2026-08-29]

### 修复
- 修复断开适配器且缺少 BatteryPower 遥测时系统功耗沿用旧值的问题；增加电气功率和 SmartBattery 满充容量兜底，并确保快照通知在退出 flush 前同步记录。
- 历史与电源诊断文件改为限量读取，并增加样本/汇总对象数量上限，降低被异常本地文件拖慢启动或占用过多内存的风险。
- 修复今日功率曲线在横向滚动时将可视时间窗外的历史点绘制到左侧 Y 轴区域的问题：现在仅绘制当前可视时间窗内的曲线样本，避免曲线与坐标轴重叠（HistoryView.swift）。
- 桌面小组件与主面板"实时功率"取值统一：新增 `BatterySnapshot.displayPower`/`displayPowerText`，适配器供电时显示系统功率（适配器输入 → 系统功率 → 电池功率，无符号），电池供电时显示充放电功率（带正负号）；小组件不再显示与主面板含义不同的电池侧功率（充满电时不再出现 "+0.0 W"）（BatterySnapshot.swift、DesktopWidgetView.swift、LiveDashboardView.swift）。
- 历史/诊断文件加载增加大小上限：历史文件 20 MB、诊断文件 50 MB，超限跳过加载，防止本机被篡改的文件导致启动卡顿或内存暴涨（BatteryHistoryStore.swift、HistorySampleRecovery.swift）。
- 移除 `list as? [AnyObject]` 恒成功转换警告（BatteryMonitor.swift）。

### 修改
- 修正 `systemPowerW` 取值逻辑的注释（优先 SystemLoad → 适配器输入 − 充电功率 → 放电功率，有 SystemPowerIn 时覆盖为直供估算）。
- README 同步：系统功耗取值说明、电源分配公式、持久化间隔改为"每 15 秒持久化（退出前 flush）"。

### 新增
- `EnergyConsumptionTests` 增加 3 个用例：`displayPower` 在已接通电源时优先适配器输入、无输入时回退系统功率、电池供电时取充放电功率。

### 修复
- `BatteryMonitor.readPowerSources()` 未设置 `externalConnected`：现根据 `kIOPSPowerSourceStateKey == kIOPSACPowerValue` 判断是否接入交流电源，修复 IOKit fallback 在 SmartBattery 读取失败时误判为电池供电的问题（BatteryMonitor.swift）。
- IOPS fallback 路径的适配器电流 `kIOPSPowerAdapterCurrentKey` 单位为 mA，此前未转换导致数值放大 1000 倍：现统一 `/1000` 转为 A，与 SmartBattery 路径一致（BatteryMonitor.swift）。

### 重构
- 将 IOPS 电源描述与适配器信息的解析逻辑提取为 `parsePowerSourceDescription(_:initial:)` 与 `applyAdapterDetails(_:to:)` static 方法，便于单元测试。

### 修改
- 为 `readPowerSources()` 与 `IOPSPowerSourceState` 补充注释，总结 externalConnected 两步判定逻辑：单电源描述按 `kIOPSPowerSourceStateKey` 判断（仅 AC 为外部供电），UPS 通过 `IOPSGetProvidingPowerSourceType` 检测并视为外部供电。

### 新增
- `BatteryMonitorIOPSParsingTests`：7 个用例覆盖 AC/电池电源状态判断、缺失状态键、电压/电流单位换算、适配器电流 mA→A 转换及零值处理。
- IOPS UPS 供电支持：新增 `BatteryMonitor.IOPSPowerSourceState` 枚举（AC/Battery/UPS），UPS 供电时视为外部供电，不误判为电池放电。UPS 不在 `kIOPSPowerSourceStateKey` 取值内，改用 `IOPSGetProvidingPowerSourceType()` 检测；补充 4 个枚举映射测试用例。

## [2026-08-29] 初始记录

### 新增
- 创建 `changelog.md`，作为项目修改记录文件。
