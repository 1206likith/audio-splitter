#pragma once
#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <memory>
#include <thread>
#include <atomic>

class AudioCapturePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit AudioCapturePlugin(flutter::PluginRegistrarWindows* registrar);
  ~AudioCapturePlugin() override;

 private:
  void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void StartCapture();
  void StopCapture();
  void CaptureLoop();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;

  IMMDeviceEnumerator* device_enumerator_ = nullptr;
  IMMDevice* audio_device_ = nullptr;
  IAudioClient* audio_client_ = nullptr;
  IAudioCaptureClient* capture_client_ = nullptr;

  std::thread capture_thread_;
  std::atomic<bool> capturing_{false};
};
