# Transit Times

An iOS app and widgets that show travel times from your current location to 5 preset destinations, by subway or car, powered by Google Maps Platform (Routes API).

- Per-destination **train** or **car** mode
- Subway next-train times, line badges and live **MTA service alerts** (NYC)
- Car **live-traffic** conditions
- **Leave now / Leave at / Arrive by**
- Home screen widgets (medium, large, single destination) and Lock Screen widgets
- Updates as your location changes

## Build it

1. Open `TransitTimes.xcodeproj` in Xcode 16+.
2. For **both** targets (`TransitTimes`, `TransitWidget`) set your Team under Signing & Capabilities and change the bundle IDs (`com.samvannette.transittimes[.widget]`) to your own.
3. Change the App Group `group.com.samvannette.transittimes` to your own in both `Config/*.entitlements` files and in `Shared/Models.swift` (`Shared.groupID`).
4. Run on an iPhone (iOS 17+).
5. In the app, tap the gear and paste a Google API key with the **Routes API** enabled. The key stays on your device.
6. Edit the 5 destinations (the defaults are New York placeholders).

MTA alerts only apply to NYC subway lines; elsewhere train times work without alert badges.
