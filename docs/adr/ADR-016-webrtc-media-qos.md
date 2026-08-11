最新更新时间：2026-08-11

# ADR-016: Native WebRTC Realtime Subsystem and Media QoS

状态：Accepted

## 背景

网络 SDK 的 WebRTC 不属于 Generic Transport 的平级 frame wrapper。它同时负责
SDP、ICE/STUN/TURN、DTLS/SRTP、RTP/RTCP、Audio、Video 和 DataChannel；实时媒体
也不能在断线后像控制消息一样重放历史帧。

## 决策

- 新增 native-only `network-webrtc` crate，固定使用稳定版 `rtc 0.9.1` 的
  sans-I/O PeerConnection；网络 I/O 仍由上层提供，便于后续复用 native UDP
  所有权，而不把 WebRTC 塞进 `network-transport`。
- PeerConnection 暴露受边界保护的 SDP offer/answer、ICE candidate、ICE restart、
  Audio/Video RTP transceiver、DataChannel 以及 sans-I/O packet/event pump。
- Audio/Video/DataChannel 使用独立有界 QoS 队列。Audio/Video 过期或拥塞时丢弃旧
  帧；DataChannel 默认采用 backpressure；连接丢失时不重放旧媒体帧，并请求新的
  Video keyframe。
- SDP、ICE candidate、DataChannel payload 和媒体队列均有明确上限；TURN 凭据只
  保存在运行时对象中，不写日志、不持久化。
- 本 Step 不新增 FFI 命令、不修改 Flutter/Dart 客户端协议、不让自定义 Relay
  转发 WebRTC 媒体；后续 signaling adapter 通过现有控制面注入 SDP/ICE。

## 影响

WebRTC Audio/Video/DataChannel 现在有独立的 native owner 和可测试的 QoS/恢复语义：
媒体恢复是“丢弃旧帧 + 请求关键帧”，而不是向 Delivery/Recovery 层塞入媒体 payload。
PeerConnection 的 sans-I/O packet pump 让未来的 UDP socket、STUN/TURN 与生命周期
可以由 native App Scope 组合，客户端仍只接收上层事件。

## 验证

- signaling state machine 覆盖 offer/answer 先后、版本递增和输入长度检查。
- Media QoS 覆盖媒体过期、video overflow、断线丢帧、keyframe request 和
  DataChannel backpressure。
- PeerConnection 本地生成的 offer 覆盖 Audio、Video、DataChannel 三类媒体段；
  WebRTC crate 使用 locked workspace 测试和 Clippy 验证。
