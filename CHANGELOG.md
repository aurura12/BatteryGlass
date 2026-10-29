# Changelog

记录本项目每次修改的内容。格式参照 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，按时间倒序排列。

## [2026-10-29]

### 修复
- 面板历史页与放大窗口同时查看不同日期时不再互相清缓存：`BatteryHistoryStore` 的归档缓存是单槽的（`cachedArchiveDay` + `cachedArchiveSamples`），一边看今日、另一边看往日时每次刷新都会重新打开 SQLite 查一遍并覆盖对方的缓存，`samplesAsync` 的异步读取收益被抵消大半。现在改成按日缓存最近 3 天（`cachedArchiveDays` + 使用顺序，超限淘汰最久未用的一天），合并结果单独按「日期 + 热层数量 / 末条 id / 内容版本 / 当前自然日」缓存，写入某天归档时只失效该日的合并结果；`pruneHistory` 与 `clearHistory` 统一走 `invalidateArchiveCache()`。补 `testInterleavedDaysKeepTheirOwnArchivedSamples`（两天交替同步 / 异步读取都取到各自的样本）。（`Stores/BatteryHistoryStore.swift`、`Tests/BatteryGlassTests/LongTermHistoryTests.swift`）

- 唤醒补采任务不再与 `BatteryMonitor` 互相持有：`startWakeValidation` 的 `Task` 闭包在循环外 `guard let self` 强引用了整个任务周期，而任务句柄又由实例持有——补采窗口内（最多 5×2 秒）`deinit` 永远不会执行，里面取消任务的逻辑成了死代码。现在补采间隔与次数在创建任务前取成局部常量，`self` 只在每一轮短暂持有。顺带按编译器告警把 `timer` / `workspaceObservers` / `wakeValidationTask` / `maintenanceTimer` 标为 `@ObservationIgnored`（`@Observable` 展开成计算属性后 `nonisolated(unsafe)` 被判定无效，rebuild 会报 4 条警告），构建恢复零警告。（`Services/BatteryMonitor.swift`）

- 每日耗电量图表的像素用例不再因偶发差异打断整轮测试：该用例用颜色统计柱子，而图表上方的指标数值用的是同一主题色、坐标轴标签的字形边缘也会被次像素抗锯齿染出蓝色，落进按颜色判定的结果里；断言失败后代码仍按索引取 `labelColumnRanges[0]`，`Fatal error: Index out of range` 直接把测试进程杀掉（今天 17:20 的一次全量运行里 16≠14、0≠5 后崩溃，后续约 450 个用例没跑）。现在窗口固定 `.aqua` 外观、只统计「蓝色一直延伸到基线」的列（排除指标数值与标签毛边），并在按索引取值前先 `guard` 断言数量。（`Tests/BatteryGlassTests/PowerChartInteractionTests.swift`）

- 诊断回填不再写入重复样本：`HistorySampleArchive` 的主键是完整时间戳（含小数秒），但 payload 用 ISO 8601 编码、读取时也用 `.iso8601` 解码，小数秒被截断。重启后内存样本的时间戳与 `live_samples` 主键不一致，回填按时间戳 upsert 就变成新增一行——库里出现两条同 id 的记录，重启后被一并加载（JSON 无边界样本时 `mergeLiveSamples` 也不会按 id 合并）。现在读取时用行内的 `timestamp` 列覆盖解码结果（`decodeSample(_:timestamp:)`），内存时间戳与主键逐位一致，回填走覆盖路径。补 `testLiveSamplesPreserveSubsecondTimestamps` 与 `testDiagnosticsRecoveryOverwritesArchivedRowInsteadOfAppending`（断言回填后归档仍只有一行、重启后数值保留）。（`Stores/HistorySampleArchive.swift`、`Tests/BatteryGlassTests/HistorySampleArchiveTests.swift`、`Tests/BatteryGlassTests/HistoryPersistenceTests.swift`）

- 旧版历史的往日样本不再错过诊断回填：`load()` 原先先 `pruneHistory()` 归档、再调度回填，而 `needsDiagnosticsRecovery()` 只看今天——v8 及更早 `history.json` 里的往日样本被移出热层之后，即使诊断日志仍有对应读数也无法再补功率（`e6ed85a` 之前是对全部样本回填的）。现在回填覆盖内存中的全部样本，并在回填结束（含无需回填、解析失败）后由 completion 再调 `pruneHistory()`；回填期间 `pruneHistory()` 直接返回，避免 `record()` 抢先把待补样本归档。往日回填值写入分钟表、当天写入 `live_samples`。补 `testLegacyHistoricalSamplesAreRecoveredBeforeArchiving`（v8 文件里的昨日样本先回填再归档）。（`Stores/BatteryHistoryStore.swift`、`Tests/BatteryGlassTests/HistoryPersistenceTests.swift`）

- 诊断回填后图表与缓存不再停留在旧数据：回填只替换样本的 `consumptionPowerW`，数量与末条 id 都不变，而 `TodaySamplesCache`、`PowerChartDataCache`、`BatteryLevelChartDataCache`、`PowerChartSegmentCache`、`BatteryLevelSegmentCache` 以及 `BatteryHistoryStore.samples(forDay:)` 的记忆化都以「数量 + 末条 id」为键，因此会一直返回回填前的结果（记录关闭时没有新样本，旧曲线永久保留）。现在 `BatteryHistoryStore` 新增 `samplesVersion`（在加载、回填、跨天归档、清空时自增；仅追加样本仍靠数量与 id 判定，不额外失效），上述缓存键与放大窗口的 `ReloadKey` 一并带上它；`PowerChartData` / `BatteryLevelChartData` 记录 `sourceVersion` 供段缓存使用。补 `testCachesRebuildWhenSampleContentVersionChanges` 与 `testDiagnosticsRecoveryInvalidatesSampleCaches`。（`Stores/BatteryHistoryStore.swift`、`Views/HistoryChartCaches.swift`、`Views/HistoryChartModels.swift`、`Views/HistoryView.swift`、`Views/ChartDetailView.swift`、`Tests/BatteryGlassTests/PowerChartDataTests.swift`、`Tests/BatteryGlassTests/HistoryPersistenceTests.swift`）

- 清空历史后曲线与日期导航不再错位：`HistoryView` 的 `activeDay` 直接读 `selectedDay`，而导航器用的 `HistoryDaySelection` 在选中日被清理后会回退到今天——清空历史后导航器显示「今日」、两侧箭头都不可用，两张图却仍标着旧日期并展示旧曲线。现在 `activeDay` 取自导航器解析后的 `daySelection.selected`，并新增 `isShowingToday` 统一决定「走今天的实时样本还是归档曲线」（`renderedSamples`、冻结快照、`reloadArchivedDayIfNeeded`、`ReloadKey` 都改用它），两者不会再出现各说各话。（`Views/HistoryView.swift`）

- 关闭历史记录后「今日累计耗电」不再看着像在正常更新：卡片原先只按已有汇总决定告警，用户当天关掉记录后数值停在关闭那一刻，图标仍是普通信息图标、文案仍是「查看统计说明」，看不出后续耗电没有计入。现在 `TodayEnergyDisplay` 接收 `recordingEnabled`（实时页与离屏冻结快照都传 `settings.recordHistory`）：记录关闭时数值旁显示感叹号、质量标签变为「记录已关闭」，说明弹层给出「历史记录已关闭，之后的使用未计入今日耗电」，关闭前已有的采样断点等原因一并保留；关闭后当天没有任何数据时仍显示「暂无有效数据」，但说明里会指出记录已关闭。补 `testRecordingDisabledMarksTheValueAsStopped`。（`Views/LiveDashboardView.swift`、`Views/DashboardView.swift`、`Tests/BatteryGlassTests/TodayEnergyDisplayTests.swift`）

## [2026-10-28]

### 修改
- 今日累计耗电的整条状态提示改为数值旁的 11pt 小图标：有告警时显示感叹号，点击图标才展开具体原因；取消整张卡片的点击动作，说明弹层缩窄并只保留简短说明，图标保留独立的键盘与 VoiceOver 焦点。（`Views/LiveDashboardView.swift`）
- 实时页将「功率与今日耗电」三列混排拆为同一行的两张玻璃卡片：「近 2 分钟功率」按平均 / 峰值显示 W，「今日累计耗电」独立显示 kWh。单位弱化、时间范围前置，移除会混淆整组数据口径的共用供电副标题；耗电质量以「含估算」「记录不完整」「未校准」等文字提示，点击整张耗电卡可查看完整原因、统计范围与单位说明。沿用紧凑布局和离屏冻结，缺失或非法耗电值显示占位符。补充展示状态测试并同步 README / CODEBUDDY。（`Views/LiveDashboardView.swift`、`Tests/BatteryGlassTests/TodayEnergyDisplayTests.swift`）

### 修复
- 历史页空态说明「为什么没有数据」：原先关闭「记录充放电历史」或历史文件读取失败（`persistenceIssue`）时，历史页只显示通用的「暂无…」，电量图甚至固定写「应用运行后每 5 秒记录一次」，容易让人以为采样坏了。现在 `HistoryView` 顶部按情况显示提示条（持久化故障优先、橙色；用户主动关闭为次要样式），三张图的空态文案由新增的 `HistoryRecordingNotice` 统一给出；面板与放大窗口共用同一套判断。补 `HistoryRecordingNoticeTests` 覆盖提示优先级与文案。（`Views/HistoryView.swift`、`Views/ChartDetailView.swift`、`Views/HistoryPowerChart.swift`、`Views/HistoryBatteryLevelChart.swift`、`Views/HistoryEnergyChart.swift`、`Support/HistoryRecordingNotice.swift`、`Tests/BatteryGlassTests/HistoryRecordingNoticeTests.swift`）
- 外接电源变化通知开启时不再静默失败：原先只有低电量开关会请求通知授权，如果用户从未开过低电量通知，直接打开「外接电源变化通知」时授权状态仍是 `.notDetermined`，系统既不弹窗也不送达。现在两个开关共用 `requestNotificationAuthorization`，拒绝时回滚开关并提示；提示文案改为同时覆盖两类提醒。（`Views/SettingsView.swift`）
- 拖动「流动速度」滑块不再让玻璃光斑瞬移：`FluidGlassBackground` 原先用「绝对时间 × 速度」计算相位，速度一变等于把相位整体缩放，`sin`/`cos` 立即跳到任意位置。新增 `FluidGlassPhase`（基准 + 时长 × 速度），速度变化时先把旧速度走过的角度并入基准再重新计时，相位保持连续；补 `FluidGlassPhaseTests` 覆盖单次与连续变速。（`Views/FluidGlassBackground.swift`、`Tests/BatteryGlassTests/FluidGlassPhaseTests.swift`）

### 优化
- 无障碍标注补全：实时页 KPI 卡片、功率趋势、电源分配与指标单元格合并为单一 VoiceOver 焦点（原先「电量 / 80 / % / 剩余…」会被拆成多个焦点）；桌面小组件同样合并播报，并新增「关闭小组件」自定义动作（关闭按钮只在悬停时出现，键盘/VoiceOver 无法触达）；设置页三个 Slider 补上用途标签与格式化数值（低电量提醒阈值 / 玻璃浓度 / 流动速度），数值行从无障碍树隐藏避免重复播报；日期导航菜单补 `accessibilityLabel/Value`；页头状态合并；`SlimBar` 进度条与流体玻璃背景标记为装饰。用 AX 树逐项验证：卡片显示为 `电量、100、%、——` 等单一 `AXStaticText`，日期菜单为 `AXMenuButton | 选择日期 | 今日`。（`Views/LiveDashboardView.swift`、`Views/StatsGridView.swift`、`Views/DesktopWidgetView.swift`、`Views/SettingsView.swift`、`Views/HistoryDayNavigator.swift`、`Views/DashboardView.swift`、`Views/FluidGlassBackground.swift`）
- 诊断日志解析移出启动主线程，并按需触发：`BatteryHistoryStore.load()` 原先无条件读取 `power-diagnostics.jsonl` 及其备份（最多 50 MB/10 万行，实测 18k 行/8.7 MB 需 **207 ms**）并逐行解码，全部发生在主线程、`BatteryGlassApp.init` 期间。现在只有**今天确实存在 `consumptionPowerW == nil` 的样本**时才启动后台任务，文件读取与解码在 `Task.detached(.utility)` 执行；结果回到主线程后补进样本、重算今天汇总与采样质量、按时间戳覆盖写回 `live_samples` 并 flush。`clearHistory()` 会取消尚未完成的任务。读取器改为可注入（`diagnosticsLoader`），测试不再触碰真实日志。（`Stores/BatteryHistoryStore.swift`、`Tests/BatteryGlassTests/HistoryPersistenceTests.swift`）
- 当天曲线改为**增量写入**，`history.json` 不再随当天时长变大：新增 `history.sqlite` 的 `live_samples` 表（`timestamp` 主键，保留 5 秒原生精度），每 15 秒只追加水位之后的新样本；`history.json` 的 payload 升到 **v9**，只保存每日汇总、睡眠数据与跨午夜边界样本（通常 0~1 条）。跨天时 `archiveLiveSamples(before:)` 把昨日样本按分钟桶降采样进 `samples` 表并删除，重启时合并 `live_samples` 与边界样本（并用 `lastLiveSample(before:)` 补跨午夜样本）恢复当天曲线与积分边界；旧版 v8 文件首次启动会自动把当天全部样本回填进归档并缩掉 JSON。实测同一台机器：`history.json` 从 833 KB（3872 条样本、持续增长）降到 101 KB 且大小恒定，每 17 秒仍写一次；当天样本在重启后完整保留（3886 → 3887 条）。（`Stores/HistorySampleArchive.swift`、`Stores/BatteryHistoryStore.swift`）
- 补测试：归档当天表的原生精度/同时间戳幂等/跨天降采样与删除/边界样本查询；`HistoryPersistenceTests` 锁定「当天样本只进归档、不进 JSON，重启后仍能恢复」。（`Tests/BatteryGlassTests/HistorySampleArchiveTests.swift`、`Tests/BatteryGlassTests/HistoryPersistenceTests.swift`、`Tests/BatteryGlassTests/LongTermHistoryTests.swift`）
- 桌面小组件只在显示内容变化时重绘，并跟随真实遮挡状态：`BatteryMonitor.shouldPublish` 的 `.widget` 分支原先每满 1 秒就无条件发布，即使百分比、功率与剩余时间都没变；现在改为比较小组件实际渲染的字段（百分比、状态、功率文本、剩余时间文本、适配器、健康度、循环次数），内容不变就不重绘，插拔等状态跃迁仍可立即发布。`DesktopWidgetController` 新增 `windowDidChangeOcclusionState`，小组件被其他窗口完全盖住（或在别的 Space）时上报不可见，`BatteryMonitor` 随即退回 `.background` 档，窗口重新露出时自动恢复。实测空闲（面板关闭、小组件被其他窗口遮挡）CPU 由约 2.0% 降到约 0.55%（60 秒 CPU 时间增量 1.18 s → 0.33 s）；30 秒心跳仍会在遮挡期间兜底刷新。（`Services/BatteryMonitor.swift`、`Services/DesktopWidgetController.swift`）
- 面板离屏时冻结实时页：`DashboardView` 在面板关闭时保存最后一份 `BatterySnapshot` 与 `recentPower`，`LiveDashboardView` / `DashboardHeader` / `DashboardPanelBackground` 通过可选参数读取冻结数据——非 nil 时不再读取 `BatteryMonitor`（`??` 的惰性求值保证不建立观察依赖），离屏内容不再随每秒发布重算 4 张 KPI 卡片、功率趋势、指标网格与玻璃光晕；面板重新打开时清除冻结值并立即发布最新快照。`publish` 也只在面板可见时写 `recentPower`，避免无消费者的赋值触发离屏视图与数组拷贝。（`Views/DashboardView.swift`、`Views/LiveDashboardView.swift`、`Services/BatteryMonitor.swift`）
- 补发布策略测试：小组件显示内容不变时满 1 秒仍不发布、功率文本（0.1 W）变化时发布、不足 1 秒的功率抖动不发布；原「每秒必发布」用例改为新语义。（`Tests/BatteryGlassTests/BatteryMonitorPublishPolicyTests.swift`）

### 新增
- 实时页新增「今日耗电」：取自 `BatteryHistoryStore.todaySummary`，在「功率与今日耗电」卡片内作为第三列（2 分钟峰值 / 2 分钟平均 / 今日耗电）。面板高度固定 672pt、实时页内容区已被占满，用 AX 实测单独加一行会把内容撑出面板（内容区 632pt），因此放进现有卡片是零高度成本。睡眠段估算、采样缺口等质量标记时数值染成琥珀色并给出原因（新增 `DailyEnergyQuality.warningText`，与历史页每日明细角标共用）；离屏冻结同步包含今日能耗（`LiveDashboardRenderedData` / `TodayEnergyDisplay`），隐藏面板不会因每 5 秒的汇总更新重算。补 `TodayEnergyDisplayTests` 与 `DailyEnergyQualityTests` 的 warningText 用例。（`Views/LiveDashboardView.swift`、`Views/DashboardView.swift`、`Stores/BatteryHistoryStore.swift`、`Models/HistorySample.swift`、`Tests/BatteryGlassTests/TodayEnergyDisplayTests.swift`）
- 历史页可在菜单栏面板内直接切换日期：原先面板固定展示今天，想回看昨天必须点开放大窗口里的小图标。现在「功率 / 电量曲线」上方新增 `◀ 今天 ▶` 日期导航（左右箭头逐天 + 点日期弹菜单，菜单只渲染最近 120 天），与放大窗口共用新增的 `Views/HistoryDayNavigator.swift`；往日曲线通过 `samplesAsync(forDay:)` 在持久化队列异步读取，不在 `body` 里同步查 SQLite。面板用 `followsToday` 区分「跟随今天」与「固定查看某天」：跟随今天时跨午夜自动切到新的一天，选择往日则停留在该日；面板关闭时往日曲线直接复用已加载的归档样本（静态数据不重复冻结），今天仍沿用冻结快照。（`Views/HistoryView.swift`、`Views/HistoryDayNavigator.swift`、`Views/ChartDetailView.swift`）
- 新增可自定义主题色：设置页「外观」分节提供 6 个预设色块与自定义取色器，选择结果以 `#RRGGBB` 持久化到 UserDefaults（`themeAccentHex`）。主题色经环境值 `\.themeAccent` 注入面板、放大窗口与桌面小组件，替换原先固定的数据蓝：曲线与填充、强调数值、系统直供指示、循环进度条、玻璃光晕跟随主题；充电绿与低电量黄/红等语义色保持不变。默认值仍为 `#127AF5`，未设置时外观与旧版本一致；原先仅电池放电使用的 `dischargeBlue` 一并并入主题色。（`Support/ThemeAccent.swift`、`Stores/AppSettings.swift`、`Views/SettingsView.swift`、`Support/BatteryStyling.swift`、`Support/DesignTokens.swift`、`Views/DashboardView.swift`、`Views/LiveDashboardView.swift`、`Views/HistoryView.swift`、`Views/ChartDetailView.swift`、`Views/DesktopWidgetView.swift`、`Views/FluidGlassBackground.swift`、`Services/ChartWindowController.swift`、`App/BatteryGlassApp.swift`、`Tests/BatteryGlassTests/ThemeAccentTests.swift`）
- 补导出写盘测试：`HistoryExporter.write` 覆盖 CSV 表头与行数、JSON 可解码，以及编码失败时目标文件保持原样；`LongTermHistoryTests` 新增「异步导出与同步导出结果逐条一致」。（`Tests/BatteryGlassTests/HistoryExporterTests.swift`、`Tests/BatteryGlassTests/LongTermHistoryTests.swift`）
- 补电源诊断日志轮换测试：把日志目录、文件名、大小阈值与节流间隔改为可在 `init` 注入（默认单例仍写 `~/Library/Application Support/BatteryGlass/power-diagnostics.jsonl`，行为不变），新增 `PowerDiagnosticsLoggerTests` 用临时目录验证逐条追加、超限时先轮换再写、以及连续轮换只保留一份备份。此前这段逻辑零覆盖——测试若走默认路径会污染真实日志。（`Services/PowerDiagnosticsLogger.swift`、`Tests/BatteryGlassTests/PowerDiagnosticsLoggerTests.swift`）
- 新增跨午夜断点的回归测试：昨晚退出、今早启动时，22:50→00:00 与 00:00→09:00 两段分别记入昨天和今天的质量标记。核查确认现有实现（`recordUnaccountedTime` 按 `daySegments` 拆天）已正确处理该场景，无需改动业务代码。

### 优化
- 导出历史不再占用主线程：原先设置页在 `NSSavePanel` 回调里同步读取整个 `history.sqlite`（按分钟归档，一年约 52 万行），再在主线程完成 CSV/JSON 编码与写盘，导出期间设置页完全无法响应。现在新增 `allCurveSamplesAsync()`——归档读取、解码、去重与排序都在持久化队列执行，主线程只取一次热层快照；编码与写盘交给 `Task.detached`。导出期间菜单禁用并显示「正在导出…」，失败仍弹既有提示。（`Stores/BatteryHistoryStore.swift`、`Support/HistoryExporter.swift`、`Views/SettingsView.swift`）
- 放大窗口不再在主线程同步查 SQLite，也只在可见时刷新：`ChartDetailView` 的 `body` 原先直接调 `samples(forDay:)`（内部 `persistenceQueue.sync`，遇到归档导入或 `history.json` 写盘最长可阻塞 `busy_timeout` 5 秒），且窗口关闭后仍每 5 秒重算整日曲线。现在样本经新增的 `BatteryHistoryStore.samplesAsync(forDay:)` 在持久化队列读取并复用同一套缓存；`ChartDetailModel.isVisible` 由窗口 delegate 同步（关闭、最小化、被遮挡），不可见时视图不读取样本计数也不发起查询，重新显示时补加载。切换日期先清空旧样本，避免旧曲线配新时间轴。（`Views/ChartDetailView.swift`、`Services/ChartWindowController.swift`、`Stores/BatteryHistoryStore.swift`）
- 曲线悬停不再按指针频率重算整图：原先把光标位置写入 `@State`，鼠标每移动一像素就重跑睡眠过滤、断点切分与降采样（10 分钟窗口约 1.4k 样本、每次数万次比较）。现在只在吸附样本切换时更新悬停状态，并把「可见段 / 降采样结果」与「电量图填充 / 缺口连线 / Y 域」分别记忆化为 `PowerChartSegmentCache`、`BatteryLevelSegmentCache`——窗口与样本不变时直接复用，悬停只插入高亮点。切换日期时一并清除悬停状态，修复放大窗口按天回看时 tooltip 仍显示上一天数据的问题。（`Views/HistoryView.swift`）

### 修改
- 面板动态字号改为显式策略：原先 `DashboardView` 直接用 `dynamicTypeSize > .large` 判定滚动回退，但界面几乎全是固定字号，系统字号放大时只有 `.caption` 会变化，容易在固定卡片高度里截断。现在面板根部用 `.dynamicTypeSize(.xSmall...`.xxxLarge)` 限定支持范围，判定抽成可测的 `PanelLayoutPolicy`（`.xLarge` 起切滚动）。没有采用「实测内容高度再切换」：那需要把测量写回 `@State`，会与面板 2Hz 重渲染形成布局反馈环（与 `ChartZoomInteraction` 里记录的问题同类）。（`Views/DashboardView.swift`、`Support/DesignTokens.swift`）

### 优化
- 补桌面小组件位置决策的测试：把「恢复位置需与屏幕相交」「右上角默认位置」抽成纯函数 `DesktopWidgetFramePolicy`，新增 `DesktopWidgetFramePolicyTests`；同时去掉 `PowerChartInteractionTests` 里的 `first!` / `last!`，改为 `guard` + `compactMap`，断言失败不再让整个测试进程崩溃。（`Services/DesktopWidgetController.swift`、`Tests/BatteryGlassTests/DesktopWidgetFramePolicyTests.swift`）
- 放大窗口的日期菜单只渲染最近 120 天：原先遍历全部可选日期为每一天构建 `Button`（多年历史时每次刷新都重建上千个视图，即使菜单没打开）。更早的日期仍可用左右箭头逐天回看，菜单底部给出提示。逻辑抽为 `HistoryDaySelection.recentMenuDays(limit:)` 并有测试。（`Models/HistoryDaySelection.swift`、`Views/ChartDetailView.swift`）
- 面板关闭后历史页不再重算：`MenuBarExtra` 面板关闭后内容视图仍存活，历史页会随每 5 秒一条新样本重建两张图（含逐样本 mark），即使窗口已离屏。`HistoryView` 新增 `isVisible` 参数，隐藏时改用最后一次的快照（样本 / 睡眠区间 / 汇总）渲染，不再读取 `BatteryHistoryStore`（三元分支的惰性求值使观察依赖根本不建立）；重新显示时用最新数据刷新，同时避免关闭动画期间闪成空态。（`Views/HistoryView.swift`、`Views/DashboardView.swift`）
- 曲线坐标换算改为二分查找：`PowerChartTimeline.position(for:)` / `date(for:)` 原先对每个样本线性扫描断点（断点多时逐样本 O(断点数)），现在预计算每个断点的压缩起点与累计压缩时长，两次二分即可定位；轴标签的「最近刻度」也先用位置字典精确命中，未命中才回退线性比较。（`Views/HistoryView.swift`）

### 修复
- 状态色按明暗外观取值：`DesignTokens.statusGreen/statusAmber/statusRed` 原先是不变的亮色，浅色模式下 10pt 前景（如 `#F59E0B` 的「插电放电」说明）与白色玻璃对比度约 2:1，达不到 4.5:1。现在用 `NSColor(name:\)` 动态颜色：浅色模式改用同色系加深版本（#15803D / #B45309 / #B91C1C），深色模式保持原亮色，指示点、徽标与渐变一并跟随。（`Support/DesignTokens.swift`）
- 桌面小组件通知回调改回同步执行：四个观察者以 `queue: .main` 注册，回调本就在主线程，原先再包一层 `Task { @MainActor }` 只是多一次调度跳转，且与同一轮里的直接调用没有顺序保证（例如改样式后立即显示，可能先按旧尺寸闪现一帧）。改用 `MainActor.assumeIsolated`，与同文件 `frameSaveTimer` 的写法一致。（`Services/DesktopWidgetController.swift`）

### 重构
- 拆分 `HistoryView.swift`（2,261 行，占源码近 1/3）为 7 个文件，行为不变：`HistoryView.swift` 只留根视图与数据装配（88 行）；`HistoryChartModels.swift` 放纯数据与坐标轴（`PowerChartData`/`PowerChartTimeline`/`PowerChartSegmentation`/`BatteryLevelChartData`/`AxisTickScale` 等）；`HistoryChartCaches.swift` 放 6 个记忆化缓存；`HistoryChartRendering.swift` 放降采样、缺口连线与空态占位；三张图表各自成文件（`HistoryPowerChart.swift`、`HistoryBatteryLevelChart.swift`、`HistoryEnergyChart.swift`，含各自的 picker 枚举）。先前所有类型内联在同一文件，加图表功能时难以定位，纯函数测试的边界也容易被后续修改混进视图代码。（`Views/History*.swift`、`Tests/BatteryGlassTests/BatteryLevelChartDataTests.swift` 注释）
- 合并重复常量，避免多处硬编码漂移：低电量阈值的合法范围与解除迟滞集中到 `AppSettings.lowBatteryThresholdRange` / `lowBatteryNotifyHysteresis`（设置页滑块、读取钳制、通知判定共用）；`dayKey` 只保留 `BatteryFormatters` 一份（`EnergyCalculator`、`SleepEnergyCalculator` 的私有副本删除），补一个两种重载输出一致的测试；`TimeRemainingSmoother` 直接引用 `TimeRemainingEstimator` 的 [60s, 48h] 结果域；`BatterySnapshot` 的 0.01 W 噪声阈值改用 `BatteryPowerThresholds.minimumDischargeW`。（`Stores/AppSettings.swift`、`Views/SettingsView.swift`、`Services/BatteryMonitor.swift`、`Support/Formatters.swift`、`Models/*`）
- 拖动桌面小组件不再每个事件写一次 UserDefaults：`windowDidMove` 原先直接写 `desktopWidgetFrameString`（`didSet` 同步 `defaults.set`），拖动期间按刷新率落盘。现在把位置暂存并在 0.4 秒后合并写入一次，销毁时 invalidate 定时器。（`Services/DesktopWidgetController.swift`）
- `./script/build_and_run.sh --verify` 不再假通过：原先只 `pgrep -x` 判存在，若旧实例没被替换掉（或被调试器暂停），新构建其实从未启动也会判成功。现在记录启动前的 PID 集合，要求在 10 秒内出现一个**新的**进程，否则以非零状态退出并打印原因。（`script/build_and_run.sh`）
- 采样定时器与通知观察者不再随实例泄漏：`BatteryMonitor` 的两个 RunLoop 定时器只被 `RunLoop` 持有，两个 `NSWorkspace` 观察者 token 创建后直接丢弃；`DesktopWidgetController` 的四个观察者也只注册不移除。两类对象都没有 `deinit`，实例释放后仍会留下 1 Hz 空转与永久回调（对测试和实例重建尤其明显）。现在两者都在 `deinit` 中 invalidate 定时器、取消补采任务并移除观察者；相关字段标注 `nonisolated(unsafe)`（实际只在主线程读写）以允许 nonisolated 的 `deinit` 访问。（`Services/BatteryMonitor.swift`、`Services/DesktopWidgetController.swift`）
- 睡眠起点改用即时读数：`handleWillSleep` 原先直接拿缓存快照当基线，而采样定时器挂在 `.common` 且带 `tolerance`，App Nap 下可能滞后数秒到数十秒。现在入睡前先 `refresh()` 再定格起点与容量，避免把睡前正常使用的时间并进睡眠区间（会被排除出能耗积分），也避免插电待机按时长外推时被放大。（`Services/BatteryMonitor.swift`）
- 导出失败不再写出 0 字节文件：`HistoryExporter.jsonString` 原先编码失败返回 `""`，设置页把空串写入目标位置后仍视为成功。现在新增会抛错的 `jsonData` / `jsonString`，调用方直接写 `Data`（同时省掉一次 `String` 往返的内存），编码失败会走进既有「导出失败」提示。（`Support/HistoryExporter.swift`、`Views/SettingsView.swift`）
- 迁移备份不再被旧备份顶掉、也不因清理失败卡住写入：原先只在 `history.legacy.json` 不存在时创建备份，若上次迁移的备份还在，本次待迁移文件不会被保存就被 v8 覆盖；且备份里温度字段清理抛错会让 `write()` 失败，`needsLegacyBackup` 永远为真，`persist()` 每 15 秒同步重试一次整笔写入。现在内容不同时另存 `history.legacy-<时间戳>.json`（绝不覆盖旧备份），温度清理改为尽力而为、不影响写入；`clearHistory()` 一并清理这些时间戳副本。（`Stores/BatteryHistoryStore.swift`）
- 用全精度样本重算某日后清除「旧口径」标记：`DailyEnergySummaryPolicy.reconcile` 原先只替换 `energyKWh`、原样带过 `energyQuality`，加载时为旧汇总种下的 `hasUnknownHistoricalCoverage` 会永久跟随该日，橙色提示无法消除。现在被重算覆盖的日期会同时清除该标记；未重算的历史日保持原样。（`Stores/DailyEnergySummaryPolicy.swift`）
- 归档单条损坏不再让整天曲线空白：`HistorySampleArchive.readSamples` 原先在循环内 `try decoder.decode`，任一 payload 损坏就整日查询失败，而 `BatteryHistoryStore` 的 catch 又会把 `cachedArchiveDay` 置 nil，导致每次进入该日都重新打开 SQLite、全表扫描再失败。现在跳过无法解码的行并记录条数，其余分钟正常展示；读取失败时改为记住该日（空结果），不再反复同步查询。（`Stores/HistorySampleArchive.swift`、`Stores/BatteryHistoryStore.swift`）
- 清空历史不再忽略删除失败：原先三个删除操作都用 `try?`，归档删不掉时内存已清空、界面显示"已清空"，但重启后旧日期会从 `history.sqlite` 重新读回。现在 `clearHistory()` 返回是否成功，删除全部成功后才清空内存并取消待结算睡眠；任一文件删除失败就记录日志、保留内存数据，设置页弹出「清空历史失败」提示。（`Stores/BatteryHistoryStore.swift`、`Views/SettingsView.swift`）
- 校准数据不再因一次读取失败被清空：原先 `power-calibration.json` 解码失败会静默返回空记录，之后任何一次保存都会用空数组覆盖原文件，唯一一份校准记录永久丢失。现在读取失败（含超过 1 MB）会把原文件改名留档为 `power-calibration.invalid-*.json` 并记录日志，不再覆盖。`save()` 改为返回成功与否，写入失败时 `completeSession` 返回新增的 `.saveFailed`，校准面板明确提示"结果未写入磁盘"，不再显示为保存成功。（`Models/PowerTelemetryCalibration.swift`、`Views/PowerCalibrationSection.swift`）
- 历史文件读取失败不再静默停写：原先 `history.json` 超限、解码失败或版本过新时只是设置 `canPersist = false`，界面照常显示"正在记录"，而 `record()` 仍无上限地往内存追加样本，退出时统一丢弃。现在三条失败路径都记录 `persistenceIssue` 并在设置页「数据与历史」显示橙色说明，`record()` 在禁用持久化时立即停止累积；原文件保持原样，可清除历史后恢复记录。同时 `BoundedFileReader` 改为分块循环读取，修复单次 `read(upToCount:)` 短读时把截断内容当完整文件、进而被误判为文件损坏的问题。（`Stores/BatteryHistoryStore.swift`、`Stores/BoundedFileReader.swift`、`Views/SettingsView.swift`）
- 睡眠中退出不再丢失区间边界：`history.json` 新增可选字段 `openSleepStart`，退出时仍处于睡眠则记录起点；下次启动用第一条样本关闭该区间，并记为「未测量的睡眠」（不再被误判为采样缺口，也不会把整段离线时间算进能耗）。跨进程恢复的区间上限为 24 小时，更长的离线时间按真实采样缺口处理。区间起点与能耗基线分离，起点读数缺失或唤醒事件丢失时也不会让区间永久保持打开。（`Stores/BatteryHistoryStore.swift`）
- 睡眠端点必须是完整读数：唤醒瞬间电量计若停在旧值（容量或电压为 0），原实现直接用它做容量差，会把整块电池记成一次睡眠耗电（一次可虚增数十 Wh）。现在 `BatteryMonitor` 新增 `isUsableSleepEndpoint` 校验，唤醒后每 2 秒补采、最多 5 次；仍不可用则只关闭睡眠区间并放弃能耗结算（历史层标为「未测量睡眠」，不再被当作采样缺口）。睡眠起点读数不完整时同样只记区间不结算，且区间边界与测量基线分离，避免唤醒事件缺失时把之后的样本永久排除出能耗积分。`SleepEnergyCalculator` 对非正端点容量直接返回 nil。（`Services/BatteryMonitor.swift`、`Models/SleepEnergyCalculator.swift`）

### 修改
- 更新 `CODEBUDDY.md`：同步本轮稳定性与性能修复（deinit 释放资源、`--verify` 新进程校验、小组件位置合并写入、`DesktopWidgetFramePolicy`、历史页隐藏时的快照渲染、日期菜单截断、动态状态色、时间轴二分查找）。
- 更新 `CODEBUDDY.md`：同步本轮数据正确性修复（归档坏行跳过与失败缓存、迁移备份命名、旧口径标记清除、导出抛错、入睡前刷新基线）。
- 更新 `CODEBUDDY.md`：同步本轮性能修复（悬停节流与分段缓存、`samplesAsync` 与放大窗口可见性门控）。
- 更新 `CODEBUDDY.md`：同步本轮数据正确性修复（睡眠端点校验与补采、`openSleepStart` 跨进程恢复、历史读取失败提示与 `clearHistory` 返回值、校准文件留档与 `.saveFailed`）。
- 更新 `CODEBUDDY.md`：`Views/HistoryView.swift` 行数改为实测约 2,070 行；「Views / UI」补记电量曲线的缺口处理（`HistoryChartRendering.gapBridges` 细线跨断点、填充改为整日单条连续 `AreaMark`）与两条曲线共用 `chartPlotStyle` 裁剪填充的修复；「常用命令」补充 `open Package.swift`（README 提供的 Xcode 运行路径）。

## [2026-10-22]

### 修复
- 电量曲线通过 `chartPlotStyle` 将填充区域裁剪在绘图区内，修复纵轴自动缩放且下界高于 0% 时，淡蓝色填充溢出到横轴时间标签下方的问题；菜单栏面板与放大窗口共用此修复。

## [2026-10-17]

### 修改
- 电量曲线用细连接线跨过采样缺口：待机期间应用只能在每次维护唤醒时记录 1–2 分钟样本，相邻片段间隔 15–20 分钟，超过 `splitByGaps(maximumGap: 300)` 的断线阈值后曲线被切成大量孤立短段（日视图上表现为断续的点/竖线）。现在保留缺口两侧的实测样本，用 1pt、45% 透明度的连线跨过缺口，既不画出断口也不补造数据点；填充区域改为整日一条连续 `AreaMark` 序列，解决稀疏段区域窄到看不见而出现的「有的曲线下有浅蓝色底色、有的没有」。（`Views/HistoryView.swift` 的 `TodayBatteryLevelChart`、`HistoryChartRendering.gapBridges`）
- 更新 `CODEBUDDY.md`：修正 `AppDelegate` 职责描述（除设置 accessory 策略外还调用 `NotificationService.installForegroundPresenter()`）；测试类地图补 `BatteryMonitorPublishPolicyTests`、`ChartZoomWindowTests`、`ChartTimeAxisTests`、`ChartViewportTests`、`HistoryDaySelectionTests`，并把误置于「Views / UI」末尾的统计边界测试说明并入测试地图；补充 bundle 元数据由 `script/build_and_run.sh` 内联生成 Info.plist、`Package.swift` 链接 `IOKit`/`ServiceManagement`，以及源码/测试类变更时同步本文件的维护约定。
- 修复电量曲线在密集样本下被画成"梳齿"竖条的问题：`TodayBatteryLevelChart` 的 `AreaMark` 从三参 `x:yStart:yEnd:`（每个 mark 都给常量 yStart）改为两参 `x:y:` 形式，与 `TodayPowerChart` 对齐；Swift Charts 在密集 Date 样本下不会把三参形式按 `series` 合并成一条连续填充区域，相邻样本之间留下竖条空隙。视觉上仍由 y 轴 `plotYDomain.lowerBound` 把填充裁到电量曲线下沿，渐变与连线不变。`BatteryLevelChartDataTests` 新增 `testContinuousDayProducesSingleSegmentForConnectedArea` 锁定整段连续输入必须落到单个 `displayedSegments` 以便 `series` 合并为连续区域。

### 优化
- 修复面板关闭后仍持续占用约 5.2% CPU 的问题：`BatteryMonitor` 原本每 0.5 秒无条件更新 `@Observable` 的 `snapshot` / `recentPower`，`MenuBarExtra` 面板虽已离屏、内容视图仍存活，于是整棵视图图（`LiveDashboardView` 各卡片）被反复重算——采样（`sample` 5 秒）显示主线程 95% 的空闲时间都在 `NSHostingView.layout → ViewGraphRootValueUpdater.render`，而 IOKit 读取实测只占 0.16%。现在把「采样」与「界面发布」拆开：内部快照 `latest` 仍每拍更新（通知照发，历史/诊断/睡眠结算/能耗口径全部不变），对外 `snapshot` 走 `shouldPublish` 三档策略——`.live` 面板可见每拍发布、`.widget` 仅桌面小组件可见时最多每秒一次、`.background` 都不在屏幕上时只在菜单栏百分比/供电状态/剩余时间文本变化或 30 秒心跳时发布。可见性由 `PanelVisibilityObserver`（面板）与 `DesktopWidgetController.setVisible`（小组件）上报。实测空闲 CPU 5.2% → 0.50%（小组件关闭）/ 1.43%（小组件在桌面上，剩余开销主要是 `ultraThinMaterial` 每秒重绘一次毛玻璃）。（`Services/BatteryMonitor.swift`、`Views/DashboardView.swift`、`Services/DesktopWidgetController.swift`）
- 采样频率按可见性分档：面板可见 2 Hz、其余 1 Hz（历史仍是 5 秒一条，2 Hz 本来就是 10 倍过采样）；两处 `Timer` 补 `tolerance`（间隔的 20%），让系统把唤醒与其它定时器合并，减少 standby 期间的 package 唤醒。
- 定时器回调不再每拍 `Task { @MainActor }`（2 Hz 下约 17 万个/天的任务分配），改用 `MainActor.assumeIsolated`；`latestTelemetryCounters` 加等值判断，值没变时不触发校准页观察者。
- 新增 `Tests/BatteryGlassTests/BatteryMonitorPublishPolicyTests.swift`（10 条）覆盖三档发布策略：可见每拍、离屏忽略功率抖动、整数百分比跳变、插拔跃迁、过渡状态变化、剩余时间分钟粒度、心跳兜底。

## [2026-10-11]

### 修改
- 修复面板关闭后仍持续占用 CPU 的问题（实测约 21%）。`FluidGlassBackground` 的 `TimelineView(.animation)` 只在选中「实时」页时始终运行，而 `MenuBarExtra(.window)` 的面板关闭后内容视图仍然存活、布局不受窗口可见性门控，导致已离屏的窗口被 30fps 动画反复触发布局。新增 `Views/PanelVisibilityObserver.swift`（`NSViewRepresentable`，监听承载窗口的 order/occlusion 通知）上报面板真实可见性，`DashboardView` 据此把动画门控为 `tab == .live && panelVisible`，面板关闭时改为静态背景。（`Views/PanelVisibilityObserver.swift`、`Views/DashboardView.swift`、`README.md`）
- `DashboardView` 用 `dynamicTypeSize > .large` 的单分支判断替换 `ViewThatFits(in: .vertical)`：`ViewThatFits` 每个布局周期都会测量全部候选（实时面板与 `ScrollView` 包裹的实时面板），在固定 392×672 面板上等于把每次失效的成本翻倍。现在标准字号直接展示，仅在系统字体放大时才用滚动版本。（`Views/DashboardView.swift`）
- 同步 `CODEBUDDY.md` 至当前工作树：历史图表描述对齐「温度/电压历史曲线已移除」——`HistoryView.swift` 行数（~2,360 → ~2,020）、删除不存在的 `TodayMetricChartDataCache`/`TodayMetric`/`MetricValueAxis`/`TodayTemperatureStats` 与「今日温度曲线」，补入 `AxisTickScale`/`EnergyAxisScale`、`PowerChartConnection`、`HistoryChartRendering`（降采样）、`DailyEnergyComparisonChart`、`ExpandedChart`/`ChartDetailModel`，并把「三张曲线」改为「两条曲线」（`TodayPowerChart`/`TodayBatteryLevelChart`）。
- `CODEBUDDY.md` 新增 `PowerDisplayTransition`（插拔过渡期实时展示状态：`ready`/`updating`/`unavailable`，只控制展示、不改动量与能耗取值）到项目结构与「电源状态判定」小节，测试地图补 `PowerDisplayTransitionTests`。
- `CODEBUDDY.md` 修正 App 初始化顺序，补 `PowerTelemetryCalibrationStore` 与 `ChartWindowController`，并更正行号引用（`@main` :49→:51、登录项回写 :68-69→:72-73）及两个 Scene 的环境注入清单；持久化 v8 迁移链补「移除历史温度」（`HistorySample` 现仅存 id/timestamp/power/consumptionPowerW/percent/cycleCount/healthPercent，加载时清除备份与归档中残留的 `temperatureCelsius`）。
- `CODEBUDDY.md` 测试地图以 `AxisTickScaleTests` 替换已不存在的 `HistoryMetricChartDataTests`。

## [2026-10-04]

### 修改
- 功率曲线在压缩后的缺口位置用同色、同粗细的蓝色竖线连接前后实测功率，消除电源切换等读数缺失导致的视觉断线；保留时间轴的 `//` 标记。连接位置与端点随图表数据缓存，面板及放大窗口同步生效，原始采样和耗电量统计保持不变。

## [2026-10-03]

### 修复
- 修复唤醒后延迟结算与退出、清空历史的时序：保存前先结算待处理的睡眠；清空时取消结算，并拦截清空时间之前的采样和睡眠事件，避免旧耗电重新写回。
- 对至少 60 秒且没有可用能耗记录的睡眠增加独立的缺失标记，跨天分别提示；延迟结算完成后消除该标记，旧文件兼容读取，历史耗电数值保持不变。
- 「近 N 天」改为包含今天的 N 个日历日，排除范围外及未来日期，缺少某天记录时不再混入第 N+1 天。
- 功率趋势按当前快照时间计算近 120 秒峰值和平均；持续缺少新读数时旧样本会过期，显示无数据。
- 清空历史同时移除已知命名的计数器修复备份；修正诊断日志容量说明为两份合计约 10 MB，并补充以上边界的回归测试。

### 修改
- 补足历史归档超限回归测试的数据量：历史样本字段精简后，原有测试文件已不足 20 MiB；增大样本量以继续同时覆盖旧文件大小和样本数限制。
- 优化插拔电源过渡期的实时展示：连接状态立即显示为「已接通电源」或「电池供电」，尚未更新的实时功率、电源分配、系统功耗统一显示「更新中」，并暂时隐藏旧的剩余时间；等待电量计更新或出现与新供电方式一致的读数后恢复展示，超过 90 秒仍无新读数时提示数据缺失。满电停充及新的混合供电读数按实际状态展示，桌面小组件与菜单栏无障碍提示同步处理。此状态只控制展示，原始采样与历史能耗取值保留。
- 提高插电混合供电的能量计量准确性：`BatteryDischargeConfirmation` 的“插电同时放电”确认从**只认 `.pluggedIn`** 扩到 `.charging`（macOS 在适配器供不上时会长时间停留在“充电中”而电池仍在放电，此前这段时间只记适配器输入、漏掉电池放电贡献），并把进入门槛由 0.01 W 提到 `confirmedDischargeW`（0.1 W，滤掉电量计零点漂移），`.pluggedIn` 需连续 2 个样本、`.charging` 需 6 个（该状态下的负读数可能只是状态切换滞后）；新增**滞回**（进入 0.1 W / 维持 0.01 W）与**状态切换重置计数**，避免读数在 0.01~0.1 W 抖动时面板在「电池放电 / 给电池 0.0 W」之间跳变、能耗里反复摘掉电池贡献。阈值统一到新增 `Models/BatteryPowerThresholds.swift`（`minimumDischargeW` / `confirmedDischargeW`），`BatterySnapshot.batteryDischargePowerW` 与 `BatteryMonitor.dischargingSystemPowerW` 一并改用，避免两处数字漂移。`BatteryMonitor.resolvedSystemPowerW` 的混合供电分支改为**先于 SystemLoad 判定**并取「适配器输入 + 电池放电」（与 `consumptionPowerW` 同口径，SystemLoad 是内部负载口径、不是本应用主指标，此前排在后面导致该分支在有 SystemLoad 的机型上永远走不到）。（`Models/BatteryDischargeConfirmation.swift`、`Models/BatteryPowerThresholds.swift`、`Models/BatterySnapshot.swift`、`Services/BatteryMonitor.swift`、`Views/LiveDashboardView.swift`）
- 采样断点判定改为**按当日累计「未计入积分的时长」并区分成因**（新增 `EnergyCalculator.unaccountedSecondsByDay` / `daySegments` 与 `DailyUnaccountedTime`：`gapSeconds` = 间隔 > `maximumGap`，`missingReadingSeconds` = 间距正常但任一端缺有效 `consumptionPowerW`；睡眠区间内不计，跨午夜按比例拆天）。`needsWarning` = 存在真实断点，或读数缺失累计 ≥ 600 秒（10 分钟）——实测读数缺失集中在**拔插电源前后约 1 分钟**（`state` 已切到电池供电而电量计仍读 0），一天 2~3 次、合计约 3.6 分钟（约 1.5 Wh、占日合计 0.4%），量级不足「日合计偏低」，而原先的逐段判定会让**单次几秒的缺失**把整天永久标成「耗电量可能偏低」（告警只置位、从不回退），同时也补上了「功率读数缺失导致能量没积上却毫无提示」这一漏洞。加载时改用 `applyTodaySamplingGapQuality(in:)` 在**诊断回填之后**重算今天（只判定今天：往日样本已降到 1 分钟一条、间隔本身就接近 `maximumGap`），使当天状态可随样本补齐自动消除；当天没有缺口也没有汇总时不再凭空创建空 summary。（`Models/EnergyCalculator.swift`、`Stores/BatteryHistoryStore.swift`）
- 能耗质量告警分层：`DailyEnergyQuality.hasWarning` 拆为 `hasAccuracyWarning`（采样断点 / 睡眠估算 / 未校准计数器 / 只统计到可观测来源 → 橙色告警）与 `hasUnknownProvenance`（旧版本记录、口径未知 → 低强度提示）。原先旧口径也计入告警，实测 37 天里 33 天被判为不完整，日视图几乎全橙、真实缺口被淹没；提示文案也把「口径未知」误述成「汇总可能偏低」。图表橙柱与覆盖提示改用统一谓词 `DailySummary.needsEnergyAttention`，旧口径日另起一行次要提示。（`Models/HistorySample.swift`、`Support/EnergyAggregator.swift`、`Views/HistoryView.swift`）
- **修复放电时电量计冻结导致功率被整段丢弃**：`BatterySnapshot.consumptionPowerW` 的放电分支在电池读数不可用时回退到 `systemPowerW`（放电状态下它由 SystemLoad 得来、恒为正，是电池输出的独立观测）——实测放电样本中 `systemPowerW` 3910/3910 为正、与 `|batteryPowerW|` 中位误差仅 **1 mW**，且 13:05 拔电前后它始终是同一个 26.57 W，能无缝衔接；此前的行为直接返回 nil，让拔电后电量计冻结（读 0 或残留充电值）的那几十秒功率全部丢失（实测每天 2~3 次）。同时把「未接入适配器但状态尚未切到放电」（拔插瞬态）的兜底由 `nil` 改为 `batteryDischargePowerW`——电池读数已明确指向放电时仍应计量。`displayPower` 的放电分支同步在读数失效时回退（否则面板会显示 0.0 W 而当日能耗仍在增长），两者取值链各自独立、互不改变定义。**用当日真实日志回放：修复后当日新增计入 0.464 Wh（占 0.3868 kWh 的 0.12%），13:05 段 45 个缺失样本全部补回。** 拔电时三类读数同时符号翻转的情况（`batP` / `telemetry` 同为正、`systemLoad` 为负）仍保持 nil 并标记为读数缺失，不用估计值填补。（`Models/BatterySnapshot.swift`）

### 新增
- 新增 15 项统计边界回归测试（`HistoryAccountingBoundaryTests`、`DailyEnergyQualityTests`、`PowerTrendStatisticsTests`）；完整测试共 386 项通过。
- 新增测试：`BatteryDischargeConfirmationTests`（进入门槛与样本数、滞回维持与退出、状态切换重置、拔电/非有限读数清零——此前该类型零覆盖）、`SamplingGapAccountingTests`（纯函数：缺失读数累计、长断点、睡眠排除、跨午夜拆天、`daySegments`）、`SamplingGapQualityTests`（`BatteryHistoryStore` 端到端：短缺失不点亮、长断点点亮、加载时重算清掉陈旧标志）；`EnergyConsumptionTests` 补混合供电三分支（有 SystemLoad 时仍用相加、无 SystemLoad 回退、无适配器输入只保留电池放电），`EnergyAggregatorTests` 补 `incompleteDayCount` 只统计真实告警日；`EnergyConsumptionTests` 另补 6 个用例覆盖 `consumptionPowerW` 的放电回退链（电量计冻结读 0 时回退 SystemLoad、电量计有效时仍优先电池读数、全部读数失效时保持 nil、适配器已拔但状态未切换时仍计量、无电池时不凭空产生功率）与 `displayPower` 的同口径回退。

## [2026-10-02]

### 修改
- 恢复面板实时页指标行的**电压**显示（`MetricsGrid` 与 `BatteryFormatters.voltage`）：4 格布局 温度 / 电压 / 系统功耗 / 电源适配器。历史记录、桌面小组件、历史与放大窗口的曲线仍不含电压。（`Views/StatsGridView.swift`、`Support/Formatters.swift`、`README.md`）
- **移除电池电压的展示与历史记录**：删除 `HistorySample.voltage` 字段（合成 Codable 会忽略旧 `history.json`/`history.sqlite` 里多出的 `voltage` 键，无需迁移分支，payload 保持 **v7**），`BatteryHistoryStore.record` 不再写入电压；`HistoryExporter` CSV 去掉「电压(V)」列（14→13 列）、导出版本 6→7。UI 侧删除 `BatteryFormatters.voltage`、面板指标行的「电压」格（4→3 格）、桌面小组件的「电压」行，历史页「温度 / 电压」分段卡改为**今日温度曲线**（`TodayMetric` 仅保留温度、移除内置切换器），放大窗口去掉「电压」标签页（`ExpandedChart` 4→3 项）。（`Models/HistorySample.swift`、`Stores/BatteryHistoryStore.swift`、`Support/HistoryExporter.swift`、`Support/Formatters.swift`、`Views/StatsGridView.swift`、`Views/DesktopWidgetView.swift`、`Views/HistoryView.swift`、`Views/ChartDetailView.swift`、`README.md`、`CODEBUDDY.md`）
- 保留底层电压读取：`BatterySnapshot.voltage` 仍用于「功率 = 电压 × 电流」与睡眠能耗（`SleepEnergyCalculator`），诊断日志 `power-diagnostics.jsonl` 仍记录原始电压（仅手动开启诊断时写入）。受影响的 `HistoryExporterTests`、`HistoryMetricChartDataTests`、`HistoryPersistenceTests`、`HistorySampleArchiveTests`、`LongTermHistoryTests` 同步调整。

### 新增
- 历史曲线改为**长期保留**：新增 `Stores/HistorySampleArchive.swift`（系统 SQLite3，无第三方依赖）把往日样本按「epoch 分钟」为 PRIMARY KEY 归档到 `history.sqlite`（每分钟最后一条；`BEGIN IMMEDIATE` 事务、upsert 幂等、失败 `ROLLBACK` 不半写），`history.json` 热层只保留「今天 + 跨午夜前最后一条」并升至 payload **v7**（旧文件迁移前备份 `history.legacy.json`）。`pruneHistory()` 改为「先写归档、成功后再从热层淘汰」；图表按需读取单日（`BatteryHistoryStore.samples(forDay:)`，归档 + 热层合并并记忆化），`availableDays()` 取归档索引与热层的并集，`allCurveSamples()` 供导出全量读取。设置页导出与清空历史相应改走归档（清空同时删除 `history.sqlite` 与 `history.legacy.json`），放大窗口日期集合改用 `history.availableDays()`，跨年份日期标签显示年份。（`Stores/HistorySampleArchive.swift`、`Stores/BatteryHistoryStore.swift`、`Support/Formatters.swift`、`Support/HistoryExporter.swift`、`Views/ChartDetailView.swift`、`Views/SettingsView.swift`、`README.md`）
- 新增测试 `HistorySampleArchiveTests`（分钟 upsert 幂等、按时区与跨午夜查询、DST 边界、失败批次回滚）与 `LongTermHistoryTests`（旧版迁移与备份、跨天归档与重启后细粒度/能量边界、超大归档按需加载、清空、迁移失败重试、损坏热层文件不被覆盖）；`HistoryRetentionTests`、`BatteryFormattersTests` 补充长期保留与跨年标签用例。

### 修改
- 更新 `CODEBUDDY.md` 以对齐当前工作树：持久化章节由「v6 / 近 7 天内存保留 + 1 分钟降采样」改为**双层持久化**——热层 `history.json` 只留「今天 + 跨午夜前最后一条」（payload **v7**，旧文件迁移前备份 `history.legacy.json`），冷层 `history.sqlite`（`HistorySampleArchive`）按 epoch 分钟归档往日样本、长期保留；补充 `samples(forDay:)`/`availableDays()`/`allCurveSamples()` 读取路径、归档先写后淘汰的崩溃安全语义，以及「`history.sqlite` 不受 `HistoryLoadLimits` 限制」的说明。新增 `HistorySampleArchive` 与 `PowerCalibrationSection` 到项目结构，补 `HistorySampleArchiveTests`、`LongTermHistoryTests`、`HistoryMetricChartDataTests` 到测试地图，修正 `HistoryView.swift` 行数（~1,900 → ~2,360）并移除易失效的类型行号。（`CODEBUDDY.md`）

## [2026-09-30]

### 新增
- 放大窗口支持**按天回看**：顶部在曲线标签页旁新增日期导航器「◀  8/25  ▶」（左右箭头逐天切换，点中间日期弹出菜单直跳某天）。切换只改共享的 `ChartDetailModel.selectedDay`，窗口不重建、位置与大小不变，窗口标题同步为「8/25 · 功率曲线」；今天显示「今日」。往日展示整天并收在当天最后一条样本处，不留大片空白。新增纯类型 `Models/HistoryDaySelection.swift`（可选日期集合始终并入今天、前/后一天导航、选中日被清理后自动回退到最近的可用日）与 `HistoryRetention.availableDays(from:calendar:)`。**面板历史页保持「今日」不变**，因此三张曲线新增的 `day` 参数带默认值，面板代码零改动；曲线内原有的 `dayKey` 参数改由 `day` 推导。（`Models/HistoryDaySelection.swift`、`Stores/BatteryHistoryStore.swift`、`Views/ChartDetailView.swift`、`Views/HistoryView.swift`、`Support/Formatters.swift`）
- 原始样本保留策略由「仅当天 + 前一天末条」改为**近 7 天**：今天保持原生 ~5 秒精度，**往日降采样到 1 分钟**（epoch 分桶、每桶留最后一条）。`HistoryRetention.retainedSamples(retentionDays:olderResolution:)` 取代 `samplesForCurrentDay`（一并删除只服务于它的 `appendingIfNeeded`），`pruneHistory()` 按 7 天 / 60 秒执行。降采样后最坏约 2.59 万条 / 5.3 MB，远低于 `HistoryLoadLimits`（10 万条 / 20 MiB）——**不提高上限、不 bump payload 版本**（字段未变）。跨午夜边界样本由「每桶留最后一条」自然保留，今天的能量插值边界不变。（`Stores/BatteryHistoryStore.swift`）
- 新增测试：`HistoryDaySelectionTests`（并入今天、前后一天导航、选中日被清理后回退、今日/昨天/日期标签）；`HistoryRetentionTests` 按新契约重写（降采样、保留窗口、升序不变、单日、无降采样、`availableDays`、**最坏情况条数与体积仍低于加载上限**）；`BatteryLevelChartDataTests` 补 `xDomain(day:now:lastSample:)` 的往日整天、按末条收尾、最小宽度与默认值不变。

### 修复
- 修复多天保留会误标采样断点：`markKnownSamplingGaps` 原先把**所有**间隔 > 60 秒（`EnergyCalculator.maximumGap`）且不在睡眠区间的相邻样本对都判为「采样断点」，而往日降到 1 分钟后相邻样本最长可差约 119 秒，会让每个旧日期都被标上 `hasSamplingGaps`、历史页日明细出现一片警告角标。现只判定「以今天结尾」的间隔（`end >= startOfDay(now)`）：今天的原生精度与当天真实断点仍照常标记，跨午夜那一对仍按原逻辑判定。（`Stores/BatteryHistoryStore.swift`）

### 新增
- 放大窗口内可直接切换曲线，且拆成**四个标签页**：顶部为「功率 / 电量 / 温度 / 电压」分段切换器，切换时只改共享的 `ChartDetailModel.kind`，窗口不重建、位置与大小不变，窗口标题同步更新。原「温度·电压」合并标签拆开后，窗口内不再出现重复的二级切换器——`TodayMetricChart` 新增 `fixedMetric`（非 nil 时以它为准并隐藏内置切换器），面板上的该卡片仍保留自带切换器；`onExpand` 改为回传当前指标 `(TodayMetric) -> Void`，面板点波压卡片的 ⤢ 会直接打开对应标签页。`ExpandedChart` 改为 4 个 case 并补 `metric` 映射、`init(metric:)`、`CaseIterable` 与 `shortTitle`，`ChartDetailView` 新增 `onKindChange` 回调供窗口控制器同步标题。（`Views/ChartDetailView.swift`、`Views/HistoryView.swift`、`Services/ChartWindowController.swift`）

### 修改
- 「放大查看」由面板内浮层改为**独立窗口**：菜单栏面板固定 392×672，绘图区约 304×407，长宽比对时间序列并不合适。新增 `Services/ChartWindowController`（普通可缩放窗口，默认 1000×600、最小 480×320，`setFrameAutosaveName` 记住位置与大小、显示配置变化后拉回主屏，只维护一个实例、切换曲线不重建窗口）与 `Views/ChartDetailView`（自行从 `BatteryHistoryStore` 取当天样本并记忆化曲线数据，窗口开着时随新样本实时刷新）；删除 `Views/ExpandedChartOverlay.swift` 及 `HistoryView` 里承载它的 `ZStack`/过渡动画，`ExpandedChart` 枚举随之迁到 `ChartDetailView.swift`。（`Views/ChartDetailView.swift`、`Services/ChartWindowController.swift`、`Views/HistoryView.swift`、`App/BatteryGlassApp.swift`）

### 修复
- 修复 `HistoryPersistenceTests.testLowerBoundSleepSegmentEnergyIsCountedExactlyOnce` 的时间相关假失败：用例以 `Date()` 为起点构造「1 小时睡眠区间」，在临近本地午夜运行时会跨天，能量被按天切分（实测 23:12 运行只剩跨天前约 48 分钟的能量，`0.0142 → 0.01134`，与失败值吻合）。起点改为锚定「当天 10:00」，使用例与运行时刻无关。（`HistoryPersistenceTests.swift`）
- 修复历史页三张曲线图的卡顿（主因）：`yDomain`（电量图）、`yAxis`（温压图）等计算属性被直接写在**逐样本的 `ForEach` 里**（`AreaMark` 的 `yStart`），于是每个样本都重跑一遍 `ChartViewport.visibleSamples`（O(全部样本) 筛选）与 `MetricValueAxis.ticks`（含刻度字符串格式化），整体退化成 O(n²)。现把 `effectiveWindow`/`visibleDomain`/`yDomain`/`yAxis`/`displaySegments`/`axisMarks`/`panRange` 等改成接受窗口参数的纯函数，并在各图 `body` 开头**每帧只求值一次**再传进 `Chart`；功率图的 `chartXAxis` 也不再在每个轴刻度上重新求值 `axisMarks`。（`Views/HistoryView.swift`）

### 修复
- 修复曲线图缩放的输入层：`.chartOverlay` 里的 SwiftUI `MagnifyGesture` 与 `.onContinuousHover` 都不够可靠（前者收不到事件；后者会被盖在其上的真实 `NSView` 挡住）。改为在 `chartOverlay` 内容之上叠加真实 AppKit 事件层 `ChartPlotEventCatcher`：`NSView` 重写 `mouseDragged` / `scrollWheel` / `magnify(with:)`，并自建 `NSTrackingArea` 上报悬停（`isFlipped` 必须为 `true`，否则悬停坐标 y 翻转；三图的 `updateHover` 相应改为接收 `CGPoint?`）。事件为增量语义，直接在当前窗口上累加，无需缓存手势起始状态。**可靠入口：⌘+滚轮缩放、双指横扫平移、按住拖动平移**（纵向滚动仍交回父级 `ScrollView`，整页滚动不受影响），标题栏另有 `🔍−`/`🔍＋`/`⟲` 按钮。目标判定用「光标屏幕坐标 + `hitTest`」而非 `event.window === self.window`——`magnify` 事件的 `event.window` 并不指向面板窗口，用它做守卫会把全部事件误判为「不是本窗口」；`hitTest` 还能正确处理 z 序与遮挡（放大浮层打开时不会同时触发底下被遮住的内联曲线）。新增纯函数 `ChartZoomGestureMath`（锚点/位移换算）与 5 个用例。（`Views/ChartZoomInteraction.swift`、`Views/HistoryView.swift`、`Models/ChartZoomWindow.swift`、`ChartZoomWindowTests`）
- 触控板捏合在菜单栏面板上**投递不稳定**，记录实测结论以免重复投入：`MagnifyGesture`、`NSView.magnify(with:)`、`NSEvent.addLocalMonitorForEvents(matching: [.magnify])` 三条路径中，前两条始终收不到；本地监听器偶尔能收到（那时缩放开箱即用），但**同样的面板、同样 `active=true` + key window 状态下，更多时候一个事件都收不到**，且 `NSApp.isActive`/`NSWindow.isKeyWindow` 均为真，故不是激活状态问题。结论：捏合仅作尽力而为的补充，主入口采用上一条中的 ⌘+滚轮（系统设置→触控板→滚动缩放开着时，捏合本就可用；此处只是面板窗口拿不到事件）。

### 修复（早期记录）
- 修复上一步排查时引入的严重卡顿：曾用 `PreferenceKey` 把绘图区矩形从 `chartOverlay` 传出并在 `onPreferenceChange` 写入 `@State` 供热区手势换算，与面板 2Hz 重渲染叠加形成布局反馈环。现已移除该链路（连同 `coordinateSpace` 与 Chart 级 `simultaneousGesture`），事件层的坐标直接在 `chartOverlay` 的 `GeometryReader` 内以纯值 `CGRect` 捕获。（`Views/ChartZoomInteraction.swift`、`Views/HistoryView.swift`）

### 新增
- 历史页三张今日曲线（功率 / 电量 / 温度·电压）支持触控板**捏合缩放**与**拖动平移**：新增纯视口模型 `ChartZoomWindow`（坐标无关的 `start/span/bounds`，含 `zoomed(by:anchorFraction:)`/`panned(by:)`/`reset()`/`rebased(to:)`，全部钳制、异常输入 no-op；功率图用「曲线秒」、电量/温压图用参考纪元秒，断点塌缩语义不被破坏）、纯函数 `ChartTimeAxis`（可见跨度决定 X 轴刻度：整日 6 小时 → 6h 内 1 小时 → 2h 内 30 分 → 1h 内 10 分，并对齐到当天整步长网格）与 `ChartViewport`（可见域样本筛选 + 等距抽样保留首尾）。缩放以锚点为中心、下限 60s（功率）/300s（电量·温压），Y 轴按可见样本重算（未缩放时与整日预计算域逐值相等），标题栏出现「已放大」与重置按钮，缩放后横向拖动平移。功率曲线放大后改用未抽样的完整段（新增 `PowerChartData.fullSegments`）渲染，避免 800 点抽样在窄窗口内过稀。（`Models/ChartZoomWindow.swift`、`Models/ChartTimeAxis.swift`、`Support/ChartViewport.swift`、`Views/ChartZoomInteraction.swift`、`Views/HistoryView.swift`）
- 历史页新增「放大查看」浮层：三张曲线标题栏右上角新增放大按钮，点击后在面板内覆盖一层撑满历史内容区的图表（绘图区由 ~138pt 提升到 ~400pt），支持右上角关闭与 Esc、带缩放淡入过渡并适配「减弱动态」。曲线视新增 `plotHeight`（`nil` 表示撑满剩余空间，经 `chartPlotHeight(_:)` 实现）与 `onExpand` 参数，浮层内为独立实例、拥有各自的缩放窗口。（`Views/ExpandedChartOverlay.swift`、`Views/HistoryView.swift`）
- 新增测试 `ChartZoomWindowTests`（缩放锚点/最小宽度钳制/平移边界/重置/退化范围/重新基准化）、`ChartTimeAxisTests`（步长选择、刻度对齐不被窗口起点带偏、刻度升序且落在域内）、`ChartViewportTests`（可见域筛选与抽样）；`BatteryLevelChartDataTests`/`HistoryMetricChartDataTests` 各追加「未缩放可见 Y 域等于整日预计算域」不变量用例。

### 修改
- `TodayPowerChart` 的时间窗口改由 `ChartZoomWindow` 驱动：视图不再使用 `scrollRange`/`scrollPosition`/`PowerChartWindow.visibleChartDomain`/`shouldFollowLatest`（后三者暂保留，以便既有 `PowerChartDataTests` 继续覆盖）；时间滑块改为绑定窗口起点、仅在可平移时显示；「跟随最新」改由 `.onChange(of: bounds.upperBound)` + `rebased(to:)` 实现（贴边窗口随新样本平移、历史窗口留在原处）。`chartOverlay` 透明层挂上共享手势修饰器 `ChartZoomInteraction`（捏合缩放 + 拖动平移；手势期间以起始窗口为基准重算，避免累计倍数/位移被重复应用，并在手势中清掉 tooltip）。（`Views/HistoryView.swift`）
- `HistoryView` 改为 `ZStack`（`ScrollView` + 放大浮层），三张曲线新增 `dayKey` 参数用于跨天重置缩放窗口：功率图仍用重建 `.id(dayKey)`，电量/温压图改用 `onChange(of: dayKey)` 以免连带重置指标选择与数据缓存。（`Views/HistoryView.swift`）
- 历史页新增两张图并替换静态「循环次数」卡片（删除 `HistoryMetricCard` 及 `HistoryView` 中仅供其使用的 `monitor` 注入与 `cycleCount`）：①「今日温度 / 电压曲线」——分段切换，分时展示当天（复用「今日电量曲线」骨架），并显示今日最高温与 ≥35°C 累计时长（跳过待机断点）、电压今日范围；②「循环次数趋势」——按天近 90 天展示每日最大循环次数（循环次数单调递增，斜率即损耗速率）。`HistorySample` 增 `temperatureCelsius`/`voltage`，`BatteryHistoryStore.record` 落盘；新增纯类型 `TodayMetric`/`TodayMetricChartData`(+Cache)/`MetricValueAxis`/`TodayTemperatureStats`/`CycleTrendData` 与测试 `HistoryMetricChartDataTests`。（`Models/HistorySample.swift`、`Stores/BatteryHistoryStore.swift`、`Views/HistoryView.swift`）
- 历史 payload v5 → v6：`HistorySample` 新增可选 `temperatureCelsius`/`voltage`，经合成 `decodeIfPresent` 解码，旧文件缺键为 nil、无需迁移分支（`DailySummary` 不变）；`HistoryExporter` CSV 表头与采样行新增「温度(°C)/电压(V)」两列（汇总行留空），JSON 导出版本同步升至 6。（`Stores/BatteryHistoryStore.swift`、`Support/HistoryExporter.swift`、`HistoryExporterTests`、`HistoryPersistenceTests`）
- 新增设置页「电源校准」录入 UI：采用**引导式校准会话**——点击「开始校准」后应用自动记录当前墙上能量计数器与时间，用户保持接通电源并用外接电表记录同期用电量，之后点击「完成校准」输入实测 kWh 即自动结算系数；支持查看/删除单条记录与清空全部记录。`PowerTelemetryCalibrationStore` 由 `struct` 改为 `@MainActor @Observable` 共享引用类型，在 `BatteryGlassApp` 中创建唯一实例并同时注入 `BatteryMonitor` 与设置页，**校准保存后睡眠能耗计量立即采用新系数，无需重启**；payload 升至 `v2`（新增可选 `session` 字段，旧文件解码为 nil、无需迁移分支）；新增 `PowerTelemetryEnergy.uncalibratedEnergyKWh(rawDelta:)` 作为未校准换算的唯一来源；`BatteryMonitor` 新增只读 `currentWallEnergyCounter`。当结算系数明显偏离常见范围（`0.05...20`）时二次确认，以防把 Wh 误当 kWh 输入。（`PowerTelemetryCalibration.swift`、`PowerTelemetryEnergy.swift`、`BatteryMonitor.swift`、`BatteryGlassApp.swift`、`Views/PowerCalibrationSection.swift`、`SettingsView.swift`）
- 校准相关测试扩展：`PowerTelemetryCalibrationTests` 覆盖记录增删清空与落盘、按 context 选取最新生效记录、会话开始/结算成功、计数器重置/上下文变化/输入非法分支、会话跨实例持久化；`PowerTelemetryEnergyTests` 覆盖 `uncalibratedEnergyKWh`。测试类更新为 `@MainActor`。

### 修复
- 修复历史页图表 Y 轴刻度标签重复（截图中温度显示「31 / 31 / 31」、电压显示「12.7 / 12.7 / 12.7」）：根因是标签小数位写死（温度取整、电压 1 位，耗电图固定 `%.1f`），而 Y 域只留 10% 余量——当日温度跨度 0.36 ℃、电压跨度 0.036 V 时，系统自动挑的 3~4 个刻度四舍五入后塌成同一个字符串。新增纯类型 `AxisTickScale` 与 `MetricValueAxis.ticks(in:)`/`fractionDigits(forStep:)`：在 Y 域内按「整齐步长」（0.001…1000 候选，取刻度数 3~5 的最小步长）生成刻度值，小数位由步长反推并带「标签塌陷则加位」兜底；温压曲线（`TodayMetricChartData.axisTicks`）与「今日耗电量」柱图（`DailyEnergyComparisonChart.energyAxis`，Y 域改为 0…峰值×1.1 且至少 0.1 kWh）均改用显式刻度。`MetricValueAxis.yDomain`/`BatteryLevelAxis.yDomain` 语义不变。新增测试 `HistoryMetricChartDataTests` 的 `AxisTickScale` 分组（9 个用例）。（`Views/HistoryView.swift`、`HistoryMetricChartDataTests.swift`）
- 修复唤醒后 30 秒维持功耗采样窗口内再次睡眠导致的待机能量丢段：`handleWillSleep()` 原先无条件 `cancelMaintenanceSampling()`，会连同上一段尚未结算的 `wakeBaseline` 一起丢弃（`finalizeSleepSegment()` 仅在 30 秒窗口跑满时才触发），典型场景「开盖后又马上合盖」会永久少记一整段睡眠能耗。现改为再次睡眠前判断 `wakeBaseline != nil`，先用已采集样本调用 `finalizeSleepSegment()` 结算上一段，再写入新的睡眠基线。（BatteryMonitor.swift）
- 修复墙上能量计数器默认单位偏差 1000 倍：`PowerTelemetryEnergy.rawUnitsPerKWh` 由占位值 `1e6` 改为经实测反推的 `1e9`。依据：解析 `power-diagnostics.jsonl`（09:54–12:03，2 小时 9 分）得到适配器输出积分 0.0631 kWh，而计数器差值按 `1e6` 换算为 ~62.5 kWh，比值 ≈ 0.00101，即 MacBookPro18,1 上真实量级约为 **1e9 单位/kWh**。此前未校准读数被高估 1000 倍（会话 2 分钟即显示 0.74 kWh ≈ 22 kW），校准系数也会落在 0.001 量级并误触「系数偏离常见范围」告警；改后未校准读数接近真值、校准系数回到 ~1.1，该常量仍为暂定起点、以电表校准记录为准。同步更新 `PowerTelemetryEnergyTests`、`SleepEnergyCalculatorTests`、`PowerTelemetryCalibrationTests` 的期望值。（`PowerTelemetryEnergy.swift` 及三个测试文件）

### 修改
- 移除历史页「循环次数趋势」图（`CycleTrendChart` 及其数据 `CycleTrendData`）：历史页不再展示循环次数趋势（实时页「循环次数」KPI 卡保持不变）。同时删除因此无用的 `PowerChartInteraction.nearestDailySummary` 及其测试。（`Views/HistoryView.swift`、`PowerChartInteractionTests`、`HistoryMetricChartDataTests`）
- 移除历史页「电池健康趋势」图（`HealthTrendChart`）：历史页不再展示健康度长期曲线。实时页「电池健康」KPI 卡与桌面小组件的健康度显示保持不变。（`Views/HistoryView.swift`）
- 更新 `CODEBUDDY.md`，修正与补齐近期变更：历史 payload 版本 `v4` → `v5`（`BatteryHistoryStore.swift:307` 实际为 v5），并补充 v5 迁移说明（`SleepSegment` 增 `hasUnobservedSource`/`boundaryPowerChange`、`DailySummary` 增 `energyQuality`，均带默认值解码、旧文件无需新迁移分支）。
- `CODEBUDDY.md` 能耗计量段补充睡眠边界语义：`SleepEnergyCalculator.minimumDuration = 60s`、`SleepBoundaryPowerChange` 对称 `sourceChanged` 分支与 `SleepSegment.hasUnobservedSource`（下界）含义。
- `CODEBUDDY.md` 补充 `DailySummary.energyQuality` 字段、`EnergyAggregator` 所在路径（`Support/EnergyAggregator.swift`），并在 Views/UI 段加入根目录已知问题记录 `HISTORY_PICKER_FLICKER.md` 的指引。
- `CODEBUDDY.md` 新增「项目结构」目录树（`Sources/BatteryGlass/` 六个子目录职责 + 顶层 `script/`、`scripts/`、`Resources/`、`design-system/`、`docs/`、`dist/`）与「App 层（入口 / 场景 / 单实例）」小节（`AppInstanceGuard`/`AppDelegate`/`@main` 均在 `App/BatteryGlassApp.swift`，`init` 固定顺序与两个 Scene 的注入）。
- `CODEBUDDY.md` 补齐此前未点名的类型与机制：`AppSettings` 设置项清单与 `DashboardView` 的 `@AppStorage("BatteryGlass.panelTab")` 例外、`MenuBarIconRenderer` 合成单张模板 `NSImage` 的原因、`ViewThatFits` 实时页回退、`HistoryView` 三个内联缓存（`TodaySamplesCache`/`PowerChartDataCache`/`BatteryLevelChartDataCache`）与两个数据纯类型。
- `CODEBUDDY.md` 补充 `LoginItemService` 的 `.notFound` 执行语义：`apply(desiredEnabled:)` 在 `.notFound` + 期望关闭时返回 `LoginItemApplyResult.cannotConfirm`，设置页回滚开关并提示、不调用系统 API。

### 修复
- 修复本地通知在应用前台（active）时被系统静默丢弃的问题：`NotificationService` 新增私有 `ForegroundNotificationPresenter`（遵循 `UNUserNotificationCenterDelegate`，`willPresent` 返回 `[.banner, .sound]`），并在 `BatteryGlassApp` 的 `AppDelegate.applicationDidFinishLaunching` 中调用 `NotificationService.installForegroundPresenter()` 安装。此前菜单栏面板打开或设置窗口位于前台时，低电量与插拔通知不会弹出横幅（NotificationService.swift、BatteryGlassApp.swift）。
- 修复插拔适配器时可能多报一次「已接入电源」的问题：`BatteryMonitor.checkAdapterChange` 原用 `defer` 无条件写 `lastAdapterConnected`，会在 `isPresent == false` 的瞬态样本上写坏基准、导致下一个正常样本补发虚假通知；现改为 `!s.isPresent` 时直接返回、不更新基准（BatteryMonitor.swift）。
- 修复 `.notFound` 状态下关闭「开机自启动」无任何反馈的问题：新增 `LoginItemApplyResult.cannotConfirm`，`LoginItemService.apply` 在 `.notFound + 期望关闭` 时返回它（仍不调用任何系统 API），设置页据此把开关回滚到原值并弹出「无法确认开机自启动状态」提示，引导用户到系统设置核对。`desiredAction` 行为不变（LoginItemService.swift、SettingsView.swift）。

### 修改
- 统一「功率趋势」卡副标题口径：适配器供电时由「适配器输入功率」改为「适配器输出功率」，与「实时功率」卡及「电源分配」卡第三格（同为 `adapterInputPowerW`）一致（LiveDashboardView.swift）。
- 设置页「关于 · 版本」不再硬编码 `1.0.0`，改为读取 `Bundle.main.infoDictionary["CFBundleShortVersionString"]`，取不到时回退 `1.0.0`（SettingsView.swift）。
- 「退出」按钮增加二次确认：`DashboardView` 底部退出按钮改为先弹 `confirmationDialog`（含破坏性「退出」与「取消」），确认后才 `terminate`，避免误点即退出（DashboardView.swift）。
- 「功率趋势」卡峰值/平均改为真正的时间窗口：由 `samples.suffix(240)`（按条数）改为以最新样本时间戳为锚点的最近 120 秒窗口，避免样本稀疏时「2 分钟」标签失真（LiveDashboardView.swift）。

### 新增
- 历史页「每日明细」新增能耗质量角标：`DailySummary.energyQuality` 任一标记为真时，日期旁显示 `exclamationmark.triangle`，hover 与 VoiceOver 给出具体原因（采样断点、睡眠段估算、计数器未校准、能量为下界、旧记录口径未知）（HistoryView.swift）。
- 「每日明细」跟随所选统计范围：范围内不足 30 行时全部显示，超出时显示最近 30 行并提示「另有 N 天未显示」，不再静默截断（HistoryView.swift）。

### 重构
- 可访问性：`AnimatedSegmentedControl` 每个分段补 `accessibilityAddTraits(.isSelected)`，VoiceOver 可播报当前选中项（AnimatedSegmentedControl.swift）。
- 性能缓存（消除 2Hz 父视图重渲染下的重复计算）：
  - `HistoryView` 新增 `DailyAggregateCache`，日/周/月聚合 `EnergyAggregator.aggregate` 仅在汇总集合或分组方式变化时重算（HistoryView.swift）。
  - `MenuBarIconRenderer` 按「电量整数百分比 | 电源状态 | 是否外接电源」记忆化模板图，避免每次 body 求值都新建 `NSImage` 并重绘（MenuBarLabel.swift）。
- 本次改动后 `swift build` 通过，`swift test` 全部 231 个测试通过。

## [2026-09-28]

### 修改
- 统一「实时功率」卡副标题：适配器供电时由「系统功率」改为「适配器输出功率」。该卡数值取 `BatterySnapshot.displayPower`（适配器供电时即 `adapterInputPowerW` = `SystemPowerIn`），与「电源分配」卡第三格「适配器输出」同源，原副标题却写成「系统功率」，与指标行「系统功耗」（`systemPowerW`，另一个量，充电时可相差数倍）撞名。现只改文案，取值逻辑不变；同步修正 `BatterySnapshot.displayPower`/`displayPowerText` 与 `PowerKpiCard.valueText` 注释中的「系统功率」措辞（BatterySnapshot.swift、LiveDashboardView.swift）。
- 完善 `CODEBUDDY.md`：修正登录项回写位置的行号引用（`BatteryGlassApp.swift:60-62` → `:68-69`）；补齐遗漏的 `BatteryLevelChartDataTests` 及 `BatteryLevelChartData` / `BatteryLevelChartDataCache`；按名点出 `Stores/HistorySampleRecovery.swift` 的回填实现；在可测试纯函数清单补 `minimumMaintenancePowers`；新增「无 lint/格式化配置」与 `swift-tools-version` 说明、`script/install_app.sh` 的 source 关系、`Views/HistoryView.swift` 为最大单文件（含内联图表数据类型）的提示，以及 `docs/superpowers/` 能耗设计与计划的参考指引。

### 修复
- 修复「睡前未插电、睡眠中（或醒来时）插上充电」这一段待机能量被整段丢弃的问题：`SleepEnergyCalculator` 原先只用睡前供电状态选分支，睡前未插电会走放电分支，而睡眠中充电使电量净增、放电量钳为 0，最终 `guard energyKWh > 0` 失败、整段静默丢弃，那段真实的插座消耗（充电 + 电脑维持 + 转换损耗）从日耗电量里消失。现在新增 `sourceChanged` 对称分支，覆盖该情形及其镜像（睡前插电、睡眠中或醒来时拔电，此前同样会丢段），按可观测来源保守计入。
- 修复中遵循「只取积分量」：插电占睡眠的比例因睡眠期间无采样而未知，因此**不使用**「唤醒后瞬时功率 × 整段时长」外推（那会把只插了几分钟的睡眠高估成全程插电，误差无上界）。有墙上累计计数器时取 `计数器差值 + 电池净释放量`，无计数器时取充入量（电量升）或电池净放电量（电量降），三者皆无则不生成区间。
- 计数器分支刻意不用 `batteryDischargingBefore` 门控：该标志要求睡前已插电，睡前未插电时恒为 false，沿用会把「记放电量」错误退化成「只记墙侧」，反而少记。边界两侧供电状态不同时容量下降本身就是放电证据，不是噪声。

### 新增
- `SleepSegment` 新增 `hasUnobservedSource: Bool`（默认 false）：为 true 表示该段 `energyKWh` 只覆盖可观测部分、真实电源侧能量被低估（下界）。
- 新增枚举 `SleepBoundaryPowerChange`（`batteryToAdapter` / `adapterToBattery`）与 `SleepSegment.boundaryPowerChange: SleepBoundaryPowerChange?`：记录睡眠边界两侧的供电状态变化方向。因睡眠期间进程被挂起、无中途采样，只断言「边界发生变化」，不声称变化发生在睡眠期间。
- 历史 payload 版本 v4 → v5。两个新字段均带默认值解码（`decodeIfPresent`），v2–v5 旧文件照常读取，`load()` 无需新增迁移分支；JSON 导出随 Codable 自动带上新字段。
- `BatteryMonitor` 新增 `Logger`（subsystem `com.batteryglass.app`，category `Sleep`），在 `willSleep`/`didWake` 各记录一行端点状态（供电状态、容量、电压、墙上计数器、推导出的变化方向），供睡眠窗口无实时采样时人工核对，可用 `./script/build_and_run.sh --telemetry` 跟随。

### 已知问题
- 唤醒后约 30 秒的维持功耗采样窗口内若再次睡眠，`handleWillSleep()` 会先 `cancelMaintenanceSampling()` 再覆盖基线，上一段尚未 finalize 的能量段被丢弃。与本次修复的丢段同类，触发条件是「开盖后又马上合盖」，尚未处理。

## [2026-09-26]

### 修复
- 修复「今日电量曲线」Y 轴顶端刻度（100%）被裁切并压到标题上的问题：顶端刻度标签以刻度线为中心绘制，贴着绘图区上沿会被 `.clipped()` 裁掉上半个字，现在在图表外包一层 14pt 顶部内边距为标签留出空间（`TodayBatteryLevelChart`，绘图区高度不变）。
- 修复拖动「今日功率曲线」时间滑块时曲线被拉伸/回缩的问题：滑块之前以真实时间定位，可见窗口宽度取决于窗口内落了多少待机断点（实测同一天内从 0 秒到 7200 秒不等），横向比例随拖动剧烈变化。现在可见窗口改为曲线坐标下的固定宽度窗口（默认 2 小时数据），滑块也在曲线坐标上取值，拖动时窗口等宽平移、比例恒定（`PowerChartWindow.visibleChartDomain`/`scrollBounds`，滑块范围与跟随最新数据的判定同步改为曲线坐标）。
- 修复今日功率曲线的待机/无读数断点仍占横向宽度的问题：断点改为不占宽度，曲线在断点处直接跳到下一段，轴上的 `//` 标记提示跳变位置。此前断点会被压缩成最长 60 秒的可见段（`PowerChartTimeline`），刚唤醒时可见窗口几乎全被该段填满，曲线被挤到右侧一小条（`Views/HistoryView.swift`）。

### 修改
- 移除今日功率曲线的待机区间底色填充：断点不占宽度后该填充不再有可见区域，待机信息改由 `//` 标记表达，同时删掉 `TodayPowerChart` 中仅服务该填充的 `RectangleMark`。

### 新增
- 为 `PowerChartTimeline` 补充单元测试：断点不占宽度、断点内时刻塌缩到跳变点、坐标反查在断点结束处恢复、断点内的整点刻度判定；并补充曲线坐标滚动窗口的测试（滑动时窗口等宽、末端跟随最新数据）（`PowerChartDataTests`）。

## [2026-09-24]

### 新增
- 历史页新增「今日电量曲线」：整日一屏展示当天 0–100% 电量随时间的变化，缺口处断开连线，支持鼠标悬停查看时间与电量（复用今日样本，无需改动持久化格式）。

## [2026-09-11]

### 优化
- 菜单栏电池图标改为按实际电量连续填充，不再限制为 0% / 25% / 50% / 75% / 100% 五档，同时保留充电闪电提示。

## [2026-09-11]

### 优化
- 同步菜单栏电池图标的充电闪电位置，适配更宽的 23pt 电池主体，避免闪电在充电状态下偏左。

## [2026-09-11]

### 优化
- 适当增加菜单栏电池图标的横向宽度，修正电池主体偏窄的视觉比例，保持内部闪电和实际电量档位不变。

## [2026-09-11]

### 修复
- 修复菜单栏充电提示容易被状态栏模板渲染吞掉的问题：把闪电叠加在真实电量电池图标内部，同时保留当前电量显示，不再额外占用右侧空间。

## [2026-09-10]

### 修复
- 修复菜单栏无障碍文案不含充电状态的问题：VoiceOver 现在完整播报「正在充电 / 电池供电 / 已接通电源 / 未检测到电池」，新增 `MenuBarAccessibility.label(for:)` 纯函数并合并为单一无障碍元素。
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
