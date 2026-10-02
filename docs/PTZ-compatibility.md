# PTZ compatibility · 雲台相容性 · 云台兼容性

## English

Luma uses read-only ISAPI requests to discover capabilities. A missing optional XML element is not a declaration that a camera has no PTZ. Version 0.1.2 recognizes momentary and continuous movement spaces per axis, plus explicit legacy pan/tilt/zoom support flags. Explicit disabled axes or a continuous-control veto take precedence. Absolute/relative-only devices without a supported manual movement method are reported separately.

Recorder channels must match an explicit video-input mapping, a matching channel ID, or a previously configured control channel. Luma does not choose an unrelated channel merely because it is the only PTZ channel returned. Authentication, timeout or malformed responses are reported as inconclusive and can be retried.

Timed movements use short device-side pulses. Continuous movement uses a start followed by Stop; it does not gain a device-side timeout from Luma's two-second hold limit. Release, navigation and background transitions request Stop. If acknowledgement fails, further movement is disabled until Stop is retried successfully. Physical movement and stopping must be tested with the target camera.

## 繁體中文

Luma 只讀取 ISAPI 資訊來偵測雲台。XML 中缺少選填欄位，不代表攝影機沒有雲台。0.1.2 分別識別各軸的限時、連續移動能力及舊韌體明確的方向／變焦支援標誌；明確禁用的軸或連續控制否決標誌優先。只有絕對／相對位置控制、沒有相容手動移動方式的設備會另外提示。

錄影機通道必須有明確的影像輸入對應、相同通道 ID，或沿用已設定的控制通道。不會因設備只回傳一個雲台通道就猜測其對應攝影機。驗證、逾時或格式錯誤會標示為無法確定，可重新偵測。

限時控制使用設備端短脈衝；連續控制依賴開始及停止指令。兩秒按住上限不等於攝影機端具備兩秒自動停止。放開、離開畫面或進入背景時會要求停止；未獲確認時暫停新的移動，直到重試停止成功。實際移動及停止需要在目標攝影機驗證。

## 简体中文

Luma 仅读取 ISAPI 信息来检测云台。XML 中缺少可选字段，不代表摄像头没有云台。0.1.2 分别识别各轴的限时、连续移动能力及旧固件明确的方向／变焦支持标志；明确禁用的轴或连续控制否决标志优先。只有绝对／相对位置控制、没有兼容手动移动方式的设备会单独提示。

录像机通道必须有明确的视频输入对应、相同通道 ID，或沿用已设置的控制通道。不会因为设备只返回一个云台通道就猜测其对应摄像头。认证、超时或格式错误会标记为无法确定，可重新检测。

限时控制使用设备端短脉冲；连续控制依赖开始及停止指令。两秒按住上限不等于摄像头端具备两秒自动停止。松手、离开画面或进入后台时会要求停止；未获确认时暂停新的移动，直到重试停止成功。实际移动及停止需要在目标摄像头验证。

## Protocol references

- [Hikvision PTZChanelCap XML](https://open.hikvision.com/hardware/XMLs/DEVICE_ABILITY_PTZChanelCap.html): separate optional movement spaces and axis ranges.
- [Hikvision PTZ protocol](https://open.hikvision.com/hardware/v2/08%E5%8D%8F%E8%AE%AE%E9%80%8F%E4%BC%A0/%E4%BA%91%E5%8F%B0%E5%92%8C%E8%B7%9F%E9%9A%8F%E5%AE%9A%E4%BD%8D.html): per-channel capabilities and explicit continuous-control veto.
- [Manufacturer integration guide, hosted copy](https://www.scribd.com/document/502000113/How-to-integrate-Hikvision-PTZ-function): channel support flags and continuous movement/stop commands.

Tests use synthetic protocol fixtures. No physical device response, footage or credentials are bundled with these examples.
