# MSap

Speech Analysis Program for macOS. AppKit port of WinSap, and the third member
of the SAP family:

| Program | Platform | UI |
|---|---|---|
| SAP | DOS | original |
| WinSap | Windows (x64 and x86) | Win32 / GDI |
| XSap | Linux | GTKMM 4 |
| **MSap** | **macOS** | **AppKit / Core Graphics** |

Version 3.1.0, matching WinSap and XSap.

## Status

**Complete.** MSap builds as a native AppKit bundle and supports waveform,
spectrum and spectrogram display; multi-track panels; mouse marking and WAV
export; AudioQueue playback; navigation; raw PCM sample rate configuration;
toolbar actions; status reporting; and command-line file opening. The user
interface has been brought to parity with WinSap and XSap. A panel's first
track opens in View All; a later track expands the view only when it is longer
than the tracks already present. A shorter track returns the shared view to
frame zero without changing its zoom span, keeping file beginnings aligned.
Every waveform uses that shared timeline, so shorter tracks are not stretched
to fill the panel. The portable model and analysis tests pass on macOS, on both
architectures.

The open panel warns before Parameter mode opens a non-`.par` file, or
Waveform/Spectrum mode opens a file outside `.wav`, `.pcm`, `.dat`, `.raw`,
`.exc`, `.res`, and `.cod`. Parameter mode lists only `.par` files, selecting a
`.par` file selects Parameter mode, and a `.par` file opened any way (panel or
command line) always loads as parameter text.

Help > MSap Help (⌘?) opens a scrollable guide to opening files, moving
through a file, marking and saving, playback, spectrum and spectrogram, every
shortcut key and settings, adapted from WinSap's Help
Topics for the Mac (⌘ keys, two-finger click, Finder). Inside it ⌘F searches
and ⌘W or Escape closes it. MSap > About MSap shows the version.

## Stereo files and playback

- WAV files may be mono or stereo, in 8-bit unsigned, 16, 24 or 32-bit
  integer PCM or 32/64-bit IEEE float, including WAVE_FORMAT_EXTENSIBLE
  headers. They are converted to 16-bit samples in memory on load with
  WinSap's rounding and clipping, and their embedded sample rate is used for
  playback. Other formats and files with more than two channels are refused
  with a message naming the problem. Saved/exported WAV files are 16-bit mono.
- A stereo WAV opened from Open Up, Open Down or the command line puts its
  left channel in an upper-panel slot and its right channel in the same
  lower-panel slot (labelled [L] and [R]). While a stereo file is open the two
  panels stay in sync: frame size, frame number, navigation/zoom, limits and
  marks apply to both (limits only when both panels are FFT or neither is).
  If the lower panel already holds files, MSap asks whether to close them
  first. Several stereo and mono files can share the upper panel, but mono
  files cannot be opened in the lower panel while a stereo file is open.
  Closing either channel closes both.
- Waveform and FFT mode never mix with stereo: a stereo file opened in FFT
  Amplitude mode must be the only open file (MSap offers to close the rest),
  and while a stereo file is open in waveform mode no file may be opened in
  FFT Amplitude mode.
- Left-clicking a file name plays the whole file; a stereo file plays in
  stereo through a two-channel AudioQueue with the cursor in both panels.
  Play Up/Down plays the marked area of the first file in that panel that has
  data there (a stereo file in stereo). Play All queues every open waveform or
  FFT-amplitude slot in upper-then-lower order, playing each stereo file once.
  Stop or right-click cancels the active item and clears the queue.
- Right-clicking a file name opens a context menu: Close file and Play marked
  area (this file only). For a stereo file it also offers Play this channel
  (the whole left or right channel) and Play marked area in this channel; its
  Play marked area plays both channels. FFT-amplitude files play with the
  cursor running over the spectrogram (it is hidden in the single-frame
  spectrum-line view), and a mark on a spectrogram is drawn as white lines at
  its edges.

## Dependencies

None beyond the macOS SDK. Cocoa, Core Graphics, Core Text and AudioToolbox all
ship with the system, so there is nothing to install.

Requires macOS 12.0 or newer, on Apple silicon or Intel. To build you also
need CMake 3.20+ and the Xcode command line tools; full Xcode is needed only
to generate the Xcode project.

## Build

```sh
./build.sh                  # host architecture, builds and runs the tests
open build/msap.app
```

```sh
./build.sh --universal      # arm64 + x86_64, before moving to an Intel Mac
./build.sh --xcode          # generate build-xcode/msap.xcodeproj
./build.sh --help           # all options
```

See `BUILD.md` for the details, including why a single architecture build is
not enough before handing the source to an Intel machine.

On a non-Apple platform `cmake` builds only the portable core and its tests,
which is a useful check that no UI code has leaked into the shared layer.

## Layout

```
src/core/           analysis code shared with WinSap and XSap - no toolkit headers
src/Model.*         document model, panels and tracks - portable C++17
src/MsapApp.h/.mm   the entire AppKit layer behind a pimpl facade
src/AudioPlayer.*   AudioQueue playback
src/HelpWindow.*    Help window shared with MacMDV, MPlayer and MVista
src/main.mm         entry point
tests/              portable tests, run on macOS and Linux alike
assets/icons/       toolbar artwork plus the MSap application icon (msap.png)
BUILD.md            how to build for either architecture and in Xcode
```

## License

MSap is distributed under the MIT License. The Viridis and Inferno
spectrogram palettes contain sampled colour data derived from Matplotlib; see
`THIRD_PARTY_NOTICES.md` for its copyright notice, license terms and a summary
of MSap's changes.
