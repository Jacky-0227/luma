# PTZ protocol reference · 雲台協定資料 · 云台协议资料

Research reviewed on 2026-10-03. This is a protocol coverage map, not a list of certified camera models. Implementation details and device-test limits are recorded in [PTZ compatibility](PTZ-compatibility.md).

## English

| Family / capability | Evidence and integration requirement | Luma 0.1.3 |
| --- | --- | --- |
| Hikvision ISAPI | Channel collection, channel configuration and per-channel capabilities; inspect pan, tilt and zoom independently. [Capability XML](https://open.hikvision.com/hardware/XMLs/DEVICE_ABILITY_PTZChanelCap.html) | Implemented; no model-name allowlist |
| Older Hikvision IPMD | Older manufacturer documentation defines `/PTZCtrl/channels` without the ISAPI prefix and general-resource capability documents. [Manufacturer specification, hosted copy](https://www.scribd.com/document/898128556/HIK-IPMD-V2-0-201312) | Read-only fallback after explicit unsupported responses; control keeps the discovered API family |
| Recorders and encoders | A video input and a PTZ control channel must refer to the same source; collection order is not a mapping. The streaming channel identifier is not automatically a PTZ identifier. | Explicit input mapping, matching channel ID, or previously configured control channel; ambiguous mapping stays unknown |
| Continuous / momentary / position control | The ISAPI schema distinguishes movement spaces and can explicitly veto continuous control. [Hikvision PTZ protocol](https://open.hikvision.com/hardware/v2/08%E5%8D%8F%E8%AE%AE%E9%80%8F%E4%BC%A0/%E4%BA%91%E5%8F%B0%E5%92%8C%E8%B7%9F%E9%9A%8F%E5%AE%9A%E4%BD%8D.html) | Prefer supported continuous control per axis; timed movement fallback; absolute/relative-only capability is not converted into hold control |
| ONVIF PTZ | Use the selected media profile's PTZ configuration and node, then inspect supported spaces and timeout range. `ContinuousMove` carries velocity and optional timeout; `Stop` is a separate operation. [Official PTZ service](https://www.onvif.org/ver20/ptz/wsdl/), [official specification](https://www.onvif.org/specs/srv/ptz/ONVIF-PTZ-Service-Spec-v241.pdf) | Researched; SOAP/ONVIF transport is not implemented and is not advertised as supported |
| ONVIF activation and identity | Hikvision documents a separate ONVIF enable switch and user management; RTSP credentials or successful video alone do not establish ONVIF control access. [Manufacturer setup guide](https://supportusa.hikvision.com/support/solutions/articles/17000128730-how-do-i-enable-onvif-on-a-hikvision-camera-) | No automatic device-setting changes or guessed ONVIF accounts |
| PSIA | IPMD and the common service/security specifications form a separate standards family. [PSIA specification catalogue](https://psialliance.org/legacy-specs/) | Catalogue reviewed; generic PSIA support is not inferred from Hikvision's similarly named IPMD interface |
| HCNetSDK / serial PTZ | The manufacturer's SDK has paired start/stop calls and distinct zoom, focus and iris commands. [Official SDK API](https://open.hikvision.com/hardware/definitions/NET_DVR_PTZControl_Other.html) | No HCNetSDK or raw serial backend; no direct Pelco-D/P claim |
| Presets, home, patrols, patterns, focus and iris | These are separate optional functions, not proof that manual pan/tilt/zoom is available. Consult the relevant advertised capability and operation. | Outside the current manual-control feature set |

### Interpretation and validation

Missing optional data means unknown, not “no PTZ.” Explicit disabled axes remain disabled. HTTP success can contain an application-level failure; an ambiguous error must not trigger a different control protocol. Detection only reads configuration. It must not move the camera, create a preset, change a protocol, or alter a recorder mapping.

For latency, distinguish touch delivery, request dispatch, authentication/connection setup, camera acknowledgement, physical motion, and video presentation delay. A received HTTP response is not a measurement of when the lens stopped. Tests should cover delayed movement acknowledgement, immediate release, rapid direction changes, leaving the screen, authentication failure and loss of connectivity. Only physical-device observation establishes end-to-end responsiveness.

## 繁體中文

研究以協定、韌體回應及通道對應為依據，沒有按型號硬開雲台。資料涵蓋以下類別；上表附原始來源。

| 類別 | 核對內容 | 0.1.3 狀態 |
| --- | --- | --- |
| 海康 ISAPI | 通道列表、通道設定、各軸能力及限時／連續／位置控制差異 | 已實作按能力辨識 |
| 舊版海康 IPMD | 無 ISAPI 前綴的路徑、一般資源格式的能力文件、XML 應用層錯誤 | 明確不支援時唯讀回退，控制沿用偵測到的介面 |
| 錄影機／編碼器 | 影像輸入與控制通道對應 | 不猜測其他通道；有歧義則保留未知 |
| ONVIF | Media Profile、PTZ Configuration、Node、移動範圍、逾時及停止操作 | 已研究；尚未實作 SOAP 控制 |
| ONVIF 啟用及帳號 | 可能有獨立開關、使用者及權限 | 不自動修改設備設定 |
| PSIA、HCNetSDK、串列協定 | 各自的服務、驗證及開始／停止語義 | 已列入資料範圍；未實作通用後端 |
| 預置點、巡航、花樣、回原點、對焦、光圈 | 與手動方向及光學變焦分開的能力 | 尚未提供操作介面 |

欄位缺失、驗證失敗、逾時或 XML 錯誤均不能直接判定「沒有雲台」。辨識只讀取資訊，不以試轉、寫入預置點或更改設定來探測。各軸明確支援連續控制時優先使用；只支援限時控制的軸保留短脈衝。

延遲須分開看觸控事件、送出指令、連線與驗證、設備回應、機械運動及影片顯示。HTTP 成功不代表已測得鏡頭停止時間。軟體測試涵蓋遲到回應、放開、快速換向及停止失敗；最終手感仍以實機為準。

## 简体中文

研究以协议、固件响应及通道对应为依据，没有按型号强行开启云台。资料涵盖以下类别；首表附原始来源。

| 类别 | 核对内容 | 0.1.3 状态 |
| --- | --- | --- |
| 海康 ISAPI | 通道列表、通道配置、各轴能力及限时／连续／位置控制差异 | 已实现按能力识别 |
| 旧版海康 IPMD | 无 ISAPI 前缀的路径、通用资源格式的能力文档、XML 应用层错误 | 明确不支持时只读回退，控制沿用检测到的接口 |
| 录像机／编码器 | 视频输入与控制通道对应 | 不猜测其他通道；有歧义则保留未知 |
| ONVIF | Media Profile、PTZ Configuration、Node、移动范围、超时及停止操作 | 已研究；尚未实现 SOAP 控制 |
| ONVIF 启用及账号 | 可能有独立开关、用户及权限 | 不自动修改设备设置 |
| PSIA、HCNetSDK、串行协议 | 各自的服务、认证及开始／停止语义 | 已列入资料范围；未实现通用后端 |
| 预置点、巡航、花样、回原点、对焦、光圈 | 与手动方向及光学变焦分开的能力 | 尚未提供操作界面 |

字段缺失、认证失败、超时或 XML 错误均不能直接判定“没有云台”。识别只读取信息，不以试转、写入预置点或修改配置来探测。各轴明确支持连续控制时优先使用；只支持限时控制的轴保留短脉冲。

延迟须分开看触摸事件、发出指令、连接与认证、设备响应、机械运动及视频显示。HTTP 成功不代表已测得镜头停止时间。软件测试覆盖迟到响应、松手、快速换向及停止失败；最终手感仍以实机为准。
