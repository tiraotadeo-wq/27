# Building 3105 v3.0

## Requirements

- **Xcode 16.2+** (for iOS 27 SDK)
- **macOS 14.0+** (Sonoma or later)
- **Minimum deployment target:** iOS 16.0 (features gate on iOS version at runtime)

## Clone

```bash
git clone https://github.com/YangJiiii/3105.git
cd 3105
git checkout v3.0
open ThreeOneOSFive.xcodeproj
```

## Build (unsigned IPA for sideloading)

```bash
xcodebuild \
  -project ThreeOneOSFive.xcodeproj \
  -scheme 3105 \
  -destination "generic/platform=iOS" \
  -configuration Release \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER="com.apple.mobile.MobileHouseArrest" \
  build
```

Package the resulting `.app` bundle into an IPA:

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "*.app" -path "*/Release-iphoneos/*" | head -1)
mkdir -p Payload
cp -r "$APP" Payload/
zip -r 3105-v3.0-unsigned.ipa Payload/
rm -rf Payload
```

## Runtime access methods

| iOS | Backend | How it works |
|-----|---------|--------------|
| 17–18 | Kernel exploit (opa334) | Opt-in button in Home tab, runs once per reboot |
| 26 | MHA-C2 | Automatic — bundle ID `com.apple.mobile.MobileHouseArrest` |
| **27+** | **BookmarkManager** | Automatic — Security-Scoped Folder Mounts |

**iOS 27 note:** BookmarkManager works on ALL 27.x releases (27.0, 27.1, 27.2, 27.3, …).  
There is no build allowlist. If `major >= 27`, the app uses BookmarkManager.

## Signing

### Enterprise cert (recommended)
- Sign with an enterprise certificate.
- Bundle ID must stay `com.apple.mobile.MobileHouseArrest`.
- All three backends work automatically.

### Standard Apple ID (SideStore / AltStore / ESign)
- Requires accepting the entitlement `com.apple.private.security.storage.AppDataContainers`.
- On non-enterprise signing this entitlement may be stripped; BookmarkManager will fall back gracefully.

## Tag as v3.0

```bash
git tag v3.0
git push origin v3.0
```
