# ODebug — 独立 TCP 调试控制台 + 跨进程视图树 dump 插件

> 原项目名 **OpenDebug**，因 roothide loader 对旧名字有过加载异常，改名 **ODebug**（包 ID `com.tanyou.odebug`）。
> 完全独立于主插件 Open，不依赖主插件任何代码。

## 安装

1. 从 [Releases](https://github.com/hejunjiea/Opendebug/releases/latest) 下载 `com.tanyou.odebug_<版本>_iphoneos-arm64e.deb`；
2. 用 Sileo / Filza 打开安装，或在设备上 `dpkg -i`，然后 respring。

支持 **roothide**（`THEOS_PACKAGE_SCHEME=roothide`）与 rootless 环境。装上后两条调试通道同时可用：

| 通道 | 位置 | 端口 | 特点 |
|------|------|------|------|
| 插件内控制台 | SpringBoard 进程内（tweak） | **4321** | 跟随 tweak 生命周期；安全模式下会被一起禁掉 |
| 常驻服务 `odebugd` | LaunchDaemon（root，进程外） | **4322** | **安全模式下也不失联**，能自动把 4321 控制台救回来（注入器） |

## 功能

- **TCP 调试控制台**：在 SpringBoard 进程内启动 TCP 服务（端口 4321），通过命令行执行运行时调试。
- **跨进程视图树 dump**：在设置里选中任意 App，即可通过控制台发命令，让该 App 把自己的
  keyWindow 视图树（view → controller 映射）打印到 syslog，用于分析任意页面的控制器结构。
- **只查最上层控制器**：`!vc top` / `!vcapp top` 只输出当前页面最上层控制器的**类名 + 内存地址**，
  拿到地址后可配合 `!mem read` 读内存、`!class` 看方法。
- **完全独立**：自带设置包（调试令牌 + AltList 应用选择列表），独立偏好域 `com.tanyou.opendebug.settings`。

---

## 目录结构

```
OpenDebug/
├── Makefile                     # Theos 构建：tweak ODebug + Settings 子项目
├── control                      # 包信息（Package: com.tanyou.odebug）
├── ODebug.plist                 # 安装后会被 postinst 替换成软链 → 指向偏好域 plist（见下）
├── Tweak.xm                     # 主入口 %ctor：SpringBoard 起控制台 / 注入目标 App 注册 dump 监听
├── TANDebugConsole.m/.h         # TCP 调试控制台（交互式会话、命令解析、认证、socket 服务）
├── TANDebugVCDump.m/.h          # view→controller dump 工具（nextResponder 链遍历 + 顶层控制器 + Darwin 监听）
├── TANHookConsole.m/.h          # App 内键盘钩子入口（被注入的 App 里接管控制台/自动恢复）
├── TANSafeMode.m/.h             # 安全模式开关（标记文件写入/软链判定/退出）
├── odebugd.m                    # ★ 常驻调试服务（LaunchDaemon、root、端口 4322、看门狗自动兜底注入）
├── odebug.sh                    # 傻瓜式交互脚本（自动读令牌 + 数字快捷键 + token 缓存）
├── odebug-iproxy.sh             # 把设备 4321 端口转发到电脑（iproxy 封一层）
├── iphone_xr.sh                 # 一键「编译 → 推送 → 设备安装」脚本（UDID 走环境变量，仓库不含设备 ID）
├── layout/
│   ├── DEBIAN/postinst          # 安装后脚本：把 ODebug.plist 变成软链 + 重签并加载 odebugd（关键机制，见下）
│   ├── DEBIAN/postrm            # 卸载脚本：仅在 remove/purge 时清标记（升级不碰安全模式）
│   ├── Library/LaunchDaemons/com.tanyou.odebugd.plist   # odebugd 的 LaunchDaemon（RunAtLoad/KeepAlive）
│   └── usr/share/odebugd/odebugd.ent                    # odebugd 的最小 entitlements（沙盒外 + task_for_pid）
├── tools/safemode_frida.py      # 安全模式取证脚本（frida 读每个进程的注入状态）
└── Settings/                    # 自带设置包（OpenDebugSettings.bundle）
    ├── Makefile
    ├── Resources/               # Info.plist / OpenDebugSettings.plist / Root.plist（设置 UI）
    ├── TANOpenDebugRootController.m    # 设置主控制器（加载 Root.plist）
    ├── TANOpenDebugAltListController.m # AltList 应用多选控制器（选注入目标 App + 写 Filter）
    └── ATL* / AltList.h / ...   # 复制的 AltList 库源码（应用选择列表 UI）
```

### 关键文件说明

| 文件 | 作用 |
|------|------|
| `Tweak.xm` | 进程门控：SpringBoard → 由 TANDebugConsole 的 constructor 启动控制台；非 SpringBoard 进程 → 注册 dump 监听 |
| `TANDebugConsole.m` | TCP 服务 + `AUTH <token> <命令>` 认证 + 命令解析 |
| `TANDebugVCDump.m` | `TANVCDumpKeyWindowToString` 遍历 keyWindow 视图树；`TANVCDumpRegisterDarwinListener` 注册 Darwin 通知监听 |
| `layout/DEBIAN/postinst` | **核心机制**：把 `ODebug.plist` 变成软链 → `/var/mobile/Library/Preferences/com.tanyou.opendebug.settings.plist` |
| `Settings/TANOpenDebugAltListController.m` | 保存时用 CFPreferences 写 `Filter` + `debugInjectedApps` 到偏好域（cfprefsd 写真实文件） |

---

## 构建与安装

```bash
cd OpenDebug
make package install        # 构建 + 安装 + 自动重启 SpringBoard
```

- 依赖：`mobilesubstrate`（roothide 由 ElleKit 提供）。
- 构建产物：`com.tanyou.odebug_*.deb`。
- 安装后 `postinst` 会自动把 `ODebug.plist` 变成软链（见工作原理）。

---

## 使用说明

### 1. 设置配置（设置 App → ODebug）

| 项 | 说明 |
|----|------|
| **调试令牌** | TCP 控制台认证令牌，默认自动生成 UUID，也可手动改 |
| **注入调试目标应用** | 勾选要查看视图树的 App，保存后写入 Filter，**重启目标 App 生效** |

> ⚠️ 令牌在**设置里改后需 `killall -9 SpringBoard`**（控制台在 SpringBoard 进程，读取令牌有缓存）。

### 2. 连接 TCP 控制台

控制台只绑定**设备本机回环** `127.0.0.1:4321`，电脑不能直接连设备 IP。

**方式 A（设备 SSH，最可靠）**：
```bash
nc 127.0.0.1 4321
```
> 若设备没装 `nc`，可用 bash 的 `/dev/tcp`（不依赖 nc）：
> ```bash
> bash -c 'exec 3<>/dev/tcp/127.0.0.1/4321; printf "AUTH <令牌> !vc top\n" >&3; cat <&3'
> ```

**方式 B（电脑 + USB 转发）**——用本目录的 `odebug-iproxy.sh` 一键转发：
```bash
./odebug-iproxy.sh          # 把设备 4321 转发到电脑 127.0.0.1:4321
# 或手动: iproxy 4321 4321
nc 127.0.0.1 4321
```

### 3. 傻瓜式脚本（推荐）

`odebug.sh` 在**电脑上**运行（也可拷到设备）：自动读调试令牌 + 交互式菜单 + 数字快捷键 + 方向键历史，不用记命令。

**前置**：
- 电脑需开 `iproxy`（`./iproxy.sh`）转发设备 4321
- 方向键历史建议装 Homebrew bash + rlwrap（脚本自动检测使用）：
  ```bash
  brew install bash rlwrap
  ```

```bash
cd OpenDebug && ./odebug.sh
```

**功能**：
- 自动读调试令牌（设备 plist / 本地缓存 / 命令行参数）
- **分组菜单 + 数字/字母快捷键**（视图/控制器、类/对象、内存/文件、App/系统、高级）：
  - `1` `!vc`（视图树，可带类名过滤） · `2` `!vc top`（最上层控制器）
  - `3` `!class` · `4` `!inheritance` · `i` `!ivars [all] [关键词]`
  - `5` `!front` · `6` `!vcapp top` · `u` `!vcapp <bundleId>`（完整视图树）
  - `7` `!mem read` · `w` `!mem write` · `8` `!ls` · `9` `!cat`
  - `r` `!plist read` · `y` `!plist write`
  - `p` `!process` · `s` `!sys` · `a` `!apps` · `b` `!bundle` · `e` `!icon`
  - `d` `!dump` · `c` `!icons list/hide/show`
  - `v` `!eval [方法]`（调用方法） · `g` `!grep <关键词>`（过滤上一条输出） · `m` `!safe`（安全模式：禁用全部插件）
  - `h` 帮助 · `0` 退出
- **方向键 ↑/↓** 翻阅历史命令、**Ctrl+L** 清屏（rlwrap 提供）
- **直接输 Mac 本地命令**（非 `!` 开头，如 `cat`/`ls`/`grep` 可查看拉取的 dump）
- **`!dump` 自动 scp 拉取** dump 目录到电脑当前目录
- **彩色提示符** + 控制台彩色输出（iTerm2）

### 4. 命令列表（认证后）

```
AUTH <令牌> <命令>
```

| 命令 | 作用 |
|------|------|
| `!vc` | 遍历**所有 window**（含悬浮窗/overlay）的 view→controller 树，每个 view 带地址 |
| `!vc <ClassName>` | 只打印类名包含 `<ClassName>` 的 view（无匹配的 window 整段跳过） |
| `!vc top` | **只打印最上层控制器的类名 + 内存地址** |
| `!front` | **看当前前台 App 的最上层控制器 + 地址**（跨进程，傻瓜式一键） |
| `!vcapp [bundleId]` | 广播 Darwin 通知，让**注入目标 App** 把完整视图树打印到 syslog |
| `!vcapp top` | 让注入目标 App 打印它的**最上层控制器 + 内存地址**（syslog 前缀 `VCDumpTop`） |
| `!class <ClassName>` | 列出类的属性 / 实例方法 / 类方法 |
| `!inheritance <ClassName>` | 打印类的**继承链**（superclass 链，看类设计） |
| `!ivars <地址> [all] [关键词]` | 列出对象的**实例变量**（沿 superclass 链收集，KVO 包装类也能看到真实 ivar；默认只显示插件自定义类，加 `all` 含系统类；对象值显示**地址+类名**、集合类只显示数量避免刷屏；再加 `关键词` 只显示名字匹配的 ivar） |
| `!ls <path>` | 列出目录内容（目录会标 `/`） |
| `!cat <path>` | 读文本文件内容 |
| `!plist read <path>` | 读 plist 文件 |
| `!plist write <path> <key> <value>` | 写 plist 文件 |
| `!mem read <addr> [len]` | 读内存（地址来自 `%p` 输出，如 `0x10a3d2c00`） |
| `!mem write <addr> <byte>` | 写内存 |
| `!process` | 当前进程信息（pid / bundleId / 可执行文件 / 启动参数） |
| `!sys` | 设备/系统信息（型号 / iOS 版本 / 内存 / CPU） |
| `!apps` | 列出所有已安装 App（emoji + 颜色区分系统/用户） |
| `!bundle <bundleId>` | 查看某个 App 的 Info.plist（可执行路径 / 版本 / 权限） |
| `!icon <bundleId>` | 显示 App 真实图标（iTerm2 imgcat） |
| `!dump <bundleId>` | 跨进程 dump App 所有 ObjC 类（每类一个文件，自动拉取到电脑） |
| `!dump <插件.dylib路径>` | dump 越狱插件 dylib 的类（如 `!dump /var/jb/.../Open.dylib`） |
| `!icons list` | 列出桌面图标 bundle ID + 显示名 |
| `!icons hide <bundleId>` / `!icons show` | 隐藏 / 恢复桌面图标 |
| `[Target method]` | 调用方法（Target 支持 **类名 / `sharedManager` / `contextHost` 别名 / `0x`实例地址**，如 `[0x1068a2400 dataContainerURL]`；地址带可读性校验，悬垂指针拒绝执行） |
| `!eval [Target method]` | 链式 / 强制调用（如 `!eval [[TOJBClass001 m] m2]`）；对不存在的 selector 返回 `(无此方法)`，不崩进安全模式 |
| `!grep <关键词>` | 过滤**上一条命令**的输出（重放+只显示匹配行，对任何命令有效，如先 `!ivars 0x...` 再 `!grep shortcut`） |
| `!safe on` | **进入安全模式（禁用全部插件）**：写标记 `<jbroot>/var/mobile/.eksafemode` + respring（只清 SpringBoard） |
| `!safe on all` | 写标记 + `jbctl reboot_userspace`：**所有进程**都不再注入 tweak（约 30-60 秒，会杀光 App） |
| `!safe off` | 删掉安全模式标记（配 `!safe respring` 恢复注入） |
| `!safe respring` | 只重启 SpringBoard |
| `!safe status` | 查安全模式状态（标记 / 软链 / 退出办法） |
| `help` / `?` | 显示完整命令菜单 |

> **`!vc top` 实战**：拿到地址后可继续 `!class <控制器类名>` 看它的属性/方法，
> 或 `!mem read <地址> 64` 读控制器对象内存。切到 App 任意页面再发 `!vcapp top` 即可看该页面顶层控制器。

> **地址安全**：地址要**当次会话现取现用**（`!vc` / `!vc top` / `!vcapp top` 输出里直接带）。
> 重启/respring 后旧地址作废；`!ivars` / `!mem read` 对悬垂地址会自动拒绝并提示，不会崩进安全模式。

> **文本颜色**（iTerm2）：
> - 控制台直接响应（`!vc top`、`!class` 等）→ **彩色**（类名青、地址黄、标题蓝、错误红、成功绿）
> - 跨进程 syslog 抓取（`!front`、`!vcapp`）→ 无色（syslog 渲染不了 ANSI）

### 5. 查看任意 App 的视图树 / 最上层控制器（跨进程）

**前置**：在 设置 → ODebug → 注入调试目标应用 里勾选目标 App，**重启该 App**。

**看完整视图树**：
```bash
# 1) 控制台发通知（设备 SSH 或 iproxy）
nc 127.0.0.1 4321
AUTH <令牌> !vcapp tv.danmaku.bilianime
# 2) 电脑上查看目标 App 打印的视图树
idevicesyslog | grep -A 100 "VCDump"
```

输出示例：
```
[open] /VCDump [tv.danmaku.bilianime]:
keyWindow: BiliWindow {{0, 0}, {430, 932}}
<UILayoutContainerView> frame=(0,0,430,932) -> BFCNavigationController
  <UIView> frame=(0,0,430,932) -> BBListHome.HomeViewController   ← 当前页面的控制器
```

**只查最上层控制器 + 内存地址**：
```bash
AUTH <令牌> !vcapp top
idevicesyslog | grep -A 5 "VCDumpTop"
```
输出示例：
```
[open] /VCDumpTop [tv.danmaku.bilianime]:
Top: BBPegasusSwift.BBPegasusViewController 0xf1e070c00
```
切到任意页面再发 `!vcapp top`，即可拿到该页面的顶层控制器和地址。

---

## 工作原理（架构）

### 数据流：设置里选 App → 查看它的视图树

```
① 设置里勾选 App → TANOpenDebugAltListController 保存
   ├─ CFPreferences 写 debugInjectedApps（注入目标数组）到 com.tanyou.opendebug.settings
   └─ CFPreferences 写 Filter（Bundles = springboard + 选中 App）到同一域
② cfprefsd 把该域写盘为真实文件 /var/mobile/Library/Preferences/com.tanyou.opendebug.settings.plist
③ ODebug.plist（软链）→ 指向该 plist 文件
   └─ roothide loader 启动进程时读 ODebug.plist，跟随软链读到 Filter
④ Filter 命中的 App 启动 → ODebug 被注入 → %ctor 运行
   └─ 非 SpringBoard 进程（isTarget = !isSB）→ 注册 Darwin 监听
      com.tanyou.open/dumpVC（完整树）与 com.tanyou.open/dumpVCTop（仅最上层控制器）
⑤ 控制台发 `!vcapp <bundleId>` / `!vcapp top` → 广播对应 Darwin 通知
⑥ 目标 App 收到通知 → dump 完整视图树 或 沿 presented/容器链找最上层控制器 → 打印到 syslog
⑦ idevicesyslog | grep VCDump / VCDumpTop 查看
```

**`!vc top` 找最上层控制器的算法**：从 `keyWindow.rootViewController` 出发，沿
`presentedViewController` → `topViewController`(导航栈) / `selectedViewController`(tab) /
`childViewControllers.lastObject`(通用容器) 走到最顶层，输出 `类名 + %p 地址`。

### 为什么用"软链 + CFPreferences"？

调试过程中踩过的坑：

| 方案 | 结果 |
|------|------|
| Settings 直接写 `/var/jb/.../ODebug.plist`（NSFileManager） | ❌ 沙盒容器虚拟化，写不到真实路径 |
| SpringBoard 侧写（mobile） | ❌ 同样写不了 `/var/jb`（容器访问控制 EPERM） |
| LaunchDaemon（root + no-sandbox） | ❌ 能写 /tmp，但 jbroot 容器路径仍 EPERM（容器级限制） |
| `ODebug.plist` 软链 → `/var/mobile/Library/Preferences/...`（NSFileManager 写） | ❌ Settings 写的还是容器路径 |
| **CFPreferences 写 Filter + 软链指向该域 plist** | ✅ **cfprefsd 写真实文件，loader 跟软链读到** |

**核心认知**：iOS 上唯一能让 App（Settings）写"真实共享文件"的途径是 CFPreferences（经 cfprefsd），
而 loader 读取的 `DynamicLibraries/*.plist` 是容器内路径、不可写。用**软链**把两者桥接。

### 为什么注入目标判断用 `!isSB` 而非读偏好？

被注入的非 SpringBoard 进程**本身就证明它被选中了**（loader 是根据 Filter 注入的）。
运行时再读 `debugInjectedApps` 会失败：CFPreferences 跨 App 读不到别的域，
沙盒也挡直接读 plist 文件。所以 ctor 里 `isTarget = !isSB` 即可。

---

## 开发者指南：如何添加新命令

所有命令都在 `TANDebugConsole.m` 的 `tan_eval()` 函数里，每个命令是一个 `if` 分支。
按这 5 步添加：

**1. 在 `tan_eval()` 加分支**（放在同类命令附近，如类相关→`!class` 后）：

```objc
// !hello [名字] - 示例命令
if ([raw isEqualToString:@"!hello"] || [raw hasPrefix:@"!hello "]) {
    NSString *arg = [raw hasPrefix:@"!hello "]
        ? [[raw substringFromIndex:7] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
        : @"";
    if (arg.length == 0) { tan_sendRsp(fd, @"用法: !hello <名字>，如 !hello 世界"); return; }
    NSString *result = [NSString stringWithFormat:@"你好，%@！", arg];
    tan_sendRsp(fd, result);
    return;
}
```

**2. `tan_helpText()` 菜单加一行**（用户 `help` 能看到）。

**3.（可选）`odebug.sh` 菜单和 case 加快捷键。**

**4. README 命令表加一行。**

**5. 构建 + 同步镜像。**

### 规范要点

| 项 | 规范 |
|----|------|
| 命令格式 | `!命令名 [参数]`，统一 `!` 前缀、小写 |
| 参数截取 | `substringFromIndex:` = `!`+命令名+空格。如 `!hello` 是 6 字符 → `:7` |
| 缺参提示 | `用法: !命令 <参数>，如 !命令 示例` |
| 私有 API | 用 `valueForKey:`（KVC）访问，避免编译期依赖私有头 |
| 崩溃保护 | 私有对象访问用 `@try/@catch` 包住 |
| 响应 | 统一 `tan_sendRsp(fd, 结果)` 后 `return` |
| 认证 | 客户端发 `AUTH <token> <命令>`，`tan_authParse` 去前缀，`tan_eval` 收纯命令 |
| 编译 | 控制台代码在 `#ifdef DEBUG` 块内 |

### 关键细节

- `performSelector` 有 ARC 警告：用 `#pragma clang diagnostic ignored "-Warc-performSelector-leaks"` 或 KVC。
- 大输出 `tan_sendRsp` 已循环写完整，不怕长结果。
- 现有命令实现是最好参考：`!class`（参数解析）、`!inheritance`（KVC 链）、`!bundle`（私有类+performSelector）。

## 安全模式（禁用全部插件）

`!safe` 与设置页「进入安全模式」开关做的是同一件事：往 mobile 可写的位置写一个标记文件，再重启相关进程。
机制与取舍（2026-10-06 真机单变量对照实测）：

| 环节 | 做法 | 说明 |
| --- | --- | --- |
| 注入器检查的路径 | `<jbroot>/basebin/.safe_mode` | `postinst` 把它做成软链；实测注入器**跟随软链**（悬空软链 ⇒ 不算存在，仍正常注入）；该目录 `root:wheel 0755`，mobile **写不了** |
| ★ 真正决定生死的文件 | **`<jbroot>/var/mobile/.eksafemode`** | 注入器解析软链时用的是 **jbroot 侧** 的 `/var/mobile` ⇒ 实际路径 = `/private/var/mobile/Containers/Shared/AppGroup/.jbroot-XXXX/var/mobile/.eksafemode` |
| 为什么不能写真实 `/var/mobile/.eksafemode` | 写了**无效** | 实测写它 + respring ⇒ 新 SpringBoard 仍 47 个 tweak（`<jbroot>/var/mobile` 与真实 `/var/mobile` 是不同 inode 的两个目录） |
| 谁写标记 | SpringBoard（mobile 501）`fopen(...,"w")` / `unlink` | `<jbroot>/var/mobile` 是 `mobile:mobile 0755` ⇒ 控制台命令与设置页开关跑在 SpringBoard 里即可，**不需要 root 组件** |
| 生效时机 | 进程**启动时**判断一次 | 已在运行的进程不受影响 ⇒ 必须重启才生效 |
| 生效范围 | 只影响新启动的进程 | 只 respring ⇒ 只有 SpringBoard 干净；`!safe on all`（`jbctl reboot_userspace`）⇒ 整个用户空间干净 |
| 进入方式 | `kill(SpringBoard, SIGKILL)` | **不能用 SIGTERM / sbreload**：安全模式处理器会接住正常退出信号并删掉标记 |

真机对照（探针统计新进程里的 `TweakInject/*.dylib` 数量）：

| 标记状态 | 新进程 tweakinject | 结论 |
| --- | --- | --- |
| 不存在 | 2（Choicy、Crane） | 正常注入 |
| 普通文件 | 0 | 安全模式生效 |
| 悬空软链 | 2 | 检查跟随软链，悬空不算存在 |
| 软链 + 目标文件（由 SpringBoard 创建） | 0 | mobile 一人即可开关 |
| 目标文件被 SpringBoard 删除 | 2 | 恢复注入 |
| 标记写在**真实** `/var/mobile/.eksafemode` | 47 | **无效**：注入器不看这个文件（`!safe on` 早期版本踩过的坑） |
| 标记写在 **`<jbroot>/var/mobile/.eksafemode`** | **0** | ★ 端到端验证通过（插件自己写 + respring ⇒ 新 SpringBoard 0 个 tweak） |

端到端实测（2026-10-06，本机 roothide 真机）：

- `!safe on`（控制台，令牌 = 自己在设置里设的那个）⇒ 标记由 SpringBoard 自己写入（内容 `[…] ODebug 安全模式标记`），SpringBoard 31678 → 31739，`tweakCount 47 → 0`；删标记 + respring ⇒ `tweakCount 47` 恢复。
- `!safe on all` ⇒ 标记 + `launchctl reboot userspace`，**19 秒**后设备回来且标记保留；新建进程 `TweakInject = []`，守护进程 `locationd / runningboardd / gpsd` 全部 `[]` ⇒ **整个用户空间干净**；exit 后 SpringBoard 恢复 47 个 tweak（已在跑的守护进程要等各自 respawn 才恢复注入）。

⚠️ 安全模式下本插件（tweak）也不注入，TCP 控制台（4321）**直接不可用** —— 这是安全模式的**定义**（所有 tweak 都不注入）：没有 `ODebug.dylib` 就没有 4321 控制台。
`frida` 在安全模式里之所以能用，是因为 `frida-server` 是 **LaunchDaemon**（root、非 tweak），从进程外注入。

> ★ **2026-10-07 更新：这个限制已经被 `odebugd` 从根上解掉了**（见下节）。
>   `odebugd` 同样是 LaunchDaemon（安全模式照旧运行），它会把 `ODebug.dylib` 从**进程外**
>   注入正在运行的 SpringBoard ⇒ **不需要 respring，4321 控制台自己就回来了**。
>   电脑侧脚本走 frida 通道（上表的通道 B）仍然保留，用来处理「连 odebugd 都不在」的极端情况。

`odebug.sh` 的 `m` 做了**双通道自动切换**（`safemode_do` / `console_alive`）：

| 通道 | 何时用 | 实际动作 |
| --- | --- | --- |
| A 插件控制台 | 控制台还在应答（正常模式） | `!safe on` / `on all` / `off` / `respring` / `status` |
| B 电脑侧 frida | 控制台不可达（已在安全模式 / SpringBoard 刚崩） | `tools/safemode_frida.py enter` / `enter-ureboot` / `exit` / `status` |

- 进入：`m` → `on`（回车也行）⇒ 写标记 + SIGKILL SpringBoard，约 15 秒后新 SB `tweakCount 0`；
- 退出：`m` → `off` ⇒ 控制台已死 ⇒ 自动 `frida exit`：**先删标记、再** SIGTERM SpringBoard ⇒ `tweakCount 47` 恢复；
- frida 解释器查找顺序：`$ODEBUG_FRIDA_PY` → `~/.frida-env/bin/python3` → `python3`；工具路径可用 `$ODEBUG_SAFEMODE_TOOL` 覆盖；
- 另一个常见坑：有些终端启动器会把子进程 **stderr 丢给 /dev/null**，而 bash 的 `read -p` 提示符正是写 stderr 的 ⇒ 看起来「卡住、没有提示」。本脚本已把提示改为 `printf`（stdout）+ `exec 2>&1`。

其它退出通道（不依赖电脑，都是非 tweak 通道）：

1. 设备内 SSH：`iproxy 2222 22` 后 `ssh -p 2222 root@127.0.0.1`（`com.openssh.sshd` 是 LaunchDaemon，安全模式照旧活着）；
2. Filza / DFTerminal：删掉 `<jbroot>/var/mobile/.eksafemode`（Filza 里通常显示为 `/var/mobile/Containers/Shared/AppGroup/.jbroot-XXXX/var/mobile/.eksafemode`）后 `sbreload`；
3. 正常模式下取消：设置页关掉「进入安全模式」开关（安全模式里设置页打不开）。

安全模式下的端到端实测（2026-10-06 真机，就用 `odebug.sh` 自己走两个通道）：

- `m` → `on` ⇒ `✅ 标记已写入 …/var/mobile/.eksafemode` ⇒ 复查 SpringBoard `32575`：`TweakInject {'n': 0, 'hasODebug': False}`；
- 安全模式里 `m` → `off` ⇒ `ℹ️ 控制台不可达 → 用 frida 通道删标记并重启 SpringBoard` ⇒ `unlinked_flag: 0`、`killed: 15` ⇒ SpringBoard `32603`：`{'n': 47, 'hasODebug': True}` ✅

卸载行为：`layout/DEBIAN/postrm` 会删掉软链与标记文件，避免卸载后设备仍停在安全模式。

---

## odebugd：常驻调试服务（安全模式下也不失联）

`odebugd` 是**独立于 tweak 的 LaunchDaemon**（`/usr/bin/odebugd`，root，只绑 `127.0.0.1:4322`）。
安全模式只拦 tweak，拦不住 LaunchDaemon ⇒ **安全模式下 4321 死了、4322 还活着**，
于是它既是应急调试通道，又是把 4321 救回来的注入器。

| 文件 | 作用 |
|------|------|
| `odebugd.m` | 服务本体：命令解析 + 进程外注入器（约 1500 行，单文件） |
| `layout/Library/LaunchDaemons/com.tanyou.odebugd.plist` | LaunchDaemon（`RunAtLoad` + `KeepAlive`、`UserName root`、`ExecuteAllowed`） |
| `layout/usr/share/odebugd/odebugd.ent` | 权限文件：从真机 `/usr/sbin/frida-server.ent` 里挑的最小集合（`platform-application`、`task_for_pid-allow`、`dynamic-codesigning`、`run-unsigned-code`、`com.apple.private.cs.debugger` 等，缺了它 daemon 会被沙盒关住 ⇒ `sysctl` 失败、`task_for_pid` 全挂） |
| `layout/DEBIAN/postinst` | 装完用**设备自带** `<jbroot>/usr/bin/ldid -S<x>.ent` 重签 `odebugd`，再 `launchctl load -w` |
| `layout/DEBIAN/postrm` | `launchctl unload -w` + 删安全模式标记（避免卸载后设备停在安全模式） |

令牌复用插件那套：依次读 `<jbroot>/Library/MobileSubstrate/DynamicLibraries/ODebug.plist` →
`com.tanyou.opendebug.settings.plist` 的 `debugAuthToken`（部署时在设置里自己设），最后兜底环境变量 `ODEBUG_TOKEN`。

电脑侧连接（仓库自带 `odebug.sh` 傻瓜脚本，或手动转发端口后直接对话）：

```bash
./odebug-iproxy.sh                       # 等价于 iproxy 4321 4321（4322 是 odebugd 的端口）
python3 -c "import socket;s=socket.create_connection(('127.0.0.1',4321));print(s.recv(200))"
# 或用 netcat： nc 127.0.0.1 4321
# 注入类命令耗时长（等用户态窗口可能要几分钟），客户端读超时务必开大
```

### 命令

| 命令 | 作用 |
|------|------|
| `!auto status \| on \| off \| run` | **安全模式自动兜底**（默认开）：把 `ODebug.dylib` 自动注入 SpringBoard |
| `!inject <pid\|springboard> [dylib]` | 手动注入（默认 `ODebug.dylib`；会先探依赖，必要时先注 `libellekit`） |
| `!safe status \| on \| on all \| off \| respring` | 安全模式开关（与插件侧同语义） |
| `!ps [过滤]` / `!ls <路径>` / `!cat <路径>` / `!plist read <路径>` | 进程与文件（`!ps` 是安全模式下唯一能看进程列表的途径：`/bin/ps` 在设备上不可用） |
| `!imgs <pid> [过滤]` / `!sym <pid> <镜像> <符号>` | 列目标进程镜像 / 调 `dlsym` 解析远端符号 |
| `!tp <pid>` | 可行性探针：`task_for_pid` + 远端 `mach_vm_allocate/protect/write` + `task_threads` |
| `!win <pid\|springboard> [秒]` | 只读采样目标有没有「用户态运行窗口」（注入的前提），给窗口率 |
| `!hj <pid> write [文本]` / `!hj <pid> open <路径>` | 单步验证：劫持一个线程调 `write` / `dlopen` |
| `!exec <pid> [code\|nop\|clone\|raw\|lib]` | 远端线程状态实验台（验证 PAC 约定、匿名页取指等） |
| `!spawn <路径> [参数]` | 起一次性进程（注入靶子） |
| `!sys` / `!log [n]` / `!exit` | 系统信息 / 自己的日志 / 断开 |

### 自动兜底是怎么工作的

SpringBoard 若在**安全模式开启时**启动，tweak 加载器就没跑 ⇒ `ODebug.dylib` 不在 SB 里 ⇒
4321 控制台是死的，而且它**没法自救**（自己根本没被加载）。这正是 odebugd 要补的洞：

```
① 看门狗线程每 5 秒：取 SpringBoard pid → 读它的镜像表，有没有 ODebug.dylib？
② 没有 ⇒ 走注入路径（与 !inject springboard 同一份代码，互斥锁串行化）
③ 注入成功 ⇒ SB 里出现 ODebug.dylib ⇒ 插件 constructor 跑起来 ⇒ 4321 当场复活
④ 兜底保护：若「注入后 90 秒内 SB 又换了新 pid」连续发生 2 次 ⇒ 自动兜底自我停用
   （避免 ODebug 本身把 SB 搞崩时反复把 SB 拖回崩溃循环），`!auto on` 可重新开启
```

真机实测（2026-10-07，`!safe on` 触发场景）：

```
18:52:13 [watchdog] SpringBoard(42032) 里没有 ODebug.dylib（多半是安全模式启动的）⇒ 自动兜底注入
18:52:13 ★ 第 0 轮抓到用户态线程 0/18
18:52:13 等待轮数=0，注入成功 ✅
18:52:13 [watchdog] ✅ ODebug.dylib 已进入 SpringBoard(42032)，插件内 4321 控制台应该回来了（无需 respring）
```

- 新 SB 刚起来时**用户态线程多**，窗口第 0 轮就抓到 ⇒ 注入几乎瞬时；
- SB 完全空闲时窗口率只有约 2%（`!win` 实测：5 秒 50 次采样只抓到 1 次）⇒ 那时手动 `!inject` 可能要等 70~180 秒；
- **只把 ODebug 注回去，其它 tweak 仍然不注入** —— 安全模式的语义不变，救回来的只有调试控制台。

### 「所有插件禁止注入」时还能用吗 —— 能，已实测

安全模式（标记 `<jbroot>/var/mobile/.eksafemode` 存在）本身就是「**所有插件禁止注入**」：
新起的进程里一个 tweak 都不加载。这个状态对 odebugd 毫无影响，而且正是它存在的意义。

| 状态 | SpringBoard 镜像数 | 里面的 tweak | 4321 控制台 |
|------|------------------|-------------|------------|
| 正常模式 | 1376 | 47 个（含 ODebug） | ✅ |
| 安全模式（不干预） | 1266 | **0 个** | ❌ 死 |
| 安全模式 + 自动兜底 | 1267 | **只有 ODebug** | ✅ 当场复活 |

关键是注入器**从进程外往 SpringBoard 里造一条正规 pthread，再让这条线程去 `dlopen`**
（走 Apple 私有 SPI `pthread_create_from_mach_thread`，链路见下面「frida 式注入器」一节）⇒
它绕过了加载器那层封锁：只放行你指定的那一个 dylib，其它插件依旧一个都不注入
（标记还在 ⇒ 安全模式语义不变）。所以「所有插件禁止注入」不但能用，还可以长期这么跑：
odebugd + ODebug 控制台照常，其它插件全灭。

> **1.0.141 真机端到端实测（2026-10-05）**：`!safe on` ⇒ 标记写入 + SpringBoard 被 SIGKILL ⇒ 新 SpringBoard
> 进安全模式（`!safe status` 报 `当前: 存在 ⇒ 安全模式(新进程不注入 tweak)`，里面一个 tweak 都没有）。
> 5 秒内看门狗自动兜底 ⇒ `!auto status`：`SpringBoard pid=47670，ODebug.dylib 已在镜像表里 ✅`；
> **`iproxy 4321 4321` 当场就连上并收到 `ODebug 调试控制台` 横幅**（无需 respring、无需人工干预）。
> 随后 `!safe off` ⇒ 标记移除、SpringBoard(47730) 由越狱自己注入 ODebug ⇒ 一切照旧。

> 4321 的 `!safe status` 会照实说明这一点（早期版本拿「我能应答 ⇒ 不是安全模式」反推，会误报）：
> ```
>   当前: 存在 ⇒ 新进程进入安全模式
>   说明: 标记**存在**，本控制台却活着 ⇒ 本进程是被 odebugd 注入器强行注入回来的
>         （安全模式仍然生效：其它插件一律不注入。要真正退出：!safe off + !safe respring）
> ```

⚠️ 唯一做不到的情况：**重启后还没启用越狱**（roothide 环境未加载）——那时 launchd 是原生的，
jbroot 里的 odebugd 根本不会启动。只要能 `dpkg`/ssh 操作到 jbroot，它就在。

### 重启用户空间（ureboot）也照样用 —— 已实测

`!safe on all` 走的是 `launchctl reboot userspace`：**launchd 连同所有 LaunchDaemon 一起重启**，
所以 odebugd 自己也会死一次，然后由 jbroot 的 launchd 拉起来（新 pid），起来后看门狗照旧干活。

```
19:16:04 !safe on all ⇒ 已启动 launchctl reboot userspace (rc=0, pid=43407)，标记保留
19:16:27 [43506] [watchdog] SpringBoard(43421) 里没有 ODebug.dylib（多半是安全模式启动的）⇒ 自动兜底注入
19:16:27 [43506] [watchdog] ✅ ODebug.dylib 已进入 SpringBoard(43421)，插件内 4321 控制台应该回来了（无需 respring）
```

实测（2026-10-05）：ureboot 后 odebugd pid `43059 → 43506`（launchd 自动拉起）、标记仍在、
SpringBoard 1225 个镜像里**只有 ODebug 一个 tweak**、4321 控制台照常应答。
整个 ureboot 期间不需要任何人工干预，也不需要 respring。

> 1.0.120 顺手修掉一个会「把人弹出安全模式」的坑：`postrm` 以前没判断 dpkg 参数，
> 而 dpkg 升级时会先调用**旧包**的 `postrm upgrade` ⇒ 每次装新版都顺手删掉安全模式标记。
> 现在只在 `remove|purge|disappear` 时清理。

### frida 式注入器（1.0.121 起，1.0.141 定型）

对照 frida-core 的 `frida-helper-backend-glue.m` 逐行复刻，链路是：

1. 在目标里各分配一页：**代码页**（写完再 `mach_vm_protect(R\|X)`）与**数据页**（路径字符串 + 各槽位）；
2. `thread_create` + `thread_set_state`（PC=代码页入口、LR=`pause`、SP=自己分配的一页栈）起一条**裸 mach 线程**；
   PC/LR 必须按「签名形态」交给内核（见下表 PAC 那条）；
3. 裸线程第一件事写 canary（`0x0DB60001` 写进数据页）⇒ 用它区分「代码页压根没执行」与「dlopen 失败」；
   接着 `pthread_create_from_mach_thread(&slot, NULL, paciza(routine), data)`，然后自己在 `pause()` 里死循环停车；
4. routine（跑在**正规 pthread** 上）`dlopen(path, RTLD_NOW|RTLD_GLOBAL)` ⇒ 返回值 + 完成标记 `0xC0FFEE` 写回数据页 ⇒ `pthread_exit`；
5. daemon 轮询数据页与目标镜像表：canary ✓ 且镜像出现 ⇒ 成功（`!fd` 还会把 `dlopen` 句柄读回来给人看）。

> **为什么不能图省事直接在裸线程上 `pthread_create`**：真机实测那样会把**整个目标进程**搞死
> （`pthread_t` 槽一直是 0、进程 1 秒内从进程表消失）。frida 同样优先用 `pthread_create_from_mach_thread`
> （Apple 私有 SPI，能从裸线程安全地建 pthread），`pthread_create` 只是它的退路。
> 另外注意 frida 的参数约定是 4 个：`x0=&slot`、`x1=NULL`、`x2=paciza(routine)`、`x3=arg`。

### 进程外注入器的硬约束（都是真机踩出来的）

| 约束 | 现象 / 做法 |
|------|------|
| **PAC：PC/SP/LR 必须按「签名形态」交给内核** | 只能用 SDK 访问器 `__darwin_arm_thread_state64_set_pc_fptr()` / `_set_lr_fptr()`（内部 `ptrauth_auth_and_resign` 并清 `KERNEL_SIGNED_PC`）。把 `thread_get_state` 读回来的原始 `__opaque_pc` 再喂给 `ptrauth_sign_unauthenticated` ⇒ 鉴别符不匹配 ⇒ 命中 **auth 陷阱 `brk #0xc470`（SIGBUS）把 odebugd 自己打死** |
| **剥离 PAC 用 47 位掩码** | `v & 0x00007FFFFFFFFFFF`；掩 48 位会把用户态最高位 VA 当成保留位，解析出垃圾地址 |
| **匿名 R\|X 页取指没问题（旧结论已推翻）** | 1.0.125 用 `!rx <pid> target` 实测：目标里 `mach_vm_allocate` + 写码 + `mach_vm_protect(R\|X)`，裸线程一跑 **100 ms 内 canary 就出现、目标存活** ⇒ 匿名可执行页可以取指。早期「一取指就被杀」的真因是 stub 里那个 `pthread_create`，以及「spawn 完立刻注入撞上 dyld 镜像表还没就绪」 |
| **阻塞在 syscall 里的线程改 PC 无效** | 内核按 syscall 返回路径走、忽略 pcb 里的 PC；`thread_abort` 也救不了 ⇒ 旧劫持法**必须等「用户态窗口」**（`TH_STATE_RUNNING` 且 PC 不在 `libsystem_kernel` 的 syscall 桩附近）。frida 式的**新建线程**不走这条：它的 PC 是我们自己设定的，随时能起 |
| **被劫持线程要「停车」而不是返回** | LR 设成远端 `pause`：线程跑完 `dlopen` 停在那里不返回原处（返回会破坏原调用栈），宿主读 x0 拿返回值后再把原状态写回 |
| **不能在注入线程上调 `dlerror()`** | 1.0.137/1.0.139 两次真机教训：canary 已写、目标 5 秒内换 pid ⇒ `dlerror` 依赖 dyld 自己的**每线程**错误状态，而这条线程不是 dyld 初始化出来的（地址校验是通过的，所以不是偏移问题）⇒ 注入流程彻底不碰 `dlerror`，失败只看 `dlopen` 返回值 + 镜像表 |
| **dylib 路径要用越狱真正注入用的那条** | roothide 实际注入的是 `<jbroot>/usr/lib/TweakInject/ODebug.dylib`（真机 `!fd` 用这个路径把镜像载进了越狱进程且目标存活）⇒ 兜底路径优先取它，旧的 `<jbroot>/Library/MobileSubstrate/DynamicLibraries/ODebug.dylib` 作后备 |
| **spawn 完要等约 2 秒再注入** | 目标刚 resume 时 dyld 镜像表可能还没就绪 ⇒ `remoteImages` 返回 0 张 ⇒ 符号全解析成 0 ⇒ stub 里 `blr 0` 当场把目标打死（这是早期 `fdbug`/`payload` 模式「秒死」的真正原因，不是布局问题） |
| **daemon 侧读「带 PAC 的指针」必须走 `vmRead`** | 1.0.138 的字节校验直接 `memcpy` 解引用 `dlsym` 返回的指针 ⇒ arm64e 上带签名位 ⇒ daemon **SIGSEGV 每 5 秒崩溃重启循环**（日志回溯直指 `odbgSymbolBytesMatch`）⇒ 改成 `vmRead(mach_task_self(), stripPAC(addr), …)` 两侧都走 `vmRead` |
| **不要对目标里我们新建的线程调 `thread_terminate`** | 真机实测：`thread_terminate` 会让 **odebugd 自己被内核当场杀掉**（多半 EXC_GUARD）⇒ 线程就让它停在目标的 `pause` 里，随目标进程消失 |
| **依赖符号** | `ODebug.dylib` 只需要 `MSHookMessageEx`；roothide 每个进程（含安全模式下的 SB）都带 `basebin/fallback/CydiaSubstrate` ⇒ 通常无需预加载，探不到才先注 `libellekit` |

### 构建与安装（开发循环）

```bash
cd OpenDebug
THEOS=/opt/theos gmake package FINALPACKAGE=0 DEBUG=1     # 调试包：packages/com.tanyou.odebug_<版本>-N+debug_iphoneos-arm64e.deb
THEOS=/opt/theos gmake package FINALPACKAGE=1             # 正式包：packages/com.tanyou.odebug_<版本>_iphoneos-arm64e.deb
```

装到设备（任选）：

```bash
# 1) 传统方式：把 deb 拷进设备再 dpkg
scp -P 2222 <deb> mobile@127.0.0.1:/tmp/install.deb
ssh -p 2222 mobile@127.0.0.1 'sudo dpkg -i /tmp/install.deb'
# 2) 直接用 Sileo / Filza 打开 deb 安装
```

> 设备日志在 `<jbroot>/var/log/odebugd.log`，`odebugd.out` / `odebugd.err` 是同目录下的 stdout/stderr。
> `applog` 每次 `fopen/fputs/fclose`、不缓冲 ⇒ 崩溃时日志最后一行就是崩溃点。
> `postinst` 会用设备自带的 `<jbroot>/usr/bin/ldid` 按 `odebugd.ent` 重签 daemon。

### 已知限制

1. **1.0.141 起不再依赖「用户态窗口」**（frida 式新建线程，PC 由我们设定）⇒ 屏幕熄灭、SpringBoard 全空闲也能注入；实测安全模式下 SB 重启后 5 秒内就注完了。
2. **注入后 SB 里只有 ODebug**：其它 tweak 要 `!safe off` + `!safe respring` 才回来。
3. 设备上**没有 `pkill`**（`/usr/bin/sh: 1: pkill: not found`），清理测试用的一次性进程要用别的手段。

---

## 注意事项 / 已知限制

1. **改注入目标后需重启目标 App**：loader 只在进程启动时读 Filter，运行中的 App 不会动态注入。
2. **改调试令牌需重启 SpringBoard**：控制台在 SpringBoard 进程，token 读取有 `dispatch_once` 缓存。
3. **控制台只绑定 `127.0.0.1`**：电脑连接需 `iproxy`，或直接用设备 SSH。
4. **`!vcapp` / `!vcapp top` 是广播**：所有被注入的目标 App 都会响应 dump，日志里按 bundleId 区分。
5. **roothide 专属**：依赖 `jbroot()` 路径解析与 roothide loader 的 Filter 行为。
6. **`!vc top` 的"最上层"是近似**：沿 presented/容器链走到不能再走为止，对 tab 控制器取
   `selectedViewController`、导航栈取 `topViewController`，一般能到当前显示页面。

---

## 常见问题

**Q: 设置里选完 App，`!vcapp` 没反应？**
A: 三步检查——① 设置保存后 `Filter` 是否包含该 App（`plutil -convert xml1 ...settings.plist`）；
② 是否**重启了目标 App**；③ `idevicesyslog | grep "\[ODebug\] ctor"` 是否出现 `proc=该App isTarget=1`。

**Q: SpringBoard 都看不到 `[ODebug] ctor`？**
A: 检查 `ODebug.plist` 是否还是软链（`ls -la .../ODebug.plist`，应为 `-> .../com.tanyou.opendebug.settings.plist`）。
重装一次即可（postinst 会重建软链）。

**Q: `nc` 连不上？**
A: 确认控制台日志 `[TANConsole] ✅ 已启动 (端口4321)`；控制台只绑设备回环，用设备 SSH 连；
若设备没 `nc`，用 `bash -c 'exec 3<>/dev/tcp/127.0.0.1/4321; ...'`。

**Q: `!vc top` 返回旧版 `keyWindow:` 而不是 `Top:`？**
A: 控制台还是旧代码，重启 SpringBoard 让新 dylib 生效（`killall -9 SpringBoard`），或重装。

认证失败 (未认证: 请发送 AUTH ...)

原因：本地缓存的 Token 与手机端不一致。

解决：运行 rm ~/.odebug_token，然后重新启动 ./odebug.sh 抓取最新 Token，或前往手机设置里手动输入。
