/************************************************************************
 *
 *  MSap - Main Application Implementation
 *
 *  FILE:      MsapApp.mm
 *
 *  PURPOSE:   The AppKit half of MSap. Counterpart of WinSap
 *             src/x64/WinsapApp.cpp and XSap src/XsapApp.cpp: it owns the
 *             window, the menus, the two panels and all drawing. Every
 *             Objective-C symbol in the program lives in a .mm file; the
 *             analysis core underneath stays plain C++17.
 *
 *  STATUS:    COMPLETE. File I/O, waveform and spectrum rendering,
 *             spectrogram caching, marking, playback, menus, toolbar and
 *             status reporting are implemented with AppKit.
 *
 *  Update:    2026.1
 *             2026.11 .par files always open as parameter text; the open
 *                     panel links Parameter Text mode to the .par extension
 *
 ************************************************************************/

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "MsapApp.h"
#include "HelpWindow.h"

#include "AudioPlayer.h"
#include "Model.h"
#include "core/SapFft.h"
#include "core/SapSpectrogramPalette.h"
#include "core/SapWaveFile.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <filesystem>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

// ===========================================================================
// Shared document state
//
// The Objective-C views need to reach the C++ model. A single owning struct
// is handed to them as a raw pointer; it outlives every view because MsapApp
// owns it and tears the window down first.
// ===========================================================================
namespace {

// The part of a panel's state that stereo files keep equal in both panels.
struct StereoView {
    size_t frameBegin = 0;
    size_t visibleFrameCount = 0;
    size_t frameLength = 0;
    size_t frameSkip = 0;
    double lowerLimit = 0.0;
    double upperLimit = 0.0;
    std::optional<msap::SampleRange> mark;
    std::optional<int64_t> pendingMark;

    bool operator==(const StereoView& other) const noexcept
    {
        return frameBegin == other.frameBegin &&
               visibleFrameCount == other.visibleFrameCount &&
               frameLength == other.frameLength && frameSkip == other.frameSkip &&
               lowerLimit == other.lowerLimit && upperLimit == other.upperLimit &&
               mark.has_value() == other.mark.has_value() &&
               (!mark.has_value() ||
                (mark->begin == other.mark->begin && mark->end == other.mark->end)) &&
               pendingMark == other.pendingMark;
    }
};

struct Document {
    msap::Panel upperPanel{true};
    msap::Panel lowerPanel{false};

    // WinSap keeps the raw PCM rate as an application wide setting rather than
    // a per file one, and stores it in the registry. On macOS the natural home
    // is NSUserDefaults; see rawSampleRate() below.
    unsigned int rawSampleRate = 16000;

    // WinSap ships Tools ▸ Lock Starting Frame CHECKED and XSap defaults
    // lockStarts_ to true, so the panels start out moving together.
    bool lockStartFrame = true;

    // Which panel the Up/Down commands act on. It is deliberately invisible:
    // MSap draws both panels identically because there is no selected-panel
    // concept to show.

    // Tools / Add Down to Up. Draws the down panel's waveform over the upper
    // one in red so two takes can be compared.
    bool overlayLower = false;

    // True while a drag is building a mark, which the status bar reports as
    // "Mark Left" exactly as WinSap does between the two mark clicks.
    bool pendingMarkUpper = false;
    bool pendingMarkLower = false;
    // Where the pending mark started, so a stereo file can copy it across.
    int64_t pendingMarkSampleUpper = 0;
    int64_t pendingMarkSampleLower = 0;

    // Last views the stereo sync saw, used to tell which panel was changed.
    StereoView lastUpperView;
    StereoView lastLowerView;
    bool syncingStereo = false;

    std::string coordinateText;
    std::string hoverFileText;
    std::string statusText = "Ready";

    float spectrogramRangeDb = msap::core::kDefaultDynamicRangeDb;
    msap::core::SpectrogramPalette spectrogramPalette =
        msap::core::kDefaultSpectrogramPalette;
    msap::AudioPlayer audioPlayer;
    std::atomic<std::uint64_t> playbackGeneration{0};
    std::vector<std::filesystem::path> startupFiles;
};

constexpr NSInteger kDefaultWindowWidth = 1280;
constexpr NSInteger kDefaultWindowHeight = 800;
constexpr CGFloat kStatusBarHeight = 24.0;

NSString* const kDefaultsRawSampleRate = @"RawSampleRate";
NSString* const kDefaultsSpectrogramPalette = @"SpectrogramPalette";
NSString* const kDefaultsSpectrogramRangeDb = @"SpectrogramRangeDb";
NSString* const kDefaultsWarnParameterExtensionMismatch =
    @"WarnParameterExtensionMismatch";
NSString* const kDefaultsWarnBinaryExtensionMismatch =
    @"WarnBinaryExtensionMismatch";

// WinSap's Help Topics (the x64 text, since MSap opens stereo files) with
// the Mac's menus, keys and settings.
NSString* MsapHelpMarkup()
{
    return @"# MSap Help\n"
           @"MSap is a speech and audio analysis program. It shows audio as waveforms, spectra and spectrograms "
           @"in two panels, **Up** and **Down**, each holding several files on a shared timeline, so recordings "
           @"can be compared frame by frame.\n"
           @"## Opening files\n"
           @"Choose **File ▸ Open Up** (F3) or **Open Down** (F4), pick a file, and choose how to show it in the "
           @"open panel:\n"
           @"- **Waveform** - audio: WAV, or raw 16-bit PCM (.pcm, .dat, .raw, .exc, .res, .cod), drawn as a waveform.\n"
           @"- **Spectrum / Spectrogram** - audio drawn as a spectrum or spectrogram.\n"
           @"- **Parameter Text** - a .par text file of parameters, drawn as curves.\n"
           @"WAV files may be 8, 16, 24 or 32-bit integer PCM or 32/64-bit float, mono or stereo. Raw PCM uses the "
           @"rate set with **Options ▸ Set Raw Samplingrate**.\n"
           @"The first file in a panel opens in View All. Every file is drawn against its panel's timeline, so a "
           @"sound at frame 150 stays at frame 150 whatever else is open.\n"
           @"### Stereo files\n"
           @"A stereo WAV opens its left channel in the upper panel and its right channel in the lower one, "
           @"labelled [L] and [R]. The two panels then share frames, zoom and marks, and closing either "
           @"channel closes both.\n"
           @"> A stereo file shown as a spectrum or spectrogram must be the only open file. While a stereo file is "
           @"open as a waveform, no file can be shown as a spectrogram, and mono files cannot open in the lower panel.\n"
           @"## Moving through a file\n"
           @"The keys move the upper panel when it has files, otherwise the lower one. With **Tools ▸ Lock Starting "
           @"Frame** (⌘L) on, the lower panel follows the upper panel's start.\n"
           @"← / →\tOne frame back or forward\n"
           @"↑ / ↓\tOne screen back or forward\n"
           @"Page Up / Page Down (fn ↑ / fn ↓)\tBack or forward by the frame skip\n"
           @"Home / End (fn ← / fn →)\tStart or end of the longest file\n"
           @"The **Up** and **Down** menus set each panel's Frame Length, Goto Frame, Number of Frames (the frames "
           @"on screen), amplitude Limit and Page Numbers.\n"
           @"## Marking and saving\n"
           @"Right-click a waveform twice to mark a range; right-click a third time to clear it. On a trackpad, "
           @"click with two fingers. **File ▸ Save as** (F2) writes the marked range of the first file in the upper "
           @"panel as a WAV file, or of the lower panel when the upper one has no mark. **Window ▸ Look Marked "
           @"Block** (⌘F4) fills the screen with the mark.\n"
           @"## Playing\n"
           @"- **Play All** (F5) plays every open audio file, upper panel first.\n"
           @"- **Play Up** (F6) and **Play Down** (F7) play the marked range of the first file in that panel.\n"
           @"- Click a file name to play the whole file. A stereo file always plays in stereo.\n"
           @"- Right-click a file name for **Close file** and **Play marked area**; a stereo file adds "
           @"**Play this channel** and **Play marked area in this channel**.\n"
           @"- **Stop** (F8), or a right-click, stops playing and clears the queue.\n"
           @"A cursor follows playback, over the spectrogram too.\n"
           @"## Spectrum and spectrogram\n"
           @"A spectrum view of 1024 samples or fewer is a line spectrum, level against frequency. Raising Number "
           @"of Frames lengthens the analysis window for finer frequency detail. A longer view becomes a "
           @"spectrogram, frequency against time, with a mark shown as white lines at its edges.\n"
           @"The status bar reads (sample, amplitude) on a waveform, (Hz, dB) on a spectrum and (time, Hz) on a "
           @"spectrogram. The contrast and colour map are remembered for the next start.\n"
           @"## Shortcut keys\n"
           @"### Files\n"
           @"F3\tOpen Up\n"
           @"F4\tOpen Down\n"
           @"F2\tSave the marked range as\n"
           @"F9\tClose files...\n"
           @"⌘W\tClose all\n"
           @"⌘A\tReload all\n"
           @"⌘Q\tQuit MSap\n"
           @"### Playing\n"
           @"F5\tPlay all\n"
           @"F6\tPlay Up\n"
           @"F7\tPlay Down\n"
           @"F8\tStop\n"
           @"### Panels\n"
           @"⌘F / ⇧⌘F\tFrame length, upper / lower panel\n"
           @"⌘G / ⇧⌘G\tGoto frame, upper / lower panel\n"
           @"⌘N / ⇧⌘N\tNumber of frames, upper / lower panel\n"
           @"### View\n"
           @"⌘F7\tZoom in\n"
           @"⌘F8\tZoom out\n"
           @"⌘F9\tView all\n"
           @"⌘F4\tLook at the marked block\n"
           @"⌘F5\tExpand the amplitude\n"
           @"⌘F6\tCompress the amplitude\n"
           @"⌘F2\tAdd Down to Up: overlay the lower waveform in red\n"
           @"⌘F10\tSync panels: copy frame length, count and start\n"
           @"⌘L\tLock starting frame\n"
           @"### Spectrogram\n"
           @"⌘U\tContrast up (narrower dB range)\n"
           @"⌘D\tContrast down (wider dB range)\n"
           @"⌘P\tNext colour map: Viridis, Inferno, Jet, Grey\n"
           @"### Help\n"
           @"⌘?\tThis page\n"
           @"Esc or ⌘W\tClose this page\n"
           @"> On a Mac laptop keyboard, hold fn with F2 to F10, or turn on “Use F1, F2, etc. keys as standard "
           @"function keys” in System Settings ▸ Keyboard. If Mission Control or another system shortcut takes a "
           @"function key, change it in System Settings ▸ Keyboard ▸ Keyboard Shortcuts.\n"
           @"## Settings\n"
           @"The raw sampling rate (with **Options ▸ Save Raw Samplingrate**), spectrogram contrast, colour map, "
           @"window position and open-file warnings are kept in the macOS defaults for org.tianwang.msap, in "
           @"~/Library/Preferences/org.tianwang.msap.plist.\n";
}

NSColor* HelpRgb(int red, int green, int blue)
{
    return [NSColor colorWithSRGBRed:red / 255.0 green:green / 255.0 blue:blue / 255.0 alpha:1.0];
}

/*****************************************************************************
 * loadRawSampleRate
 *
 * NSUserDefaults replaces WinSap's registry key and XSap's key file. A value
 * of zero means nothing was ever stored, so the 16000 Hz default stands. The
 * rate has to be read before the window is built: WinSap had a bug where the
 * status bar was painted from the default because the load ran afterwards.
 *
 *****************************************************************************/
unsigned int loadRawSampleRate()
{
    const NSInteger stored =
        [[NSUserDefaults standardUserDefaults] integerForKey:kDefaultsRawSampleRate];
    return stored > 0 ? static_cast<unsigned int>(stored) : 16000u;
}

/*****************************************************************************
 * saveRawSampleRate
 *
 * Only called from the Save Raw Samplingrate menu item, never on quit. The
 * window geometry is a separate concern and AppKit persists that itself when
 * the window has a frame autosave name.
 *
 *****************************************************************************/
void saveRawSampleRate(unsigned int rate)
{
    [[NSUserDefaults standardUserDefaults] setInteger:static_cast<NSInteger>(rate)
                                               forKey:kDefaultsRawSampleRate];
}

/*****************************************************************************
 * loadSpectrogramPalette
 *
 * Restores a saved palette only when it is still a valid enum value. This
 * keeps a damaged or future preference from escaping into the renderer.
 *
 *****************************************************************************/
msap::core::SpectrogramPalette loadSpectrogramPalette()
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kDefaultsSpectrogramPalette] == nil) {
        return msap::core::kDefaultSpectrogramPalette;
    }

    const NSInteger stored = [defaults integerForKey:kDefaultsSpectrogramPalette];
    const NSInteger count =
        static_cast<NSInteger>(msap::core::SpectrogramPalette::Count);
    if (stored < 0 || stored >= count) {
        return msap::core::kDefaultSpectrogramPalette;
    }
    return static_cast<msap::core::SpectrogramPalette>(stored);
}

/*****************************************************************************
 * saveSpectrogramPalette
 *
 * Colour-map changes are preferences rather than document state, so each
 * Cmd+P selection becomes the next-launch default immediately.
 *
 *****************************************************************************/
void saveSpectrogramPalette(msap::core::SpectrogramPalette palette)
{
    [[NSUserDefaults standardUserDefaults]
        setInteger:static_cast<NSInteger>(palette)
            forKey:kDefaultsSpectrogramPalette];
}

/*****************************************************************************
 * loadSpectrogramRangeDb
 *
 * Restores only values accepted by the contrast commands. Missing, damaged or
 * obsolete preferences fall back to the compiled 80 dB default.
 *
 *****************************************************************************/
float loadSpectrogramRangeDb()
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kDefaultsSpectrogramRangeDb] == nil) {
        return msap::core::kDefaultDynamicRangeDb;
    }

    const double stored = [defaults doubleForKey:kDefaultsSpectrogramRangeDb];
    if (!std::isfinite(stored) || stored < 20.0 || stored > 120.0) {
        return msap::core::kDefaultDynamicRangeDb;
    }
    return static_cast<float>(stored);
}

/*****************************************************************************
 * saveSpectrogramRangeDb
 *
 * Contrast changes are global display preferences, so remember each step for
 * the next launch.
 *
 *****************************************************************************/
void saveSpectrogramRangeDb(float rangeDb)
{
    [[NSUserDefaults standardUserDefaults] setDouble:rangeDb
                                             forKey:kDefaultsSpectrogramRangeDb];
}

/*****************************************************************************
 * extensionWarningEnabled
 *
 * Warning preferences default to enabled when no value has been saved.
 *
 *****************************************************************************/
bool extensionWarningEnabled(NSString* key)
{
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    id stored = [defaults objectForKey:key];
    return stored == nil || [stored boolValue];
}

/*****************************************************************************
 * disableExtensionWarning
 *
 * Continuing through a mismatch suppresses that warning category on later
 * opens, matching WinSap's registry and XSap's key-file behavior.
 *
 *****************************************************************************/
void disableExtensionWarning(NSString* key)
{
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:key];
}

/*****************************************************************************
 * lowerExtension
 *
 * Normalises a path extension for file-type checks.
 *
 *****************************************************************************/
std::string lowerExtension(const std::filesystem::path& path)
{
    std::string extension = path.extension().string();
    std::transform(extension.begin(), extension.end(), extension.begin(),
                   [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
    return extension;
}

/*****************************************************************************
 * hasParameterExtension
 *
 * Parameter mode uses the traditional SAP .par file extension.
 *
 *****************************************************************************/
bool hasParameterExtension(const std::filesystem::path& path)
{
    return lowerExtension(path) == ".par";
}

/*****************************************************************************
 * hasBinaryExtension
 *
 * Waveform and spectrum modes share the binary-data extensions accepted by
 * the file chooser.
 *
 *****************************************************************************/
bool hasBinaryExtension(const std::filesystem::path& path)
{
    const std::string extension = lowerExtension(path);
    return extension == ".wav" || extension == ".dat" || extension == ".pcm" ||
           extension == ".exc" || extension == ".res" || extension == ".cod" ||
           extension == ".raw";
}

// The quantity plotted under the cursor. Both spectrum displays replace the
// amplitude axis, so the status bar readout has to follow the active mode.
enum class HoverAxis { Amplitude,
                       SpectrumLine,
                       Spectrogram };

/*****************************************************************************
 * hoverAxis
 *
 * Describes what a panel is currently plotting and, for the two spectrum
 * displays, the frequency belonging at the top of the plot. Ported unchanged
 * from XSap so the three ports report identical coordinates.
 *
 *****************************************************************************/
HoverAxis hoverAxis(const msap::Panel& source,
                    unsigned int rawSampleRate,
                    double& topHz,
                    unsigned int& sampleRate) noexcept
{
    topHz = 0.0;
    sampleRate = 0;
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = source.track(slot);
        if (track == nullptr || track->type() != msap::TrackType::FftAmplitude) {
            continue;
        }
        const unsigned int rate = track->effectiveSampleRate(rawSampleRate);
        sampleRate = rate;

        const size_t span = source.visibleFrameCount() * source.frameLength();
        if (span > msap::core::kSpectrogramThreshold) {
            // The cache analyses all the way to Nyquist.
            topHz = rate / 2.0;
            return HoverAxis::Spectrogram;
        }

        // The line plot draws bins 0 .. kFftCutOff-1 of a kFftLength point
        // transform, which deliberately stops short of Nyquist.
        topHz = static_cast<double>(rate) * msap::core::kFftCutOff /
                static_cast<double>(msap::core::kFftLength);
        return HoverAxis::SpectrumLine;
    }
    return HoverAxis::Amplitude;
}

/*****************************************************************************
 * panelHasWaveform
 *
 * True when a panel holds at least one binary track, which is what the
 * amplitude readout and the Add Down to Up overlay both need.
 *
 *****************************************************************************/
bool panelHasWaveform(const msap::Panel& source) noexcept
{
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = source.track(slot);
        if (track != nullptr && track->isBinary()) {
            return true;
        }
    }
    return false;
}

/*****************************************************************************
 * panelHasFft
 *
 * Reports whether a panel contains an FFT amplitude track. Stereo sync and
 * the playback cursor treat such a panel differently.
 *
 *****************************************************************************/
bool panelHasFft(const msap::Panel& source) noexcept
{
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = source.track(slot);
        if (track != nullptr && track->type() == msap::TrackType::FftAmplitude) {
            return true;
        }
    }
    return false;
}

/*****************************************************************************
 * stereoActive / stereoFftActive
 *
 * A stereo file is open when the upper panel holds a left channel; it is in
 * FFT mode when that channel is an FFT amplitude track (WinSap StereoActive /
 * StereoFftActive).
 *
 *****************************************************************************/
bool stereoActive(const Document& document) noexcept
{
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = document.upperPanel.track(slot);
        if (track != nullptr && track->isStereoChannel()) {
            return true;
        }
    }
    return false;
}

bool stereoFftActive(const Document& document) noexcept
{
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = document.upperPanel.track(slot);
        if (track != nullptr && track->isStereoChannel() &&
            track->type() == msap::TrackType::FftAmplitude) {
            return true;
        }
    }
    return false;
}

bool isStereoPairSlot(const Document& document, size_t slot) noexcept
{
    const msap::Track* upTrack = document.upperPanel.track(slot);
    const msap::Track* downTrack = document.lowerPanel.track(slot);
    return upTrack != nullptr && upTrack->isStereoChannel() && downTrack != nullptr &&
           downTrack->isStereoChannel();
}

StereoView stereoView(const Document& document, bool upper)
{
    const msap::Panel& source = upper ? document.upperPanel : document.lowerPanel;
    const bool pending = upper ? document.pendingMarkUpper : document.pendingMarkLower;
    const int64_t pendingSample =
        upper ? document.pendingMarkSampleUpper : document.pendingMarkSampleLower;
    StereoView view;
    view.frameBegin = source.frameBegin();
    view.visibleFrameCount = source.visibleFrameCount();
    view.frameLength = source.frameLength();
    view.frameSkip = source.frameSkip();
    view.lowerLimit = source.lowerLimit();
    view.upperLimit = source.upperLimit();
    view.mark = source.selectedSampleRange();
    if (pending) {
        view.pendingMark = pendingSample;
    }
    return view;
}

/*****************************************************************************
 * syncStereoState
 *
 * Keeps both halves of every stereo file together and, while one is open,
 * gives the two panels the same view and mark (WinSap SyncStereoState). A
 * channel whose partner was closed is closed as well. Without an explicit
 * source the panel that changed since the last sync is copied. Returns true
 * when a channel was closed, so the caller can relayout the panels.
 *
 *****************************************************************************/
bool syncStereoState(Document& document, std::optional<bool> fromUpper)
{
    if (document.syncingStereo) {
        return false;
    }
    document.syncingStereo = true;
    bool closed = false;
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* upTrack = document.upperPanel.track(slot);
        const msap::Track* downTrack = document.lowerPanel.track(slot);
        const bool up = upTrack != nullptr && upTrack->isStereoChannel();
        const bool down = downTrack != nullptr && downTrack->isStereoChannel();
        if (!up && !down) {
            continue;
        }
        if (up && down && upTrack->channel() == 0 && downTrack->channel() == 1 &&
            upTrack->path() == downTrack->path()) {
            continue;
        }
        std::string ignored;
        if (up) {
            document.upperPanel.closeTrack(slot, ignored);
        }
        if (down) {
            document.lowerPanel.closeTrack(slot, ignored);
        }
        closed = true;
    }
    if (closed) {
        if (document.upperPanel.openTrackCount() == 0U) {
            document.upperPanel.clearMark();
            document.pendingMarkUpper = false;
        }
        if (document.lowerPanel.openTrackCount() == 0U) {
            document.lowerPanel.clearMark();
            document.pendingMarkLower = false;
        }
    }

    if (stereoActive(document)) {
        if (!fromUpper.has_value()) {
            if (!(stereoView(document, true) == document.lastUpperView)) {
                fromUpper = true;
            } else if (!(stereoView(document, false) == document.lastLowerView)) {
                fromUpper = false;
            }
        }
        if (fromUpper.has_value()) {
            const bool sourceUpper = *fromUpper;
            const msap::Panel& source = sourceUpper ? document.upperPanel : document.lowerPanel;
            msap::Panel& target = sourceUpper ? document.lowerPanel : document.upperPanel;
            std::string ignored;
            // Frame length first: it decides how many frames the files hold
            if (target.frameLength() != source.frameLength()) {
                target.setFrameLength(source.frameLength(), ignored);
            }
            target.setVisibleFrameCount(source.visibleFrameCount(), ignored);
            target.setFrameBegin(source.frameBegin(), ignored);
            target.setFrameSkip(source.frameSkip(), ignored);

            // FFT amplitude files use dB limits, which do not carry over to samples
            if (panelHasFft(source) == panelHasFft(target) &&
                (target.lowerLimit() != source.lowerLimit() ||
                 target.upperLimit() != source.upperLimit())) {
                target.setAmplitudeLimits(source.lowerLimit(), source.upperLimit(), ignored);
            }

            const std::optional<msap::SampleRange> mark = source.selectedSampleRange();
            const bool pending =
                sourceUpper ? document.pendingMarkUpper : document.pendingMarkLower;
            const int64_t pendingSample =
                sourceUpper ? document.pendingMarkSampleUpper : document.pendingMarkSampleLower;
            bool& targetPending =
                sourceUpper ? document.pendingMarkLower : document.pendingMarkUpper;
            int64_t& targetPendingSample =
                sourceUpper ? document.pendingMarkSampleLower : document.pendingMarkSampleUpper;
            target.clearMark();
            targetPending = false;
            if (mark.has_value()) {
                if (!target.setMarkStart(mark->begin, ignored) ||
                    !target.setMarkEnd(mark->end, ignored)) {
                    target.clearMark();
                }
            } else if (pending && target.setMarkStart(pendingSample, ignored)) {
                targetPending = true;
                targetPendingSample = pendingSample;
            }
        }
    }
    document.lastUpperView = stereoView(document, true);
    document.lastLowerView = stereoView(document, false);
    document.syncingStereo = false;
    return closed;
}

/*****************************************************************************
 * formatTime
 *
 * Renders a sample offset as hh:mm:ss.mmm, the format WinSap uses for both
 * the spectrogram readout and the playback progress pane.
 *
 *****************************************************************************/
NSString* formatTime(long long samples, unsigned int sampleRate)
{
    const double seconds = sampleRate > 0
                               ? static_cast<double>(samples) / static_cast<double>(sampleRate)
                               : 0.0;
    const long long totalMs = static_cast<long long>(seconds * 1000.0 + 0.5);
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld.%03lld",
                                      totalMs / 3600000, (totalMs / 60000) % 60,
                                      (totalMs / 1000) % 60, totalMs % 1000];
}

/*****************************************************************************
 * panelSampleRate
 *
 * Finds the effective sample rate of a panel's first binary track, falling
 * back to the configured raw rate. XSap uses the same rule for the times in
 * the frame header.
 *
 *****************************************************************************/
unsigned int panelSampleRate(const msap::Panel& source, unsigned int rawDefault) noexcept
{
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = source.track(slot);
        if (track != nullptr && track->isBinary()) {
            return track->effectiveSampleRate(rawDefault);
        }
    }
    return rawDefault;
}

/*****************************************************************************
 * panelFont, panelCharacterWidth
 *
 * The frame header is laid out in character columns, exactly as WinSap's
 * fixed pitch client area was, so the panel chrome uses a monospaced font and
 * measures one advance to convert XSap's column numbers into points.
 *
 *****************************************************************************/
NSFont* panelFont(void)
{
    static NSFont* font = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
      if (font == nil) {
          font = [NSFont userFixedPitchFontOfSize:11.0];
      }
    });
    return font;
}

/*****************************************************************************
 * panelTextLineHeight
 *
 * The height the panel font actually paints, which is smaller than the
 * nominal character cell. Needed to centre a line of text inside its band
 * rather than hanging it from the top edge.
 *
 *****************************************************************************/
CGFloat panelTextLineHeight(void)
{
    static CGFloat height = 0.0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      height = [@"0" sizeWithAttributes:@{NSFontAttributeName : panelFont()}].height;
      if (height <= 0.0) {
          height = 13.0;
      }
    });
    return height;
}

CGFloat panelCharacterWidth(void)
{
    static CGFloat width = 0.0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      width = [@"0" sizeWithAttributes:@{NSFontAttributeName : panelFont()}].width;
      if (width <= 0.0) {
          width = 7.0;
      }
    });
    return width;
}

constexpr CGFloat kPanelCharacterHeight = 16.0;
constexpr CGFloat kPanelLineSpacing = 2.0;

// Per track colours, shared by the plot and by the file names in the header so
// that a curve and its label always agree.
// WinSap rules every panel frame and separator with a single one-pixel cyan
// pen, identically for the up and the down panel. Slightly dimmed here because
// a Mac display renders saturated cyan noticeably hotter than Windows does.
constexpr std::array<double, 3> kPanelChromeColor = {{0.0, 0.62, 0.62}};

/*****************************************************************************
 * panelChromeLineWidth
 *
 * Returns the width, in points, of exactly one device pixel, so the panel
 * frame stays as fine on a Retina display as WinSap's one-pixel pen is on
 * Windows.
 *
 *****************************************************************************/
CGFloat panelChromeLineWidth(NSView* view)
{
    const CGFloat scale = [view convertSizeToBacking:NSMakeSize(1.0, 1.0)].width;
    return scale > 0.0 ? 1.0 / scale : 1.0;
}

// WinSap sets these in WinsapApp.cpp and XSap repeats them: yellow, magenta,
// cyan, white, green, blue, in slot order.
constexpr std::array<std::array<double, 3>, msap::Panel::kMaxTracks> kTrackColors = {{{{1.0, 1.0, 0.0}}, {{1.0, 0.0, 1.0}}, {{0.0, 1.0, 1.0}}, {{1.0, 1.0, 1.0}}, {{0.0, 1.0, 0.0}}, {{0.0, 0.0, 1.0}}}};

NSColor* trackColor(size_t slot)
{
    const auto& rgb = kTrackColors[slot % kTrackColors.size()];
    return [NSColor colorWithSRGBRed:rgb[0] green:rgb[1] blue:rgb[2] alpha:1.0];
}

/*****************************************************************************
 * PanelLayout
 *
 * The rectangles that make up one panel, in the flipped top down space the
 * plot view draws in. The frame header sits above the plot for the up panel
 * and below it for the down panel, which is how WinSap and XSap mirror them.
 *
 *****************************************************************************/
struct PanelLayout {
    NSRect panel = NSZeroRect;
    NSRect frameInfo = NSZeroRect;
    NSRect parameters = NSZeroRect;
    NSRect plot = NSZeroRect;
};

PanelLayout makePanelLayout(NSRect bounds, bool upper, bool hasParameter)
{
    const CGFloat frameHeight = kPanelCharacterHeight + kPanelLineSpacing + 1.0;
    const CGFloat parameterHeight = 2.0 * (kPanelCharacterHeight + kPanelLineSpacing) + 1.0;

    PanelLayout result;
    result.panel = bounds;
    const CGFloat width = bounds.size.width;
    const CGFloat top = NSMinY(bounds);
    const CGFloat height = bounds.size.height;

    const CGFloat contentTop = upper ? top + frameHeight : top;
    const CGFloat contentBottom = upper ? top + height : top + height - frameHeight;
    result.frameInfo = upper ? NSMakeRect(0.0, top, width, frameHeight)
                             : NSMakeRect(0.0, contentBottom, width, frameHeight);
    if (hasParameter) {
        result.parameters =
            upper ? NSMakeRect(0.0, contentTop, width, parameterHeight)
                  : NSMakeRect(0.0, contentBottom - parameterHeight, width, parameterHeight);
    }

    const CGFloat plotTop =
        upper ? contentTop + (hasParameter ? parameterHeight : 0.0) : contentTop;
    const CGFloat plotBottom =
        upper ? contentBottom : contentBottom - (hasParameter ? parameterHeight : 0.0);
    const CGFloat gutterWidth = 10.0 * panelCharacterWidth();
    result.plot = NSMakeRect(gutterWidth, plotTop,
                             std::max(0.0, width - gutterWidth),
                             std::max(0.0, plotBottom - plotTop));
    return result;
}

bool panelHasParameterText(const msap::Panel& source) noexcept
{
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = source.track(slot);
        if (track != nullptr && track->type() == msap::TrackType::ParameterText) {
            return true;
        }
    }
    return false;
}

} // namespace

// ===========================================================================
// MsapPlotView
//
// One custom drawn view per panel, the equivalent of XSap's Gtk::DrawingArea
// and of the WinSap client area blit. Waveform, envelope, spectrum and
// spectrogram all render here through Core Graphics.
// ===========================================================================
@protocol MsapStatusSink <NSObject>
- (void)refreshStatus;
// Right clicking a panel stops playback before it marks, exactly as XSap's
// handleClick does.
- (BOOL)stopPlaybackFromPanel;
- (void)playTrackInUpperPanel:(BOOL)upper slot:(size_t)slot;
- (void)closeTrackInUpperPanel:(BOOL)upper slot:(size_t)slot;
// Right clicking a file name pops up its context menu (WinSap ShowFileMenu).
- (void)showFileMenuInUpperPanel:(BOOL)upper
                            slot:(size_t)slot
                           event:(NSEvent*)event
                            view:(NSView*)view;
// Routes navigation keys through the same upper-first policy as menu commands.
- (BOOL)handleNavigationKey:(unichar)key;
@end

@interface MsapPlotView : NSView
@property(nonatomic, assign) Document* document;
@property(nonatomic, assign) BOOL isUpperPanel;
@property(nonatomic, assign) BOOL spectrogramRefreshScheduled;
@end

@implementation MsapPlotView

/*****************************************************************************
 * isFlipped
 *
 * Core Graphics puts the origin at the bottom left. WinSap and XSap both draw
 * top down, so flipping the view keeps the ported arithmetic unchanged and
 * avoids sign errors in every y coordinate.
 *
 *****************************************************************************/
- (BOOL)isFlipped
{
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent*)event
{
    (void)event;
    return YES;
}

- (msap::Panel&)panel
{
    return self.isUpperPanel ? self.document->upperPanel : self.document->lowerPanel;
}

- (void)scheduleSpectrogramRefresh
{
    if (self.spectrogramRefreshScheduled) {
        return;
    }
    self.spectrogramRefreshScheduled = YES;
    __weak MsapPlotView* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     MsapPlotView* strongSelf = weakSelf;
                     if (strongSelf == nil) {
                         return;
                     }
                     strongSelf.spectrogramRefreshScheduled = NO;
                     [strongSelf setNeedsDisplay:YES];
                   });
}

- (void)drawMessage:(NSString*)message atPoint:(NSPoint)point color:(NSColor*)color
{
    NSDictionary* attributes = @{
        NSForegroundColorAttributeName : color,
        NSFontAttributeName : [NSFont systemFontOfSize:12.0]
    };
    [message drawAtPoint:point withAttributes:attributes];
}

/*****************************************************************************
 * drawRect
 *
 * Entry point for all panel drawing, equivalent to XSap's draw callback.
 * Dispatches on track type and draws the appropriate visualization.
 *
 *****************************************************************************/
- (void)drawRect:(NSRect)dirtyRect
{
    // AppKit hands these sibling views a dirty rect covering the whole window,
    // so clip explicitly or a panel paints over its neighbour and the status
    // bar.
    NSRectClip(self.bounds);

    CGContextRef context = (CGContextRef)[[NSGraphicsContext currentContext] CGContext];

    // Fill background with black (matching WinSap/XSap)
    CGContextSetRGBFillColor(context, 0.0, 0.0, 0.0, 1.0);
    CGContextFillRect(context, NSRectToCGRect(self.bounds));

    if (self.document == nullptr) {
        return;
    }

    msap::Panel& panel = [self panel];

    // An empty panel is drawn as plain black, with no frame, so that starting
    // the app with no files gives the same blank window WinSap and XSap do.
    if (panel.openTrackCount() == 0) {
        return;
    }

    const PanelLayout layout = [self panelLayout];

    // WinSap rules the panel frame and the internal separators with one
    // one-pixel cyan pen and draws both panels identically; there is no
    // selected-panel highlight. A point is two pixels on a Retina display, so
    // stroke a single device pixel or the frame looks twice as heavy as it
    // does on Windows.
    const CGFloat hairline = panelChromeLineWidth(self);
    CGContextSetLineWidth(context, hairline);
    CGContextSetRGBStrokeColor(context, kPanelChromeColor[0], kPanelChromeColor[1],
                               kPanelChromeColor[2], 1.0);
    CGContextStrokeRect(context,
                        NSInsetRect(self.bounds, hairline / 2.0, hairline / 2.0));

    // The rules that separate the frame header, the parameter strip and the
    // scale gutter from the plot, as WinSap and XSap draw them.
    CGContextBeginPath(context);
    const CGFloat frameSeparator = self.isUpperPanel ? NSMaxY(layout.frameInfo)
                                                     : NSMinY(layout.frameInfo);
    CGContextMoveToPoint(context, NSMinX(layout.panel), frameSeparator + hairline / 2.0);
    CGContextAddLineToPoint(context, NSMaxX(layout.panel), frameSeparator + hairline / 2.0);
    if (layout.parameters.size.height > 0.0) {
        const CGFloat parameterSeparator = self.isUpperPanel
                                               ? NSMaxY(layout.parameters)
                                               : NSMinY(layout.parameters);
        CGContextMoveToPoint(context, NSMinX(layout.panel), parameterSeparator + hairline / 2.0);
        CGContextAddLineToPoint(context, NSMaxX(layout.panel), parameterSeparator + hairline / 2.0);
    }
    CGContextMoveToPoint(context, NSMinX(layout.plot) + hairline / 2.0, NSMinY(layout.plot));
    CGContextAddLineToPoint(context, NSMinX(layout.plot) + hairline / 2.0, NSMaxY(layout.plot));
    CGContextStrokePath(context);

    [self drawFrameInfo:layout panel:panel];
    [self drawAmplitudeLabels:layout panel:panel];
    [self drawParameterText:layout panel:panel];

    const NSRect plot = NSInsetRect(layout.plot, 2.0, 2.0);
    const auto mark = panel.selectedSampleRange();
    if (mark.has_value()) {
        const msap::SampleRange visible = panel.visibleSampleRange();
        const int64_t begin = std::max(visible.begin, mark->begin);
        const int64_t end = std::min(visible.end, mark->end);
        if (end > begin && !visible.empty()) {
            const double x1 = plot.origin.x +
                              static_cast<double>(begin - visible.begin) / visible.length() * plot.size.width;
            const double x2 = plot.origin.x +
                              static_cast<double>(end - visible.begin) / visible.length() * plot.size.width;
            CGContextSetRGBFillColor(context, 0.28, 0.28, 0.28, 1.0);
            CGContextFillRect(context, CGRectMake(x1, plot.origin.y, x2 - x1, plot.size.height));
        }
    }

    // Everything from here on belongs inside the plot, so a long curve cannot
    // spill into the gutter or the header.
    CGContextSaveGState(context);
    CGContextClipToRect(context, NSRectToCGRect(plot));

    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = panel.track(slot);
        if (track == nullptr || track->type() == msap::TrackType::ParameterText) {
            continue;
        }
        const auto& color = kTrackColors[slot];
        if (track->type() == msap::TrackType::FftAmplitude) {
            [self drawSpectrumInContext:context rect:plot track:*track panel:panel color:color.data()];
        } else {
            [self drawWaveformInContext:context rect:plot track:*track panel:panel color:color.data()];
        }
    }

    if (self.isUpperPanel && self.document->overlayLower &&
        panelHasWaveform(self.document->lowerPanel)) {
        for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
            const msap::Track* overlay = self.document->lowerPanel.track(slot);
            if (overlay != nullptr &&
                overlay->type() == msap::TrackType::WaveformPcm16) {
                static constexpr double red[3] = {1.0, 0.0, 0.0};
                [self drawWaveformInContext:context
                                       rect:plot
                                      track:*overlay
                                      panel:self.document->lowerPanel
                                      color:red];
                break;
            }
        }
    }

    const bool spectrumFile = panelHasFft(panel);
    const bool spectrogramView =
        spectrumFile && panel.visibleFrameCount() * panel.frameLength() >
                            msap::core::kSpectrogramThreshold;
    if (spectrogramView) {
        // A spectrogram covers the grey mark background, so the marked block
        // is shown by its edges instead: white lines at the start and, once
        // complete, the end.
        const msap::SampleRange visible = panel.visibleSampleRange();
        std::vector<int64_t> edges;
        if (mark.has_value()) {
            edges = {mark->begin, mark->end};
        } else if ([self pendingMark]) {
            edges = {self.isUpperPanel ? self.document->pendingMarkSampleUpper
                                       : self.document->pendingMarkSampleLower};
        }
        CGContextSetRGBStrokeColor(context, 1.0, 1.0, 1.0, 1.0);
        CGContextSetLineWidth(context, 1.0);
        CGContextBeginPath(context);
        for (const int64_t edge : edges) {
            if (visible.empty() || edge < visible.begin || edge > visible.end) {
                continue;
            }
            const double x = plot.origin.x + static_cast<double>(edge - visible.begin) /
                                                 visible.length() * plot.size.width;
            CGContextMoveToPoint(context, x, plot.origin.y);
            CGContextAddLineToPoint(context, x, NSMaxY(plot));
        }
        CGContextStrokePath(context);
    }

    // A single-frame spectrum line has a frequency x-axis, so there is no time
    // cursor
    const auto cursor = panel.playbackCursor();
    if (cursor.has_value() && (!spectrumFile || spectrogramView)) {
        const auto x = panel.pixelOffsetForSample(
            *cursor, static_cast<size_t>(std::max(1.0, plot.size.width)));
        if (x.has_value()) {
            CGContextSetRGBStrokeColor(context, 1.0, 0.5, 0.0, 1.0);
            CGContextSetLineWidth(context, 2.0);
            CGContextMoveToPoint(context, plot.origin.x + *x, plot.origin.y);
            CGContextAddLineToPoint(context, plot.origin.x + *x, NSMaxY(plot));
            CGContextStrokePath(context);
        }
    }

    CGContextRestoreGState(context);
}

/*****************************************************************************
 * panelLayout, plotRect
 *
 * The panel chrome geometry. plotRect is the wave area the mouse maps onto,
 * which is the plot inset by the two point margin the drawing uses.
 *
 *****************************************************************************/
- (PanelLayout)panelLayout
{
    const bool hasParameter =
        self.document != nullptr && panelHasParameterText([self panel]);
    return makePanelLayout(self.bounds, self.isUpperPanel, hasParameter);
}

- (NSRect)plotRect
{
    return NSInsetRect([self panelLayout].plot, 2.0, 2.0);
}

/*****************************************************************************
 * drawFrameInfo
 *
 * The one line header WinSap and XSap put next to the plot: the first and last
 * visible frame, the frame size, the matching times and the open file names in
 * their track colours. Columns are in character widths so the fields line up
 * the way the original fixed pitch display did.
 *
 *****************************************************************************/
- (void)drawFrameInfo:(const PanelLayout&)layout panel:(const msap::Panel&)panel
{
    const CGFloat charWidth = panelCharacterWidth();
    // The band is a whole character cell tall, so centre the glyphs in it
    // instead of hanging them from the top edge of the flipped view.
    const CGFloat top = NSMinY(layout.frameInfo) +
                        std::round((layout.frameInfo.size.height - panelTextLineHeight()) / 2.0);
    NSFont* font = panelFont();
    NSColor* cyan = [NSColor colorWithSRGBRed:0.0 green:1.0 blue:1.0 alpha:1.0];
    NSColor* white = [NSColor whiteColor];

    void (^put)(CGFloat, NSString*, NSColor*) =
        ^(CGFloat column, NSString* text, NSColor* color) {
          [text drawAtPoint:NSMakePoint(column * charWidth, top)
              withAttributes:@{NSFontAttributeName : font,
                               NSForegroundColorAttributeName : color}];
        };

    put(1.0, @"Frame=", cyan);
    // Frame numbers take 10 columns (kMaxParameterFrames has 10 digits) and
    // times 13 (hhh:mm:ss.mmm), matching WinSAP DrawFrameInfo.
    put(18.0, @"...", cyan);
    put(33.0, @"FrameSize=", cyan);
    put(64.0, @"...", cyan);

    const long long firstFrame = static_cast<long long>(panel.frameBegin());
    const long long lastFrame =
        static_cast<long long>(panel.frameBegin() + panel.visibleFrameCount());
    put(7.0, [NSString stringWithFormat:@"%10lld", firstFrame], white);
    put(22.0, [NSString stringWithFormat:@"%10lld", lastFrame], white);
    put(43.0, [NSString stringWithFormat:@"%5lld", static_cast<long long>(panel.frameLength())], white);

    const unsigned int rate = panelSampleRate(panel, self.document->rawSampleRate);
    const long long frameLength = static_cast<long long>(panel.frameLength());
    put(50.0, formatTime(firstFrame * frameLength, rate), white);
    put(68.0, formatTime(lastFrame * frameLength, rate), white);

    [self enumerateTrackLabels:layout
                         panel:panel
                         using:^(size_t slot, NSString* name, NSRect rect) {
                           put(NSMinX(rect) / charWidth, name, trackColor(slot));
                         }];
}

/*****************************************************************************
 * enumerateTrackLabels
 *
 * Walks the open file names in the frame information band and hands each one
 * to the block with the rectangle it occupies. Drawing and hit testing share
 * this so the hover readout always lines up with the painted name.
 *
 *****************************************************************************/
- (void)enumerateTrackLabels:(const PanelLayout&)layout
                       panel:(const msap::Panel&)panel
                       using:(void (^)(size_t, NSString*, NSRect))block
{
    const CGFloat charWidth = panelCharacterWidth();
    CGFloat column = 82.0;
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = panel.track(slot);
        if (track == nullptr) {
            continue;
        }
        if (column * charWidth >= NSMaxX(layout.panel) - 20.0) {
            break;
        }
        NSString* name = [[NSString stringWithUTF8String:track->path().c_str()]
            lastPathComponent];
        if (track->isStereoChannel()) {
            name = [name stringByAppendingString:track->channel() == 0 ? @" [L]" : @" [R]"];
        }
        const NSRect rect = NSMakeRect(column * charWidth, NSMinY(layout.frameInfo),
                                       static_cast<CGFloat>([name length]) * charWidth,
                                       layout.frameInfo.size.height);
        block(slot, name, rect);
        column += static_cast<CGFloat>([name length]) + 1.0;
    }
}

/*****************************************************************************
 * drawAmplitudeLabels
 *
 * The vertical scale down the left gutter. A waveform is labelled with the
 * panel amplitude limits, which are the full 16 bit range by default, a single
 * frame spectrum with its dB limits, and a spectrogram with hertz from zero at
 * the bottom to Nyquist at the top. Tick density follows the available height
 * so the labels never collide.
 *
 *****************************************************************************/
- (void)drawAmplitudeLabels:(const PanelLayout&)layout panel:(const msap::Panel&)panel
{
    if (layout.plot.size.height < 3.0 * kPanelCharacterHeight) {
        return;
    }

    const CGFloat charWidth = panelCharacterWidth();
    const double oneSidePixels =
        (layout.plot.size.height - 3.0 * kPanelCharacterHeight) / 2.0;

    double axisTop = panel.upperLimit();
    double axisBottom = panel.lowerLimit();
    double topHz = 0.0;
    unsigned int rate = 0;
    if (hoverAxis(panel, self.document->rawSampleRate, topHz, rate) ==
        HoverAxis::Spectrogram) {
        axisTop = topHz;
        axisBottom = 0.0;
    }

    const int tickCount = std::max(0, static_cast<int>(
                                          (oneSidePixels - kPanelCharacterHeight) / (2.0 * kPanelCharacterHeight)));
    const double spacing =
        (oneSidePixels - static_cast<double>(tickCount) * kPanelCharacterHeight) /
        static_cast<double>(tickCount + 1);
    const double step =
        (axisTop - axisBottom) / static_cast<double>(2 * (tickCount + 1));

    NSDictionary* attributes = @{
        NSFontAttributeName : panelFont(),
        NSForegroundColorAttributeName :
            [NSColor colorWithSRGBRed:0.0
                                green:1.0
                                 blue:1.0
                                alpha:1.0]
    };
    void (^label)(double, double) = ^(double value, double top) {
      [[NSString stringWithFormat:@"%8.0f", value]
             drawAtPoint:NSMakePoint(charWidth, top)
          withAttributes:attributes];
    };

    label(axisTop, NSMinY(layout.plot) + 1.0);
    label((axisTop + axisBottom) / 2.0,
          NSMinY(layout.plot) + kPanelCharacterHeight + oneSidePixels);
    label(axisBottom,
          NSMaxY(layout.plot) - kPanelCharacterHeight - 1.0);

    double offset = spacing;
    double value = axisTop - step;
    const double upperStart = NSMinY(layout.plot) + kPanelCharacterHeight;
    for (int tick = 0; tick < tickCount; ++tick) {
        label(value, upperStart + offset);
        offset += kPanelCharacterHeight + spacing;
        value -= step;
    }

    offset = spacing;
    value = (axisTop + axisBottom) / 2.0 - step;
    const double lowerStart =
        NSMinY(layout.plot) + 2.0 * kPanelCharacterHeight + oneSidePixels;
    for (int tick = 0; tick < tickCount; ++tick) {
        label(value, lowerStart + offset);
        offset += kPanelCharacterHeight + spacing;
        value -= step;
    }
}

/*****************************************************************************
 * drawParameterText
 *
 * The two line parameter strip between the header and the plot.
 *
 *****************************************************************************/
- (void)drawParameterText:(const PanelLayout&)layout panel:(const msap::Panel&)panel
{
    if (layout.parameters.size.height <= 0.0) {
        return;
    }
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = panel.track(slot);
        if (track == nullptr || track->type() != msap::TrackType::ParameterText) {
            continue;
        }
        const auto frame = track->currentParameterFrame(panel);
        if (frame.has_value()) {
            NSDictionary* attributes = @{
                NSFontAttributeName : panelFont(),
                NSForegroundColorAttributeName : [NSColor yellowColor]
            };
            // Each of the two rows is a character cell tall; centre the text
            // in its own row for the same reason as the frame header.
            const CGFloat rowHeight = kPanelCharacterHeight + kPanelLineSpacing;
            const CGFloat inset =
                std::round((rowHeight - panelTextLineHeight()) / 2.0);
            NSString* first = [NSString stringWithFormat:@"%s  %s",
                                                         frame->header.c_str(), frame->line1.c_str()];
            [first drawAtPoint:NSMakePoint(NSMinX(layout.parameters) + 8.0,
                                           NSMinY(layout.parameters) + inset)
                withAttributes:attributes];
            [[NSString stringWithUTF8String:frame->line2.c_str()]
                   drawAtPoint:NSMakePoint(NSMinX(layout.parameters) + 8.0,
                                           NSMinY(layout.parameters) + rowHeight + inset)
                withAttributes:attributes];
        }
        break;
    }
}

/*****************************************************************************
 * drawWaveformInContext
 *
 * Draws waveform data as a connected trace.
 *
 *****************************************************************************/
- (void)drawWaveformInContext:(CGContextRef)context
                         rect:(NSRect)rect
                        track:(const msap::Track&)track
                        panel:(const msap::Panel&)panel
                        color:(const double*)color
{
    // Ask for one column per physical pixel rather than per point, or a Retina
    // display throws away half of the detail the panel could show. The results
    // come back in that pixel space, so x is divided by the scale on the way
    // into the point based context.
    const double scale = std::max(1.0, [self convertSizeToBacking:NSMakeSize(1.0, 1.0)].width);
    const size_t columnCount =
        static_cast<size_t>(std::max(1.0, rect.size.width * scale));

    std::string error;
    auto points = track.computeConnectedPoints(
        panel.visibleSampleRange(),
        columnCount,
        columnCount * 4U,
        error);

    // Draw baseline
    CGContextSetRGBStrokeColor(context, 0.7, 0.7, 0.7, 1.0);
    CGContextSetLineWidth(context, 0.5);
    double baseline = [self valueToY:0.0 rect:rect panel:panel];
    CGContextBeginPath(context);
    CGContextMoveToPoint(context, rect.origin.x, baseline);
    CGContextAddLineToPoint(context, rect.origin.x + rect.size.width, baseline);
    CGContextStrokePath(context);

    // Draw waveform. WinSap's one pixel GDI pen is not antialiased and is
    // physically much larger than one Retina pixel, so a full point of width
    // with round joins reads the same on a Mac; a hairline breaks up into a
    // dotted trace instead.
    CGContextSetRGBStrokeColor(context, color[0], color[1], color[2], 1.0);
    CGContextSetLineWidth(context, 1.25);
    CGContextSetLineJoin(context, kCGLineJoinRound);
    CGContextSetLineCap(context, kCGLineCapRound);

    if (!points.empty()) {
        // One path, one stroke. Stroking each segment separately makes every
        // join a pair of butt ends, which is what gives the trace its broken,
        // segmented look.
        CGContextBeginPath(context);
        CGContextMoveToPoint(context,
                             rect.origin.x + points[0].x / scale,
                             [self valueToY:points[0].sample
                                       rect:rect
                                      panel:panel]);
        for (size_t i = 1; i < points.size(); ++i) {
            CGContextAddLineToPoint(context,
                                    rect.origin.x + points[i].x / scale,
                                    [self valueToY:points[i].sample
                                              rect:rect
                                             panel:panel]);
        }
        CGContextStrokePath(context);
        return;
    }

    // Fall back to envelope if points calculation failed
    auto columns = track.computeEnvelope(
        panel.visibleSampleRange(), columnCount, error);

    if (!error.empty()) {
        [self drawMessage:[NSString stringWithUTF8String:error.c_str()]
                  atPoint:NSMakePoint(rect.origin.x + 8.0, rect.origin.y + 8.0)
                    color:[NSColor systemRedColor]];
        return;
    }

    // WinSap's DrawWaveformDecimated joins each column to the one before it
    // whenever their min/max spans do not overlap. Without those connectors
    // the trace breaks into free floating vertical dashes wherever the signal
    // moves quickly, which is exactly the "segments" look.
    const double minimumSpan = 1.0 / scale;
    const msap::SampleRange visible = panel.visibleSampleRange();
    double previousX = 0.0;
    double previousTop = 0.0;
    double previousBottom = 0.0;
    bool firstColumn = true;

    CGContextBeginPath(context);
    for (size_t i = 0; i < columns.size(); ++i) {
        const double offset =
            static_cast<double>(columns[i].source.begin - visible.begin) /
            static_cast<double>(visible.length());
        const double x = rect.origin.x + offset * rect.size.width;
        double top = [self valueToY:columns[i].maximum rect:rect panel:panel];
        double bottom = [self valueToY:columns[i].minimum rect:rect panel:panel];
        if (top > bottom) {
            std::swap(top, bottom);
        }
        // A column whose samples all share one value would otherwise stroke a
        // zero length segment and vanish.
        if (bottom - top < minimumSpan) {
            bottom = top + minimumSpan;
        }

        CGContextMoveToPoint(context, x, top);
        CGContextAddLineToPoint(context, x, bottom);
        if (!firstColumn) {
            if (previousBottom < top) {
                CGContextMoveToPoint(context, previousX, previousBottom);
                CGContextAddLineToPoint(context, x, top);
            } else if (previousTop > bottom) {
                CGContextMoveToPoint(context, previousX, previousTop);
                CGContextAddLineToPoint(context, x, bottom);
            }
        }

        previousX = x;
        previousTop = top;
        previousBottom = bottom;
        firstColumn = false;
    }
    CGContextStrokePath(context);
}

- (void)drawSpectrumInContext:(CGContextRef)context
                         rect:(NSRect)rect
                        track:(const msap::Track&)track
                        panel:(const msap::Panel&)panel
                        color:(const double*)color
{
    const size_t firstSample = panel.frameBegin() * panel.frameLength();
    const size_t span = panel.visibleFrameCount() * panel.frameLength();
    if (span > msap::core::kSpectrogramThreshold) {
        [self drawSpectrogramInContext:context
                                  rect:rect
                                 track:track
                           firstSample:firstSample
                                  span:span];
        return;
    }

    const float* db = track.spectrumDb(
        panel.frameBegin(), panel.frameLength(), panel.visibleFrameCount());
    if (db == nullptr) {
        return;
    }

    const int bins = msap::core::kFftCutOff;
    const int columns = std::max(1, std::min(static_cast<int>(rect.size.width), bins));
    const double columnWidth = rect.size.width / columns;
    auto dbToY = [&](double value) {
        const double clamped = std::clamp(
            value, static_cast<double>(msap::core::kFftLowLimitDb),
            static_cast<double>(msap::core::kFftUpLimitDb));
        const double ratio = (msap::core::kFftUpLimitDb - clamped) /
                             (msap::core::kFftUpLimitDb - msap::core::kFftLowLimitDb);
        return rect.origin.y + ratio * std::max(0.0, rect.size.height - 1.0);
    };

    CGContextSetShouldAntialias(context, false);
    CGContextSetRGBStrokeColor(context, color[0], color[1], color[2], 1.0);
    CGContextSetLineWidth(context, 1.0);
    CGContextBeginPath(context);
    int bin = 0;
    for (int column = 0; column < columns; ++column) {
        const int binEnd = static_cast<int>(
            (static_cast<long long>(column) + 1) * bins / columns);
        float low = db[bin];
        float high = db[bin];
        for (; bin < binEnd && bin < bins; ++bin) {
            low = std::min(low, db[bin]);
            high = std::max(high, db[bin]);
        }
        const double x = std::floor(rect.origin.x + column * columnWidth) + 0.5;
        const double top = std::floor(dbToY(high)) + 0.5;
        const double bottom = std::floor(dbToY(low)) + 0.5;
        const double first = (column & 1) == 0 ? top : bottom;
        const double second = (column & 1) == 0 ? bottom : top;
        if (column == 0) {
            CGContextMoveToPoint(context, x, first);
        } else {
            CGContextAddLineToPoint(context, x, first);
        }
        CGContextAddLineToPoint(context, x, second);
    }
    CGContextStrokePath(context);
    CGContextSetShouldAntialias(context, true);
}

/*****************************************************************************
 * valueToY
 *
 * Maps a data value to pixel Y coordinate using panel limits.
 *
 *****************************************************************************/
- (double)valueToY:(double)value rect:(NSRect)rect panel:(const msap::Panel&)panel
{
    double lower = panel.lowerLimit();
    double upper = panel.upperLimit();
    double clamped = std::clamp(value, lower, upper);
    double ratio = (upper - clamped) / (upper - lower);
    return rect.origin.y + ratio * std::max(0.0, rect.size.height - 1.0);
}

/*****************************************************************************
 * drawSpectrogram
 *
 * The spectrogram cache already produces a finished RGB pixel buffer, exactly
 * as it does for WinSap's DIB and XSap's Cairo surface. Wrapping it in a
 * CGImage and letting Core Graphics scale it is the whole macOS side of the
 * job.
 *
 *****************************************************************************/
- (void)drawSpectrogramInContext:(CGContextRef)context
                            rect:(CGRect)rect
                           track:(const msap::Track&)track
                     firstSample:(size_t)firstSample
                            span:(size_t)span
{
    const NSRect backing = [self convertRectToBacking:rect];
    const int width = std::max(1, static_cast<int>(std::round(backing.size.width)));
    const int height = std::max(1, static_cast<int>(std::round(backing.size.height)));

    const msap::core::SpectrogramView* view =
        track.spectrogramView(firstSample, span, width, height,
                              self.document->spectrogramRangeDb, 0.0, 0.0);
    std::vector<std::uint8_t> grey;
    int sourceWidth = 0;
    int sourceHeight = 0;
    bool topDown = true;

    if (view != nullptr && !view->empty()) {
        grey = view->grey;
        sourceWidth = view->width;
        sourceHeight = view->height;
    } else {
        const msap::core::SpectrogramImage* image =
            track.spectrogram(firstSample, span, width);
        if (image == nullptr || image->empty()) {
            return;
        }
        grey = image->grey;
        sourceWidth = image->columns;
        sourceHeight = image->bins;
        topDown = false;
    }

    msap::core::SpectrogramColor palette[256];
    msap::core::BuildSpectrogramPalette(self.document->spectrogramPalette, palette);
    std::vector<std::uint8_t> pixels(
        static_cast<size_t>(sourceWidth) * static_cast<size_t>(sourceHeight) * 4U);
    for (int row = 0; row < sourceHeight; ++row) {
        const int sourceRow = topDown ? row : sourceHeight - 1 - row;
        for (int column = 0; column < sourceWidth; ++column) {
            const size_t sourceIndex = topDown
                                           ? static_cast<size_t>(sourceRow) * sourceWidth + column
                                           : static_cast<size_t>(column) * sourceHeight + sourceRow;
            const auto& rgb = palette[grey[sourceIndex]];
            const size_t destination =
                (static_cast<size_t>(row) * sourceWidth + column) * 4U;
            pixels[destination] = rgb.r;
            pixels[destination + 1U] = rgb.g;
            pixels[destination + 2U] = rgb.b;
            pixels[destination + 3U] = 255U;
        }
    }

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(
        pixels.data(), sourceWidth, sourceHeight, 8, sourceWidth * 4U, space,
        kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGImageRef image = bitmap != nullptr ? CGBitmapContextCreateImage(bitmap) : nullptr;
    if (image != nullptr) {
        CGContextSaveGState(context);
        CGContextSetInterpolationQuality(context, kCGInterpolationNone);
        CGContextTranslateCTM(context, rect.origin.x, rect.origin.y + rect.size.height);
        CGContextScaleCTM(context, 1.0, -1.0);
        CGContextDrawImage(context,
                           CGRectMake(0.0, 0.0, rect.size.width, rect.size.height), image);
        CGContextRestoreGState(context);
        CGImageRelease(image);
    }
    if (bitmap != nullptr) {
        CGContextRelease(bitmap);
    }
    CGColorSpaceRelease(space);

    if (track.spectrogramCacheBuilding()) {
        [self drawMessage:[NSString stringWithFormat:@"analysing %d%%",
                                                     track.spectrogramCacheProgress()]
                  atPoint:NSMakePoint(rect.origin.x + 8.0, rect.origin.y + 8.0)
                    color:[NSColor systemRedColor]];
        [self scheduleSpectrogramRefresh];
    }
}

/*****************************************************************************
 * keyDown
 *
 * Keyboard input. Arrow keys move frames, Page Up/Down fast move, F-keys
 * trigger commands.
 *
 *****************************************************************************/
- (void)keyDown:(NSEvent*)event
{
    if (self.document != nullptr && self.document->audioPlayer.isPlaying()) {
        return;
    }
    NSString* chars = [event characters];
    if ([chars length] == 0) {
        [super keyDown:event];
        return;
    }

    const unichar key = [chars characterAtIndex:0];
    id delegate = [NSApp delegate];
    if ([delegate conformsToProtocol:@protocol(MsapStatusSink)] &&
        [(id<MsapStatusSink>)delegate handleNavigationKey:key]) {
        return;
    }

    [super keyDown:event];
}

/*****************************************************************************
 * mouseDown
 *
 * Gives the plot keyboard focus. Clicking a file name plays that track;
 * waveform marking remains on the right button.
 *
 *****************************************************************************/
- (void)notifyStatus
{
    id delegate = [NSApp delegate];
    if ([delegate conformsToProtocol:@protocol(MsapStatusSink)]) {
        [(id<MsapStatusSink>)delegate refreshStatus];
    }
}

- (void)redrawBoth
{
    syncStereoState(*self.document, std::nullopt);
    [self setNeedsDisplay:YES];
    for (NSView* sibling in [[self superview] subviews]) {
        [sibling setNeedsDisplay:YES];
    }
    [self notifyStatus];
}

- (bool)pendingMark
{
    return self.isUpperPanel ? self.document->pendingMarkUpper
                             : self.document->pendingMarkLower;
}

- (void)setPendingMark:(bool)pending
{
    if (self.isUpperPanel) {
        self.document->pendingMarkUpper = pending;
    } else {
        self.document->pendingMarkLower = pending;
    }
}

- (std::optional<size_t>)trackLabelAtPoint:(NSPoint)point
{
    __block std::optional<size_t> result;
    const PanelLayout layout = [self panelLayout];
    const msap::Panel& panel = [self panel];
    [self enumerateTrackLabels:layout
                         panel:panel
                         using:^(size_t slot, NSString*, NSRect rect) {
                           if (!result.has_value() && NSPointInRect(point, rect)) {
                               result = slot;
                           }
                         }];
    return result;
}

- (void)mouseDown:(NSEvent*)event
{
    if (self.document == nullptr) {
        return;
    }

    [[self window] makeFirstResponder:self];

    const NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
    const auto slot = [self trackLabelAtPoint:location];
    id delegate = [NSApp delegate];
    if (slot.has_value() &&
        [delegate conformsToProtocol:@protocol(MsapStatusSink)]) {
        [(id<MsapStatusSink>)delegate playTrackInUpperPanel:self.isUpperPanel
                                                       slot:*slot];
        return;
    }

    // WinSap does all waveform marking on the right button.
    [self redrawBoth];
}

/*****************************************************************************
 * rightMouseDown
 *
 * WinSap marks with three right clicks rather than a drag: the first sets the
 * left edge and shows "Mark Left", the second sets the right edge, swapping if
 * the clicks arrived backwards, and shows "Mark All", and the third clears the
 * mark. A right click while a clip is playing stops it instead.
 *
 *****************************************************************************/
- (void)rightMouseDown:(NSEvent*)event
{
    if (self.document == nullptr) {
        return;
    }

    id delegate = [NSApp delegate];
    if ([delegate conformsToProtocol:@protocol(MsapStatusSink)] &&
        [(id<MsapStatusSink>)delegate stopPlaybackFromPanel]) {
        return;
    }

    [[self window] makeFirstResponder:self];

    const NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];
    const auto slot = [self trackLabelAtPoint:location];
    if (slot.has_value() &&
        [delegate conformsToProtocol:@protocol(MsapStatusSink)]) {
        // Right-clicking a file name opens its context menu
        [(id<MsapStatusSink>)delegate showFileMenuInUpperPanel:self.isUpperPanel
                                                          slot:*slot
                                                         event:event
                                                          view:self];
        return;
    }

    msap::Panel& panel = [self panel];
    if (!panelHasWaveform(panel)) {
        [self redrawBoth];
        return;
    }

    const NSRect plot = [self plotRect];
    if (!NSPointInRect(location, plot)) {
        [self redrawBoth];
        return;
    }

    const size_t width = static_cast<size_t>(std::max(1.0, plot.size.width));
    const size_t pixel = static_cast<size_t>(
        std::clamp(location.x - NSMinX(plot), 0.0,
                   std::max(0.0, plot.size.width - 1.0)));
    const auto sample = panel.sampleIndexAtPixel(pixel, width);
    if (!sample.has_value()) {
        [self redrawBoth];
        return;
    }

    std::string error;
    if (panel.selectedSampleRange().has_value()) {
        panel.clearMark();
        [self setPendingMark:false];
    } else if (![self pendingMark]) {
        if (!panel.setMarkStart(*sample, error)) {
            [self redrawBoth];
            return;
        }
        if (self.isUpperPanel) {
            self.document->pendingMarkSampleUpper = *sample;
        } else {
            self.document->pendingMarkSampleLower = *sample;
        }
        [self setPendingMark:true];
    } else {
        if (!panel.setMarkEnd(*sample, error)) {
            [self redrawBoth];
            return;
        }
        [self setPendingMark:false];
    }
    [self redrawBoth];
}

/*****************************************************************************
 * updateTrackingAreas, mouseMoved, mouseExited
 *
 * Feeds the WinSap coordinate pane. The readout follows whichever picture is
 * on screen, so the spectrum and spectrogram report frequency rather than a
 * sample index.
 *
 *****************************************************************************/
- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    for (NSTrackingArea* area in [self trackingAreas]) {
        [self removeTrackingArea:area];
    }
    NSTrackingArea* area = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                     NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:area];
}

/*****************************************************************************
 * fileInfoTextAtPoint
 *
 * Returns the status bar description of the open file whose name is under the
 * point, or nil when the point is not over a name. The text matches XSap: the
 * full path, then either the parameter frame count or the stream format.
 *
 *****************************************************************************/
- (NSString*)fileInfoTextAtPoint:(NSPoint)point panel:(const msap::Panel&)panel
{
    __block NSString* result = nil;
    const PanelLayout layout = [self panelLayout];
    [self enumerateTrackLabels:layout
                         panel:panel
                         using:^(size_t slot, NSString*, NSRect rect) {
                           if (result != nil || !NSPointInRect(point, rect)) {
                               return;
                           }
                           const msap::Track* track = panel.track(slot);
                           if (track == nullptr) {
                               return;
                           }
                           NSString* path = [NSString stringWithUTF8String:track->path().c_str()];
                           if (track->type() == msap::TrackType::ParameterText) {
                               result = [NSString stringWithFormat:@"%@  |  Parameter file, Total frames = %zu",
                                                                   path, track->parameterFrameCount()];
                               return;
                           }
                           const unsigned int rate = track->effectiveSampleRate(self.document->rawSampleRate);
                           const char* channels =
                               !track->isStereoChannel()
                                   ? "Mono"
                                   : (track->channel() == 0 ? "Stereo (left channel)"
                                                            : "Stereo (right channel)");
                           const char* format = track->isWav()
                                                    ? msap::core::WavSampleFormatName(track->sampleFormat())
                                                    : "16-bit PCM";
                           result = [NSString stringWithFormat:
                                                  @"%@  |  %s%u Hz, %s, %s, %zu samples (%.3f sec)",
                                                  path, track->isWav() ? "WAV: " : "Raw PCM: ", rate,
                                                  track->isWav() ? channels : "Mono", format,
                                                  track->sampleCount(),
                                                  rate == 0U ? 0.0
                                                             : static_cast<double>(track->sampleCount()) / rate];
                         }];
    return result;
}

- (void)mouseMoved:(NSEvent*)event
{
    if (self.document == nullptr) {
        return;
    }
    const msap::Panel& panel = [self panel];
    self.document->coordinateText.clear();
    self.document->hoverFileText.clear();
    if (panel.openTrackCount() == 0) {
        [self notifyStatus];
        return;
    }

    const NSPoint location = [self convertPoint:[event locationInWindow] fromView:nil];

    // Only a file name in the frame information band produces the file
    // readout, the way XSap does it. Everywhere else the pane is left to the
    // last command message.
    NSString* hover = [self fileInfoTextAtPoint:location panel:panel];
    if (hover != nil) {
        self.document->hoverFileText = [hover UTF8String];
    }

    const NSRect plot = [self plotRect];
    if (!NSPointInRect(location, plot)) {
        [self notifyStatus];
        return;
    }

    double topHz = 0.0;
    unsigned int hoverRate = 0;
    const HoverAxis axis =
        hoverAxis(panel, self.document->rawSampleRate, topHz, hoverRate);
    if (axis == HoverAxis::Amplitude && !panelHasWaveform(panel)) {
        [self notifyStatus];
        return;
    }

    const size_t pixel = static_cast<size_t>(
        std::clamp(location.x - plot.origin.x, 0.0, std::max(0.0, plot.size.width - 1.0)));
    const auto sample = panel.sampleIndexAtPixel(
        pixel, static_cast<size_t>(std::max(1.0, plot.size.width)));
    if (!sample.has_value()) {
        [self notifyStatus];
        return;
    }

    const msap::SampleRange visible = panel.visibleSampleRange();
    const int64_t xCoord = *sample - visible.begin;
    const double ratio = std::clamp(
        (location.y - plot.origin.y) / std::max(1.0, plot.size.height - 2.0), 0.0, 1.0);
    const int yCoord = static_cast<int>(
        panel.upperLimit() - ratio * (panel.upperLimit() - panel.lowerLimit()));

    NSString* text = nil;
    if (axis == HoverAxis::SpectrumLine) {
        const double across = std::clamp(
            (location.x - plot.origin.x) / std::max(1.0, plot.size.width), 0.0, 1.0);
        text = [NSString stringWithFormat:@" (%ld Hz, %d dB)",
                                          std::lround(across * topHz), yCoord];
    } else if (axis == HoverAxis::Spectrogram) {
        const double up = std::clamp(
            (NSMaxY(plot) - location.y) / std::max(1.0, plot.size.height), 0.0, 1.0);
        text = [NSString stringWithFormat:@" (%@, %ld Hz)",
                                          formatTime(*sample, hoverRate), std::lround(up * topHz)];
    } else {
        text = [NSString stringWithFormat:@" (%lld, %d)",
                                          static_cast<long long>(xCoord), yCoord];
    }
    self.document->coordinateText = [text UTF8String];
    [self notifyStatus];
}

- (void)mouseExited:(NSEvent*)event
{
    (void)event;
    if (self.document != nullptr) {
        self.document->coordinateText.clear();
        self.document->hoverFileText.clear();
        [self notifyStatus];
    }
}

@end

// ===========================================================================
// MsapStatusBarView
//
// WinSap's six pane msctls_statusbar32, rebuilt with AppKit. The pane widths
// and their order are taken straight from ToolbarManager::CreateStatusline so
// the three ports read the same way: coordinate, up mark, down mark, raw
// rate, wav rate and a stretchy information pane.
// ===========================================================================
@interface MsapStatusBarView : NSView
@property(nonatomic, strong) NSArray<NSTextField*>* panes;
@end

@implementation MsapStatusBarView

// Right hand edges of the fixed panes, as in WinSap's {190, 290, 390, 490,
// 590, -1}. The last pane stretches to the window edge.
static const CGFloat kStatusPaneEdges[5] = {190.0, 290.0, 390.0, 490.0, 590.0};
static const NSInteger kStatusPaneCount = 6;

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    NSMutableArray<NSTextField*>* panes = [NSMutableArray array];
    for (NSInteger index = 0; index < kStatusPaneCount; ++index) {
        NSTextField* label = [[NSTextField alloc] initWithFrame:NSZeroRect];
        [label setEditable:NO];
        [label setSelectable:NO];
        [label setBordered:NO];
        [label setDrawsBackground:NO];
        [label setFont:[NSFont systemFontOfSize:11]];
        [label setTextColor:[NSColor labelColor]];
        [label setLineBreakMode:NSLineBreakByTruncatingTail];
        [[label cell] setUsesSingleLineMode:YES];
        [self addSubview:label];
        [panes addObject:label];
    }
    self.panes = panes;
    [self layoutPanes];
    return self;
}

- (BOOL)isFlipped
{
    return NO;
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [self layoutPanes];
}

/*****************************************************************************
 * layoutPanes
 *
 * Places the six panes between the separator lines. Fixed widths keep the
 * plot area from shifting as the hover readout changes length.
 *
 *****************************************************************************/
- (void)layoutPanes
{
    const CGFloat height = self.bounds.size.height;
    CGFloat left = 0.0;
    for (NSInteger index = 0; index < kStatusPaneCount; ++index) {
        const CGFloat right = (index < kStatusPaneCount - 1)
                                  ? kStatusPaneEdges[index]
                                  : std::max(kStatusPaneEdges[kStatusPaneCount - 2] + 40.0,
                                             self.bounds.size.width);
        [self.panes[index] setFrame:NSMakeRect(left + 6.0,
                                               (height - 15.0) / 2.0,
                                               std::max(10.0, right - left - 10.0),
                                               15.0)];
        left = right;
    }
}

/*****************************************************************************
 * drawRect
 *
 * Paints the sunken pane separators. Win32 draws them for free; on macOS the
 * lines have to be stroked so the panes stay visually distinct.
 *
 *****************************************************************************/
- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    NSRectClip(self.bounds);
    [[NSColor windowBackgroundColor] setFill];
    NSRectFill(self.bounds);

    [[NSColor separatorColor] setStroke];
    NSBezierPath* path = [NSBezierPath bezierPath];
    [path setLineWidth:1.0];
    [path moveToPoint:NSMakePoint(0.0, NSMaxY(self.bounds) - 0.5)];
    [path lineToPoint:NSMakePoint(NSMaxX(self.bounds), NSMaxY(self.bounds) - 0.5)];
    for (NSInteger index = 0; index < kStatusPaneCount - 1; ++index) {
        const CGFloat x = kStatusPaneEdges[index] + 0.5;
        if (x >= NSMaxX(self.bounds)) {
            break;
        }
        [path moveToPoint:NSMakePoint(x, 4.0)];
        [path lineToPoint:NSMakePoint(x, NSMaxY(self.bounds) - 4.0)];
    }
    [path stroke];
}

@end

// ===========================================================================
// MsapContentView
//
// Lays out the two panels and the status bar. WinSap and XSap both split the
// plot area deterministically rather than offering a draggable divider, so a
// plain container is a closer match than NSSplitView; a panel switched off
// from the Up or Down menu gives its height to the other one.
// ===========================================================================
@interface MsapContentView : NSView
@property(nonatomic, weak) NSView* upperPanelView;
@property(nonatomic, weak) NSView* lowerPanelView;
@property(nonatomic, weak) NSView* statusBarView;
- (void)layoutContents;
@end

@implementation MsapContentView

// The one pixel gap left between the two panel frames has to read as black,
// not as the window background.
- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    NSRectClip(self.bounds);
    [[NSColor blackColor] setFill];
    NSRectFill(self.bounds);
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [self layoutContents];
}

// AppKit reaches a layer backed content view through several different paths
// depending on how the window was resized, so every one of them relayouts.
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    (void)oldSize;
    [self layoutContents];
}

- (void)layout
{
    [super layout];
    [self layoutContents];
}

- (void)layoutContents
{
    const NSRect bounds = self.bounds;
    const CGFloat width = bounds.size.width;
    [self.statusBarView setFrame:NSMakeRect(0.0, 0.0, width, kStatusBarHeight)];

    const CGFloat plotHeight = std::max(0.0, bounds.size.height - kStatusBarHeight);
    const BOOL upperShown = self.upperPanelView != nil && ![self.upperPanelView isHidden];
    const BOOL lowerShown = self.lowerPanelView != nil && ![self.lowerPanelView isHidden];

    if (upperShown && lowerShown) {
        // WinSap ends the upper panel at midY and starts the lower at midY+1,
        // and GDI's Rectangle omits its bottom edge, so a single black row
        // separates the two one-pixel frames. Reproduce that gap or the two
        // adjacent borders stack into one heavy double line.
        const CGFloat gap = self.upperPanelView != nil
                                ? panelChromeLineWidth(self.upperPanelView)
                                : 1.0;
        const CGFloat half = std::floor(std::max(0.0, plotHeight - gap) / 2.0);
        // The upper panel is the one at the top, so it takes the higher
        // origin in AppKit's bottom-left coordinate space.
        [self.lowerPanelView setFrame:NSMakeRect(0.0, kStatusBarHeight, width, half)];
        [self.upperPanelView setFrame:NSMakeRect(0.0, kStatusBarHeight + half + gap, width,
                                                 std::max(0.0, plotHeight - half - gap))];
    } else if (upperShown) {
        [self.upperPanelView setFrame:NSMakeRect(0.0, kStatusBarHeight, width, plotHeight)];
    } else if (lowerShown) {
        [self.lowerPanelView setFrame:NSMakeRect(0.0, kStatusBarHeight, width, plotHeight)];
    }
}

@end

// ===========================================================================
// MsapAppDelegate
//
// Owns the window and the menus. AppKit drives the lifecycle, so this is the
// closest thing to WinSap's window procedure.
// ===========================================================================
namespace {

struct PlaybackItem {
    bool upper = true;
    // A stereo item plays the upper slot as the left channel and the same
    // lower slot as the right one, with a cursor in both panels.
    bool stereo = false;
    int64_t begin = 0;
    std::vector<int16_t> samples;
    std::vector<int16_t> rightSamples;
    unsigned int sampleRate = 0;
    std::string description;
};

// Pane indices, mirroring WinSap's STATUSBAR_* constants in ToolbarManager.h.
constexpr NSInteger kPaneCoordinate = 0;
constexpr NSInteger kPaneMarkUp = 1;
constexpr NSInteger kPaneMarkDown = 2;
constexpr NSInteger kPaneRawRate = 3;
constexpr NSInteger kPaneWavRate = 4;
constexpr NSInteger kPaneInfo = 5;

} // namespace

/*****************************************************************************
 * MsapFileListSource
 *
 * Backs one list box of the Select Files sheet. It keeps the panel slot each
 * row came from, because closed slots leave gaps and the row number on its own
 * would no longer identify the track.
 *
 *****************************************************************************/
@interface MsapFileListSource : NSObject <NSTableViewDataSource>
- (void)addSlot:(size_t)slot name:(NSString*)name;
- (size_t)slotAtRow:(NSUInteger)row;
- (NSUInteger)count;
@end

@implementation MsapFileListSource {
    std::vector<size_t> slots_;
    NSMutableArray<NSString*>* names_;
}

- (instancetype)init
{
    self = [super init];
    if (self != nil) {
        names_ = [NSMutableArray array];
    }
    return self;
}

- (void)addSlot:(size_t)slot name:(NSString*)name
{
    slots_.push_back(slot);
    [names_ addObject:name];
}

- (size_t)slotAtRow:(NSUInteger)row
{
    return row < slots_.size() ? slots_[row] : 0U;
}

- (NSUInteger)count
{
    return slots_.size();
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView
{
    (void)tableView;
    return static_cast<NSInteger>(slots_.size());
}

- (id)tableView:(NSTableView*)tableView
    objectValueForTableColumn:(NSTableColumn*)column
                          row:(NSInteger)row
{
    (void)tableView;
    (void)column;
    return row >= 0 && static_cast<NSUInteger>(row) < [names_ count]
               ? names_[static_cast<NSUInteger>(row)]
               : @"";
}

@end

/*****************************************************************************
 * MsapOpenPanelTypeLink
 *
 * Ties the open panel's Parameter Text mode to the .par extension, as WinSap
 * ties its Parameter mode to the *.par filter: Parameter mode shows only .par
 * files, and selecting a .par file selects Parameter mode, so a parameter
 * text file cannot be opened as raw binary by accident.
 *
 *****************************************************************************/
static constexpr NSInteger kOpenModeParameter = 2;

@interface MsapOpenPanelTypeLink : NSObject <NSOpenSavePanelDelegate>
- (instancetype)initWithPanel:(NSOpenPanel*)panel mode:(NSPopUpButton*)mode;
- (void)modeChanged:(id)sender;
@end

@implementation MsapOpenPanelTypeLink {
    __weak NSOpenPanel* panel_;
    __weak NSPopUpButton* mode_;
}

- (instancetype)initWithPanel:(NSOpenPanel*)panel mode:(NSPopUpButton*)mode
{
    self = [super init];
    if (self != nil) {
        panel_ = panel;
        mode_ = mode;
    }
    return self;
}

- (void)applyFilter
{
    UTType* parameterType = [UTType typeWithFilenameExtension:@"par"];
    if ([mode_ indexOfSelectedItem] == kOpenModeParameter && parameterType != nil) {
        [panel_ setAllowedContentTypes:@[ parameterType ]];
    } else {
        [panel_ setAllowedContentTypes:@[ UTTypeAudio, UTTypeData, UTTypePlainText ]];
    }
}

- (void)modeChanged:(id)sender
{
    (void)sender;
    [self applyFilter];
}

- (void)panelSelectionDidChange:(id)sender
{
    NSURL* url = [sender URL];
    const bool parameterFile =
        url != nil && [[[url pathExtension] lowercaseString] isEqualToString:@"par"];
    if (parameterFile && [mode_ indexOfSelectedItem] != kOpenModeParameter) {
        [mode_ selectItemAtIndex:kOpenModeParameter];
        [self applyFilter];
    }
}

@end

@interface MsapAppDelegate : NSObject <NSApplicationDelegate, NSToolbarDelegate,
                                       NSToolbarItemValidation, NSWindowDelegate,
                                       NSMenuItemValidation,
                                       MsapStatusSink> {
    std::vector<PlaybackItem> playbackQueue_;
    size_t playbackQueueIndex_;
}
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) MsapContentView* contentContainer;
@property(nonatomic, strong) MsapPlotView* upperView;
@property(nonatomic, strong) MsapPlotView* lowerView;
@property(nonatomic, strong) MsapStatusBarView* statusBar;
@property(nonatomic, assign) Document* document;
- (void)openStartupFiles;
- (void)stopPlayback:(BOOL)userInitiated;
@end

@implementation MsapAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification
{
    (void)notification;
    [self buildMenuBar];
    [self buildWindow];
    [self openStartupFiles];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender
{
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification*)notification
{
    (void)notification;
    [self stopPlayback:NO];
}

- (BOOL)windowShouldClose:(NSWindow*)sender
{
    (void)sender;
    [self stopPlayback:NO];
    return YES;
}

- (void)showAlertWithTitle:(NSString*)title
                   message:(NSString*)message
                     style:(NSAlertStyle)style
{
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert setInformativeText:message];
    [alert setAlertStyle:style];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)setStatus:(NSString*)text
{
    self.document->statusText = text != nil ? [text UTF8String] : "";
    [self refreshStatus];
}

- (void)setPane:(NSInteger)pane text:(NSString*)text color:(NSColor*)color
{
    if (self.statusBar == nil || pane >= (NSInteger)[self.statusBar.panes count]) {
        return;
    }
    NSTextField* label = self.statusBar.panes[(NSUInteger)pane];
    [label setStringValue:text ?: @""];
    [label setTextColor:color ?: [NSColor labelColor]];
}

/*****************************************************************************
 * refreshStatus
 *
 * Refills WinSap's six status panes. The raw rate is greyed while no raw
 * stream is open because the setting has nothing to act on; the wav rate
 * stays blank until a wav file is loaded and turns red when the open files
 * disagree, exactly as the owner drawn Win32 panes behave.
 *
 *****************************************************************************/
- (void)refreshStatus
{
    if (self.statusBar == nil) {
        return;
    }

    [self setPane:kPaneCoordinate
             text:[NSString stringWithUTF8String:self.document->coordinateText.c_str()]
            color:nil];

    [self setPane:kPaneMarkUp
             text:self.document->pendingMarkUpper
                      ? @"Up Mark Left"
                      : (self.document->upperPanel.selectedSampleRange().has_value()
                             ? @"Up Mark All"
                             : @"")
                      color:nil];
    [self setPane:kPaneMarkDown
             text:self.document->pendingMarkLower
                      ? @"Down Mark Left"
                      : (self.document->lowerPanel.selectedSampleRange().has_value()
                             ? @"Down Mark All"
                             : @"")
                      color:nil];

    bool rawActive = false;
    bool wavFound = false;
    bool wavMixed = false;
    uint32_t firstWavRate = 0;
    for (const msap::Panel* panel :
         {&self.document->upperPanel, &self.document->lowerPanel}) {
        for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
            const msap::Track* track = panel->track(slot);
            if (track == nullptr || !track->isBinary()) {
                continue;
            }
            if (track->isWav()) {
                if (!wavFound) {
                    wavFound = true;
                    firstWavRate = track->sampleRate();
                } else if (track->sampleRate() != firstWavRate) {
                    wavMixed = true;
                }
            } else {
                rawActive = true;
            }
        }
    }

    [self setPane:kPaneRawRate
             text:[NSString stringWithFormat:@"Raw %u Hz", self.document->rawSampleRate]
            color:rawActive ? [NSColor labelColor] : [NSColor disabledControlTextColor]];
    [self setPane:kPaneWavRate
             text:wavFound ? [NSString stringWithFormat:@"Wav %u Hz", firstWavRate] : @""
            color:wavMixed ? [NSColor systemRedColor] : [NSColor labelColor]];

    NSString* info;
    if (self.document->audioPlayer.isPlaying() || self.document->hoverFileText.empty()) {
        info = [NSString stringWithUTF8String:self.document->statusText.c_str()];
    } else {
        info = [NSString stringWithUTF8String:self.document->hoverFileText.c_str()];
    }
    [self setPane:kPaneInfo text:info color:nil];
}

- (void)redraw
{
    if (syncStereoState(*self.document, std::nullopt)) {
        // A stereo channel lost its partner and was closed with it
        [self syncPanelVisibility];
        return;
    }
    [self.upperView setNeedsDisplay:YES];
    [self.lowerView setNeedsDisplay:YES];
    [self refreshStatus];
}

/*****************************************************************************
 * buildWindow
 *
 * Creates the main window and the two stacked panel views. setFrameAutosaveName
 * makes AppKit remember the position and size for us, which is what WinSap
 * hand rolls with registry reads and writes in OnDestroy.
 *
 *****************************************************************************/
- (void)buildWindow
{
    const NSRect frame = NSMakeRect(0, 0, kDefaultWindowWidth, kDefaultWindowHeight);
    const NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;

    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window setTitle:@"MSap"];
    [self.window setFrameAutosaveName:@"MsapMainWindow"];
    [self.window setBackgroundColor:[NSColor blackColor]];

    [self buildToolbar];

    // The container is populated before it becomes the content view; AppKit
    // then sizes it to the window and layoutContents runs again, so the panels
    // follow whatever the frame autosave restored.
    const NSRect content = [self.window contentLayoutRect];
    MsapContentView* container = [[MsapContentView alloc]
        initWithFrame:NSMakeRect(0.0, 0.0, content.size.width,
                                 std::max(content.size.height, 2.0 * kStatusBarHeight))];
    [container setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    self.contentContainer = container;

    self.statusBar = [[MsapStatusBarView alloc]
        initWithFrame:NSMakeRect(0.0, 0.0, content.size.width, kStatusBarHeight)];
    [container addSubview:self.statusBar];
    container.statusBarView = self.statusBar;

    self.upperView = [[MsapPlotView alloc] initWithFrame:NSZeroRect];
    self.upperView.document = self.document;
    self.upperView.isUpperPanel = YES;
    [container addSubview:self.upperView];
    container.upperPanelView = self.upperView;

    self.lowerView = [[MsapPlotView alloc] initWithFrame:NSZeroRect];
    self.lowerView.document = self.document;
    self.lowerView.isUpperPanel = NO;
    [container addSubview:self.lowerView];
    container.lowerPanelView = self.lowerView;

    [self.window setContentView:container];

    [self.window setAcceptsMouseMovedEvents:YES];
    [self.window setDelegate:self];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.upperView];
    [self syncPanelVisibility];
    [self refreshStatus];
}

/*****************************************************************************
 * windowDidResize
 *
 * The status bar and the split view track the window through their resizing
 * masks; the split still needs a nudge so the two panels keep equal heights.
 *
 *****************************************************************************/
- (void)windowDidResize:(NSNotification*)notification
{
    (void)notification;
    [self.contentContainer layoutContents];
    [self.statusBar setNeedsDisplay:YES];
}

/*****************************************************************************
 * syncPanelVisibility
 *
 * A panel is live once it holds at least one file. There is no active or
 * selected panel anywhere in MSap, so this only decides what is on screen.
 *
 *****************************************************************************/
- (void)syncPanelVisibility
{
    const bool upperLive = self.document->upperPanel.openTrackCount() != 0U;
    const bool lowerLive = self.document->lowerPanel.openTrackCount() != 0U;
    // WinSap and XSap give the whole plot area to a single loaded file and
    // only split the window once both slots hold something. With nothing
    // loaded at all both slots stay visible so either one can be opened into.
    const bool nothingLoaded = !upperLive && !lowerLive;
    [self.upperView setHidden:!(upperLive || nothingLoaded)];
    [self.lowerView setHidden:!(lowerLive || nothingLoaded)];
    [self.contentContainer layoutContents];
    [self redraw];
}

/*****************************************************************************
 * buildToolbar
 *
 * Rebuilds WinSap's fixed button strip. The order and the icons come from
 * ToolbarManager.cpp's kToolbarButtons table, so the three ports present the
 * same row of buttons; user customisation is off for the same reason.
 *
 *****************************************************************************/
- (void)buildToolbar
{
    NSToolbar* toolbar = [[NSToolbar alloc] initWithIdentifier:@"MsapToolbarWinSap"];
    [toolbar setDelegate:self];
    [toolbar setAllowsUserCustomization:NO];
    [toolbar setAutosavesConfiguration:NO];
    [toolbar setDisplayMode:NSToolbarDisplayModeIconOnly];
    [self.window setToolbar:toolbar];
}

/*****************************************************************************
 * addItemTo
 *
 * Adds one menu item and its shortcut. AppKit spells modifiers with a mask
 * rather than in the title, so the WinSap accelerator table is expressed here
 * as a key string plus a mask instead of the "\tCtrl+F5" suffixes.
 *
 *****************************************************************************/
static NSMenuItem* addItemTo(NSMenu* menu,
                             NSString* title,
                             SEL action,
                             id target,
                             NSString* key,
                             NSEventModifierFlags mask)
{
    NSMenuItem* item = [menu addItemWithTitle:title action:action keyEquivalent:key ?: @""];
    [item setTarget:target];
    if (key != nil && [key length] != 0) {
        [item setKeyEquivalentModifierMask:mask];
    }
    return item;
}

/*****************************************************************************
 * functionKey
 *
 * Turns an NSFnnFunctionKey constant into the one character string AppKit
 * wants for a key equivalent.
 *
 *****************************************************************************/
static NSString* functionKey(unichar key)
{
    return [NSString stringWithCharacters:&key length:1];
}

/*****************************************************************************
 * buildMenuBar
 *
 * Mirrors WinSap's IDC_WINSAP menu resource and XSap's buildMenuBar item for
 * item: File, Up, Down, Tools, Play, Options, Window and Help. macOS owns the
 * first menu, so About and Quit live in the application menu instead of under
 * Help and File, and WinSap's Ctrl accelerators become Command accelerators.
 *
 *****************************************************************************/
- (void)buildMenuBar
{
    NSMenu* menubar = [[NSMenu alloc] init];
    [NSApp setMainMenu:menubar];

    const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    const NSEventModifierFlags shiftCmd = NSEventModifierFlagShift | cmd;
    const NSEventModifierFlags none = 0;

    // ---- Application menu. macOS substitutes the app name for the title.
    NSMenuItem* appItem = [[NSMenuItem alloc] init];
    [menubar addItem:appItem];
    NSMenu* appMenu = [[NSMenu alloc] init];
    addItemTo(appMenu, @"About MSap...", @selector(onAbout:), self, @"", none);
    [appMenu addItem:[NSMenuItem separatorItem]];
    addItemTo(appMenu, @"Quit MSap", @selector(terminate:), nil, @"q", cmd);
    [appItem setSubmenu:appMenu];

    // ---- File
    NSMenuItem* fileItem = [[NSMenuItem alloc] init];
    [menubar addItem:fileItem];
    NSMenu* fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    addItemTo(fileMenu, @"Open Up ...", @selector(onOpenUp:), self,
              functionKey(NSF3FunctionKey), none);
    addItemTo(fileMenu, @"Open Down...", @selector(onOpenDown:), self,
              functionKey(NSF4FunctionKey), none);
    [fileMenu addItem:[NSMenuItem separatorItem]];
    addItemTo(fileMenu, @"Save as...", @selector(onSaveAs:), self,
              functionKey(NSF2FunctionKey), none);
    addItemTo(fileMenu, @"Close Files...", @selector(onCloseFiles:), self,
              functionKey(NSF9FunctionKey), none);
    addItemTo(fileMenu, @"Close All", @selector(onCloseAll:), self, @"w", cmd);
    [fileMenu addItem:[NSMenuItem separatorItem]];
    addItemTo(fileMenu, @"Reload All", @selector(onReloadAll:), self, @"a", cmd);
    [fileItem setSubmenu:fileMenu];

    // ---- Up and Down. The two menus are identical apart from the panel they
    // act on, exactly as in the WinSap resource.
    //
    // macOS has no Alt mnemonic walk. The three frequently used frame dialogs
    // use Command shortcuts, with Shift selecting the down panel.
    for (bool upper : {true, false}) {
        NSMenuItem* barItem = [[NSMenuItem alloc] init];
        [menubar addItem:barItem];
        NSMenu* menu = [[NSMenu alloc] initWithTitle:(upper ? @"Up" : @"Down")];
        addItemTo(menu, @"Frame Length",
                  upper ? @selector(onUpFrameLength:) : @selector(onDownFrameLength:),
                  self, @"f", upper ? cmd : shiftCmd);
        addItemTo(menu, @"Goto Frame",
                  upper ? @selector(onUpGotoFrame:) : @selector(onDownGotoFrame:),
                  self, @"g", upper ? cmd : shiftCmd);
        addItemTo(menu, @"Number of Frames",
                  upper ? @selector(onUpNumberOfFrames:) : @selector(onDownNumberOfFrames:),
                  self, @"n", upper ? cmd : shiftCmd);
        addItemTo(menu, @"Limit",
                  upper ? @selector(onUpLimit:) : @selector(onDownLimit:),
                  self, @"", none);
        addItemTo(menu, @"Page Numbers",
                  upper ? @selector(onUpPageNumbers:) : @selector(onDownPageNumbers:),
                  self, @"", none);
        [barItem setSubmenu:menu];
    }

    // ---- Tools
    NSMenuItem* toolsItem = [[NSMenuItem alloc] init];
    [menubar addItem:toolsItem];
    NSMenu* toolsMenu = [[NSMenu alloc] initWithTitle:@"Tools"];
    addItemTo(toolsMenu, @"Move Frame Forward", @selector(onMoveForward:), self,
              functionKey(NSRightArrowFunctionKey), none);
    addItemTo(toolsMenu, @"Move Frame Backward", @selector(onMoveBackward:), self,
              functionKey(NSLeftArrowFunctionKey), none);
    addItemTo(toolsMenu, @"Fast Forward", @selector(onFastForward:), self,
              functionKey(NSPageDownFunctionKey), none);
    addItemTo(toolsMenu, @"Fast Backward", @selector(onFastBackward:), self,
              functionKey(NSPageUpFunctionKey), none);
    // WinSap also pages a whole screenful on the up and down arrows and jumps
    // to the ends on Home and End. Those matter more on a Mac than on Windows
    // because a MacBook keyboard has no Page or Home keys of its own, only
    // Fn+Arrow, so the plain arrows are the only unmodified way to page.
    addItemTo(toolsMenu, @"Page Forward", @selector(onPageForward:), self,
              functionKey(NSDownArrowFunctionKey), none);
    addItemTo(toolsMenu, @"Page Backward", @selector(onPageBackward:), self,
              functionKey(NSUpArrowFunctionKey), none);
    addItemTo(toolsMenu, @"Go to Start", @selector(onGoToStart:), self,
              functionKey(NSHomeFunctionKey), none);
    addItemTo(toolsMenu, @"Go to End", @selector(onGoToEnd:), self,
              functionKey(NSEndFunctionKey), none);
    [toolsMenu addItem:[NSMenuItem separatorItem]];
    addItemTo(toolsMenu, @"Add Down to Up", @selector(onAddDownToUp:), self,
              functionKey(NSF2FunctionKey), cmd);
    [toolsMenu addItem:[NSMenuItem separatorItem]];
    addItemTo(toolsMenu, @"Expand", @selector(onExpand:), self,
              functionKey(NSF5FunctionKey), cmd);
    addItemTo(toolsMenu, @"Compress", @selector(onCompress:), self,
              functionKey(NSF6FunctionKey), cmd);
    [toolsMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* lockItem = addItemTo(toolsMenu, @"Lock Starting Frame",
                                     @selector(onToggleLock:), self, @"l", cmd);
    [lockItem setState:self.document->lockStartFrame ? NSControlStateValueOn
                                                     : NSControlStateValueOff];
    [toolsItem setSubmenu:toolsMenu];

    // ---- Play
    NSMenuItem* playItem = [[NSMenuItem alloc] init];
    [menubar addItem:playItem];
    NSMenu* playMenu = [[NSMenu alloc] initWithTitle:@"Play"];
    addItemTo(playMenu, @"Play All", @selector(onPlayAll:), self,
              functionKey(NSF5FunctionKey), none);
    addItemTo(playMenu, @"Play Up", @selector(onPlayUp:), self,
              functionKey(NSF6FunctionKey), none);
    addItemTo(playMenu, @"Play Down", @selector(onPlayDown:), self,
              functionKey(NSF7FunctionKey), none);
    addItemTo(playMenu, @"Stop", @selector(onPlayStop:), self,
              functionKey(NSF8FunctionKey), none);
    [playItem setSubmenu:playMenu];

    // ---- Options
    NSMenuItem* optItem = [[NSMenuItem alloc] init];
    [menubar addItem:optItem];
    NSMenu* optMenu = [[NSMenu alloc] initWithTitle:@"Options"];
    addItemTo(optMenu, @"Set Raw Samplingrate...", @selector(onSetRawSampleRate:),
              self, @"", none);
    addItemTo(optMenu, @"Save Raw Samplingrate", @selector(onSaveRawSampleRate:),
              self, @"", none);
    [optMenu addItem:[NSMenuItem separatorItem]];
    addItemTo(optMenu, @"Spectrogram Contrast Up", @selector(onSpectrogramContrastUp:),
              self, @"u", cmd);
    addItemTo(optMenu, @"Spectrogram Contrast Down", @selector(onSpectrogramContrastDown:),
              self, @"d", cmd);
    addItemTo(optMenu, @"Spectrogram Colour Map", @selector(onSpectrogramColorMap:),
              self, @"p", cmd);
    [optItem setSubmenu:optMenu];

    // ---- Window
    NSMenuItem* windowItem = [[NSMenuItem alloc] init];
    [menubar addItem:windowItem];
    NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    addItemTo(windowMenu, @"Look Marked Block", @selector(onLookMarked:), self,
              functionKey(NSF4FunctionKey), cmd);
    addItemTo(windowMenu, @"Sync Panels", @selector(onSyncPanels:), self,
              functionKey(NSF10FunctionKey), cmd);
    [windowMenu addItem:[NSMenuItem separatorItem]];
    addItemTo(windowMenu, @"Zoom In", @selector(onZoomInAll:), self,
              functionKey(NSF7FunctionKey), cmd);
    addItemTo(windowMenu, @"Zoom Out", @selector(onZoomOutAll:), self,
              functionKey(NSF8FunctionKey), cmd);
    addItemTo(windowMenu, @"View all", @selector(onViewAll:), self,
              functionKey(NSF9FunctionKey), cmd);
    [windowItem setSubmenu:windowMenu];

    // ---- Help
    NSMenuItem* helpItem = [[NSMenuItem alloc] init];
    [menubar addItem:helpItem];
    NSMenu* helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    addItemTo(helpMenu, @"MSap Help", @selector(onHelp:), self, @"?", cmd);
    [helpMenu addItem:[NSMenuItem separatorItem]];
    addItemTo(helpMenu, @"About MSap...", @selector(onAbout:), self, @"", none);
    [helpItem setSubmenu:helpMenu];
    [NSApp setHelpMenu:helpMenu];
}

// ---- Command handlers -----------------------------------------------------

/*****************************************************************************
 * showOpenDialog
 *
 * Presents an NSOpenPanel allowing the user to select a file to open. Returns
 * the path and mode, or empty path if the user cancelled. Filters are set to
 * show WAV and raw PCM files.
 *
 *****************************************************************************/
- (BOOL)showOpenDialog:(NSString*)title
            fileChosen:(NSURL**)outPath
             trackType:(msap::TrackType*)outTrackType
{
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    [panel setTitle:title];
    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setCanCreateDirectories:NO];

    [panel setAllowedContentTypes:@[ UTTypeAudio, UTTypeData, UTTypePlainText ]];

    NSStackView* options = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    [options setOrientation:NSUserInterfaceLayoutOrientationVertical];
    [options setAlignment:NSLayoutAttributeLeading];

    NSPopUpButton* mode = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    [mode addItemsWithTitles:@[ @"Waveform", @"Spectrum / Spectrogram", @"Parameter Text" ]];
    [options addArrangedSubview:mode];
    [panel setAccessoryView:options];

    // The panel and the popup hold the link weakly; keep it alive for runModal.
    NS_VALID_UNTIL_END_OF_SCOPE MsapOpenPanelTypeLink* typeLink =
        [[MsapOpenPanelTypeLink alloc] initWithPanel:panel mode:mode];
    [mode setTarget:typeLink];
    [mode setAction:@selector(modeChanged:)];
    [panel setDelegate:typeLink];

    const NSModalResponse response = [panel runModal];
    [panel setDelegate:nil];
    [mode setTarget:nil];
    if (response == NSModalResponseOK) {
        NSURL* url = [[panel URLs] firstObject];
        if (url != nil) {
            *outPath = url;
            switch ([mode indexOfSelectedItem]) {
            case 1:
                *outTrackType = msap::TrackType::FftAmplitude;
                break;
            case kOpenModeParameter:
                *outTrackType = msap::TrackType::ParameterText;
                break;
            default:
                *outTrackType = msap::TrackType::WaveformPcm16;
                break;
            }
            if (hasParameterExtension(std::filesystem::path([[url path] UTF8String]))) {
                *outTrackType = msap::TrackType::ParameterText;
            }
            return YES;
        }
    }
    return NO;
}

/*****************************************************************************
 * openFileInPanel
 *
 * Helper to open a file in either panel. The selected mode controls loading;
 * suspicious file extensions require confirmation before the open proceeds.
 *
 *****************************************************************************/
- (void)openFileInPanel:(BOOL)upper
{
    NSURL* fileURL = nil;
    msap::TrackType trackType = msap::TrackType::WaveformPcm16;
    if (![self showOpenDialog:(upper ? @"Open Upper File" : @"Open Lower File")
                   fileChosen:&fileURL
                    trackType:&trackType]) {
        return;
    }

    const std::filesystem::path path([fileURL.path UTF8String]);
    NSString* mismatch = nil;
    NSString* warningPreference = nil;
    if (trackType == msap::TrackType::ParameterText && !hasParameterExtension(path)) {
        warningPreference = kDefaultsWarnParameterExtensionMismatch;
        mismatch = @"You selected Parameter Text mode, but the file does not have a "
                   ".par extension.\n\nContinue opening and stop showing this "
                   "parameter-extension warning?";
    } else if (trackType != msap::TrackType::ParameterText && !hasBinaryExtension(path)) {
        warningPreference = kDefaultsWarnBinaryExtensionMismatch;
        mismatch = @"You selected Waveform or Spectrum / Spectrogram mode, but the file "
                   "extension is not .wav, .dat, .pcm, .exc, .res, .cod, or .raw.\n\n"
                   "Continue opening and stop showing this binary/spectrum-extension "
                   "warning?";
    }
    if (mismatch != nil && extensionWarningEnabled(warningPreference)) {
        NSAlert* alert = [[NSAlert alloc] init];
        [alert setMessageText:@"File Type Mismatch"];
        [alert setInformativeText:mismatch];
        [alert setAlertStyle:NSAlertStyleWarning];
        [[alert addButtonWithTitle:@"Cancel"] setKeyEquivalent:@"\e"];
        [alert addButtonWithTitle:@"Continue"];
        if ([alert runModal] != NSAlertSecondButtonReturn) {
            return;
        }
        disableExtensionWarning(warningPreference);
    }

    [self setupFile:path
            inUpper:upper
          trackType:trackType];
}

/*****************************************************************************
 * allowMonoOpenWithStereo
 *
 * A mono file may join a stereo file only in the upper panel, and only when
 * that keeps waveform and FFT mode apart (WinSap AllowMonoOpenWithStereo).
 *
 *****************************************************************************/
- (BOOL)allowMonoOpenWithStereo:(msap::TrackType)trackType
{
    if (!stereoActive(*self.document)) {
        return YES;
    }
    if (stereoFftActive(*self.document)) {
        [self showAlertWithTitle:@"Open File"
                         message:@"A stereo file is open in FFT mode, and no other file can be open with it.\n"
                                 "Close the stereo file first."
                           style:NSAlertStyleWarning];
        return NO;
    }
    if (trackType == msap::TrackType::FftAmplitude) {
        [self showAlertWithTitle:@"Open File"
                         message:@"A stereo file is open in waveform mode, so files cannot be opened in FFT mode.\n"
                                 "Close the stereo files first."
                           style:NSAlertStyleWarning];
        return NO;
    }
    return YES;
}

/*****************************************************************************
 * setupFile
 *
 * Routes a file chosen for one panel (WinSap SetupFileUp / SetupFileDown):
 * unreadable WAV formats are refused, a stereo WAV is split over both panels
 * and the stereo rules decide where a mono file may go.
 *
 *****************************************************************************/
- (BOOL)setupFile:(const std::filesystem::path&)path
          inUpper:(BOOL)upper
        trackType:(msap::TrackType)trackType
{
    // A .par name always means parameter text, whatever mode was chosen and
    // however the file was opened, so it is never loaded as raw samples.
    const bool parameterFile = hasParameterExtension(path);
    if (parameterFile) {
        trackType = msap::TrackType::ParameterText;
    }
    const std::optional<msap::core::WaveInfo> info =
        parameterFile ? std::nullopt : msap::probeWavFile(path);
    if (info.has_value()) {
        const std::string formatError = msap::wavFormatError(path, *info);
        if (!formatError.empty()) {
            [self showAlertWithTitle:@"Unsupported Format"
                             message:[NSString stringWithUTF8String:formatError.c_str()]
                               style:NSAlertStyleWarning];
            return NO;
        }
        // WAV files are always binary - override parameter mode if selected
        if (trackType == msap::TrackType::ParameterText) {
            trackType = msap::TrackType::WaveformPcm16;
        }
        if (info->channels == 2U) {
            return [self openStereoFile:path upperIndex:-1 trackType:trackType];
        }
    }
    if (!upper && stereoActive(*self.document)) {
        [self showAlertWithTitle:@"Open Down"
                         message:@"The lower panel shows the right channels of the open stereo files.\n"
                                 "Close the stereo files before opening a mono file in the lower panel."
                           style:NSAlertStyleWarning];
        return NO;
    }
    if (![self allowMonoOpenWithStereo:trackType]) {
        return NO;
    }
    return [self openPath:path inUpper:upper trackType:trackType];
}

/*****************************************************************************
 * openStereoFile
 *
 * Opens a stereo WAV with its left channel in upper slot upperIndex and its
 * right channel in the same lower slot; a negative index picks a free slot.
 * Files that cannot stay open with it are listed and closed only after the
 * user agrees (WinSap OpenStereoFile).
 *
 *****************************************************************************/
- (BOOL)openStereoFile:(const std::filesystem::path&)path
            upperIndex:(int)upperIndex
             trackType:(msap::TrackType)trackType
{
    // In FFT mode a stereo file stands alone. In waveform mode the lower panel
    // is given over to right channels and no file may be in FFT mode.
    Document* document = self.document;
    const bool fftMode = trackType == msap::TrackType::FftAmplitude;
    auto conflicts = [document, fftMode](bool upper, size_t slot) {
        const msap::Panel& panel = upper ? document->upperPanel : document->lowerPanel;
        const msap::Track* track = panel.track(slot);
        if (track == nullptr) {
            return false;
        }
        if (fftMode || track->type() == msap::TrackType::FftAmplitude) {
            return true;
        }
        return !upper && !track->isStereoChannel();
    };
    bool hasConflicts = false;
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks && !hasConflicts; ++slot) {
        hasConflicts = conflicts(true, slot) || conflicts(false, slot);
    }
    if (!hasConflicts) {
        return [self finishOpenStereoFile:path upperIndex:upperIndex trackType:trackType];
    }

    // Name each file that would be closed and the reason it cannot stay
    bool lowerFiles = false;
    bool fftFiles = false;
    std::string closeList;
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const bool closeUp = conflicts(true, slot);
        const bool closeDown = conflicts(false, slot);
        if (!closeUp && !closeDown) {
            continue;
        }
        const bool pair = isStereoPairSlot(*document, slot);
        for (int side = 0; side < 2; ++side) {
            const msap::Panel& panel = side == 0 ? document->upperPanel : document->lowerPanel;
            const msap::Track* track = panel.track(slot);
            if (track == nullptr || !(pair || (side == 0 ? closeUp : closeDown))) {
                continue;
            }
            if (pair && side == 1) {
                continue; // listed once as a stereo file
            }
            const bool fft = track->type() == msap::TrackType::FftAmplitude;
            fftFiles = fftFiles || fft;
            lowerFiles = lowerFiles || (side == 1 && !fft);
            closeList += "    ";
            closeList += pair ? "Both panels" : (side == 0 ? "Upper panel" : "Lower panel");
            closeList += ": ";
            closeList += track->path().filename().string();
            closeList += pair ? " (stereo" : " (";
            closeList += pair ? (fft ? ", FFT mode)" : ")") : (fft ? "FFT mode)" : "waveform)");
            closeList += "\n";
        }
    }

    std::string message = path.filename().string();
    if (fftMode) {
        message += " is a stereo file being opened in FFT mode. Its left channel goes "
                   "to the upper panel and its right channel to the lower panel, and a "
                   "stereo file in FFT mode must be the only open file.\n";
    } else {
        message += " is a stereo file being opened in waveform mode. Its left channel "
                   "goes to the upper panel and its right channel to the lower panel.\n";
        if (lowerFiles) {
            message += "\n- The lower panel can then only show the right channels of "
                       "stereo files, so mono files open there must be closed.\n";
        }
        if (fftFiles) {
            message += "\n- Waveform and FFT mode cannot be mixed while a stereo file "
                       "is open, so files open in FFT mode must be closed.\n";
        }
    }
    message += "\nThese files will be closed:\n";
    message += closeList;
    message += "\nClose them and open the stereo file?";

    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Open Stereo File"];
    [alert setInformativeText:[NSString stringWithUTF8String:message.c_str()]];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert addButtonWithTitle:@"Yes"];
    [[alert addButtonWithTitle:@"No"] setKeyEquivalent:@"\e"];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        [self setStatus:@"Stereo file not opened."];
        return NO;
    }

    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        bool closeUp = conflicts(true, slot);
        bool closeDown = conflicts(false, slot);
        // A stereo file goes as a whole
        if ((closeUp || closeDown) && isStereoPairSlot(*document, slot)) {
            closeUp = closeDown = true;
        }
        std::string ignored;
        if (closeUp) {
            document->upperPanel.closeTrack(slot, ignored);
        }
        if (closeDown) {
            document->lowerPanel.closeTrack(slot, ignored);
        }
    }
    for (const bool upper : {true, false}) {
        msap::Panel& panel = upper ? document->upperPanel : document->lowerPanel;
        if (!panelHasWaveform(panel)) {
            panel.clearMark();
            (upper ? document->pendingMarkUpper : document->pendingMarkLower) = false;
        }
    }
    // Everything else is gone, so an FFT stereo file takes the first slot
    return [self finishOpenStereoFile:path
                           upperIndex:fftMode ? 0 : upperIndex
                            trackType:trackType];
}

/*****************************************************************************
 * finishOpenStereoFile
 *
 * Loads both channels of a stereo file into the same slot of the two panels
 * once any conflicting files are closed, then syncs the lower view to the
 * upper one.
 *
 *****************************************************************************/
- (BOOL)finishOpenStereoFile:(const std::filesystem::path&)path
                  upperIndex:(int)upperIndex
                   trackType:(msap::TrackType)trackType
{
    Document* document = self.document;
    if (upperIndex < 0 || upperIndex >= static_cast<int>(msap::Panel::kMaxTracks)) {
        upperIndex = static_cast<int>(msap::Panel::kMaxTracks) - 1;
        for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
            if (document->upperPanel.track(slot) == nullptr) {
                upperIndex = static_cast<int>(slot);
                break;
            }
        }
    }
    const size_t slot = static_cast<size_t>(upperIndex);
    std::string error;
    document->upperPanel.closeTrack(slot, error);
    document->lowerPanel.closeTrack(slot, error);
    error.clear();

    msap::TrackOpenOptions options;
    options.rawPcmSampleRate = document->rawSampleRate;
    options.channel = 0;
    bool opened = document->upperPanel.openTrackAt(slot, path, trackType, options, error);
    if (opened) {
        options.channel = 1;
        opened = document->lowerPanel.openTrackAt(slot, path, trackType, options, error);
    }
    if (!opened) {
        std::string ignored;
        document->upperPanel.closeTrack(slot, ignored);
        document->lowerPanel.closeTrack(slot, ignored);
        [self syncPanelVisibility];
        [self showAlertWithTitle:@"Open Failed"
                         message:[NSString stringWithUTF8String:error.c_str()]
                           style:NSAlertStyleCritical];
        return NO;
    }

    syncStereoState(*document, true);
    [self syncPanelVisibility];
    [self setStatus:[NSString stringWithFormat:
                                  @"Opened stereo %s in slot %zu: left channel up, right channel down.",
                                  path.string().c_str(), slot + 1U]];
    [self redraw];
    return YES;
}

- (BOOL)openPath:(const std::filesystem::path&)path
         inUpper:(BOOL)upper
       trackType:(msap::TrackType)trackType
{
    std::string error;
    msap::Panel& panel = upper ? self.document->upperPanel : self.document->lowerPanel;

    msap::TrackOpenOptions options;
    options.rawPcmSampleRate = self.document->rawSampleRate;

    size_t openedSlot = 0;
    if (!panel.openTrack(path, trackType, options, openedSlot, error)) {
        [self showAlertWithTitle:@"Open Failed"
                         message:[NSString stringWithUTF8String:error.c_str()]
                           style:NSAlertStyleCritical];
        return NO;
    }

    [self syncPanelVisibility];
    [self setStatus:[NSString stringWithFormat:@"Opened %s in %@ slot %zu.",
                                               path.filename().string().c_str(),
                                               upper ? @"upper" : @"down",
                                               openedSlot + 1U]];
    [self redraw];
    return YES;
}

- (void)openStartupFiles
{
    for (size_t index = 0; index < self.document->startupFiles.size(); ++index) {
        const std::filesystem::path& path = self.document->startupFiles[index];
        const std::string extension = lowerExtension(path);
        msap::TrackType type = msap::TrackType::WaveformPcm16;
        if (hasParameterExtension(path)) {
            type = msap::TrackType::ParameterText;
        } else if (extension == ".fft") {
            type = msap::TrackType::FftAmplitude;
        }
        [self setupFile:path
                inUpper:(index % 2U) == 0U
              trackType:type];
    }
}

- (void)onOpenUp:(id)sender
{
    (void)sender;
    [self openFileInPanel:YES];
}

- (void)onOpenDown:(id)sender
{
    (void)sender;
    [self openFileInPanel:NO];
}

/*****************************************************************************
 * onSaveAs
 *
 * Save the currently marked block from the active panel. Panel must have
 * a file open and a marked region. Opens an NSSavePanel.
 *
 *****************************************************************************/
- (void)onSaveAs:(id)sender
{
    (void)sender;

    // Save As writes a marked range, so the mark itself picks the panel. The
    // upper one wins if both are marked. There is no active panel to consult.
    msap::Panel* panel = [self panelHoldingMark];
    const auto range = panel->selectedSampleRange();
    if (!range.has_value() || range->empty()) {
        [self showAlertWithTitle:@"Save Failed"
                         message:@"Mark a complete waveform range first."
                           style:NSAlertStyleWarning];
        return;
    }

    const msap::Track* track = panel->track(0);
    if (track == nullptr || range->end > static_cast<int64_t>(track->sampleCount())) {
        [self showAlertWithTitle:@"Save Failed"
                         message:@"Waveform slot 0 does not cover the marked range."
                           style:NSAlertStyleCritical];
        return;
    }
    if (track->type() != msap::TrackType::WaveformPcm16) {
        [self showAlertWithTitle:@"Save Failed"
                         message:@"Slot 0 is not a waveform."
                           style:NSAlertStyleCritical];
        return;
    }

    NSSavePanel* savePanel = [NSSavePanel savePanel];
    [savePanel setTitle:@"Save Marked Block"];
    [savePanel setNameFieldStringValue:@"marked.wav"];
    [savePanel setAllowedContentTypes:@[ [UTType typeWithFilenameExtension:@"wav"] ]];
    [savePanel setCanCreateDirectories:YES];

    if ([savePanel runModal] == NSModalResponseOK) {
        NSURL* url = [savePanel URL];
        const std::string path([url.path UTF8String]);
        const std::vector<int16_t> samples = track->copySamples(*range);
        std::string error;
        if (!msap::core::WriteWavFile(path, samples.data(), samples.size(),
                                      track->effectiveSampleRate(self.document->rawSampleRate),
                                      error)) {
            [self showAlertWithTitle:@"Save Failed"
                             message:[NSString stringWithUTF8String:error.c_str()]
                               style:NSAlertStyleCritical];
            return;
        }
        [self setStatus:[NSString stringWithFormat:@"Saved %zu samples to %@.",
                                                   samples.size(), url.lastPathComponent]];
    }
}

/*****************************************************************************
 * buildFileListTable
 *
 * One of the two list boxes in the Select Files sheet. WinSap uses
 * LBS_EXTENDEDSEL, so the table allows any combination of rows. The scroll
 * view is returned and the table is handed back through the out parameter.
 *
 *****************************************************************************/
static NSScrollView* buildFileListTable(NSRect frame,
                                        MsapFileListSource* source,
                                        NSTableView** tableOut)
{
    NSTableView* table = [[NSTableView alloc] initWithFrame:frame];
    NSTableColumn* column =
        [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [column setWidth:frame.size.width - 4.0];
    [table addTableColumn:column];
    [table setHeaderView:nil];
    [table setAllowsMultipleSelection:YES];
    [table setAllowsEmptySelection:YES];
    [table setDataSource:source];

    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:frame];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setDocumentView:table];
    *tableOut = table;
    return scroll;
}

/*****************************************************************************
 * runSelectFilesDialog
 *
 * WinSap's IDD_LISTDIALOG, rebuilt on an NSAlert. Two multiple selection
 * lists show the open files of the upper and down panels, and the tick marks
 * come back as the slot numbers to act on. There is no active panel involved;
 * this is how WinSap has always chosen which files File Close operates on.
 * Returns NO when the user cancels.
 *
 *****************************************************************************/
- (BOOL)runSelectFilesDialogUpper:(std::vector<size_t>*)upperSlots
                            lower:(std::vector<size_t>*)lowerSlots
{
    MsapFileListSource* upperSource = [[MsapFileListSource alloc] init];
    MsapFileListSource* lowerSource = [[MsapFileListSource alloc] init];
    for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
        const msap::Track* track = self.document->upperPanel.track(slot);
        if (track != nullptr) {
            [upperSource addSlot:slot
                            name:[NSString stringWithUTF8String:track->path().c_str()]];
        }
        track = self.document->lowerPanel.track(slot);
        if (track != nullptr) {
            [lowerSource addSlot:slot
                            name:[NSString stringWithUTF8String:track->path().c_str()]];
        }
    }
    if ([upperSource count] == 0U && [lowerSource count] == 0U) {
        [self showAlertWithTitle:@"Select Files"
                         message:@"No files are open."
                           style:NSAlertStyleWarning];
        return NO;
    }

    const CGFloat width = 420.0;
    const CGFloat listHeight = 110.0;
    NSView* accessory =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 2 * listHeight + 44.0)];

    NSTableView* upperTable = nil;
    NSTableView* lowerTable = nil;
    NSTextField* (^label)(NSString*, CGFloat) = ^(NSString* text, CGFloat y) {
      NSTextField* field = [NSTextField labelWithString:text];
      [field setFrame:NSMakeRect(0, y, width, 16.0)];
      [accessory addSubview:field];
      return field;
    };

    label(@"Up Panel Files:", 2 * listHeight + 26.0);
    [accessory addSubview:buildFileListTable(
                              NSMakeRect(0, listHeight + 26.0, width, listHeight),
                              upperSource, &upperTable)];
    label(@"Down Panel Files:", listHeight + 6.0);
    [accessory addSubview:buildFileListTable(NSMakeRect(0, 0, width, listHeight),
                                             lowerSource, &lowerTable)];

    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Select Files"];
    [alert setInformativeText:@"Choose the files to close."];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert setAccessoryView:accessory];
    [[alert window] setInitialFirstResponder:upperTable];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return NO;
    }

    upperSlots->clear();
    lowerSlots->clear();
    [[upperTable selectedRowIndexes]
        enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
          upperSlots->push_back([upperSource slotAtRow:row]);
        }];
    [[lowerTable selectedRowIndexes]
        enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
          lowerSlots->push_back([lowerSource slotAtRow:row]);
        }];
    return YES;
}

/*****************************************************************************
 * onCloseFiles
 *
 * WinSap's File Close: pick any combination of the open files in either panel
 * and close just those. MSap has no active panel, so the dialog is the only
 * thing that decides.
 *
 *****************************************************************************/
- (void)onCloseFiles:(id)sender
{
    (void)sender;

    std::vector<size_t> upperSlots;
    std::vector<size_t> lowerSlots;
    if (![self runSelectFilesDialogUpper:&upperSlots lower:&lowerSlots]) {
        return;
    }
    if (upperSlots.empty() && lowerSlots.empty()) {
        [self setStatus:@"No files selected."];
        return;
    }

    [self onPlayStop:nil];
    std::string error;
    for (size_t slot : upperSlots) {
        self.document->upperPanel.closeTrack(slot, error);
    }
    for (size_t slot : lowerSlots) {
        self.document->lowerPanel.closeTrack(slot, error);
    }
    // A mark only means something while the panel still holds a waveform.
    if (self.document->upperPanel.openTrackCount() == 0U) {
        self.document->pendingMarkUpper = false;
    }
    if (self.document->lowerPanel.openTrackCount() == 0U) {
        self.document->pendingMarkLower = false;
    }
    [self syncPanelVisibility];
    [self setStatus:[NSString stringWithFormat:@"Closed %zu file(s).",
                                               upperSlots.size() + lowerSlots.size()]];
    [self redraw];
}

/*****************************************************************************
 * onCloseAll
 *
 * Close all tracks in both panels.
 *
 *****************************************************************************/
- (void)onCloseAll:(id)sender
{
    (void)sender;

    [self onPlayStop:nil];
    self.document->upperPanel.closeAll();
    self.document->lowerPanel.closeAll();
    [self setStatus:@"Closed all files."];
    [self redraw];
}

/*****************************************************************************
 * onReloadAll
 *
 * Reload all open tracks in both panels.
 *
 *****************************************************************************/
- (void)onReloadAll:(id)sender
{
    (void)sender;

    std::vector<std::string> failures;
    const size_t count = self.document->upperPanel.reloadAll(failures) +
                         self.document->lowerPanel.reloadAll(failures);
    if (self.document->upperPanel.openTrackCount() == 0U) {
        self.document->pendingMarkUpper = false;
    }
    if (self.document->lowerPanel.openTrackCount() == 0U) {
        self.document->pendingMarkLower = false;
    }
    [self syncPanelVisibility];

    if (!failures.empty()) {
        std::string msg = "Failed to reload:\n";
        for (const auto& f : failures) {
            msg += f + "\n";
        }
        [self showAlertWithTitle:@"Reload Incomplete"
                         message:[NSString stringWithUTF8String:msg.c_str()]
                           style:NSAlertStyleWarning];
    }

    [self setStatus:[NSString stringWithFormat:@"Reloaded %zu file(s).", count]];
    [self redraw];
}

// ---- Up and Down menus ---------------------------------------------------

- (msap::Panel&)panelFor:(BOOL)upper
{
    return upper ? self.document->upperPanel : self.document->lowerPanel;
}

/*****************************************************************************
 * panelHoldingMark
 *
 * Picks the panel a mark driven command should act on. MSap has no active or
 * selected panel, so the mark decides: the upper panel when it carries one,
 * otherwise the down panel. The upper panel is returned when neither is marked
 * so the caller can report the failure against a real panel.
 *
 *****************************************************************************/
- (msap::Panel*)panelHoldingMark
{
    if (self.document->upperPanel.selectedSampleRange().has_value()) {
        return &self.document->upperPanel;
    }
    if (self.document->lowerPanel.selectedSampleRange().has_value()) {
        return &self.document->lowerPanel;
    }
    return &self.document->upperPanel;
}

/*****************************************************************************
 * showInputWithTitle
 *
 * XSap's showInput helper, rebuilt on NSAlert with a text field accessory.
 * The validator returns nil on success or the message to show, which keeps
 * every rule inside the panel model rather than in the dialog code.
 *
 *****************************************************************************/
- (void)showInputWithTitle:(NSString*)title
                    prompt:(NSString*)prompt
                   initial:(NSString*)initial
                 validator:(NSString* (^)(NSString* text))validator
{
    while (true) {
        NSAlert* alert = [[NSAlert alloc] init];
        [alert setMessageText:title];
        [alert setInformativeText:prompt];
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];

        NSTextField* field =
            [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
        [field setStringValue:initial ?: @""];
        [alert setAccessoryView:field];
        [[alert window] setInitialFirstResponder:field];

        if ([alert runModal] != NSAlertFirstButtonReturn) {
            return;
        }
        NSString* text = [field stringValue];
        NSString* error = validator(text);
        if (error == nil) {
            return;
        }
        initial = text;
        [self showAlertWithTitle:@"Input rejected"
                         message:error
                           style:NSAlertStyleWarning];
    }
}

/*****************************************************************************
 * parseCount
 *
 * Accepts a non negative whole number. Anything else is rejected before it
 * can reach the panel model.
 *
 *****************************************************************************/
static BOOL parseCount(NSString* text, size_t* value, NSString** error)
{
    NSString* trimmed = [text stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] == 0) {
        *error = @"Enter a whole number.";
        return NO;
    }
    NSScanner* scanner = [NSScanner scannerWithString:trimmed];
    unsigned long long parsed = 0;
    if (![scanner scanUnsignedLongLong:&parsed] || ![scanner isAtEnd] ||
        [trimmed hasPrefix:@"-"]) {
        *error = @"Enter a whole number that is not negative.";
        return NO;
    }
    *value = static_cast<size_t>(parsed);
    return YES;
}

- (void)promptFrameLength:(BOOL)upper
{
    msap::Panel& panel = [self panelFor:upper];
    if (panel.openTrackCount() == 0U) {
        return;
    }
    [self showInputWithTitle:[NSString stringWithFormat:@"%@ frame length",
                                                        upper ? @"Upper" : @"Down"]
                      prompt:@"Frame length in samples (valid range: 1 or greater):"
                     initial:[NSString stringWithFormat:@"%zu", panel.frameLength()]
                   validator:^NSString*(NSString* text) {
                     size_t value = 0;
                     NSString* error = nil;
                     if (!parseCount(text, &value, &error)) {
                         return error;
                     }
                     std::string message;
                     msap::Panel& target = [self panelFor:upper];
                     if (!target.setFrameLength(value, message)) {
                         return [NSString stringWithUTF8String:message.c_str()];
                     }
                     if (upper && self.document->lockStartFrame &&
                         self.document->lowerPanel.openTrackCount() != 0U) {
                         std::string ignored;
                         self.document->lowerPanel.setFrameBegin(target.frameBegin(), ignored);
                     }
                     [self setStatus:value == target.frameLength()
                                         ? [NSString stringWithFormat:@"%@ frame length updated.",
                                                                      upper ? @"Upper" : @"Down"]
                                         : [NSString stringWithFormat:@"%@ frame length adjusted to %zu to fit the file.",
                                                                      upper ? @"Upper" : @"Down", target.frameLength()]];
                     [self redraw];
                     return (NSString*)nil;
                   }];
}

- (void)promptGotoFrame:(BOOL)upper
{
    msap::Panel& panel = [self panelFor:upper];
    if (panel.openTrackCount() == 0U) {
        return;
    }
    [self showInputWithTitle:[NSString stringWithFormat:@"%@ goto frame",
                                                        upper ? @"Upper" : @"Down"]
                      prompt:@"Frame index:"
                     initial:[NSString stringWithFormat:@"%zu", panel.frameBegin()]
                   validator:^NSString*(NSString* text) {
                     size_t value = 0;
                     NSString* error = nil;
                     if (!parseCount(text, &value, &error)) {
                         return error;
                     }
                     std::string message;
                     if (![self panelFor:upper].gotoFrame(value, message)) {
                         return [NSString stringWithUTF8String:message.c_str()];
                     }
                     // Lock Starting Frame drags the down panel along with the upper one.
                     if (self.document->lockStartFrame && upper &&
                         self.document->lowerPanel.openTrackCount() != 0U) {
                         std::string ignored;
                         self.document->lowerPanel.setFrameBegin(
                             self.document->upperPanel.frameBegin(), ignored);
                     }
                     const size_t actual = [self panelFor:upper].frameBegin();
                     [self setStatus:value == actual
                                         ? @"Frame position updated."
                                         : [NSString stringWithFormat:@"Frame position adjusted to %zu to fit the file.",
                                                                      actual]];
                     [self redraw];
                     return (NSString*)nil;
                   }];
}

- (void)promptVisibleFrames:(BOOL)upper
{
    msap::Panel& panel = [self panelFor:upper];
    if (panel.openTrackCount() == 0U) {
        return;
    }
    [self showInputWithTitle:[NSString stringWithFormat:@"%@ visible frames",
                                                        upper ? @"Upper" : @"Down"]
                      prompt:@"Number of frames to display (valid range: 1 or greater):"
                     initial:[NSString stringWithFormat:@"%zu", panel.visibleFrameCount()]
                   validator:^NSString*(NSString* text) {
                     size_t value = 0;
                     NSString* error = nil;
                     if (!parseCount(text, &value, &error)) {
                         return error;
                     }
                     std::string message;
                     if (![self panelFor:upper].setVisibleFrameCount(value, message)) {
                         return [NSString stringWithUTF8String:message.c_str()];
                     }
                     if (upper && self.document->lockStartFrame &&
                         self.document->lowerPanel.openTrackCount() != 0U) {
                         std::string ignored;
                         self.document->lowerPanel.setFrameBegin(
                             self.document->upperPanel.frameBegin(), ignored);
                     }
                     const size_t actual = [self panelFor:upper].visibleFrameCount();
                     [self setStatus:value == actual
                                         ? @"Visible frame count updated."
                                         : [NSString stringWithFormat:@"Visible frame count adjusted to %zu to fit the file.",
                                                                      actual]];
                     [self redraw];
                     return (NSString*)nil;
                   }];
}

- (void)promptFrameSkip:(BOOL)upper
{
    msap::Panel& panel = [self panelFor:upper];
    if (panel.openTrackCount() == 0U) {
        return;
    }
    [self showInputWithTitle:[NSString stringWithFormat:@"%@ Page Numbers",
                                                        upper ? @"Upper" : @"Down"]
                      prompt:@"Input number of frames to jump when using PageUp/PageDown (>0):"
                     initial:[NSString stringWithFormat:@"%zu", panel.frameSkip()]
                   validator:^NSString*(NSString* text) {
                     size_t value = 0;
                     NSString* error = nil;
                     if (!parseCount(text, &value, &error)) {
                         return error;
                     }
                     if (value == 0U) {
                         return @"Page size must be greater than zero.";
                     }
                     std::string message;
                     msap::Panel& target = [self panelFor:upper];
                     if (!target.setFrameSkip(value, message)) {
                         return [NSString stringWithUTF8String:message.c_str()];
                     }
                     [self setStatus:value == target.frameSkip()
                                         ? [NSString stringWithFormat:@"%@ PageUp/PageDown jump updated.",
                                                                      upper ? @"Upper" : @"Down"]
                                         : [NSString stringWithFormat:@"%@ PageUp/PageDown jump adjusted to %zu " "to fit the file.",
                                                                      upper ? @"Upper" : @"Down", target.frameSkip()]];
                     [self redraw];
                     return (NSString*)nil;
                   }];
}

- (void)promptLimits:(BOOL)upper
{
    msap::Panel& panel = [self panelFor:upper];
    if (panel.openTrackCount() == 0U) {
        return;
    }
    [self showInputWithTitle:[NSString stringWithFormat:@"%@ amplitude limits",
                                                        upper ? @"Upper" : @"Down"]
                      prompt:@"Enter lower and upper limits:"
                     initial:[NSString stringWithFormat:@"%g %g",
                                                        panel.lowerLimit(), panel.upperLimit()]
                   validator:^NSString*(NSString* text) {
                     NSArray<NSString*>* parts = [[text stringByTrimmingCharactersInSet:
                                                            [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                         componentsSeparatedByCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
                     NSMutableArray<NSString*>* fields = [NSMutableArray array];
                     for (NSString* part in parts) {
                         if ([part length] != 0) {
                             [fields addObject:part];
                         }
                     }
                     if ([fields count] != 2) {
                         return @"Enter lower and upper limits separated by whitespace.";
                     }
                     double values[2] = {0.0, 0.0};
                     for (NSUInteger index = 0; index < 2; ++index) {
                         NSScanner* scanner = [NSScanner scannerWithString:fields[index]];
                         if (![scanner scanDouble:&values[index]] || ![scanner isAtEnd] ||
                             !std::isfinite(values[index])) {
                             return @"Limits must be finite numbers.";
                         }
                     }
                     const bool reversed = values[0] > values[1];
                     if (reversed) {
                         std::swap(values[0], values[1]);
                     }
                     std::string message;
                     if (![self panelFor:upper].setAmplitudeLimits(values[0], values[1], message)) {
                         return [NSString stringWithUTF8String:message.c_str()];
                     }
                     [self setStatus:reversed ? @"Amplitude limits swapped and updated."
                                              : @"Amplitude limits updated."];
                     [self redraw];
                     return (NSString*)nil;
                   }];
}

- (void)onUpFrameLength:(id)sender
{
    (void)sender;
    [self promptFrameLength:YES];
}
- (void)onDownFrameLength:(id)sender
{
    (void)sender;
    [self promptFrameLength:NO];
}
- (void)onUpGotoFrame:(id)sender
{
    (void)sender;
    [self promptGotoFrame:YES];
}
- (void)onDownGotoFrame:(id)sender
{
    (void)sender;
    [self promptGotoFrame:NO];
}
- (void)onUpNumberOfFrames:(id)sender
{
    (void)sender;
    [self promptVisibleFrames:YES];
}
- (void)onDownNumberOfFrames:(id)sender
{
    (void)sender;
    [self promptVisibleFrames:NO];
}
- (void)onUpPageNumbers:(id)sender
{
    (void)sender;
    [self promptFrameSkip:YES];
}
- (void)onDownPageNumbers:(id)sender
{
    (void)sender;
    [self promptFrameSkip:NO];
}
- (void)onUpLimit:(id)sender
{
    (void)sender;
    [self promptLimits:YES];
}
- (void)onDownLimit:(id)sender
{
    (void)sender;
    [self promptLimits:NO];
}

// ---- Tools menu ----------------------------------------------------------

/*****************************************************************************
 * navigateActive
 *
 * Runs a navigation step and, when Lock Starting Frame is on and the upper
 * panel moved, repeats the starting frame on the down panel. WinSap routes the
 * arrow keys through the Tools commands, which always drive the upper panel,
 * and XSap picks the target the same way in navigate(): the upper panel
 * whenever it holds data, the down panel only when the upper one is empty.
 * Navigation deliberately ignores which panel was last opened or clicked, so
 * that with a file in each panel the arrows always move both.
 *
 *****************************************************************************/
- (void)navigateActive:(BOOL (^)(msap::Panel& panel, std::string& error))step
                status:(NSString*)status
{
    const bool useUpper = self.document->upperPanel.openTrackCount() != 0U;
    msap::Panel& panel = useUpper ? self.document->upperPanel
                                  : self.document->lowerPanel;
    if (panel.openTrackCount() == 0U) {
        return;
    }
    std::string error;
    if (!step(panel, error)) {
        [self setStatus:[NSString stringWithUTF8String:error.c_str()]];
        [self redraw];
        return;
    }
    if (self.document->lockStartFrame && useUpper &&
        self.document->lowerPanel.openTrackCount() != 0U) {
        std::string ignored;
        self.document->lowerPanel.setFrameBegin(panel.frameBegin(), ignored);
    }
    [self setStatus:status];
    [self redraw];
}

- (void)onMoveForward:(id)sender
{
    (void)sender;
    [self
        navigateActive:^BOOL(msap::Panel& panel, std::string& error) {
          return panel.moveOneFrame(1, error);
        }
                status:@"Moved forward."];
}

- (void)onMoveBackward:(id)sender
{
    (void)sender;
    [self
        navigateActive:^BOOL(msap::Panel& panel, std::string& error) {
          return panel.moveOneFrame(-1, error);
        }
                status:@"Moved backward."];
}

- (void)onFastForward:(id)sender
{
    (void)sender;
    [self
        navigateActive:^BOOL(msap::Panel& panel, std::string& error) {
          return panel.moveBySkip(1, error);
        }
                status:@"Moved forward by frame skip."];
}

- (void)onFastBackward:(id)sender
{
    (void)sender;
    [self
        navigateActive:^BOOL(msap::Panel& panel, std::string& error) {
          return panel.moveBySkip(-1, error);
        }
                status:@"Moved backward by frame skip."];
}

- (void)onPageForward:(id)sender
{
    (void)sender;
    [self
        navigateActive:^BOOL(msap::Panel& panel, std::string& error) {
          return panel.moveByScreen(1, error);
        }
                status:@"Paged forward."];
}

- (void)onPageBackward:(id)sender
{
    (void)sender;
    [self
        navigateActive:^BOOL(msap::Panel& panel, std::string& error) {
          return panel.moveByScreen(-1, error);
        }
                status:@"Paged backward."];
}

- (void)onGoToStart:(id)sender
{
    (void)sender;
    [self
        navigateActive:^BOOL(msap::Panel& panel, std::string& error) {
          return panel.moveToStart(error);
        }
                status:@"Moved to the first frame."];
}

- (void)onGoToEnd:(id)sender
{
    (void)sender;
    [self
        navigateActive:^BOOL(msap::Panel& panel, std::string& error) {
          return panel.moveToEnd(error);
        }
                status:@"Moved to the last frame."];
}

- (BOOL)handleNavigationKey:(unichar)key
{
    if (key == NSLeftArrowFunctionKey) {
        [self onMoveBackward:nil];
    } else if (key == NSRightArrowFunctionKey) {
        [self onMoveForward:nil];
    } else if (key == NSPageUpFunctionKey) {
        [self onFastBackward:nil];
    } else if (key == NSPageDownFunctionKey) {
        [self onFastForward:nil];
    } else if (key == NSUpArrowFunctionKey) {
        [self onPageBackward:nil];
    } else if (key == NSDownArrowFunctionKey) {
        [self onPageForward:nil];
    } else if (key == NSHomeFunctionKey) {
        [self onGoToStart:nil];
    } else if (key == NSEndFunctionKey) {
        [self onGoToEnd:nil];
    } else {
        return NO;
    }
    return YES;
}

- (void)onAddDownToUp:(id)sender
{
    self.document->overlayLower = !self.document->overlayLower;
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem*)sender setState:self.document->overlayLower
                                          ? NSControlStateValueOn
                                          : NSControlStateValueOff];
    }
    [self setStatus:self.document->overlayLower
                        ? @"Lower waveform overlay enabled."
                        : @"Lower waveform overlay disabled."];
    [self redraw];
}

/*****************************************************************************
 * changeAmplitudeAll
 *
 * Expand and Compress act on both panels at once, matching WinSap's Ctrl+F5
 * and Ctrl+F6. Only waveform panels have meaningful limits, so panels without
 * a file are skipped.
 *
 *****************************************************************************/
- (void)changeAmplitudeAll:(double)factor expand:(BOOL)expand status:(NSString*)status
{
    std::string error;
    for (msap::Panel* panel : {&self.document->upperPanel, &self.document->lowerPanel}) {
        if (panel->openTrackCount() == 0U) {
            continue;
        }
        if (expand) {
            panel->expandAmplitude(factor, error);
        } else {
            panel->compressAmplitude(factor, error);
        }
    }
    [self setStatus:status];
    [self redraw];
}

- (void)onExpand:(id)sender
{
    (void)sender;
    [self changeAmplitudeAll:0.5 expand:YES status:@"Expanded amplitude."];
}

- (void)onCompress:(id)sender
{
    (void)sender;
    [self changeAmplitudeAll:2.0 expand:NO status:@"Compressed amplitude."];
}

// ---- Play menu ----

/*****************************************************************************
 * stopPlaybackFromPanel
 *
 * Lets a right click in a panel stop a running clip. Returns YES when it
 * consumed the click so the panel knows not to mark as well.
 *
 *****************************************************************************/
- (BOOL)stopPlaybackFromPanel
{
    if (playbackQueue_.empty() && !self.document->audioPlayer.isPlaying()) {
        return NO;
    }
    [self stopPlayback:YES];
    return YES;
}

- (void)stopPlayback:(BOOL)userInitiated
{
    self.document->playbackGeneration.fetch_add(1);
    self.document->audioPlayer.stop();
    playbackQueue_.clear();
    playbackQueueIndex_ = 0;
    self.document->upperPanel.clearPlaybackCursor();
    self.document->lowerPanel.clearPlaybackCursor();
    self.document->hoverFileText.clear();
    [self setStatus:userInitiated ? @"Playback stopped." : @""];
    [self redraw];
}

- (BOOL)launchPlaybackItem:(const PlaybackItem&)item
{
    const std::uint64_t generation = self.document->playbackGeneration.load();
    const bool upper = item.upper;
    const bool stereo = item.stereo;
    const int64_t begin = item.begin;
    const size_t sampleCount = item.samples.size();
    __weak MsapAppDelegate* weakSelf = self;
    const unsigned int rate = item.sampleRate;
    const std::string description = item.description;
    auto callback = [weakSelf, generation, upper, stereo, begin, sampleCount, rate, description](
                        size_t played, msap::AudioPlayer::PlaybackEvent event) {
        dispatch_async(dispatch_get_main_queue(), ^{
          MsapAppDelegate* strongSelf = weakSelf;
          if (strongSelf == nil ||
              strongSelf.document->playbackGeneration.load() != generation) {
              return;
          }

          msap::Panel& panel = upper
                                   ? strongSelf.document->upperPanel
                                   : strongSelf.document->lowerPanel;
          msap::Panel& otherPanel = upper
                                        ? strongSelf.document->lowerPanel
                                        : strongSelf.document->upperPanel;
          if (event == msap::AudioPlayer::PlaybackEvent::Progress && played > 0) {
              std::string error;
              const size_t offset = std::min(played - 1U, sampleCount - 1U);
              panel.setPlaybackCursor(begin + static_cast<int64_t>(offset), error);
              if (stereo) {
                  otherPanel.setPlaybackCursor(begin + static_cast<int64_t>(offset), error);
              }
              [strongSelf setStatus:
                              [NSString stringWithFormat:@"%@  %s  (right-click to stop)",
                                                         formatTime(static_cast<long long>(std::min(played, sampleCount)), rate),
                                                         description.c_str()]];
              [strongSelf redraw];
              return;
          }

          panel.clearPlaybackCursor();
          if (stereo) {
              otherPanel.clearPlaybackCursor();
          }
          if (event == msap::AudioPlayer::PlaybackEvent::Completed &&
              strongSelf->playbackQueueIndex_ + 1U < strongSelf->playbackQueue_.size()) {
              ++strongSelf->playbackQueueIndex_;
              [strongSelf launchPlaybackItem:
                              strongSelf->playbackQueue_[strongSelf->playbackQueueIndex_]];
              return;
          }

          if (event == msap::AudioPlayer::PlaybackEvent::Failed) {
              const std::string error = strongSelf.document->audioPlayer.lastError();
              [strongSelf showAlertWithTitle:@"Playback Failed"
                                     message:[NSString stringWithUTF8String:error.c_str()]
                                       style:NSAlertStyleCritical];
          } else if (event == msap::AudioPlayer::PlaybackEvent::Completed) {
              [strongSelf setStatus:@"Playback complete."];
          }
          strongSelf->playbackQueue_.clear();
          strongSelf->playbackQueueIndex_ = 0;
          [strongSelf redraw];
        });
    };

    if (!self.document->audioPlayer.play(
            item.samples, item.sampleRate, std::move(callback),
            item.rightSamples.empty() ? nullptr : &item.rightSamples)) {
        const std::string error = self.document->audioPlayer.lastError();
        [self stopPlayback:NO];
        [self showAlertWithTitle:@"Playback Failed"
                         message:[NSString stringWithUTF8String:error.c_str()]
                           style:NSAlertStyleCritical];
        return NO;
    }
    [self setStatus:[NSString stringWithUTF8String:item.description.c_str()]];
    return YES;
}

- (BOOL)startPlaybackQueue:(std::vector<PlaybackItem>)items
{
    [self stopPlayback:NO];
    if (items.empty()) {
        [self showAlertWithTitle:@"Playback Failed"
                         message:@"No playable waveform tracks are open."
                           style:NSAlertStyleWarning];
        return NO;
    }
    playbackQueue_ = std::move(items);
    playbackQueueIndex_ = 0;
    return [self launchPlaybackItem:playbackQueue_.front()];
}

/*****************************************************************************
 * playbackItemInUpperPanel
 *
 * Builds a playback item for part of one waveform or FFT amplitude track. A
 * stereo item plays the upper slot as the left channel and the lower slot as
 * the right one. Returns nullopt with error set when nothing can be played.
 *
 *****************************************************************************/
- (std::optional<PlaybackItem>)playbackItemInUpperPanel:(BOOL)upper
                                                    slot:(size_t)slot
                                                   range:(msap::SampleRange)range
                                                  stereo:(BOOL)stereo
                                                   error:(std::string&)error
{
    const msap::Panel& panel =
        upper ? self.document->upperPanel : self.document->lowerPanel;
    const msap::Track* track = panel.track(slot);
    if (track == nullptr || !track->isBinary()) {
        error = "Only waveform and FFT amplitude tracks can be played.";
        return std::nullopt;
    }
    const msap::Track* rightTrack = nullptr;
    if (stereo) {
        if (!isStereoPairSlot(*self.document, slot) ||
            self.document->upperPanel.track(slot)->sampleCount() !=
                self.document->lowerPanel.track(slot)->sampleCount()) {
            error = "Both channels of the stereo file must be open to play it in stereo.";
            return std::nullopt;
        }
        track = self.document->upperPanel.track(slot);
        rightTrack = self.document->lowerPanel.track(slot);
    }
    range.end = std::min(range.end, static_cast<int64_t>(track->sampleCount()));
    if (range.begin < 0 || range.empty()) {
        error = "The selected file contains no playable samples.";
        return std::nullopt;
    }

    PlaybackItem item;
    item.upper = stereo ? true : upper;
    item.stereo = stereo;
    item.begin = range.begin;
    item.samples = track->copySamples(range);
    if (rightTrack != nullptr) {
        item.rightSamples = rightTrack->copySamples(range);
    }
    if (item.samples.empty() ||
        (rightTrack != nullptr && item.rightSamples.size() != item.samples.size())) {
        error = "The selected file contains no playable samples.";
        return std::nullopt;
    }
    item.sampleRate = track->effectiveSampleRate(self.document->rawSampleRate);
    item.description = "Playing " +
                       std::string(stereo ? "stereo" : (upper ? "upper" : "down")) +
                       " slot " + std::to_string(slot + 1U) + " (" +
                       track->path().filename().string() + ") at " +
                       std::to_string(item.sampleRate) + " Hz.";
    return item;
}

/*****************************************************************************
 * playTrackRangeInUpperPanel
 *
 * Plays part of one track, reporting a failure to build the item. Label
 * clicks, the file menu and Play Up/Down all come through here.
 *
 *****************************************************************************/
- (BOOL)playTrackRangeInUpperPanel:(BOOL)upper
                              slot:(size_t)slot
                             range:(msap::SampleRange)range
                            stereo:(BOOL)stereo
{
    std::string error;
    std::optional<PlaybackItem> item = [self playbackItemInUpperPanel:upper
                                                                 slot:slot
                                                                range:range
                                                               stereo:stereo
                                                                error:error];
    if (!item.has_value()) {
        [self showAlertWithTitle:@"Playback Failed"
                         message:[NSString stringWithUTF8String:error.c_str()]
                           style:NSAlertStyleWarning];
        return NO;
    }
    std::vector<PlaybackItem> items;
    items.push_back(std::move(*item));
    return [self startPlaybackQueue:std::move(items)];
}

/*****************************************************************************
 * playTrackInUpperPanel
 *
 * Plays one labelled file from start to finish; clicking either channel of a
 * stereo file plays the file in stereo.
 *
 *****************************************************************************/
- (void)playTrackInUpperPanel:(BOOL)upper slot:(size_t)slot
{
    if (!playbackQueue_.empty() || self.document->audioPlayer.isPlaying()) {
        [self setStatus:@"Stop playback before playing another file."];
        return;
    }

    const msap::Panel& panel =
        upper ? self.document->upperPanel : self.document->lowerPanel;
    const msap::Track* track = panel.track(slot);
    if (track == nullptr) {
        return;
    }
    const msap::SampleRange whole{0, static_cast<int64_t>(track->sampleCount())};
    [self playTrackRangeInUpperPanel:upper
                                slot:slot
                               range:whole
                              stereo:track->isStereoChannel()];
}

/*****************************************************************************
 * playMarkedAreaInUpperPanel
 *
 * Plays the complete mark of one file, in stereo when asked and the file is
 * a stereo channel (WinSap PlayMarkedArea).
 *
 *****************************************************************************/
- (BOOL)playMarkedAreaInUpperPanel:(BOOL)upper slot:(size_t)slot stereo:(BOOL)stereo
{
    const msap::Panel& panel =
        upper ? self.document->upperPanel : self.document->lowerPanel;
    const msap::Track* track = panel.track(slot);
    const auto range = panel.selectedSampleRange();
    if (track == nullptr || !track->isBinary() || !panel.markedAreaHasData(slot) ||
        !range.has_value()) {
        return NO;
    }
    return [self playTrackRangeInUpperPanel:upper
                                       slot:slot
                                      range:*range
                                     stereo:stereo && track->isStereoChannel()];
}

- (void)closeTrackInUpperPanel:(BOOL)upper slot:(size_t)slot
{
    msap::Panel& panel =
        upper ? self.document->upperPanel : self.document->lowerPanel;
    const msap::Track* track = panel.track(slot);
    if (track == nullptr) {
        return;
    }
    const std::string name = track->path().filename().string();

    std::string error;
    if (!panel.closeTrack(slot, error)) {
        [self showAlertWithTitle:@"Close Failed"
                         message:[NSString stringWithUTF8String:error.c_str()]
                           style:NSAlertStyleCritical];
        return;
    }
    // Closing one channel of a stereo file closes the other one too
    syncStereoState(*self.document, std::nullopt);

    if (!panelHasWaveform(self.document->upperPanel)) {
        self.document->upperPanel.clearMark();
        self.document->pendingMarkUpper = false;
    }
    if (!panelHasWaveform(self.document->lowerPanel)) {
        self.document->lowerPanel.clearMark();
        self.document->pendingMarkLower = false;
    }
    self.document->hoverFileText.clear();
    [self syncPanelVisibility];
    [self setStatus:[NSString stringWithFormat:@"Closed %s.", name.c_str()]];
    [self redraw];
}

/*****************************************************************************
 * showFileMenuInUpperPanel
 *
 * Pops up the menu for a right-clicked file name (WinSap ShowFileMenu):
 * Close file and the marked-area playback commands, plus whole-channel
 * playback for a stereo file. Marked-area items are disabled when the file
 * has no data in a complete mark. Each item's tag carries the panel and slot.
 *
 *****************************************************************************/
- (void)showFileMenuInUpperPanel:(BOOL)upper
                            slot:(size_t)slot
                           event:(NSEvent*)event
                            view:(NSView*)view
{
    const msap::Panel& panel =
        upper ? self.document->upperPanel : self.document->lowerPanel;
    const msap::Track* track = panel.track(slot);
    if (track == nullptr) {
        return;
    }
    const bool stereo = track->isStereoChannel();
    const bool playable = track->isBinary();
    const bool marked = playable && panel.markedAreaHasData(slot);
    NSString* channel = upper ? @"left" : @"right";
    const NSInteger tag = static_cast<NSInteger>(slot) * 2 + (upper ? 1 : 0);

    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    [menu setAutoenablesItems:NO];
    [addItemTo(menu, @"Close file", @selector(onFileMenuClose:), self, nil, 0) setTag:tag];
    [menu addItem:[NSMenuItem separatorItem]];
    if (stereo) {
        NSMenuItem* item = addItemTo(menu,
                                     [NSString stringWithFormat:@"Play this channel (%@)", channel],
                                     @selector(onFileMenuPlayChannel:), self, nil, 0);
        [item setTag:tag];
        [item setEnabled:playable];
        item = addItemTo(menu, @"Play marked area (stereo)",
                         @selector(onFileMenuPlayMarkedStereo:), self, nil, 0);
        [item setTag:tag];
        [item setEnabled:marked];
        item = addItemTo(menu,
                         [NSString stringWithFormat:@"Play marked area in this channel (%@)", channel],
                         @selector(onFileMenuPlayMarkedChannel:), self, nil, 0);
        [item setTag:tag];
        [item setEnabled:marked];
    } else {
        NSMenuItem* item = addItemTo(menu, @"Play marked area",
                                     @selector(onFileMenuPlayMarkedChannel:), self, nil, 0);
        [item setTag:tag];
        [item setEnabled:marked];
    }
    [NSMenu popUpContextMenu:menu withEvent:event forView:view];
}

- (void)onFileMenuClose:(id)sender
{
    const NSInteger tag = [(NSMenuItem*)sender tag];
    [self closeTrackInUpperPanel:(tag % 2) != 0 slot:static_cast<size_t>(tag / 2)];
}

- (void)onFileMenuPlayChannel:(id)sender
{
    const NSInteger tag = [(NSMenuItem*)sender tag];
    const BOOL upper = (tag % 2) != 0;
    const size_t slot = static_cast<size_t>(tag / 2);
    const msap::Panel& panel =
        upper ? self.document->upperPanel : self.document->lowerPanel;
    const msap::Track* track = panel.track(slot);
    if (track == nullptr) {
        return;
    }
    const msap::SampleRange whole{0, static_cast<int64_t>(track->sampleCount())};
    [self playTrackRangeInUpperPanel:upper slot:slot range:whole stereo:NO];
}

- (void)onFileMenuPlayMarkedStereo:(id)sender
{
    const NSInteger tag = [(NSMenuItem*)sender tag];
    [self playMarkedAreaInUpperPanel:(tag % 2) != 0 slot:static_cast<size_t>(tag / 2) stereo:YES];
}

- (void)onFileMenuPlayMarkedChannel:(id)sender
{
    const NSInteger tag = [(NSMenuItem*)sender tag];
    [self playMarkedAreaInUpperPanel:(tag % 2) != 0 slot:static_cast<size_t>(tag / 2) stereo:NO];
}

/*****************************************************************************
 * playPanel
 *
 * Plays the marked area of the first file in the panel that has data there;
 * a stereo file plays both channels (WinSap PlayPanelMark).
 *
 *****************************************************************************/
- (BOOL)playPanel:(BOOL)upper
{
    const msap::Panel& panel =
        upper ? self.document->upperPanel : self.document->lowerPanel;
    if (panel.openTrackCount() == 0U) {
        return NO;
    }
    const auto range = panel.selectedSampleRange();
    if (!range.has_value() || range->empty()) {
        [self setStatus:@"Mark an area first: right-click the waveform at its start and its end."];
        return NO;
    }
    const auto slot = panel.firstMarkedDataSlot();
    if (!slot.has_value()) {
        [self setStatus:@"No open file has data in the marked area."];
        return NO;
    }
    return [self playMarkedAreaInUpperPanel:upper slot:*slot stereo:YES];
}

/*****************************************************************************
 * onPlayAll
 *
 * Queues every open waveform and FFT amplitude file in upper-then-down
 * order; a stereo file plays once, in stereo, from its upper slot.
 *
 *****************************************************************************/
- (void)onPlayAll:(id)sender
{
    (void)sender;
    std::vector<PlaybackItem> items;
    for (const bool upper : {true, false}) {
        const msap::Panel& panel =
            upper ? self.document->upperPanel : self.document->lowerPanel;
        for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
            const msap::Track* track = panel.track(slot);
            if (track == nullptr || !track->isBinary() || track->sampleCount() == 0 ||
                (!upper && track->isStereoChannel())) {
                continue;
            }
            std::string error;
            const msap::SampleRange whole{0, static_cast<int64_t>(track->sampleCount())};
            std::optional<PlaybackItem> item = [self playbackItemInUpperPanel:upper
                                                                         slot:slot
                                                                        range:whole
                                                                       stereo:track->isStereoChannel()
                                                                        error:error];
            if (!item.has_value()) {
                [self showAlertWithTitle:@"Playback Failed"
                                 message:[NSString stringWithUTF8String:error.c_str()]
                                   style:NSAlertStyleWarning];
                return;
            }
            items.push_back(std::move(*item));
        }
    }
    [self startPlaybackQueue:std::move(items)];
}

- (void)onPlayUp:(id)sender
{
    (void)sender;
    [self playPanel:YES];
}

- (void)onPlayDown:(id)sender
{
    (void)sender;
    [self playPanel:NO];
}

- (void)onPlayStop:(id)sender
{
    (void)sender;
    [self stopPlayback:YES];
}

// ---- Options menu ----

- (void)onSetRawSampleRate:(id)sender
{
    (void)sender;
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Set Raw Sample Rate"];
    [alert setInformativeText:@"Sampling rate for raw PCM streams (Hz):"];
    [alert addButtonWithTitle:@"Set"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField* input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    [input setStringValue:[NSString stringWithFormat:@"%u", self.document->rawSampleRate]];
    [alert setAccessoryView:input];
    if ([alert runModal] != NSAlertFirstButtonReturn) {
        return;
    }

    const NSInteger rate = [input integerValue];
    if (rate < 1000 || rate > 768000) {
        [self showAlertWithTitle:@"Invalid Sample Rate"
                         message:@"Enter a value from 1000 through 768000 Hz."
                           style:NSAlertStyleWarning];
        return;
    }

    std::string error;
    for (msap::Panel* panel :
         {&self.document->upperPanel, &self.document->lowerPanel}) {
        for (size_t slot = 0; slot < msap::Panel::kMaxTracks; ++slot) {
            msap::Track* track = panel->track(slot);
            if (track != nullptr && track->isBinary() && !track->isWav() &&
                !track->setRawPcmSampleRate(static_cast<uint32_t>(rate), error)) {
                [self showAlertWithTitle:@"Sample Rate Failed"
                                 message:[NSString stringWithUTF8String:error.c_str()]
                                   style:NSAlertStyleCritical];
                return;
            }
        }
    }
    self.document->rawSampleRate = static_cast<unsigned int>(rate);
    [self setStatus:@"Raw PCM sample rate updated."];
    [self redraw];
}

- (void)onSaveRawSampleRate:(id)sender
{
    (void)sender;
    saveRawSampleRate(self.document->rawSampleRate);
    [self setStatus:@"Raw PCM sample rate saved."];
}

- (void)onSpectrogramContrastUp:(id)sender
{
    (void)sender;
    self.document->spectrogramRangeDb =
        std::max(20.0f, self.document->spectrogramRangeDb - 5.0f);
    saveSpectrogramRangeDb(self.document->spectrogramRangeDb);
    [self setStatus:
              [NSString stringWithFormat:@"Spectrogram Contrast Up: %.0f dB below peak.",
                                         self.document->spectrogramRangeDb]];
    [self redraw];
}

- (void)onSpectrogramContrastDown:(id)sender
{
    (void)sender;
    self.document->spectrogramRangeDb =
        std::min(120.0f, self.document->spectrogramRangeDb + 5.0f);
    saveSpectrogramRangeDb(self.document->spectrogramRangeDb);
    [self setStatus:
              [NSString stringWithFormat:@"Spectrogram Contrast Down: %.0f dB below peak.",
                                         self.document->spectrogramRangeDb]];
    [self redraw];
}

- (void)onSpectrogramColorMap:(id)sender
{
    (void)sender;
    self.document->spectrogramPalette =
        msap::core::NextSpectrogramPalette(self.document->spectrogramPalette);
    saveSpectrogramPalette(self.document->spectrogramPalette);
    [self setStatus:
              [NSString stringWithFormat:@"Spectrogram colour map: %s.",
                                         msap::core::SpectrogramPaletteName(
                                             self.document->spectrogramPalette)]];
    [self redraw];
}

- (void)onLookMarked:(id)sender
{
    (void)sender;
    msap::Panel& panel = *[self panelHoldingMark];
    const auto range = panel.selectedSampleRange();
    if (!range.has_value() || range->empty()) {
        [self showAlertWithTitle:@"Marked Block"
                         message:@"Set a complete mark before looking at it."
                           style:NSAlertStyleWarning];
        return;
    }
    const size_t frameLength = panel.frameLength();
    const size_t begin = static_cast<size_t>(range->begin) / frameLength;
    const size_t count = std::max<size_t>(
        1U, (static_cast<size_t>(range->length()) + frameLength - 1U) / frameLength);
    std::string error;
    panel.setVisibleFrameCount(count, error);
    panel.setFrameBegin(begin, error);
    if (&panel == &self.document->upperPanel &&
        self.document->lockStartFrame &&
        self.document->lowerPanel.openTrackCount() != 0U) {
        std::string ignored;
        self.document->lowerPanel.setFrameBegin(panel.frameBegin(), ignored);
    }
    [self setStatus:@"Showing marked block."];
    [self redraw];
}

- (void)onSyncPanels:(id)sender
{
    (void)sender;
    if (self.document->upperPanel.openTrackCount() == 0 ||
        self.document->lowerPanel.openTrackCount() == 0) {
        [self showAlertWithTitle:@"Sync Panels"
                         message:@"Both panels need an open file."
                           style:NSAlertStyleWarning];
        return;
    }
    msap::Panel copy = self.document->lowerPanel;
    std::string error;
    if (!copy.setFrameLength(self.document->upperPanel.frameLength(), error) ||
        !copy.setVisibleFrameCount(self.document->upperPanel.visibleFrameCount(), error) ||
        !copy.setFrameBegin(self.document->upperPanel.frameBegin(), error)) {
        [self showAlertWithTitle:@"Sync Panels"
                         message:[NSString stringWithUTF8String:error.c_str()]
                           style:NSAlertStyleWarning];
        return;
    }
    self.document->lowerPanel = std::move(copy);
    [self setStatus:@"Down panel synced to up panel."];
    [self redraw];
}

- (void)applyToBothPanels:(bool (msap::Panel::*)(std::string&))operation
                   status:(NSString*)status
{
    std::string error;
    if (self.document->upperPanel.openTrackCount() != 0) {
        (self.document->upperPanel.*operation)(error);
    }
    if (self.document->lowerPanel.openTrackCount() != 0) {
        (self.document->lowerPanel.*operation)(error);
    }
    if (self.document->lockStartFrame &&
        self.document->upperPanel.openTrackCount() != 0U &&
        self.document->lowerPanel.openTrackCount() != 0U) {
        self.document->lowerPanel.setFrameBegin(
            self.document->upperPanel.frameBegin(), error);
    }
    [self setStatus:status];
    [self redraw];
}

- (void)onZoomInAll:(id)sender
{
    (void)sender;
    [self applyToBothPanels:&msap::Panel::zoomIn status:@"Zoomed in."];
}

- (void)onZoomOutAll:(id)sender
{
    (void)sender;
    [self applyToBothPanels:&msap::Panel::zoomOut status:@"Zoomed out."];
}

- (void)onViewAll:(id)sender
{
    (void)sender;
    [self applyToBothPanels:&msap::Panel::viewAll status:@"Showing all frames."];
}

- (void)onToggleLock:(id)sender
{
    self.document->lockStartFrame = !self.document->lockStartFrame;
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        [(NSMenuItem*)sender setState:self.document->lockStartFrame
                                          ? NSControlStateValueOn
                                          : NSControlStateValueOff];
    }
    // WinSap aligns the panels the moment the lock goes on rather than waiting
    // for the next move, so the two pictures agree straight away.
    if (self.document->lockStartFrame &&
        self.document->upperPanel.openTrackCount() != 0U &&
        self.document->lowerPanel.openTrackCount() != 0U) {
        std::string ignored;
        self.document->lowerPanel.setFrameBegin(
            self.document->upperPanel.frameBegin(), ignored);
        [self redraw];
    }
    [self setStatus:self.document->lockStartFrame
                        ? @"Starting-frame lock enabled."
                        : @"Starting-frame lock disabled."];
}

// ---- Help menu ----

/*****************************************************************************
 * onHelp
 *
 * WinSap's Help Topics window, in WinSap's light colours, with the Mac's
 * keys and menus.
 *
 *****************************************************************************/
- (void)onHelp:(id)sender
{
    (void)sender;
    wavedsp::HelpTheme theme;
    theme.background = HelpRgb(255, 255, 255);
    theme.text = HelpRgb(32, 32, 32);
    theme.title = HelpRgb(0, 84, 147);
    theme.heading = HelpRgb(0, 102, 180);
    theme.muted = HelpRgb(110, 110, 110);
    theme.rule = HelpRgb(240, 244, 249);
    theme.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    wavedsp::ShowHelp(self.window, @"MSap Help", MsapHelpMarkup(), theme);
}

- (void)onAbout:(id)sender
{
    (void)sender;
    [self showAlertWithTitle:@"About MSap"
                     message:@"MSap 3.1.0 - Speech Analysis Program\n\n" "The macOS port of WinSap and XSap, which descend from the " "original DOS Sap."
                       style:NSAlertStyleInformational];
}

// ---- NSToolbarDelegate methods -------------------------------------------
//
// The button strip is WinSap's kToolbarButtons table verbatim, separators and
// all: open up, open down, save as | fast backward, move backward, move
// forward, fast forward, view all | zoom in, zoom out | play all, play up,
// play down | about.

- (NSArray*)toolbarAllowedItemIdentifiers:(NSToolbar*)toolbar
{
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSArray*)toolbarDefaultItemIdentifiers:(NSToolbar*)toolbar
{
    (void)toolbar;
    return @[ @"OpenUp", @"OpenDown", @"SaveAs",
              NSToolbarSpaceItemIdentifier,
              @"FastBackward", @"MoveBackward", @"MoveForward", @"FastForward", @"ViewAll",
              NSToolbarSpaceItemIdentifier,
              @"ZoomIn", @"ZoomOut",
              NSToolbarSpaceItemIdentifier,
              @"PlayAll", @"PlayUp", @"PlayDown",
              NSToolbarSpaceItemIdentifier,
              @"About" ];
}

/*****************************************************************************
 * toolbarImageNamed
 *
 * Loads one of the shared PNG icons. CMake copies them into
 * Contents/Resources/icons, which imageForResource: does not search, so the
 * subdirectory has to be named explicitly; the SF Symbol is only a fallback
 * for a broken bundle.
 *
 *****************************************************************************/
- (NSImage*)toolbarImageNamed:(NSString*)name systemSymbol:(NSString*)symbol
{
    NSString* path = [[NSBundle mainBundle] pathForResource:name
                                                     ofType:@"png"
                                                inDirectory:@"icons"];
    NSImage* image = path != nil
                         ? [[NSImage alloc] initWithContentsOfFile:path]
                         : nil;
    if (image == nil) {
        image = [[NSBundle mainBundle] imageForResource:name];
    }
    if (image == nil && symbol != nil) {
        image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:name];
    }
    [image setSize:NSMakeSize(24.0, 24.0)];
    return image;
}

- (NSToolbarItem*)toolbar:(NSToolbar*)toolbar
        itemForItemIdentifier:(NSString*)itemIdentifier
    willBeInsertedIntoToolbar:(BOOL)flag
{
    (void)toolbar;
    (void)flag;

    struct ToolbarSpec {
        NSString* identifier;
        NSString* label;
        NSString* icon;
        NSString* symbol;
        SEL action;
    };
    const ToolbarSpec specs[] = {
        {@"OpenUp", @"Open Up", @"openUp", @"arrow.up.doc",
         @selector(onOpenUp:)},
        {@"OpenDown", @"Open Down", @"openDown", @"arrow.down.doc",
         @selector(onOpenDown:)},
        {@"SaveAs", @"Save As", @"saveAs", @"square.and.arrow.down",
         @selector(onSaveAs:)},
        {@"FastBackward", @"Fast Backward", @"fastBackward", @"backward.fill",
         @selector(onFastBackward:)},
        {@"MoveBackward", @"Move Backward", @"moveBackward", @"chevron.left",
         @selector(onMoveBackward:)},
        {@"MoveForward", @"Move Forward", @"moveForward", @"chevron.right",
         @selector(onMoveForward:)},
        {@"FastForward", @"Fast Forward", @"fastForward", @"forward.fill",
         @selector(onFastForward:)},
        {@"ViewAll", @"View All", @"viewAll", @"arrow.up.left.and.arrow.down.right",
         @selector(onViewAll:)},
        {@"ZoomIn", @"Zoom In", @"zoomIn", @"plus.magnifyingglass",
         @selector(onZoomInAll:)},
        {@"ZoomOut", @"Zoom Out", @"zoomOut", @"minus.magnifyingglass",
         @selector(onZoomOutAll:)},
        {@"PlayAll", @"Play All", @"playAll", @"play.fill",
         @selector(onPlayAll:)},
        {@"PlayUp", @"Play Up", @"playUp", @"play.fill",
         @selector(onPlayUp:)},
        {@"PlayDown", @"Play Down", @"playDown", @"play.fill",
         @selector(onPlayDown:)},
        {@"About", @"About", @"about", @"info.circle",
         @selector(onAbout:)},
    };

    for (const ToolbarSpec& spec : specs) {
        if (![itemIdentifier isEqualToString:spec.identifier]) {
            continue;
        }
        NSToolbarItem* item =
            [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
        [item setTarget:self];
        [item setLabel:spec.label];
        [item setPaletteLabel:spec.label];
        [item setToolTip:spec.label];
        [item setAction:spec.action];
        [item setImage:[self toolbarImageNamed:spec.icon systemSymbol:spec.symbol]];
        return item;
    }
    return [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
}

/*****************************************************************************
 * validateMenuItem
 *
 * Keeps checkable items in step with the model and disables normal commands
 * while playback owns the document. Stop remains available.
 *
 *****************************************************************************/
- (BOOL)validateMenuItem:(NSMenuItem*)item
{
    const SEL action = [item action];
    const BOOL playbackActive =
        !playbackQueue_.empty() || self.document->audioPlayer.isPlaying();
    if (playbackActive && action != @selector(onPlayStop:)) {
        return NO;
    }
    if (action == @selector(onToggleLock:)) {
        [item setState:self.document->lockStartFrame ? NSControlStateValueOn
                                                     : NSControlStateValueOff];
    } else if (action == @selector(onAddDownToUp:)) {
        [item setState:self.document->overlayLower ? NSControlStateValueOn
                                                   : NSControlStateValueOff];
    }
    return YES;
}

- (BOOL)validateToolbarItem:(NSToolbarItem*)item
{
    if (playbackQueue_.empty() && !self.document->audioPlayer.isPlaying()) {
        return YES;
    }
    return [item action] == @selector(onPlayStop:);
}

@end

// ===========================================================================
// MsapApp - the C++ facade
// ===========================================================================
namespace msap {

struct MsapApp::Impl {
    Document document;
    MsapAppDelegate* delegate = nil;
};

MsapApp::MsapApp()
    : impl_(std::make_unique<Impl>())
{
}

MsapApp::~MsapApp() = default;

/*****************************************************************************
 * run
 *
 * Starts the AppKit run loop. The raw PCM sampling rate is read before the
 * window is created so the first paint already shows the stored value.
 *
 *****************************************************************************/
int MsapApp::run(int argc, char** argv)
{
    impl_->document.rawSampleRate = loadRawSampleRate();
    impl_->document.spectrogramPalette = loadSpectrogramPalette();
    impl_->document.spectrogramRangeDb = loadSpectrogramRangeDb();

    for (int index = 1; index < argc; ++index) {
        const std::string argument =
            argv != nullptr && argv[index] != nullptr ? argv[index] : "";
        if (argument == "--help") {
            std::cout << "Usage: msap [--help] [--version] [audio-file ...]\n";
            return 0;
        }
        if (argument == "--version") {
            std::cout << MSAP_VERSION << '\n';
            return 0;
        }
        if (argument.rfind("-psn_", 0) == 0) {
            continue;
        }
        if (!argument.empty() && argument.front() == '-') {
            std::cerr << "msap: unknown option '" << argument << "'\n";
            return 1;
        }
        impl_->document.startupFiles.emplace_back(argument);
    }

    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        impl_->delegate = [[MsapAppDelegate alloc] init];
        impl_->delegate.document = &impl_->document;
        [NSApp setDelegate:impl_->delegate];

        [NSApp activateIgnoringOtherApps:YES];
        [NSApp run];
    }
    return 0;
}

} // namespace msap
