# 睡眠录音（测试版）

一个 Apple Watch 独立 App，用来测试三件事：

1. 手表能不能整晚在后台录音，系统会不会中途打断
2. 录一整晚要用掉多少电
3. 苹果自带的声音识别能不能认出打鼾

> 仅用于个人测试，不是医疗诊断。录音只保存在手表上。

## 虚拟机里要用的链接（直接点）

- macOS 15.7.9 安装包（苹果官方服务器，约 15GB）：[InstallAssistant.pkg](https://swcdn.apple.com/content/downloads/16/08/140-85388-A_3LX3Q36I6P/zxod6nr7zkovvsml6s628z44gdbc4exa5p/InstallAssistant.pkg)
- Xcode 26.6 下载页（登录 Apple ID 后搜索 "Xcode 26.6"）：[developer.apple.com/download/all](https://developer.apple.com/download/all/)
- 本项目代码 ZIP：[下载](https://github.com/jjjj8/apple-watch/archive/refs/heads/main.zip)

## 它做什么

- 点"开始整晚录音"后，手表在后台持续录音（16kHz 压缩音频，每 15 分钟一个文件，一晚约 100MB）
- 每约 3 秒用苹果内置的声音分类模型判断一次是否在打鼾
- 每 5 分钟记录一次电量
- 记录系统打断（来电、闹钟等）和录音断档（音频停了超过 5 秒）
- 早上点"停止"后显示报告：时长、电量消耗、断档次数、鼾声片段；点某段鼾声可以在手表上回放

## 安装到手表（需要一台苹果芯片的 Mac）

Xcode 27 只能在苹果芯片（M1 及以后）的 Mac 上运行。

### 第一次准备（约 1 小时，大部分时间在下载）

1. 在 Mac 上打开 App Store，搜索 **Xcode**，点"获取"安装（约 10GB 以上）。
2. 打开 Xcode，第一次会问要装哪些平台，勾选 **watchOS**，等它下载完。
3. Xcode 菜单 **Xcode → Settings → Accounts**，点左下角 **+**，选 **Apple ID**，用你的 Apple ID 登录（免费账号即可）。
4. 下载代码：打开 https://github.com/jjjj8/apple-watch ，点绿色的 **Code** 按钮 → **Download ZIP**，解压。
5. 双击解压出来的 **SleepSound.xcodeproj**，用 Xcode 打开。

### 打开手表和 iPhone 的开发者模式

1. iPhone 用数据线连上 Mac，iPhone 上点"信任此电脑"。
2. iPhone：**设置 → 隐私与安全性 → 开发者模式**，打开，按提示重启。
   （如果找不到这个选项，先完成下面"签名"那步并点一次运行，它就会出现。）
3. 手表：**设置 → 隐私与安全性 → 开发者模式**，打开，按提示重启。
4. 手表和 iPhone 保持解锁、靠近 Mac、连同一个 Wi-Fi。

### 签名并运行

1. Xcode 左边点最上面蓝色的 **SleepSound**，中间选 **Signing & Capabilities**。
2. **Team** 下拉框选你的名字（Personal Team）。
3. 如果下面报红字说 Bundle Identifier 已被占用，把 **Bundle Identifier** 改成别的，比如 `com.你的名字拼音.sleepsound.watchkitapp`。
4. Xcode 窗口最上方中间，点设备选择框，选你的 **Apple Watch**（第一次可能要等几分钟"准备设备"）。
5. 点左上角 ▶︎ 运行按钮。第一次可能需要在 Mac 上输入密码、点"始终允许"。
6. 如果手表上提示"不受信任的开发者"：在 iPhone 上 **设置 → 通用 → VPN 与设备管理**，点你的 Apple ID，选"信任"。

装好后手表上会出现"睡眠录音"。免费账号签的 App **7 天后会失效**，重新点一次 ▶︎ 就能续上。

## 测试方法

1. 晚上手表充满电，戴上，打开"睡眠录音"，点"开始整晚录音"，第一次会问麦克风权限，点允许。
2. 正常睡觉，不用管它。
3. 早上点"停止"，看报告，把截图发给 Claude。重点看：
   - **电量**：一晚用了多少
   - **系统有没有打断**：断档次数和缺失时长
   - **打鼾**：点几段听一下，识别得准不准

## 文件说明

- `SleepSound/Model/Recorder.swift`：录音、打鼾识别、电量和打断记录
- `SleepSound/Model/NightReport.swift`：把一晚的记录整理成报告
- `SleepSound/Views/`：手表界面
- `.github/workflows/build.yml`：GitHub 云端自动编译检查
