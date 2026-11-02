# Terminal — iOS SSH client

Apple-grade SSH/SFTP terminal for iPhone/iPad. Sideloaded IPA.

## Stack
- SwiftUI, iOS 17 target, builds on Xcode 26 (GitHub Actions)
- `Citadel` (SSH/SFTP on swift-nio-ssh fork), `SwiftTerm` (xterm), `Runestone` (editor)
- Secrets → Keychain `ThisDeviceOnly`; profiles → Codable JSON (FileProtectionComplete)

## Build
- Project is generated: `brew install xcodegen && xcodegen` → `Terminal.xcodeproj`
- CI: `.github/workflows/ios.yml` produces unsigned `Terminal.ipa` + `.tipa` artifacts
- Local machine has Xcode 14.2 only — do NOT build locally; CI is the source of truth

## Architecture
- `App/` — entry, AppState (stores + engine + keepalive + biometry lock), privacy curtain
- `Models/` — ServerProfile/AuthMethod/PortForward/Snippet/StoredSSHKey/KnownHost/AppSettings/TerminalTheme
- `Storage/Stores.swift` — JSONStore + ProfilesStore/KeysStore/KnownHostsStore/SnippetsStore/SettingsStore (all @MainActor ObservableObject)
- `Vault/` — Keychain, BiometricGate, SSHWire (wire format), OpenSSHKeyParser (openssh-key-v1 + bcrypt + AES-CTR import), KeyVault (generate ed25519/SE-P256/ecdsa, auth methods, export), BlowfishTables/BCryptPBKDF/AESCTR
- `SSH/` — SSHConnection (actor, multiplexed transport + bastion jump + prepared auth), HostKeyTrustValidator (TOFU), ShellChannel (PTY bridge over `withPTY`), SFTPService, PortForwarder (-L via NWListener+directTCPIP, -R via runRemotePortForward, -D SOCKS5), SessionEngine (@MainActor pool + NWPathMonitor + keepalive), TerminalSession (per-tab VM + tmux reattach)
- `Terminal/` — TerminalSurface (UIViewRepresentable + delegate), KeyboardAccessoryView (Esc/Tab/Ctrl/arrows), TerminalScreenView
- `KeepAlive/` — silent-audio keep-alive (`.mixWithOthers`: doesn't touch music/VPN/Now Playing)
- `Design/` — terminalGlass() (iOS 26 glassEffect via `#if swift(>=6.2)` + materials fallback), Haptics, StatusDot, EmptyState

## Invariants — do not break
- No visible technical text in UI: statuses are color/motion (StatusDot), errors are one human phrase
- No "About"/version screens, no telemetry, no analytics
- Password tag: `password.<profile.id.uuidString>`; key material: `sshkey.<id>`; passphrases: `sshpass.<id>`
- Auth is prepared async (Keychain/biometry) BEFORE connect — Citadel auth closure must be trivially sync
- Do NOT set `SSHClientSettings.algorithms` — the nio-ssh fork defaults ARE the strict allowlist (AES-GCM, ECDH+Curve25519, ed25519/ECDSA). `.all` would re-add AES-CTR, group14-sha1, ssh-rsa
- KeepAlive must NEVER break user music/VPN/NowPlaying — only `.mixWithOthers` audio
- iOS 26 APIs only via `#if swift(>=6.2)` + `if #available` — must compile on older SDKs too

## Icons
- Regenerate: `swift scripts/make_icons.swift` (writes AppIcon.appiconset)
