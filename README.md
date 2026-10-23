# TT Custom

This is the deliberately small iOS TeamTalk client prototype. It has two screens:

1. Server connection details.
2. Microphone/speaker selection and audio controls after joining the root channel.

Audio uses TeamTalk's synchronized iOS Voice-Processing I/O device when echo cancellation is enabled. That lets Apple's audio session and hardware path provide acoustic echo cancellation. Turning it off uses Remote I/O instead.

The audio screen exposes:

- available microphone selection through `AVAudioSession`
- built-in speaker override and the system `AVRoutePickerView` for AirPods/Bluetooth/other outputs
- iOS preferred I/O buffer duration
- TeamTalk receive playout/de-jitter buffer
- microphone transmission toggle

Build from this directory with:

```sh
xcodebuild -project TTCustom.xcodeproj -scheme "TT Custom" -sdk iphoneos -configuration Debug build
```

The TeamTalk SDK license values remain in `iTeamTalk/License.swift`; they are intentionally blank in this checkout. A valid TeamTalk SDK license is required for redistribution of an app embedding the SDK.
