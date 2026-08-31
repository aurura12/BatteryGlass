# Changelog

记录本项目每次修改的内容。格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，按时间倒序排列。

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
