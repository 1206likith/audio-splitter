#include "audio_capture_plugin.h"
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ksmedia.h>
#include <vector>
#include <stdexcept>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "uuid.lib")

namespace {
const char kChannelName[] = "com.audiosplitter.app/system_audio_control";
const char kEventChannelName[] = "com.audiosplitter.app/system_audio";
}  // namespace

// StreamHandler for the EventChannel
class AudioEventStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  AudioCapturePlugin* plugin;
  explicit AudioEventStreamHandler(AudioCapturePlugin* p) : plugin(p) {}

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) override;

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancelInternal(
      const flutter::EncodableValue* arguments) override;
};

// Module-level sink — the capture thread writes to this from a background
// thread, while OnListenInternal / OnCancelInternal run on the platform thread.
// Access is guarded by the fact that StartCapture is only called after the
// sink is set and StopCapture joins the thread before clearing it.
static std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> g_event_sink;

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
AudioEventStreamHandler::OnListenInternal(
    const flutter::EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) {
  g_event_sink = std::move(events);
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
AudioEventStreamHandler::OnCancelInternal(const flutter::EncodableValue* arguments) {
  g_event_sink = nullptr;
  return nullptr;
}

// static
void AudioCapturePlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<AudioCapturePlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

AudioCapturePlugin::AudioCapturePlugin(flutter::PluginRegistrarWindows* registrar) {
  // COM is already initialised by main.cpp (COINIT_APARTMENTTHREADED).
  // The capture thread will call CoInitialize for its own apartment.

  method_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    registrar->messenger(), kChannelName,
    &flutter::StandardMethodCodec::GetInstance());

  method_channel_->SetMethodCallHandler(
    [this](const auto& call, auto result) {
      HandleMethodCall(call, std::move(result));
    });

  event_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
    registrar->messenger(), kEventChannelName,
    &flutter::StandardMethodCodec::GetInstance());

  auto handler = std::make_unique<AudioEventStreamHandler>(this);
  event_channel_->SetStreamHandler(std::move(handler));
}

AudioCapturePlugin::~AudioCapturePlugin() {
  StopCapture();
}

void AudioCapturePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "startCapture") {
    StartCapture();
    result->Success();
  } else if (method_call.method_name() == "stopCapture") {
    StopCapture();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void AudioCapturePlugin::StartCapture() {
  if (capturing_) return;
  capturing_ = true;
  capture_thread_ = std::thread([this]() { CaptureLoop(); });
}

void AudioCapturePlugin::StopCapture() {
  if (!capturing_) return;
  capturing_ = false;
  if (capture_thread_.joinable()) capture_thread_.join();

  if (capture_client_) { capture_client_->Release(); capture_client_ = nullptr; }
  if (audio_client_) { audio_client_->Stop(); audio_client_->Release(); audio_client_ = nullptr; }
  if (audio_device_) { audio_device_->Release(); audio_device_ = nullptr; }
  if (device_enumerator_) { device_enumerator_->Release(); device_enumerator_ = nullptr; }
}

void AudioCapturePlugin::CaptureLoop() {
  // The capture thread needs its own COM apartment.
  CoInitialize(nullptr);

  HRESULT hr;

  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator), (void**)&device_enumerator_);
  if (FAILED(hr)) { capturing_ = false; CoUninitialize(); return; }

  // Use the default render endpoint — WASAPI loopback captures what is being
  // played through that endpoint, giving us system audio.
  hr = device_enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, &audio_device_);
  if (FAILED(hr)) { capturing_ = false; CoUninitialize(); return; }

  hr = audio_device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&audio_client_);
  if (FAILED(hr)) { capturing_ = false; CoUninitialize(); return; }

  // Request PCM16 stereo 48 kHz — the format Dart expects.
  WAVEFORMATEX wfx = {};
  wfx.wFormatTag      = WAVE_FORMAT_PCM;
  wfx.nChannels       = 2;
  wfx.nSamplesPerSec  = 48000;
  wfx.wBitsPerSample  = 16;
  wfx.nBlockAlign     = wfx.nChannels * wfx.wBitsPerSample / 8;  // 4
  wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;    // 192000
  wfx.cbSize          = 0;

  // 1-second buffer; 0 periodicity = shared mode default.
  REFERENCE_TIME hnsRequestedDuration = 10000000;
  hr = audio_client_->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                  AUDCLNT_STREAMFLAGS_LOOPBACK,
                                  hnsRequestedDuration, 0, &wfx, nullptr);
  if (FAILED(hr)) { capturing_ = false; CoUninitialize(); return; }

  hr = audio_client_->GetService(__uuidof(IAudioCaptureClient), (void**)&capture_client_);
  if (FAILED(hr)) { capturing_ = false; CoUninitialize(); return; }

  audio_client_->Start();

  // Reusable buffer — avoids a heap allocation on every 10ms capture tick.
  // resize() only reallocates when the new size exceeds capacity.
  std::vector<uint8_t> captureBuffer;

  while (capturing_) {
    Sleep(10);  // Poll every 10 ms

    UINT32 packetLength = 0;
    hr = capture_client_->GetNextPacketSize(&packetLength);
    if (FAILED(hr)) break;

    while (packetLength != 0) {
      BYTE*  pData              = nullptr;
      UINT32 numFramesAvailable = 0;
      DWORD  flags              = 0;

      hr = capture_client_->GetBuffer(&pData, &numFramesAvailable, &flags, nullptr, nullptr);
      if (FAILED(hr)) break;

      if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && g_event_sink != nullptr) {
        const int byteCount = numFramesAvailable * 4;  // 2 channels * 2 bytes/sample
        captureBuffer.resize(byteCount);
        memcpy(captureBuffer.data(), pData, byteCount);
        flutter::EncodableValue value(captureBuffer);
        g_event_sink->Success(value);
      }

      capture_client_->ReleaseBuffer(numFramesAvailable);

      hr = capture_client_->GetNextPacketSize(&packetLength);
      if (FAILED(hr)) break;
    }
  }

  audio_client_->Stop();
  CoUninitialize();
}
