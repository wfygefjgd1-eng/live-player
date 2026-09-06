# live-player 代码审查报告（2026-09-07）

> 审查范围：`android-native/`（Java + ExoPlayer 电视端）、根目录 5 个 Python 播放器变体 + Kivy 安卓版 + 频道管理脚本、`clean-client/`（Android 客户端）、`scripts/` 与 `iptv-mirrors/` 频道管线、`TVPlayer-iOS/scripts/`、4 个 GitHub Actions 工作流、根目录 3 个补丁文件。
>
> 严重级：P0 = 崩溃/产物不可用；P1 = 真实 bug / 重大性能问题；P2 = 次要问题 / 优化点。

---

## 〇、修复优先级 Top 10（跨模块汇总）

| # | 级别 | 位置 | 问题 |
|---|------|------|------|
| 1 | P0 | `android-native/.../MainActivity.java:172/481/1689` | 移动网络下启动必崩：`showIndicator()` 在 `bindViews()` 之前被调用，`indicator` 为 null → NPE |
| 2 | P0 | `buildozer.spec:5-9` | APK 打包缺 `main.py` 入口，装上即崩（仓库无 main.py 也无复制钩子） |
| 3 | P1 | `MainActivity.java:1046-1047/1026/99-100` | `netPool` 自阻塞：镜像竞速子任务提交进同一个有界池并 `await`，并发 2 个顶层任务时互相饿死，整轮加载超时失败 |
| 4 | P1 | `MainActivity.java:914-942/1941-1946` | `onResume` 先清空频道列表并停播再拉源，拉取失败只剩黑屏；且无视融合模式，列表静默缩水成单源 |
| 5 | P1 | `M3UParser.java:80/57` | 畸形频道名（超长数字）抛 NumberFormatException，整份 M3U 解析被丢弃 |
| 6 | P1 | `tv_player_tk.py:507` | 缺 `import time`，卡顿检测/自动换线整体失效（每次触发 NameError） |
| 7 | P1 | `tv_player_tk.py:321-335` vs `tv_player_pro.py:385-397` | 两个程序共用 `~/.tv_player/favorites.json` 但格式互不兼容，先跑一个再跑另一个即崩 |
| 8 | P1 | `iptv-mirrors/multi_pass_filter.py:27`、`playback_quality_filter.py:26`、`strict_quality_filter.py:25` | 硬编码 `C:\Users\96335\Desktop\TVPlayer`，任何其它机器/CI 上不可运行 |
| 9 | P1 | `scripts/download_and_merge_sources.py:66-69` | `#EXTINF` 后跟 `#EXTVLCOPT`/`#EXTGRP` 等选项行时整个频道被丢弃（IPTV 源中极常见） |
| 10 | P1 | `.github/workflows/build-android.yml:47-53` + `android-native/app/build.gradle:27-31` | Release 产物是未签名 APK，真机无法安装 |

---

## 一、android-native（Java + ExoPlayer 电视端）

### 架构摘要
单 Activity 架构：`MainActivity`（2121 行）承担 UI、手势/遥控、播放器生命周期、多源下载与频道合并全部职责，无 ViewModel 分层。播放使用旧版 ExoPlayer 2.19.1（`com.google.android.exoplayer` 坐标，已 EOL），M3U 源硬编码指向 GitHub/jsDelivr，由 `MirrorResolver` 展开镜像后在自建 `netPool` 上并发竞速，配合 `loadGeneration` 代号做过期取消。持久化全部走“JSON 塞 SharedPreferences”的 `StorageHelper`。

### P0

**P0-1 启动崩溃：移动网络下 `showIndicator` 在 `bindViews` 之前被调用 → NPE**
- `MainActivity.java:172`（调用点）、`:1689`（触发行）、`:481`（崩溃行）
- `onCreate` 中 `checkNetworkSpeed()` 先于 `bindViews()` 执行，移动网络分支直接调 `showIndicator("移动网络，快速切换模式")`，而 `showIndicator` 第一行是 `indicator.setText(text)`，此时 `indicator` 尚未 `findViewById`。**手机插 SIM 卡联网时启动必崩**；电视盒子（以太网/WiFi）不触发，故长期未被发现。
- 修复：`checkNetworkSpeed()` 移到 `bindViews()` 之后；或 `showIndicator` 开头加 `if (indicator == null) return;`。

### P1

**P1-1 线程池自阻塞（starvation）**
- `MainActivity.java:1046-1047`（`done.await(12, SECONDS)`）、`:1026`（`netPool.execute` 提交子任务）、`:99-100`（池大小 `max(2, min(4, cores-1))`，最小 2）
- 顶层拉取任务都在 `netPool` 上运行，其内部 `fetchOneSource`→`httpGetWithMirrors` 又向**同一个池**提交 N 个镜像候选任务并阻塞 `await`。两个顶层任务并发时（onCreate 融合加载期间用户切后台再回来触发 `onResume` 重载，即可发生），2 个线程全部阻塞在 `await`，镜像子任务永远排队 → 每个源白白等满 12s 超时返回 null，**整轮加载判为失败**；单任务时竞速也退化为准串行。
- 修复：镜像竞速用独立 Executor（或 OkHttp 异步回调），顶层与子任务绝不共用同一个有界池。

**P1-2 畸形频道名导致 NumberFormatException，整份 M3U 被丢弃**
- `M3UParser.java:80`、`:57`
- `CCTV_PATTERN` 的 `group(1)` 无位数限制，`Integer.parseInt` 对 `CCTV99999999999999999999` 直接抛 NFE；`parse()` 无 try/catch，异常一路抛到 `fetchOneSource` 的 catch（`MainActivity.java:1805`）→ 整个源返回空列表，一个坏名字毁掉全部几千频道。
- 放大器：`StorageHelper.java:80` `o.optString("key", M3UParser.normalizeName(...))` 的 fallback 参数**无论 key 是否存在都急切求值**，缓存加载（主线程）也必跑一遍该正则管线，同名异常会让整个缓存加载失败。
- 修复：`parseInt` 前校验长度或包 try/catch；`StorageHelper` 改为先 `optString("key","")`，为空时再单独计算默认值。

**P1-3 主线程重 IO/JSON**
- `MainActivity.java:658`（onCreate 主线程解析数千频道 JSON 缓存）
- `applyChannelLineRules` 对**每条 URL** 调 `storage.isLineHidden(url)`，而它每次都重新 `loadHiddenLines()` 反序列化整个 Set（`StorageHelper.java:243/263`）；N 台 × M 线 = 数千次 SP 反序列化全在主线程，大列表明显掉帧甚至 ANR。`isFavorite/isHidden`（`StorageHelper.java:130/150`）同病。
- `applyLoadedChannels` 每次最终批次（含每次 `onResume` 刷新）在主线程全量序列化保存（`StorageHelper.java:49`）。
- 修复：循环外读一次 hidden Set 复用；缓存读写移后台线程；`saveChannels` 异步化。

**P1-4 `onResume` 重载：先清空列表并停播，失败则 UI 彻底空白；且忽略融合模式**
- `MainActivity.java:914-942`（清空 915-916、停播 904-907、单源拉取 936）、失败落点 `:1941-1946`
- 每次 Resume 先 `channels.clear()` + `player.stop()`，再拉源。弱网/镜像全挂时旧列表已清、播放已停，只剩“加载失败”黑屏，无任何回退。且只拉 `activeSourceUrl` 单源，硬编码 `applyLoadedChannels(parsed, ..., 1, 1, false)`，smart/complete 融合模式聚合的多源大列表切后台回来后静默缩水。
- 修复：后台拉取成功后再替换列表（失败保留旧数据继续播）；按融合逻辑拉取；失败时至少回读缓存。

### P2

1. **全量刷新列表** `MainActivity.java:1230-1232`：换台时 `adapter.setData(channels)` 全量 `notifyDataSetChanged`，数千频道只为更新一行。改 `notifyItemChanged(currentIndex)`。
2. **“假 READY” 分支超时保护是死代码** `:236-239`：`scheduleStallCheck` 入口 `:1069` 的 `if (!waitingForReady && !currentPlaybackReachedReady) return;` 使该分支永远不会安排超时，播放被抑制时画面卡死无自动恢复。
3. **Handler 回调泄漏** `:1151-1156`：静音二次确认的匿名 Runnable 无引用可移除；`:1632-1650` `onDestroy` 漏调 `cancelPreferLineTask()`，`preferLineRunnable` 销毁后仍存活 6s。
4. **httpGet 无 finally、无大小上限** `:981-1002`：异常路径连接泄漏；`readLine()` 循环无上限可 OOM。改 try-with-resources + 10MB 上限。
5. **rtmp 放行但无解码模块** `:1214-1216` + `build.gradle:50`：核心 ExoPlayer 无 extension-rtmp，rtmp 线路必然失败并被信誉机制**拉黑 24 小时**（`markFailure` `:1394`）。
6. **端口过滤误杀** `:1511`：只放行 80/443/8080/1935，IPTV 常见的 `:8000/:8081/:9981/:8899` 全被静默丢弃。删除该过滤，让播放失败+信誉机制自然淘汰。
7. **LineReputationStore 无限增长 + 每次 mark 全量序列化** `LineReputationStore.java:218-241/92/113`：加容量上限/LRU 与写入防抖。
8. **Channel.addUrl 线性查重 → 聚合 O(n²)** `Channel.java:35`：内部维护 `HashSet` 查重。
9. **M3U 名称取“第一个逗号”** `M3UParser.java:13/31-32`：`group-title="央视,新闻"` 时名字错乱。改为取最后一个逗号之后（EXTINF 语义即如此）。
10. **跨线程共享字段无同步**：`activeSourceUrl`、`sourceUrls`、`fusionMode` 主线程写、netPool 线程读，改 `volatile` 或在提交任务前捕获为 final 局部变量。
11. **过时 API**：`getActiveNetworkInfo()`（`:1525/1684`，API 29 废弃）、`FLAG_FULLSCREEN`（`:148-150`）、`InputMethodManager.SHOW_FORCED`（`:793`，关闭对话框后软键盘强制残留）；`isNetworkSlow`（`:123`）死字段。
12. **销毁时未解绑 PlayerView** `:1644-1647`：release 前加 `playerView.setPlayer(null)`。
13. **ChannelAdapter** `:82/95`：`getAdapterPosition()` 废弃；监听器每次 bind 重建，移到 `onCreateViewHolder`。
14. **安全/清单/构建**：`AndroidManifest.xml:19` 全局明文放行（建议 networkSecurityConfig 按域收敛）；`:14` `allowBackup="true"`；`:15-16` 图标直接用系统 drawable。`build.gradle:12` targetSdk 33（Play 要求 34+）；`:29` release 未混淆、proguard-rules 形同虚设；`:17` 仅 arm64-v8a，老盒子装不上；ExoPlayer 2.19.1 已 EOL，建议迁移 Media3。
15. **“fast” 模式实际最慢** `:674-688`：`fetchChannels()` 对 15+ 候选源**串行**逐个拉，每个最长 16s。限制尝试个数或真并发竞速。
16. **源输入无校验** `:809-830`：`addButton` 不校验 URL 格式；大量中文文案硬编码在 Java/布局中，未进 `strings.xml`。

### 已核实无问题（避免误报）
`channels` 列表仅主线程读写；`httpGet` 已设 6s/10s 超时；`loadGeneration` 代号检查实现正确；索引边界检查齐全。

---

## 二、Python 播放器（5 个桌面变体 + Kivy + 频道管理）

### 架构摘要
同一概念用 5 种 GUI 方案各实现一遍：`tv_player.py`（tkinter 演示版，只展示地址不播放）、`tv_player_tk.py`（tkinter + mpv `--wid`，**功能最全、最当前**）、`tv_player_desktop.py`（tkinter + mpv 骨架版）、`tv_player_mpv.py`（PySide6 + mpv 子进程）、`tv_player_pro.py`（PySide6 + libVLC）、`android_main.py`（Kivy）。共享代码（Channel/M3UParser/Storage/收藏/隐藏）是复制粘贴式的，已出现多处行为漂移。`buildozer.spec` 只打包 `android_main.py`。

### P0

**buildozer.spec:5-9, 26-27 — APK 无入口文件，必崩**
`source.include_patterns = android_main.py`，但 p4a 固定加载 `main.py`；仓库既无 `main.py` 也无构建期复制钩子。修复：提供 `main.py`（内容 `from android_main import TVPlayerApp; TVPlayerApp().run()`）。
另：`:9` requirements 缺 `ffpyplayer`，Android 上 Kivy `Video` 运行时抛 "Provider not found"（P1）；`:15-16` minapi 19 配 NDK 25b 不匹配（p4a 实际要求 ≥21）（P2）。

### P1

1. **tv_player_tk.py:507（及 511/515/517/520）缺 `import time`**：`is_stalled()` 抛 NameError，卡顿检测/自动换线从不工作。头部补 `import time`。
2. **favorites.json 格式冲突**：tk 版存频道 key 字符串列表（`tv_player_tk.py:321-335`），pro/mpv 版存 `[{"name":...,"url":...}]` 字典列表（`tv_player_pro.py:385-397`）；共用 `~/.tv_player/favorites.json`，先跑一个再跑另一个抛 TypeError。统一 schema 并在 `_load` 处容错降级。hidden.json 同样两套语义（tk 存 key、mpv/pro 存 URL）。
3. **tv_player_tk.py:374/974/982 每个元素整读一次 JSON 文件**：`is_line_hidden/is_favorite` 每次查询都 `read_text + json.loads`，5000 频道 × 每次击键 = 上万次读盘。启动时一次性读入内存 set。
4. **tv_player_tk.py:535-556 Windows 命名管道 IPC 无超时且在 UI 线程**：`ReadFile` 无 OVERLAPPED，`timeout` 参数只对 Unix 生效；mpv 一旦无响应整个界面永久冻结。改 OVERLAPPED+超时或移后台线程。`tv_player_desktop.py:463-473/577-598` 同病（每 400ms 串行查 6 个属性）。
5. **tv_player_tk.py:488-495 IPC 响应不按 request_id 匹配**：mpv 广播事件先到时读到错误值，`is_stalled` 误判乱切线。循环读到匹配的 request_id 为止。
6. **tv_player_desktop.py:436-441 “睡 1 秒即 ready”**：`_ready_probe` 只要 mpv 进程活着就 `on_ready()`，`CHANNEL_SWITCH_TIMEOUT_MS=4000` 永远到不了，死流（mpv 活着但永远缓冲不出画面）永不切线。换成 tk 版 1085-1115 的 time-pos 推进检测。
7. **android_main.py:199/225 锁定状态下 `collide_point` 用窗口坐标传给子控件**：点锁按钮几乎无法解锁。改 `self.lock_btn.to_widget(*touch.pos)`。
8. **android_main.py:382-384 刷新失败清空唯一本地缓存**：`_fetch_next` 空队列分支无条件 `self._save_cache()`，用空列表覆盖几千条频道缓存。仅非空时保存，失败保留旧数据。
9. **android_main.py:326-337 收藏/隐藏是死功能**：`fav_store/hidden_store` 只有 `exists` 查询无任何 `put` 写入，按钮永远给出空结果。
10. **tv_player_mpv.py:306/381/391 向 mpv stdin 写命令但启动参数含 `--no-terminal`**：音量/暂停/退出命令全部无效，quit 靠 1 秒后 kill() 兜底。改用 `--input-ipc-server` IPC。
11. **tv_player.py:314-317 点击行号换算错误**：每条目占两行（频道行+空行）但直接把行号当索引，点频道 2 播频道 3。改 `(行号-1)//2` 并跳过空行。
12. **tv_player.py:390-392 切换源在 UI 线程做最长约 60s 网络请求**：窗口冻结一分钟无反馈。照搬 `load_channels` 的线程模式。

### P2（精选）

- **IPC 起播竞态** `tv_player_tk.py:462`：`Popen` 后立即发 IPC 解暂停，管道尚未创建必然失败。
- **auto_switching 防重入标志被自己重置** `tv_player_tk.py:1042 vs 1181-1183`（desktop 1432/1511 同病）：所有线路全死后无限循环重试。flag 重置移到用户主动操作入口。
- **删除线路后索引漂移** `tv_player_tk.py:1224/1241-1248`：照搬 desktop 1081-1095 的按 key 重定位。
- **搜索/列表全量重建** `tv_player_tk.py:703/970-993`、`android_main.py:153/334-340`：加 200-300ms 防抖 + 增量更新。
- **JSON 读写非原子 + 吞异常** `tv_player_tk.py:260-264`、`channel_rules_manager.py:130-164/38-40`、desktop/mpv/pro 同病：半写损坏后静默丢失用户数据；规则文件损坏被默认规则静默覆盖。改临时文件 + `os.replace`，损坏先备份 `.corrupt`。
- **测速 response 泄漏** `tv_player_mpv.py:119-131`、`tv_player_pro.py:136-143`：成功路径不 `resp.close()`。用 `with requests.get(...) as resp:`。
- **测速/加载线程非 daemon** `tv_player_mpv.py:106-107/158-159`、pro 同病：关窗后进程滞留最长几十秒。
- **裸 `except:`** `tv_player_mpv.py:186/199/281/406/438/615`、`channel_manager.py:155-161` 等：吞掉 KeyboardInterrupt、隐藏真实错误。收窄为 `except requests.RequestException:`。
- **HEAD 探测假阴性** `channel_manager.py:155-161`：大量 IPTV 服务器对 HEAD 返回 405，好频道被误判不可用。改 Range GET 读首块。
- **硬编码跳线规则与 channel_rules_manager.py 重复且已漂移** `tv_player_tk.py:352-364`：后者没有任何播放器导入，改配置文件不生效。改用 `ChannelRulesManager`。
- **跨线程调 Tk** `tv_player_tk.py:252-262/943-947`：`_on_close` 后工作线程 `root.after` 抛 TclError。用 queue + 主线程轮询。
- **libVLC stop() 阻塞 GUI 线程** `tv_player_pro.py:320/334-338`：每次切台顿一下，某些版本有死锁风险。
- **测速阈值文案漂移** `tv_player_pro.py:820 vs 165`：文案“低于2MB/s”代码却是 1MB/s。
- **channel_manager.py:94-107 内容非空即判成功**：拉回错误页时把频道清成 0 还报成功；解析为空不替换列表。
- **desktop 注释与代码矛盾** `tv_player_desktop.py:1066-1070`；watcher 起播误报 `:444-459`；双绑定二次起播 `:784-785`；死代码 `:1514-1519`。
- **channel_rules_manager.py:117-118 空索引规则无法往返**：`add_rule(key, [])` 重启后消失。
- **Kivy emoji 不可渲染** `android_main.py:295`：默认字体显示方框。
- **android_main.py:405 解码无容错**：坏字节中断镜像回退链。

---

## 三、clean-client / 频道管线 / CI / 补丁文件

### 架构摘要
`clean-client` 是对某原始 APK 逆向后的“干净版”Android 客户端（Retrofit+OkHttp+ExoPlayer），带 Splash 选线（ping 最优线路后重建 baseUrl）。频道管线有 6 套功能重叠的 Python 抓取/验证脚本。CI 4 个工作流负责构建 APK/IPA 与同步 M3U 镜像。未发现泄露密钥，也无 `pull_request_target` 滥用。

### P1

1. **Splash 选线竞态** `clean-client/.../ui/SplashActivity.java:54/68`：`runOnUiThread(NetManager::rebuild)` 只是异步投递，工作线程立即继续 `NetManager.api().systemInfo(...)`，bootstrap 请求可能仍打到旧线路，选线逻辑形同虚设。改为工作线程直接同步调 `NetManager.rebuild()`（内部加 volatile/synchronized）。
2. **Fragment 回调 `requireContext()` 崩溃** `VideoListFragment.java:144/154`：Retrofit 回调异步到达时若已离开 Fragment 抛 IllegalStateException。回调开头 `if (!isAdded()) return;`。
3. **全明文 HTTP + 明文 token** `LineConfig.java:17-22` + `AndroidManifest.xml:15` + `HeaderInterceptor.java:44-47`：四条默认线路全 http，token 同时放 `token` 和 `Authorization` 两个明文头。用 networkSecurityConfig 按域放行替代全局放行。
4. **三个管线脚本硬编码开发者本机路径** `multi_pass_filter.py:27`、`playback_quality_filter.py:26`、`strict_quality_filter.py:25`：`BASE = Path(r"C:\Users\96335\Desktop\TVPlayer")`。改 `Path(__file__).resolve().parents[1]`。
5. **M3U 解析丢弃带 `#` 指令行的频道** `scripts/download_and_merge_sources.py:66-69`：`#EXTINF` 后跟 `#EXTVLCOPT`/`#EXTGRP`/`#EXT-X` 时频道整体丢弃。向前循环跳过 `#` 行直到 URL 行。
6. **CI 产出未签名 APK** `build-android.yml:47-53` + `android-native/app/build.gradle:27-31`：`assembleRelease` 无 signingConfig，发布到 Releases 的 APK 真机装不上。用 secrets 注入 keystore，或改发 debug 签名包并标注。

### P2（精选）

- **HttpLoggingInterceptor release 常开** `NetManager.java:19-20`；**token 明文存储 + allowBackup** `SplashActivity.java:77` + Manifest:9。
- **Splash 选线无总超时** `SplashActivity.java:35/97-116`：最坏 360s；Executor 持有 Activity 引用，销毁后仍 startActivity。独立短超时 client + 各阶段判 `isDestroyed()`。
- **pickLine 回退死条件** `SplashActivity.java:112-115`：`if (resp.code() > 0)` 恒真，404/500 也会选中该线路。
- **NetManager 懒加载非线程安全** `NetManager.java:43-55`；**搜索失败提示显示 "null"** `SearchActivity.java:86`；**列表无分页** `VideoListFragment.java:44`（永远第 1 页 20 条）；**重复请求头** `PlayerActivity.java:50-51`（Referer/referer）。
- **clean-client/local.properties 提交进 git**：含 `sdk.dir=C:/Users/96335/Android/Sdk`，泄露用户名；`.gitignore` 只排除了 android-native 的。`git rm --cached`。
- **TLS 校验全局关闭** `multi_pass_filter.py:72-74`、`playback_quality_filter.py:63-65`、`strict_quality_filter.py:50-52`、`build_validated_list.py:189`：下载内容进 App 内置频道表，中间人可注入恶意 m3u8。
- **数据回流：管线自己的输出是自己的输入** `download_and_merge_sources.py:14-21`、`multi_pass_filter.py:34-58`：某次误删的频道永远回不来，僵尸条目互相“续命”。
- **三个脚本互相覆盖同一批输出** `multi_pass_filter.py:415-426`、`playback_quality_filter.py:496-512`、`strict_quality_filter.py:582-593`：最终产物取决于谁最后跑；且均非原子写入。
- **五套解析/合并归一化逻辑各不相同**（`download_and_merge_sources.py:88-97` 精确匹配、`build_validated_list.py:87`、`multi_pass_filter.py:102-112`、`playback_quality_filter.py:96`、`strict_quality_filter.py:288`）：同一频道在不同管线合并结果不同。抽公共 `iptv_lib.py`。
- **编码隐患** `download_and_merge_sources.py:31`：requests 未固定 charset，中文可能乱码。统一 `content.decode('utf-8', errors='replace')`。
- **URL 去重 O(n²)**：`download_and_merge_sources.py:97`、`build_validated_list.py:90/229-230` 等列表线性查找，改 set。
- **validate_and_filter_channels.py**：ffprobe 缺失时在工作线程 `sys.exit`（错误消息打 10 遍）；无断点续跑、串行遍历数千频道。
- **download_and_validate.py（iOS）**：`:59` 用最后一个逗号段做频道名（名字含逗号被截断）；`:102-124` stage1 死代码；`:340` 相对 CWD 写输出；`:350/353` 全离线时 ZeroDivisionError。
- **validate_channels.py（iOS）**：HEAD 探测假阴性，已被 stage2 取代仍在仓库。
- **playback_quality_filter.py**：`:384` 非旗舰线路硬截 900 条（顺序依赖、静默丢台）；`:405` 进度条条件恒真。
- **strict_quality_filter.py:220 运算符优先级可疑**：`A or B and C` 实际是 `A or (B and C)`，小体积 m3u8 无视速度直接通过。显式加括号。
- **CI：两个 iOS 工作流重复且互相矛盾**（`build-ios.yml` vs `ios-build.yml`，选 Xcode 方式/产物路径/验证逻辑都不同）；**release `body_path` 文件不保证存在**（`build-ios.yml:103`、`build-android.yml:76`——版本 2.4.6 无对应 RELEASE_NOTES 文件，Release 创建会失败）；**sync-iptv-mirrors.yml quoted heredoc 时间戳不展开**（`:37/:63`）；**下载失败被静默吞掉**（`:24-33`）；`build-android.yml:13`、`sync-iptv-mirrors.yml:13` 无 `timeout-minutes`；所有 action 按可变 tag 引用，建议钉 commit SHA。
- **根目录 3 个补丁文件均为死代码**：`ANDROID_PATCH_THREE_ISSUES.java`、`ANDROID_OPTIMIZATION_PATCH.java` 是无 class 包裹的裸片段（直接编译失败），且目标文件早已演化出不同实现（`CHANNEL_SWITCH_TIMEOUT_MS = 5000L` vs 补丁的 4000/3000），按补丁粘贴会造成重复成员编译错误；`PATCH_RULES_MANAGER.py` 对应的集成从未落地，文件内示例若被 import 会 NameError。建议删除或移入 `docs/patches/` 并标注“历史快照，勿直接应用”。

---

## 四、横向共性问题

1. **复制粘贴漂移是最大根因**：5 个 Python 播放器变体、6 套频道管线、2 个 iOS 工作流、2 份收藏/隐藏格式——同一逻辑多份拷贝且各自演化。建议抽公共模块（Python 侧 `iptv_core.py`/`iptv_lib.py`），一次性消掉 M3UParser×5、SpeedTester×2、Storage×4 等重复。
2. **UI 线程阻塞是两个平台的通病**：Android 侧 SharedPreferences 逐条读 + 主线程全量 JSON；Python 侧无超时 IPC、同步网络请求全在主线程。
3. **存储可靠性**：所有 JSON 配置写入均为非原子直接覆盖，损坏即静默丢用户数据。统一“临时文件 + os.replace/apply()”。
4. **HEAD 探测与“第一个逗号”解析**这两个错误模式在 4+ 个文件中重复出现。
5. **仓库卫生**：~90 个 RELEASE_NOTES/优化报告 markdown、3 个死补丁文件、提交的 local.properties、82MB 仓库（含 2 个 IPA 二进制产物）应清理，构建产物不入库。
