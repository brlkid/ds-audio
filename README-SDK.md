# Bundled TeamTalk SDK

This app is intentionally self-contained. The native SDK files required by
the app are stored in `Vendor/TeamTalkSDK/`:

- `TeamTalk.h` — the C API header used by `TeamTalkKit`.
- `libTeamTalk5.a` — the universal native TeamTalk library used by the app.

The archive currently contains the device `arm64` and Intel simulator
architectures. Building for an Apple Silicon simulator requires adding an
arm64 simulator slice or replacing this archive with an appropriate
XCFramework.

The TeamTalk SDK remains subject to its original license and redistribution
terms. The app’s SDK license values remain intentionally blank in
`iTeamTalk/License.swift`.
