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
| `!safe off` | 先删掉安全模式标记，再强制结束 SpringBoard（退出安全模式） |
| `!safe off all` | 先确认安全模式标记删除成功，再重启整个用户空间 |
| `!safe respring` | 只重启 SpringBoard |
| `!safe status` | 查安全模式状态（标记 / 软链 / 退出办法） |
| `!ureboot confirm` | 重启用户空间；不修改安全模式标记，也不重启整机 |

4322 守护进程菜单中，`o` 会进入安全模式并重启用户空间；`m` 会打开安全模式向导：

```text
1  进入安全模式（只重启 SpringBoard）
2  进入安全模式并重启整个用户空间
3  退出安全模式（只重启 SpringBoard）
4  退出安全模式并重启整个用户空间
5  只重启 SpringBoard（不修改安全模式标记）
s  查看状态
```

4322 主菜单按 `b` 也可以直接重启 SpringBoard，执行前会再次确认；该操作不会修改安全模式标记，也不会重启整机或用户空间。
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

`odebugd` 是**独立于 tweak 的 LaunchDaemon**（`/usr/bin/odebugd`，root）。
安全模式只拦 tweak，拦不住 LaunchDaemon ⇒ **安全模式下 4321 死了、4322 还活着**，
于是它既是应急调试通道，又是把 4321 救回来的注入器。

### WLAN 直连模式（1.0.142 起，1.0.143 收进设置页）

- **设置页「WLAN 直连」开关（1.0.143）**：一个开关统管 4321+4322（偏好 `debugBindAll`）。4321 改后需 respring；4322 重启后生效（`!restart` 或重启手机）。打开 ⇒ 同网段电脑**免数据线直连 `手机IP:4321/:4322`**，token 鉴权照旧；`!net` 随时查当前绑定与手机各网卡 IP。
- 显式覆盖（优先于设置页）：`ODEBUGD_BIND` 环境变量 / `--bind` 参数（`0.0.0.0`/`lan`/`any` 开，`127.0.0.1` 关）。
- 自给自足命令：`!putb <路径> <base64>`（分段上传）+ `!pute <路径>`（收尾 chmod）、`!dpkg <deb>`（用 jbroot 的 dpkg 装包）、`!restart`（自杀，launchd 拉起新版）⇒ **纯 Wi-Fi 即可传包/升级自己**。
  - ⚠️ roothide 路径戏法：daemon 视角的 `/tmp` 实际落在真实 `/rootfs/private/var/tmp` ⇒ `!dpkg` 要用 `/rootfs/private/var/tmp/xxx.deb` 这个 dpkg 子进程视角的路径（真机踩过：daemon 视角路径 dpkg 报 ENOENT）。
- Mac 侧：`odebug_console.py --host <手机IP> --port 4322 --token ty '<命令>'`（`--host` 时不起 iproxy）。
- 备选通道：SSH（如有）`ssh -L 4322:127.0.0.1:4322` 隧道照样可用。
- 🔐 安全提示：开 LAN 监听后凭 token 一层鉴权，仅建议在**可信家庭网段**开启；改回 `127.0.0.1` 后 `!restart` 即恢复仅本机。


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
| `!safe status \| on \| on all \| off \| off all \| respring` | 安全模式开关；`off all` 先删标记、确认成功后重启用户空间 |
| `!ureboot confirm` | 只执行 `launchctl reboot userspace`；所有 App 和用户级进程会结束，但 BootSessionID 应保持不变 |
| `!layout status` | 定位 SpringBoard 实际使用的 `RecentAppLayouts.pb.lzfse`、`RecentAppLayouts.pb`、`SBRecentAppLayouts.plist` |
| `!layout clean` | 把找到的布局缓存逐项改名为同目录 `.rescue-backup-yyyyMMdd-HHmmss`；全部移动和校验成功后，仅执行 `launchctl reboot userspace` |
| `!re module [pid\|springboard] [过滤]` | 复刻模块取证；4321 查当前已注入进程，4322 可跨进程检查 SpringBoard/App |
| `!re classes [过滤]` / `!re class <类名>` | 当前进程 Objective-C 类和类结构 |
| `!re ivars <地址> [all]` / `!re vc [top]` | 对象 ivar 与进程内视图层级 |
| `!re selector [-|+] <对象\|类> <selector>` | 只读 selector 的 owner、IMP、类型编码，不调用方法；类名目标默认实例优先再回退类方法，`-` 强制实例方法、`+` 强制类方法，并输出 `requestedKind` / `methodKind` |
| `!re invoke0 <对象\|类> <selector>` | 调用无参数 BOOL getter，并明确输出 `boolValue=0/1`；其他返回类型拒绝调用 |
| `!re snapshot <对象> <ivar>` | 只读单 ivar 的类型、偏移、原始字节和对象值 |
| `!re addr <模块> <0x地址\|+0x偏移>` | strip PAC 后换算模块基址、运行时地址和 IDA 偏移 |
| `!re ui [过滤] [--depth N] [--max N] [--compact] [--no-constraints]` | 输出可限制深度、节点数和约束的结构化 UIKit JSON；合并 scene windows 与 `UIApplication.windows`，按对象身份去重以纳入独立 overlay 窗口 |
| `!re frida <模块> <偏移> <selector>` | 按 IDA 偏移生成待审阅的 Frida Interceptor 脚本 |
| `!re hook\|intercept <类> <selector>` | 通过 `MSHookMessageEx` 安装签名白名单内的 log-only hook |
| `!re trace add\|list\|log\|remove\|clear` | 管理调用跟踪；`--ttl` 的绝对过期时间会跨 SpringBoard/用户空间重启保存 |
| `!re mem read\|patch\|patches\|undo` | 带映射检查的读取、可逆单字节补丁和旧值账本 |
| `!re evidence begin\|input\|status\|end\|stat\|read` | 记录场景，并支持分块读取超过 512 KB 的 JSON |
| `!re evidence crash [数量]` | 关联最近 SpringBoard/Jetsam/backboardd 崩溃及布局、TweakInject 特征 |
| `!replica status\|begin\|quarantine\|rollback` | 复刻文件快照、可逆隔离和恢复 |
| `!rescue diagnose\|plan\|apply` | 白屏/白苹果诊断、一次性计划和用户空间救援 |
| `!ps [过滤]` / `!ls <路径>` / `!cat <路径>` / `!plist read <路径>` | 进程与文件（`!ps` 是安全模式下唯一能看进程列表的途径：`/bin/ps` 在设备上不可用） |
| `!imgs <pid> [过滤]` / `!sym <pid> <镜像> <符号>` | 列目标进程镜像 / 调 `dlsym` 解析远端符号 |
| `!tp <pid>` | 可行性探针：`task_for_pid` + 远端 `mach_vm_allocate/protect/write` + `task_threads` |
| `!win <pid\|springboard> [秒]` | 只读采样目标有没有「用户态运行窗口」（注入的前提），给窗口率 |
| `!hj <pid> write [文本]` / `!hj <pid> open <路径>` | 单步验证：劫持一个线程调 `write` / `dlopen` |
| `!exec <pid> [code\|nop\|clone\|raw\|lib]` | 远端线程状态实验台（验证 PAC 约定、匿名页取指等） |
| `!spawn <路径> [参数]` | 起一次性进程（注入靶子） |
| `!run [--timeout <秒>] <路径> [参数]` | 前台执行并捕获 stdout、stderr 与退出码（默认 20 秒，上限 120 秒） |
| `!sys` / `!log [n]` / `!exit` | 系统信息 / 自己的日志 / 断开 |

`!layout clean` 不会删除布局文件，也不会改 `IconState.plist` 或安全模式标记。它先排除 `/var`、`/private/var`、`/rootfs` 与当前 jbroot 路径视图指向的同一 inode，再尝试时间戳改名；已有同名备份时自动追加 `-2`、`-3`。只要任一目标移动或校验失败，本次已经移动的文件会按相反顺序回滚，并且不会重启用户空间。所有文件都成功备份后才调用 `launchctl reboot userspace`，绝不调用整机 `reboot`、`shutdown` 或结束 SpringBoard。4322 菜单中按 `z` 可直接进入该功能，选择 `clean` 时需要再次确认。`!layout status`、`!layout clean` 和 `!sys` 都会显示 `BootSessionID`；正常重启用户空间后该值保持不变，如果变化则说明整机启动链发生了变化。

`!re` 的基础取证命令在目标进程内直接读取 Objective-C runtime、dyld 和视图树；4322 的 `!re module` 通过 `task_for_pid` 只读取远端镜像表。`selector` 和 `snapshot` 不会调用 selector、修改内存或安装 hook。证据会话最多保留 4 MiB，单条记录最多 1 MiB，超出后会明确标记截断。

`!re hook`、`!re intercept`、`!re trace` 和 `!re mem patch` 会改变目标进程状态，属于高风险操作。hook 沿用 `TANHookConsole` 的 ARM64 ABI 签名白名单和纯 C 日志路径，不认识的签名会拒绝安装。调用日志包含全局 `seq`、线程标识、参数、double 和返回值。`!re mem patch` 只写一个字节，并且先检查地址是否映射、只读页能否 `vm_protect`；每次写入都会保存旧值到进程内账本。

地址换算示例：

```text
!re addr TrollOpenRe.dylib 0x10449a204
!re addr TrollOpenRe.dylib +0x9a204
```

输出同时包含 `loadAddress`、`canonicalImplementation`、`runtimeAddress` 和 `idaOffset`。`!re selector` 现在也会自动附带 IMP 对应的 `loadAddress` 与 `idaOffset`。同名 selector 同时存在于实例和类方法面时，可显式查询：

```text
!re selector -NSObject description
!re selector +NSObject description
```

结构化 UI 示例：

```text
!re ui
!re ui RBDynamicIsland
!re ui RBDynamicIsland --depth 12 --max 400 --compact --no-constraints
```

输出为 `odebug-re-ui-v1` JSON，包含 UIView 类、地址、frame、bounds、hidden、alpha、背景色、layer 圆角/边框、label 字体和颜色、image 尺寸、view controller、subviews 顺序以及 Auto Layout constraints。

过滤模式会包含匹配节点及其完整子树。`--compact` 去除缩进、对象地址和冗余默认字段；`--no-constraints` 移除约束数组；`--depth` 和 `--max` 分别限制深度与输出节点数。JSON 同时返回 `visitedCount` 和 `truncated`，用于判断结果是否完整。

Frida 模板生成示例：

```text
!re frida TrollOpenRe.dylib 0x9a204 -[TOJBClass001 method:]
```

生成的脚本只作为文件内容返回，不会自动执行。它使用 `Module.getBaseAddress` 和 `Interceptor.attach`，并附带 enter/leave 及全局 sequence。

### 原版/复刻版差分采集

原版和复刻版必须分别加载、分别采集，第一次不要同时启用，避免两套 hook 相互覆盖。每次使用相同的场景名、输入和命令顺序：

```text
!re evidence begin notification-card
!re evidence input title=Message
!re evidence input message=Body
!re evidence input icon=AppIcon
!re evidence input appName=Demo
!re module TrollOpen
!re vc top
!re selector 0x对象地址 preferredEdgeOutsetsForLayoutMode:
!re snapshot 0x对象地址 layoutMode
!re evidence end
```

`end` 会返回类似 `/var/mobile/Library/Preferences/ODebugRE/20261121-...-notification-card.json` 的证据文件。用 `!cat <路径>` 取出 JSON，分别保存为 `original.json` 和 `replica.json`。

大型 evidence 使用分块读取：

```text
!re evidence stat
!re evidence read 0x0 262144
!re evidence read 0x40000 262144
```

`read` 返回一行 JSON，`data` 为 base64，并包含 `offset`、`length`、`size` 和 `eof`。场景执行器会自动使用此协议，失败时才回退到 `!cat`。

宿主机使用差分工具：

```sh
./tools/odebug_re_compare.py original.json replica.json \
  --scenario tools/odebug_re_scenario.template.json \
  --out diff-report.json
```

工具会忽略 PID、时间戳、BootSessionID、ASLR slide、IMP 和对象地址等易变内容，按原来的命令顺序比较输入、类、selector、尺寸、状态和视图输出。退出码：

- `0`：归一化后的证据一致。
- `1`：存在已确认差异。
- `3`：缺少必需输入/命令或证据被截断，结果标为“待证实”。

默认不使用数值容差放行。尺寸或约束不一致会进入 `differences`；无法形成完整证据的项目会进入 `pending`，发布验收时不能把 `pending` 当作通过。

调用顺序的采集示例：

```text
!re evidence begin notification-card-trace
!re evidence input title=Message
!re trace add RBDynamicIslandNotificationLayoutProvider152 preferredEdgeOutsetsForLayoutMode: --ttl 60
触发一次通知卡展示
!re trace log 200
!re trace remove RBDynamicIslandNotificationLayoutProvider152 preferredEdgeOutsetsForLayoutMode:
!re evidence end
```

紧急恢复全部 hook：

```text
!re trace clear
```

它等价于 `!hook clear`，会遍历所有活跃槽位并使用 hook 前保存的原始 IMP 恢复，同时清除持久化 hook 列表。

内存补丁示例：

```text
!re mem read 0x地址 32
!re mem patch 0x地址 0x01
!re mem patches
!re mem undo 1
!re mem undo all
```

补丁编号只在当前进程内有效，进程退出或 SpringBoard 重启后账本清空，不能跨进程恢复。

### 自动化与差分工具

场景执行器：

```sh
./tools/odebug_re_run.py scenario.json \
  --host 192.168.46.224 \
  --port 4321 \
  --token-file /private/path/odebug-token \
  --out-dir analysis/replica-notification-card
```

它会按顺序执行 `!re evidence begin`、场景输入、观测命令和 `!re evidence end`，保存 `transcript.json` 与 `evidence.json`。先用 `--dry-run` 可以只检查命令计划。

设置键接线审计：

```sh
./tools/odebug_re_settings_audit.py \
  ReplicaProject/Resources/AnimationSettings.plist \
  --source producer=ReplicaProject/Prefs \
  --source reader=ReplicaProject/Sources \
  --expect-domain com.example.replica.originals \
  --expect-notification com.example.replica-updated \
  --out analysis/settings-audit.json
```

工具递归提取 plist 中带 `key` 的设置项，再以 `producer`/`reader` 角色扫描
`.h/.m/.mm/.xm`。输出把声明键分为 `WIRED`、`UNWIRED`、`UI_ONLY` 和 `RUNTIME_ONLY`，
同时核对显式传入的偏好域与 Darwin 通知是否同时出现在设置端和运行端。对
`<base>.mass`、`<base>.stiffness`、`<base>.damping` 这类由
`SpringPreset`/`SpringParam` 动态拼接的键，会根据 reader 中的 base 字符串
建立派生引用。注释里的键名、域和通知名会被忽略。

只有已由原版二进制或调用链证明“仅用于设置页过滤、占位或生成运行时值”的键，
才通过可重复的 `--ui-only-key <key>` 显式标记为 `UI_ONLY`。未被 plist 声明的
`UI_ONLY` 键会让工具失败，避免把拼错或真实漏接线的配置键隐藏掉。

同一个项目可把 plist、producer/reader、通道和 UI-only 证据保存到 profile：

```sh
./tools/odebug_re_settings_audit.py \
  --profile /path/to/project/tools/settings-audit-profile.json \
  --out analysis/settings-audit.json
```

Profile 内分路径相对 profile 文件所在目录解析。格式为：

```json
{
  "schema": "odebug-re-settings-profile-v1",
  "plists": ["../Prefs/Root.plist"],
  "sources": {
    "producer": ["../Prefs"],
    "reader": ["../Sources"]
  },
  "expectedDomains": ["com.example.replica.originals"],
  "expectedNotifications": ["com.example.replica-updated"],
  "uiOnlyKeys": {
    "placeholderKey": "original UI-only evidence"
  }
}
```

退出码：`0` 表示没有未接线键或通道不一致；`1` 表示需要处理。扫描单个设置页
时，其他页面消费者的键会出现在 `RUNTIME_ONLY` 中作为信息展示，不会单独导致
失败。该工具是静态证据：动态计算出的键仍应使用 `!re trace` 在目标进程做一次
针对性确认，不能把静态 `WIRED` 当成运行时效果已经被真机验证。

截图差分：

```sh
./tools/odebug_re_image_diff.py original.png replica.png \
  --crop 20,80,360,120 \
  --threshold 0 \
  --out image-diff.json \
  --overlay image-diff.bmp
```

工具通过 macOS `sips` 读取 PNG/JPEG，输出变化像素数、比例、平均绝对误差和变化区域；退出码 `0` 表示一致，`1` 表示存在像素差异。

覆盖率报告：

```sh
idat64 -A -S"tools/ida_re_export.py --out analysis/ida-selectors.json" \
  TrollOpenRe.dylib.i64

./tools/odebug_re_coverage.py \
  --original original.json \
  --replica replica.json \
  --implemented implemented-selectors.json \
  --ida analysis/ida-selectors.json \
  --out coverage.json \
  --csv coverage.csv
```

状态包括 `verified`、`implemented-not-tested`、`missing-in-replica`、`unimplemented` 和 `pending`。只有原版与复刻版都实际观察到、并且实现清单中存在对应 selector 时，才会标记为 `verified`。

### 复刻安装事务和救机计划

安装复刻文件前记录原文件快照：

```text
!replica begin TrollOpenRe \
  /var/jb/Library/MobileSubstrate/DynamicLibraries/TrollOpenRe.dylib \
  /var/jb/Library/MobileSubstrate/DynamicLibraries/TrollOpenRe.plist
!replica status
```

安装完成后标记本次 replica 进入 active：

```text
!replica finish
```

安装后出现崩溃循环时可以先隔离：

```text
!replica quarantine
```

需要恢复安装前的原文件：

```text
!replica rollback
```

所有操作都保留原文件、隔离文件和 rollback preimage，不直接删除。

救机流程采用两阶段一次性计划：

```text
!rescue diagnose
!rescue plan quarantine
!rescue apply <plan-id>
```

可用 action：

- `layout`：可逆备份 SpringBoard 布局缓存。
- `quarantine`：隔离 replica manifest 中的复刻文件。
- `rollback`：恢复安装前快照。
- `safe`：写入安全标记。

计划 300 秒过期、只能消费一次，并记录创建时的 BootSessionID 和诊断结果。apply 成功后才触发 `launchctl reboot userspace`。

宿主机安装守护器：

```sh
./tools/odebug_replica_guard.py \
  --host 192.168.46.168 \
  --name TrollOpenRe \
  --path /var/jb/Library/MobileSubstrate/DynamicLibraries/TrollOpenRe.dylib \
  --path /var/jb/Library/MobileSubstrate/DynamicLibraries/TrollOpenRe.plist \
  --deb package.deb \
  --watch-seconds 180 \
  --auto-rescue \
  --token-file /private/path/odebug-token
```

守护器监控 SpringBoard PID、4321、4322 和 MCP 8099；超过 PID 变化阈值或插件端口离线超过 grace period 时，自动创建并执行 `quarantine` 救援计划。先加 `--dry-run` 可查看计划。

### IDA-first 复刻工作区

只使用电脑 IDA 时，可以完成静态接口、调用图、常量和复刻覆盖率，不依赖手机在线。

导出增强版 IDA evidence：

```sh
idat64 -A \
  -S"tools/ida_re_export.py --include-strings \
      --out analysis/ida-evidence.json" \
  -Lanalysis/ida-export.log \
  analysis/original-plugin.i64
```

导出内容包含类、selector、地址、IDA offset、prototype、callers/callees、引用字符串、立即数、hook API xref 和字符串。对 `MSHookMessageEx`、`class_replaceMethod` 等固定 class/selector 参数，导出器会沿 ARM64 寄存器赋值恢复 `targetClass`、`targetSelector` 和 `targetKind`；运行期传入动态 `Method` 的 exchange 无法静态确定目标类时会保留为空，不以猜测补全。`__imp__` 导入桩不会计为真实 hook 调用。

布局候选会记录 `CGRectMake`、`CGPointMake`、`CGSizeMake`、`UIEdgeInsetsMake`、字体、圆角和 constraint API，以及方法内立即数。

扫描复刻源码：

```sh
./tools/odebug_source_scan.py ReplicaProject \
  --out analysis/source-evidence.json
```

如果复刻类为避免冲突使用 `Replica` 后缀：

```sh
./tools/odebug_source_scan.py ReplicaProject \
  --strip-suffix Replica \
  --out analysis/source-evidence.json
```

也可多次使用 `--map OriginalClass=ReplicaClass` 做显式映射。默认仅扫描 `.m/.mm/.xm`，并排除 `Evidence`、`Package`、`ReferencePackage`、`Tests`、`.theos` 和构建目录。
批量映射可写成 `{"maps":{"OriginalClass":"ReplicaClass"}}` 并通过
`--map-file` 传入。生成计划时可加
`--built-dependencies-dir .theos/obj/debug/arm64e`：只有出现在编译器
`.Td` 依赖中的源码/头文件才算 `built`，存在但未编入产物的方法会标记为
`source-not-built`。
扫描实现时还会合并跨行 Objective-C selector，并从已实现类的头文件记录
`@property` 自动合成的 getter/setter；category 中的 property 不会被误算为
自动合成。纯内存管理访问器会与真实布局/业务方法区分，避免把 ivar offset
误报成待补代码。

合并 IDA 与源码，生成可执行工作队列：

```sh
./tools/odebug_replication_plan.py \
  --ida analysis/ida-evidence.json \
  --source analysis/source-evidence.json \
  --out analysis/replication-plan.json \
  --markdown analysis/replication-plan.md
```

Markdown 报告只列出按类聚合的缺口和前 100 个工作项；完整工作队列保留在 JSON。

生成只含 selector、类型注释和 IDA evidence 的 ObjC 骨架：

```sh
./tools/odebug_skeleton.py \
  --ida analysis/ida-evidence.json \
  --out analysis/generated-skeleton
```

比较两版 IDA evidence 的 selector 和调用边：

```sh
./tools/odebug_ida_diff.py \
  --original analysis/original-ida.json \
  --replica analysis/replica-ida.json \
  --out analysis/ida-diff.json
```

检查复刻源码是否保留了有效证据标签：

```sh
./tools/odebug_evidence_lint.py \
  --ida analysis/ida-evidence.json \
  --source analysis/source-evidence.json \
  --out analysis/evidence-lint.json
```

只想检查 IDA 中原版方法的证据标签时：

```sh
./tools/odebug_evidence_lint.py \
  --ida analysis/ida-evidence.json \
  --source analysis/source-evidence.json \
  --ignore-not-in-ida \
  --out analysis/evidence-lint-focused.json
```

发现缺失、未知 offset 或 IDA 中不存在的方法时返回退出码 `1`。

根据 IDA evidence 自动生成注释补丁，默认只写 `.patch` 文件：

```sh
./tools/odebug_evidence_patch.py \
  --ida analysis/ida-evidence.json \
  --source analysis/source-evidence.json \
  --patch analysis/evidence.patch \
  --report analysis/evidence-patch-report.json \
  --only-required
```

确认补丁后加 `--apply` 才会修改源码。
默认 diff 以 `source-evidence.json` 的 `sourceRoot` 为基准生成 `a/...`、
`b/...` 相对路径，可直接从目标仓库根目录执行 `git apply --check`；源码根不在
evidence 中时可用 `--patch-root` 明确指定。

提取复刻源码的 Objective-C message callgraph：

```sh
./tools/odebug_source_callgraph.py \
  --source analysis/source-evidence.json \
  --out analysis/source-callgraph.json
```

把 ODebug 运行时 evidence 注释回 IDA：

```sh
idat64 -A \
  -S"tools/ida_odebug_import.py \
      --evidence analysis/runtime-evidence.json \
      --report analysis/ida-import.json" \
  -Lanalysis/ida-import.log \
  analysis/replica.i64
```

工具按 `imageBase + idaOffset` 定位函数，追加 repeatable comment，并尽可能设置颜色。不会自动重命名函数。

批量导出指定类的 Hex-Rays 伪代码：

```sh
./tools/odebug_ida.py pseudocode \
  --db analysis/original-plugin.i64 \
  --evidence analysis/ida-evidence.json \
  --class TOJBClass012 \
  --class DIMiniElement \
  --out analysis/pseudocode-priority
```

每个方法会生成独立 `.c` 文件，文件开头保留 IDA offset 和
`Class selector` 证据标签；`manifest.json` 记录类、selector、运行时地址、
IDA offset、成功状态、失败原因，以及输入二进制和 evidence 的 SHA256。
提供 `--evidence` 时只导出其中匹配的方法，适合按
`replication-plan.json` 的缺口类分批处理。默认排除 `.cxx_*`、
`__deallocating__`、`__destroy_helper_block_` 和
`__copy_helper_block_` 等编译器生成符号；只有确需检查这些符号时才加
`--include-compiler-generated`。伪代码是待核对的静态证据，不能仅凭文本相似
就判定原版与复刻版行为一致。

统一入口：

```sh
./tools/odebug_ida.py export \
  --db analysis/original-plugin.i64 \
  --out analysis/ida-evidence.json \
  --include-strings

./tools/odebug_ida.py import-runtime \
  --db analysis/replica.i64 \
  --evidence analysis/runtime-evidence.json \
  --report analysis/ida-import.json

./tools/odebug_ida.py pseudocode \
  --db analysis/original-plugin.i64 \
  --evidence analysis/ida-evidence.json \
  --class TOJBClass012 \
  --out analysis/pseudocode-priority
./tools/odebug_ida.py scan ReplicaProject --out analysis/source-evidence.json
./tools/odebug_ida.py scan ReplicaProject --strip-suffix Replica \
  --out analysis/source-evidence.json
./tools/odebug_ida.py plan --ida analysis/ida-evidence.json \
  --source analysis/source-evidence.json \
  --out analysis/replication-plan.json
./tools/odebug_ida.py skeleton --ida analysis/ida-evidence.json \
  --out analysis/generated-skeleton
./tools/odebug_ida.py diff --original original.json --replica replica.json \
  --out analysis/ida-diff.json
./tools/odebug_ida.py lint --ida analysis/ida-evidence.json \
  --source analysis/source-evidence.json \
  --ignore-not-in-ida \
  --out analysis/evidence-lint.json
./tools/odebug_ida.py patch-evidence --ida analysis/ida-evidence.json \
  --source analysis/source-evidence.json \
  --patch analysis/evidence.patch \
  --report analysis/evidence-patch-report.json \
  --only-required
./tools/odebug_ida.py callgraph --source analysis/source-evidence.json \
  --out analysis/source-callgraph.json
./tools/odebug_ida.py coverage --ida analysis/ida-evidence.json \
  --implemented analysis/source-evidence.json \
  --out analysis/coverage.json
```

没有设备 evidence 时，静态结果只能达到 `implemented`、`implemented-not-tested`、`missing` 和 `pending`。`verified` 仍要求原版与复刻版的运行时证据。

安装前的 deb 静态验收：

```sh
./tools/ios_package_preflight.py \
  --deb packages/com.example.package.deb \
  --expect-id com.example.package \
  --expect-version 1.2.3-4 \
  --expect-arch iphoneos-arm64e \
  --require-rpath @loader_path/.jbroot/Library/Frameworks \
  --require-rpath @loader_path/.jbroot/usr/lib \
  --require-string notificationIslandEnabled \
  --out analysis/package-preflight.json
```

工具会检查 Debian 归档成员、control、解包结果、动态库和 Preferences
bundle 的 arm64e 架构、CodeDirectory、`ldid` 可读性、rpath、Tweak
filter plist 以及指定的关键字符串。它不会安装或运行包。

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

### USB 救援诊断

手机已经启用 iDownload 时，可指定设备 UDID 和通过设备证据确认的当前 jbroot，执行只读诊断：

```sh
python3 tools/usb_rescue_status.py --udid <UDID> --jbroot /private/var/containers/Bundle/Application/.jbroot-<标识>
```

脚本使用仅监听本机的 USB 转发，读取身份、launchd 任务、两个安全模式路径和 daemon 日志；默认只读。追加 `--start` 会请求 bootstrap 已安装的 odebugd 并打印结果；不改动标记、不重启设备。已有任务时 bootstrap 可能返回已加载，需以 launchd 状态及端口连接为准。安全模式标记存在时，odebugd 暂停向 SpringBoard 自动注入；手动 `!auto run` 同样拒绝执行。独立控制端口是否可用仍需现场验证。


多台手机选择：普通运行 `./odebug.sh` 会自动扫描局域网；发现多台时显示设备名、IP、端口和版本供选择，单台则直接连接。指定 `ODEBUG_HOST=<IP>` 时直连该地址；`ODEBUG_CHOOSE=1` 可强制显示选择列表。

### 早期救援服务

本节已按 Relaxin `main` 的公开快照 `f44e0acfef4453989381736e0c86b9c14e7ea045` 核对，不再沿用 Dopamine/RootHide 的行为推断：

- `Vendor/Dopamine/BaseBin/launchdhook/src/daemon_hook.m` 只把 jbroot 的 `basebin/LaunchDaemons` 注入 launchd 扫描结果，不扫描 `Library/LaunchDaemons`。
- `RelaxinEngine/Bootstrap/RLXBaseBinInstaller.m` 安装 BaseBin 时先删除整个 `basebin` 目录，再解包；同时把 `basebin/LaunchDaemons/*.plist` 中 `ProgramArguments` 的 `@JBROOT@` 原地展开为真实 jbroot。这个快照不生成 `__Patched` 字段。
- `Vendor/Dopamine/BaseBin/jbctl/src/internal.m` 的 `jbctl internal startup` 会随后执行 `launchctl bootstrap system /Library/LaunchDaemons`。
- `com.aapl.relaxin.startup.plist` 使用 `Interactive`、`RunAtLoad=true`，并通过 `ProgramArguments` 调用 `@JBROOT@/basebin/jbctl internal startup`。

因此救援采用两个不同 Label，而不是把同一个 job 放进两个目录：

1. `com.tanyou.odebug-rescue` 位于 `basebin/LaunchDaemons`，由 `launchdhook` 最早注入 launchd。它每 60 秒检查一次 `odebugd`。
2. `com.tanyou.odebug-rescue-repair` 位于 `Library/LaunchDaemons`，会随 Relaxin startup 的 `bootstrap system` 启动。它每 300 秒检查 BaseBin 早期 plist；BaseBin 升级把它整体删除后，它会从 `usr/share/odebugd` 的模板补回，并注册早期 job。

两个 job 共用同一套救援逻辑，但 LaunchDaemon 不直接调用 shell 脚本：包内的原生 `usr/libexec/odebug_rescue_launcher` 会扫描当前 `.jbroot-*`，设置 `ODEBUG_RESCUE_JBROOT`，再用该 jbroot 的 shell 执行 `usr/libexec/odebug-rescue`。这样既不依赖 iOS 真实根中不存在的 `/bin/sh`，也能跨 BaseBin 随机化继续工作。真机对照测试确认：`/var/jb/usr/libexec/odebug_rescue_launcher` 可被 launchd 正常执行；同一程序即使签名有效，只要放在 `/var/mobile/Library/Logs/`，launchd 就会返回 `78 EX_CONFIG`。安装时 postinst 会先用设备自带 `ldid` 重签 launcher，再 `bootout` 缓存的旧救援 job 并 `bootstrap` 新 plist，确保新的 ProgramArguments 立即进入 launchd。脚本先解析 `launchctl print` 的实际生效域，核对 `state = running`、PID 仍存活，并用原生 launcher 的 `--probe-port 4322` 检查回环端口。若 job 完全未注册，依次执行 `bootstrap system`、`bootstrap user/501`，最后才尝试旧式 `launchctl load -w`。若 job 已注册但 PID 或端口不健康，只对 `com.tanyou.odebugd` 执行服务级 `kickstart -k`；仍未恢复时才对该服务 `bootout` 并重新 bootstrap。恢复尝试默认写入 300 秒冷却，避免 launchd 每分钟重复拉起造成风暴。该路径不注入 SpringBoard、不修改 `.safe_mode`/`.eksafemode`，也不重启 SpringBoard、设备或用户空间。

安装后可在设备 root shell 运行以下只读诊断：

```sh
/var/jb/usr/libexec/odebug_rescue_launcher --diagnose
cat /var/mobile/Library/Logs/odebug-rescue.log
```

这个服务的边界必须明确：`launchdhook` 本身没有注入 launchd，或整个 Relaxin bootstrap 没启动时，rescue 也不可能运行；那种情况下仍要使用 iDownload/USB 根 shell。它负责恢复“`odebugd` job 丢失/尚未注册”“job 已注册但进程卡死或 4322 不监听”以及“BaseBin 更新删除了早期 rescue plist”的场景。

`odebugd` 启动时仍会做一次模板恢复作为额外保护；Library 中的 repair job 负责解决 `odebugd` 自己未启动时无法自愈的循环依赖。Relaxin 的 `rerandomizeRoot:` 会整体改名 `.jbroot-*`，因此三个 rescue plist 的 `ProgramArguments` 使用 Relaxin 维护的稳定兼容路径 `/var/jb/usr/libexec/odebug_rescue_launcher`，而不是固化当前随机 jbroot 名。原生 launcher 自己会扫描真实 `.jbroot-*` 定位 `odebugd`、`launchctl` 和 plist。安装维护脚本会尝试把两个 rescue job 注册到 `system` 域。注册失败不会触发 respring，Relaxin 下一次 startup 仍会扫描 Library 中的 repair job。
