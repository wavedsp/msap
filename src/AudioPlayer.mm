/************************************************************************
 *
 *  MSap - Audio Playback Implementation
 *
 *  FILE:      AudioPlayer.mm
 *
 *  PURPOSE:   Plays a span of samples on a background thread. Counterpart of
 *             WinSap's waveOut player and of XSap's PulseAudio / ALSA player.
 *             On macOS the backend is AudioQueue from AudioToolbox, which is
 *             part of the system, so MSap has no third party dependency at
 *             all.
 *
 *  STATUS:    COMPLETE. AudioQueue playback is buffered on a worker thread
 *             and reports consumed-sample progress to the AppKit layer.
 *
 *  Update:    2026.1
 *             2026.11 Finished flag set under its mutex so stop() cannot
 *                     miss the wake up; thread creation failure handled
 *
 ************************************************************************/

#import <AudioToolbox/AudioToolbox.h>

#include "AudioPlayer.h"

#include <algorithm>
#include <condition_variable>
#include <cstring>
#include <exception>
#include <new>

namespace msap {

namespace {

// Three buffers is the usual AudioQueue compromise: enough to ride out a
// scheduling hiccup without adding audible latency to the stop command.
constexpr int kBufferCount = 3;
constexpr UInt32 kFramesPerBuffer = 4096;

} // namespace

/*****************************************************************************
 * PlaybackState
 *
 * Shared between the caller and the worker thread. Held by shared_ptr so a
 * stop() that races with the end of playback cannot free it underneath the
 * AudioQueue callback.
 *
 *****************************************************************************/
struct AudioPlayer::PlaybackState {
    std::vector<std::int16_t> samples; // Interleaved when channels is 2
    unsigned int sampleRate = 16000;
    unsigned int channels = 1;
    PlaybackCallback callback;

    std::atomic<bool> abort{false};
    std::atomic<std::size_t> position{0};
    std::atomic<std::size_t> inFlight{0};
    std::atomic<bool> finished{false};

    std::mutex doneMutex;
    std::condition_variable doneSignal;

    std::string error;
};

namespace {

/*****************************************************************************
 * signalFinished
 *
 * Sets the finished flag under doneMutex. Setting it without the lock can
 * land between the worker's predicate check and its wait, losing the wake up
 * and leaving stop() (and so quitting during playback) blocked in join().
 *
 *****************************************************************************/
void signalFinished(AudioPlayer::PlaybackState* state)
{
    {
        std::lock_guard<std::mutex> guard(state->doneMutex);
        state->finished.store(true);
    }
    state->doneSignal.notify_all();
}

/*****************************************************************************
 * enqueueBuffer
 *
 * Copies the next chunk of samples into a queue buffer. The cumulative frame
 * count is stored on the buffer so the output callback reports audio that has
 * actually played, rather than audio that has merely been queued.
 *
 *****************************************************************************/
bool enqueueBuffer(AudioPlayer::PlaybackState* state,
                   AudioQueueRef queue,
                   AudioQueueBufferRef buffer)
{
    const std::size_t total = state->samples.size();
    std::size_t position = state->position.load();
    if (state->abort.load() || position >= total) {
        return false;
    }

    const std::size_t remaining = total - position;
    const std::size_t wanted = buffer->mAudioDataBytesCapacity / sizeof(std::int16_t);
    const std::size_t count = std::min(remaining, wanted);

    std::memcpy(buffer->mAudioData,
                state->samples.data() + position,
                count * sizeof(std::int16_t));
    buffer->mAudioDataByteSize = static_cast<UInt32>(count * sizeof(std::int16_t));
    buffer->mUserData = reinterpret_cast<void*>(
        static_cast<std::uintptr_t>((position + count) / state->channels));

    if (AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr) != noErr) {
        state->error = "AudioQueueEnqueueBuffer failed";
        signalFinished(state);
        return false;
    }

    state->position.store(position + count);
    state->inFlight.fetch_add(1);
    return true;
}

/*****************************************************************************
 * fillBuffer
 *
 * AudioQueue output callback. The supplied buffer has finished playing. It is
 * refilled when samples remain, otherwise the worker is released after the
 * final queued buffer drains.
 *
 *****************************************************************************/
void fillBuffer(void* userData, AudioQueueRef queue, AudioQueueBufferRef buffer)
{
    auto* state = static_cast<AudioPlayer::PlaybackState*>(userData);
    if (state == nullptr) {
        return;
    }

    const std::size_t played =
        static_cast<std::size_t>(reinterpret_cast<std::uintptr_t>(buffer->mUserData));
    state->inFlight.fetch_sub(1);
    if (state->callback) {
        state->callback(played, AudioPlayer::PlaybackEvent::Progress);
    }

    if (!state->abort.load() && enqueueBuffer(state, queue, buffer)) {
        return;
    }

    if (state->abort.load() || state->inFlight.load() == 0) {
        signalFinished(state);
        AudioQueueStop(queue, false);
    }
}

} // namespace

AudioPlayer::AudioPlayer() = default;

AudioPlayer::~AudioPlayer()
{
    stop();
}

bool AudioPlayer::play(const std::vector<std::int16_t>& samples,
                       unsigned int sampleRate,
                       PlaybackCallback callback,
                       const std::vector<std::int16_t>* rightSamples)
{
    if (rightSamples != nullptr && rightSamples->size() != samples.size()) {
        setLastError("play() requires both stereo channels to have the same length");
        return false;
    }
    return play(samples.data(), samples.size(), sampleRate, std::move(callback),
                rightSamples != nullptr ? rightSamples->data() : nullptr);
}

/*****************************************************************************
 * play
 *
 * Copies the requested span and starts the worker. Any playback already in
 * flight is stopped first, matching the behaviour of the other two ports.
 *
 *****************************************************************************/
bool AudioPlayer::play(const std::int16_t* samples,
                       std::size_t sampleCount,
                       unsigned int sampleRate,
                       PlaybackCallback callback,
                       const std::int16_t* rightSamples)
{
    if (samples == nullptr || sampleCount == 0 || sampleRate == 0) {
        setLastError("nothing to play");
        return false;
    }

    stop();
    setLastError({});

    auto state = std::make_shared<PlaybackState>();
    try {
        if (rightSamples != nullptr) {
            state->channels = 2;
            state->samples.resize(sampleCount * 2U);
            for (std::size_t i = 0; i < sampleCount; ++i) {
                state->samples[2U * i] = samples[i];
                state->samples[2U * i + 1U] = rightSamples[i];
            }
        } else {
            state->samples.assign(samples, samples + sampleCount);
        }
    } catch (const std::bad_alloc&) {
        setLastError("play() ran out of memory copying the PCM samples");
        return false;
    }
    state->sampleRate = sampleRate;
    state->callback = std::move(callback);

    {
        std::lock_guard<std::mutex> guard(mutex_);
        state_ = state;
    }

    playing_.store(true);
    // Thread creation can fail under resource pressure; an exception escaping
    // into the AppKit caller would terminate the program.
    try {
        worker_ = std::thread(&AudioPlayer::playbackThread, this, state);
    } catch (const std::exception&) {
        {
            std::lock_guard<std::mutex> guard(mutex_);
            state_.reset();
        }
        playing_.store(false);
        setLastError("play() could not start the playback thread");
        return false;
    }
    return true;
}

/*****************************************************************************
 * playbackThread
 *
 * Owns the AudioQueue for the duration of one play() call. AudioQueue
 * callbacks are delivered on an internal thread, so this one simply waits for
 * the finished flag and then tears the queue down.
 *
 *****************************************************************************/
void AudioPlayer::playbackThread(std::shared_ptr<PlaybackState> state)
{
    AudioStreamBasicDescription format = {};
    format.mSampleRate = state->sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    format.mChannelsPerFrame = state->channels;
    format.mBitsPerChannel = 16;
    format.mBytesPerFrame = 2 * state->channels;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = 2 * state->channels;

    AudioQueueRef queue = nullptr;
    OSStatus status = AudioQueueNewOutput(&format, fillBuffer, state.get(),
                                          nullptr, nullptr, 0, &queue);
    if (status != noErr || queue == nullptr) {
        setLastError("AudioQueueNewOutput failed");
        invokeCallback(state->callback, 0, PlaybackEvent::Failed);
        playing_.store(false);
        return;
    }

    for (int i = 0; i < kBufferCount; i++) {
        AudioQueueBufferRef buffer = nullptr;
        if (AudioQueueAllocateBuffer(queue, kFramesPerBuffer * 2 * state->channels, &buffer) != noErr) {
            setLastError("AudioQueueAllocateBuffer failed");
            AudioQueueDispose(queue, true);
            invokeCallback(state->callback, 0, PlaybackEvent::Failed);
            playing_.store(false);
            return;
        }
        if (!enqueueBuffer(state.get(), queue, buffer)) {
            break;
        }
    }

    if (state->inFlight.load() == 0) {
        setLastError(state->error.empty() ? "AudioQueue could not queue audio" : state->error);
        AudioQueueDispose(queue, true);
        invokeCallback(state->callback, 0, PlaybackEvent::Failed);
        playing_.store(false);
        return;
    }

    if (AudioQueueStart(queue, nullptr) != noErr) {
        setLastError("AudioQueueStart failed");
        AudioQueueDispose(queue, true);
        invokeCallback(state->callback, 0, PlaybackEvent::Failed);
        playing_.store(false);
        return;
    }

    {
        std::unique_lock<std::mutex> guard(state->doneMutex);
        state->doneSignal.wait(guard, [&state] { return state->finished.load(); });
    }

    // A clean end drains, an abort does not.
    AudioQueueStop(queue, state->abort.load() ? false : true);
    AudioQueueDispose(queue, true);

    const std::size_t played = state->position.load() / state->channels;
    PlaybackEvent event = PlaybackEvent::Completed;
    if (!state->error.empty()) {
        setLastError(state->error);
        event = PlaybackEvent::Failed;
    } else if (state->abort.load()) {
        event = PlaybackEvent::Cancelled;
    }

    playing_.store(false);
    invokeCallback(state->callback, played, event);
}

/*****************************************************************************
 * stop
 *
 * Asks the worker to abort and waits for it. Safe to call when nothing is
 * playing.
 *
 *****************************************************************************/
void AudioPlayer::stop()
{
    std::shared_ptr<PlaybackState> state;
    {
        std::lock_guard<std::mutex> guard(mutex_);
        state = state_;
    }

    if (state) {
        state->abort.store(true);
        signalFinished(state.get());
    }

    if (worker_.joinable()) {
        worker_.join();
    }

    {
        std::lock_guard<std::mutex> guard(mutex_);
        state_.reset();
    }
    playing_.store(false);
}

bool AudioPlayer::isPlaying() const noexcept
{
    return playing_.load();
}

std::string AudioPlayer::lastError() const
{
    std::lock_guard<std::mutex> guard(mutex_);
    return lastError_;
}

void AudioPlayer::setLastError(std::string error)
{
    std::lock_guard<std::mutex> guard(mutex_);
    lastError_ = std::move(error);
}

void AudioPlayer::invokeCallback(const PlaybackCallback& callback,
                                 std::size_t playedSamples,
                                 PlaybackEvent event)
{
    if (callback) {
        callback(playedSamples, event);
    }
}

} // namespace msap
