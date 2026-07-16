# DMM6500 Control

A native macOS (SwiftUI) app for remote-controlling a Keithley
DMM6500 6½-digit bench multimeter over the network. 
It talks directly to the device's own SCPI raw-socket port
on your local network.

![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)

> Built with AI for personal use with a specific device on hand — no promised
> support or roadmap. Partially verified against real hardware (see
> [Caveats](#caveats) below); you're welcome to copy, use, and modify it
> for your own setup.

## What it does

- On connect, reads whatever function, range, filter, and NPLC/bandwidth
  the instrument is already set to (front panel, a previous session,
  whatever) and just displays that — it never forces its own defaults
  onto the device. Changing any of them from the UI is entirely optional.
- Live measurement readout for 12 general-purpose functions: DC/AC
  Voltage, DC/AC Current, 2-Wire/4-Wire Resistance, Diode, Capacitance,
  Continuity, Temperature, Frequency, and Period, with the displayed unit
  and decimal count matching the instrument's own range-based scaling
  (e.g. a 100mV range shows as mV, not a truncated V reading)
- Polling rate adapts to a selectable sample-rate preset (Fast/Medium/Slow):
  DC functions/Resistance/Temperature/Diode use NPLC, AC functions use
  detector bandwidth (3/30/300 Hz), Frequency/Period use Aperture (2-273ms)
  — the poll interval itself is derived from whichever speed value is in
  effect, since the instrument can't return a reading faster than it takes 
  to integrate/settle one. A compact "Rate" dropdown
  plus a small advanced-override button exposes the raw value under a
  Custom preset, labeled to match whichever mechanism the current function
  actually uses
- Range control as a dropdown of the instrument's actual fixed ranges for
  the current function (plus Auto), not free-form numeric entry — DC/AC
  Current's 10A range is always listed as "10A (Rear)" but greyed out
  unless the rear AMPS terminals are physically selected (queried via
  `ROUTe:TERMinals?`, since there's no remote way to switch terminals)
- A simple Filter on/off toggle ("Repeat 10x" when on) 
- Diode shows a Bias (test current) level dropdown (10µA/100µA/1mA/10mA)
  in place of Range
- Range/Filter/Sample Rate controls are hidden entirely for functions 
  that don't support them, instead of cluttering the
  window with disabled controls
- Read-only status badges on the primary reading, abbreviated the way the
  instrument itself does — "Front"/"Rear" terminals; "AZero" (shown only
  when on, like the instrument's own annunciator - no "off" badge); DC
  Voltage's input impedance as "10 MΩ"/"AutoΩ". No editing UI for these,
  just a reflection of whatever's already set
- Overrange reads as "Overflow", or "Open" on Resistance/Continuity 
- A live graphing window, Start/Stop/Clear
- Localized into English, German, Spanish, Catalan, French, European
  Portuguese, Brazilian Portuguese, Dutch, Italian, Polish, Czech, Danish,
  Swedish, Norwegian (Bokmål), Finnish, Chinese (Simplified), Japanese, and
  Korean


## Deliberately out of scope

Scanner cards, TSP scripting, reading buffers/`TRACe` management, the
`TRIGger:BLOCk` trigger-model subsystem, and the high-speed digitizer mode
are all excluded by design, to keep this a simple measurement/mode/rate
control surface rather than a full instrument-automation tool.

## Caveats

Originally written against the official Keithley DMM6500
Reference Manual (DMM6500-901-01 Rev. B); some details have since been
corrected against a real unit, but not everything has been exercised yet.

Confirmed against real hardware:
- DC Voltage/Current, Resistance, and Temperature use `NPLCycles` as
  documented. AC Voltage/Current reject both `NPLCycles` and `APERture` -
  they're controlled by `DETector:BANDwidth` instead, an enumerated
  low-frequency filter setting that only accepts 3, 30, or 300 Hz (not a
  continuous integration time, despite what the manual's general pattern
  suggested).
- Frequency and Period reject NPLC entirely and use `APERture` (seconds,
  2ms-273ms, default 200ms) instead - confirmed both against hardware and
  against the manual's own prose (Section 4, p.4-68/4-69): "When using
  NPLCs to adjust the rate, frequency and period cannot be set. However,
  when using aperture to adjust the rate, aperture can be set for both
  frequency and period." Diode also uses NPLC (manual-confirmed via its
  own dedicated Measure Settings table, p.3-35/3-36, and its own row in
  the Aperture Details table, p.12-77 - not yet hardware-tested).
  Capacitance has a fixed, non-adjustable aperture and Continuity's NPLC
  is always fixed at 0.006 PLC (both manual-confirmed, p.4-32/4-23) - so
  neither gets a Sample Rate control.
- A full re-read of the manual found that its "Functions" applicability
  tables attached to `NPLCycles`/`APERture`/`DETector:BANDwidth`/`AVERage`
  command reference pages are generic **copy-pasted boilerplate**, not
  real per-function tables - they even list `DIGitize:VOLTage`/
  `DIGitize:CURRent` under commands the manual's own prose says don't
  apply to digitize functions at all. The function-specific "Measure
  Settings" tables in Section 3 (pp. 3-29 to 3-38) are the reliable
  source; anything sourced only from the generic list should be treated
  as unconfirmed.
- Fixed two client-side bugs found via live testing: (1) the Range
  dropdown could show a stale fixed range while the device was genuinely
  still auto-ranging, because `RANGe:AUTO?`'s reply was checked with exact
  string equality against `"1"` rather than parsed numerically; and (2) a
  single transient failure of the background range-refresh query (every
  2s) cleared the cached range value entirely, which made the *next*
  reading render in a fallback (non-range-aware, wrong-decimal-count)
  format for one frame — visible as an occasional flash to a value like
  "10.000000V" that doesn't match the instrument's own 6.5-digit display.
  Confirmed as a client bug (not an instrument auto-ranging artifact, as
  first suspected) since the DMM's own screen never showed it, and the
  digit count was a giveaway. Both are fixed in `DeviceClient.getRange`/
  `AppModel.refreshConfigIfClean`.
- Diode bias/test current (`SENSe:DIODe:BIAS:LEVel`, 10µA/100µA/1mA/10mA,
  default 1mA) and DC Voltage input impedance
  (`SENSe:VOLTage:DC:INPutimpedance`, `MOHM10`/`AUTO`, default `MOHM10`)
  are manual-verified with page citations, not yet tried against real
  hardware.
- Auto Zero (`SENSe:<f>:AZERo`, per-function not global — there's no
  `SYSTem:AZERo`) **is** hardware-confirmed, including which functions
  reject it: it returns SCPI error -113 "unknown header" on Continuity,
  Capacitance, Frequency, and Period, and isn't available on AC Voltage/AC
  Current either — the manual's shared applicability table implied
  broader support than the instrument actually has. Only queried for DC
  Voltage/Current, Resistance (2W/4W), Diode, and Temperature
  (`DMMFunction.supportsAutoZero`).
- 1 mF removed from the Capacitance range list — confirmed not to exist on
  the user's unit despite being in the manual's range table.

Still best-effort / not yet confirmed:
- Averaging filter (`AVERage`) support is only confirmed-by-worked-example
  for DC Voltage, DC Current, and 2-Wire Resistance (`Models.swift`
  `supportsFilter`). The manual's only *explicit* exclusion anywhere is
  digitize functions (not used by this app at all) - meaning the filter
  quite possibly works on every other function too (AC Voltage/Current,
  4-Wire Resistance, Temperature, Diode, Capacitance, Continuity,
  Frequency, Period), but none of those has a worked example to confirm
  it, and Auto Zero already taught this app that an unconfirmed function
  can visibly error (-113) on the instrument - so filter support was left
  exactly as before rather than widened on an inferred-only basis. Worth
  hardware-testing `<f>:AVERage:STATe ON` for the missing functions if you
  want that filter option to show up in the app for them.
- Which functions support range control (`DMMFunction.supportsRange`) is
  still a best-effort mapping — revisit if your unit disagrees.
- The fixed range lists per function (`DMMFunction.fixedRangeOptions`) are
  drawn from the manual's own range table (p.12-105), not yet confirmed
  against this specific unit. Also not modeled: 4-Wire Resistance has
  fewer available ranges when offset compensation is turned on (the full
  list is always shown here).
- On quit, the app sends `TRIGger:CONTinuous RESTart` followed by
  `LOGOUT` (both bare commands, no arguments) to resume the instrument's
  own free-running continuous-measurement loop and then release its
  remote-control lockout, so the front panel doesn't sit there afterward
  idle-between-triggers and still reporting an active LAN session.
  `LOGOUT` itself is **hardware-confirmed** (the more common SCPI/
  Keithley-family convention `SYSTem:LOCal` does *not* work on this
  instrument - a direct user report found the real command by searching
  the manual text for "logout"). `TRIGger:CONTinuous RESTart` is the same
  report's confirmed next step in that sequence and matches what a user
  of this app directly observed (front panel stuck on "IDLE" instead of
  "CONT" after quitting) 

Please treat the app as a work in progress rather than a fully
field-tested tool, and expect to tweak the command details in
`DeviceClient.swift`/`Models.swift` against your own unit's behavior.

## Installing the pre-built app (unsigned binary)

This app is **ad-hoc signed** (`codesign --sign -`), not signed with a paid
Apple Developer ID or notarized — this is a personal/hobby tool, not a
distributed product. macOS Gatekeeper will therefore refuse to open it
normally the first time, usually with a dialog saying it "cannot be opened
because Apple cannot check it for malicious software" (wording varies by
macOS version). This is expected — here's how to get past it:

**Option A — System Settings (no Terminal needed):**
1. Try to open the app once (double-click it) — it'll be blocked.
2. Open **System Settings → Privacy & Security**, scroll down — you should
   see a note that the app was blocked, with an **Open Anyway** button.
   Click it.
3. Try opening the app again; confirm in the follow-up dialog (may ask for
   your password or Touch ID).

**Option B — Terminal (one command, faster):**
```sh
xattr -cr "/path/to/DMM6500 Control.app"
```
This clears the quarantine flag macOS attaches to anything downloaded from
the internet. After this, the app opens normally.

You only need to do this once per copy of the app.

## Building it yourself

No Xcode project or license required — this is a plain Swift Package
Manager executable, hand-wrapped into a `.app` bundle by a small script.

**Requirements**: macOS 14+, and the Xcode **Command Line Tools** (not the
full Xcode.app):
```sh
xcode-select --install
```

**Build and package:**
```sh
cd dmm6500-control
swift build -c release      # compiles the binary
./build_app.sh               # wraps it into DMM6500 Control.app
```

`build_app.sh` copies the compiled binary, the app icon, and all 18
localization bundles into a proper `Contents/…` app structure, writes an
`Info.plist`, and ad-hoc code-signs the result. The finished
`DMM6500 Control.app` appears in the `dmm6500-control/` directory — drag it to
`/Applications` if you'd like it there permanently. Since you signed it
yourself locally, you won't hit the Gatekeeper warning above for your own
build (quarantine is only attached to files that arrived via download,
AirDrop, etc., not ones compiled on your own machine).

To rebuild after making changes, just re-run both commands — `build_app.sh`
always does a fresh `swift build` itself, so a bare `./build_app.sh` is
enough for subsequent builds.

## License

MIT — see the `LICENSE` file.
