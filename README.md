# D's Audio

D's Audio is a high-quality chat-room audio client for iPhone and iPad. It is
designed for people who want the relaxed feel of a persistent voice room with
better audio controls, clearer status information, and more control over how
their device handles sound.

## Features

- Persistent room-based voice conversations
- Microphone input selection through the iOS audio session
- Speaker, wired-headset, Bluetooth, and AirPods routing
- Optional native call controls
- Apple audio processing controls, including echo cancellation, noise
  suppression, and automatic gain control
- Optional WebRTC processing controls
- Microphone, system-audio, and monitor levels
- System-audio sharing through the iOS content-sharing picker
- Configurable audio bitrate, DTX, RED, limiter, and I/O buffer settings
- Per-participant playback volume
- In-room text chat and spoken announcements
- Connection, audio-stream, and transport diagnostics
- VoiceOver-oriented controls and status messages

## Requirements

- macOS with Xcode
- An iPhone or iPad running a supported iOS version
- A running D's Audio server with a compatible LiveKit deployment
- A development signing team configured in Xcode for device installation

The server URL, room, account, and display name are entered on the connection
screen. The app does not include server credentials.

## Building

From this directory:

```sh
xcodebuild \
  -project TTCustom.xcodeproj \
  -scheme "TT Custom" \
  -sdk iphoneos \
  -configuration Debug \
  build
```

To install on a connected device, select the `TT Custom` scheme and a signed
device destination in Xcode, then run the app.

## Project layout

- `iTeamTalk/` — the iOS application and user interface
- `LiveKitTransport/` — the UI-independent LiveKit transport package
- `iTeamTalkTests/` — application tests
- `TTCustom.xcodeproj/` — Xcode project

The transport layer owns room connection, publication, subscription, audio
mixing, and transport statistics. The application layer owns settings,
accessibility, routing controls, announcements, and presentation.

## Status

D's Audio is under active development. The current focus is dependable,
low-latency audio, stable routing, accessible controls, and a polished room
experience across iPhone, iPad, and desktop clients.

## License

The application source and its dependencies may have different license terms.
Review the license for each bundled or externally linked dependency before
redistributing a build or offering a hosted service.
