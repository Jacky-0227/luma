# PTZ compatibility · 雲台相容性 · 云台兼容性

## English

Luma uses read-only requests to discover capabilities. A missing optional XML element is not a declaration that a camera has no PTZ. Version 0.1.3 recognizes ISAPI capability spaces, explicit legacy axis flags, and older `PTZChannel` capability documents. Only when all relevant ISAPI discovery routes explicitly report unsupported does Luma try the older `/PTZCtrl` family on the same device. XML application errors are checked even with HTTP 200/400; ambiguous errors do not authorize fallback. There is no model-name allowlist.

Recorder channels must match an explicit video-input mapping, a matching channel ID, or a previously configured control channel. Luma does not choose an unrelated channel merely because it is the only PTZ channel returned. Explicit access denials have their own message; network failures or malformed responses remain inconclusive. Both can be retried.

Partial axis information is supplemented by reading the same channel's configuration. Explicit denials survive merging. Documented success codes 0 and 1 are accepted only with an absent or consistent success substatus. Each axis prefers continuous control when explicitly supported; timed movement remains available otherwise. Explicit disabled axes and a continuous-control veto take precedence. Absolute/relative-only capability does not enable manual hold controls. Timed movements use short device-side pulses. Continuous movement requires a start followed by Stop; Luma's two-second hold limit is not a device-side timeout.

Native touch-down and release events bypass the scroll view's initial touch delay. Stop is sent independently of an outstanding movement response. If an old movement finishes after Stop was issued, a final Stop follows it. Rapid changes keep only the newest still-held direction; releasing it discards that intent. Movement and Stop share an ephemeral session with two connection slots and session-only credentials. Failed stop attempts block further movement until a confirmed stop. Navigation and background transitions also request Stop. Camera execution time and video latency still require physical-device measurement.

## 繁體中文

Luma 只讀取資訊來偵測雲台。XML 缺少選填欄位，不代表攝影機沒有雲台。0.1.3 識別 ISAPI 移動能力、舊韌體的各軸支援標誌及 `PTZChannel` 格式的能力文件。相關 ISAPI 偵測路由均明確回報不支援時，才回退至同一設備的舊 `/PTZCtrl` 介面。HTTP 200/400 內的 XML 錯誤也會檢查；含義不明的錯誤不會觸發回退。沒有按型號硬開雲台。

錄影機通道必須有明確的影像輸入對應、相同通道 ID，或沿用已設定的控制通道。不會因設備只回傳一個雲台通道就猜測其對應攝影機。明確拒絕存取時會單獨提示帳號及權限；網路失敗或格式錯誤仍標示為無法確定，皆可重新偵測。

只有部分軸資訊時，會補讀同一通道設定，合併時保留明確禁用的標誌。成功狀態碼相容 0 及 1，但矛盾的子狀態仍拒絕。各軸明確支援時優先使用連續控制，否則保留限時短脈衝；明確禁用及連續控制否決標誌優先。只有絕對／相對位置能力不會啟用按住移動。兩秒按住上限不等於攝影機端具備自動停止。

原生按下、放開事件不等待滾動視圖的初始觸控延遲。停止指令獨立發送，不等待移動回應；舊移動較晚完成時會補發停止。快速換向只保留最新且仍按住的方向，放開即清除。移動及停止共用暫存連線階段，提供兩個連線槽及僅存於該階段的憑據。停止重試失敗會暫停新的移動，直到確認停止。離開畫面或進入背景亦會要求停止。設備執行時間及影片延遲仍須實機量測。

## 简体中文

Luma 仅读取信息来检测云台。XML 缺少可选字段，不代表摄像头没有云台。0.1.3 识别 ISAPI 移动能力、旧固件的各轴支持标志及 `PTZChannel` 格式的能力文档。相关 ISAPI 检测路由均明确返回不支持时，才回退到同一设备的旧 `/PTZCtrl` 接口。HTTP 200/400 内的 XML 错误也会检查；含义不明的错误不会触发回退。没有按型号强行开启云台。

录像机通道必须有明确的视频输入对应、相同通道 ID，或沿用已设置的控制通道。不会因为设备只返回一个云台通道就猜测其对应摄像头。明确拒绝访问时会单独提示账号及权限；网络失败或格式错误仍标记为无法确定，均可重新检测。

只有部分轴信息时，会补读同一通道配置，合并时保留明确禁用的标志。成功状态码兼容 0 和 1，但矛盾的子状态仍拒绝。各轴明确支持时优先使用连续控制，否则保留限时短脉冲；明确禁用及连续控制否决标志优先。只有绝对／相对位置能力不会启用按住移动。两秒按住上限不等于摄像头端具备自动停止。

原生按下、松开事件不等待滚动视图的初始触摸延迟。停止指令独立发送，不等待移动响应；旧移动较晚完成时会补发停止。快速换向只保留最新且仍按住的方向，松手即清除。移动及停止共用临时会话，提供两个连接槽及仅存于会话中的凭据。停止重试失败会暂停新的移动，直到确认停止。离开画面或进入后台也会要求停止。设备执行时间及视频延迟仍须实机测量。

## Protocol references

See the broader [protocol coverage and research map · 協定資料 · 协议资料](PTZ-protocol-reference.md), including ONVIF, PSIA, recorder mapping, SDK control and unsupported features.

- [Hikvision PTZChanelCap XML](https://open.hikvision.com/hardware/XMLs/DEVICE_ABILITY_PTZChanelCap.html): separate optional movement spaces and axis ranges.
- [Hikvision PTZ protocol](https://open.hikvision.com/hardware/v2/08%E5%8D%8F%E8%AE%AE%E9%80%8F%E4%BC%A0/%E4%BA%91%E5%8F%B0%E5%92%8C%E8%B7%9F%E9%9A%8F%E5%AE%9A%E4%BD%8D.html): per-channel capabilities and explicit continuous-control veto.
- [Manufacturer integration guide, hosted copy](https://www.scribd.com/document/502000113/How-to-integrate-Hikvision-PTZ-function): channel support flags and continuous movement/stop commands.
- [Manufacturer IPMD specification, hosted copy](https://www.scribd.com/document/898128556/HIK-IPMD-V2-0-201312): older routes, general-resource capabilities and application status codes.
- [Apple scroll touch delivery](https://developer.apple.com/documentation/uikit/uiscrollview/delayscontenttouches): removal of the initial content-touch delay is scoped to the controls' containing scroll views.
- [Apple ephemeral credential storage](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/urlcredentialstorage): session-scoped private memory storage.

Tests use synthetic protocol fixtures. No physical device response, footage or credentials are bundled with these examples.

## Control readiness and visible latency / 控制預熱與畫面延遲 / 控制预热与画面延迟

In 0.1.4, a visible live view makes a read-only GET to the detected API family’s channel status endpoint before control use, then at most once every 20 seconds while idle. The same private session retains Digest credentials and keep-alive. Touch-down or Stop cancels an unfinished readiness read; an unsupported status resource does not disable detected controls. Navigation/background cancellation stops readiness work. No movement is used to warm a connection.

0.1.4 在即時畫面可見時，以唯讀 GET 預先查詢已偵測介面的通道狀態，閒置時最多每 20 秒再查一次，同一私有連線保留 Digest 驗證。按下方向鍵或停止會取消尚未完成的預熱；不支援狀態查詢不會停用已識別的控制。離開或進入背景時取消預熱，不以移動攝影機預熱。

0.1.4 在实时画面可见时，以只读 GET 预先查询已检测接口的通道状态，空闲时最多每 20 秒再查一次，同一私有连接保留 Digest 认证。按下方向键或停止会取消尚未完成的预热；不支持状态查询不会停用已识别的控制。离开或进入后台时取消预热，不以移动摄像头预热。

Single-camera RTSP playback uses `network-caching=100` and `clock-jitter=100`; dashboards retain `network-caching=500`. Audio/video synchronization remains enabled. Smaller buffers reduce client-side waiting but do not remove camera encoding, frame-rate, transport or motor latency. Poor networks may show more stutter.

單路 RTSP 使用 100 毫秒網路緩衝及 100 毫秒額外時鐘補償上限，儀表板保留 500 毫秒緩衝；音畫同步仍啟用。這減少用戶端等待，但不會消除攝影機編碼、幀率、傳輸與馬達延遲；網路不穩時可能較易卡頓。

单路 RTSP 使用 100 毫秒网络缓冲及 100 毫秒额外时钟补偿上限，仪表板保留 500 毫秒缓冲；音画同步仍启用。这减少客户端等待，但不会消除摄像头编码、帧率、传输与马达延迟；网络不稳时可能较易卡顿。

Sources: [Hikvision status resource](https://open.hikvision.com/hardware/v2/08%E5%8D%8F%E8%AE%AE%E9%80%8F%E4%BC%A0/%E4%BA%91%E5%8F%B0%E5%92%8C%E8%B7%9F%E9%9A%8F%E5%AE%9A%E4%BD%8D.html), [VLC 3.0.21 RTSP PTS delay](https://github.com/videolan/vlc/blob/3.0.21/modules/access/live555.cpp#L1673), [VLC clock compensation](https://github.com/videolan/vlc/blob/3.0.21/src/input/es_out.c#L2368).
