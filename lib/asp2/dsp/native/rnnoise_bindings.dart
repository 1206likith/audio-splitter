import 'dart:ffi';

/// Minimal hand-written FFI bindings for **librnnoise** (Xiph's recurrent-neural
/// noise suppressor), mirroring the load-probe pattern established for libopus in
/// Phase 1 so every native dependency is introduced the same way.
///
/// librnnoise C signatures (from rnnoise.h):
/// ```c
/// typedef struct DenoiseState DenoiseState;
/// int           rnnoise_get_frame_size(void);                 // 480 @ 48kHz
/// DenoiseState* rnnoise_create(RNNModel* model);              // model may be NULL
/// void          rnnoise_destroy(DenoiseState* st);
/// float         rnnoise_process_frame(DenoiseState* st, float* out, const float* in);
/// ```
/// Samples are 32-bit floats scaled to the int16 range (i.e. roughly
/// `pcmSample * 32768`), processed one 480-sample (10 ms) mono frame at a time;
/// `rnnoise_process_frame` returns the voice-activity probability for the frame.

typedef DenoiseState = Pointer<Void>;

typedef _GetFrameSizeC = Int32 Function();
typedef GetFrameSizeDart = int Function();

typedef _CreateC = Pointer<Void> Function(Pointer<Void> model);
typedef CreateDart = Pointer<Void> Function(Pointer<Void> model);

typedef _DestroyC = Void Function(Pointer<Void> st);
typedef DestroyDart = void Function(Pointer<Void> st);

typedef _ProcessFrameC = Float Function(
    Pointer<Void> st, Pointer<Float> out, Pointer<Float> input);
typedef ProcessFrameDart = double Function(
    Pointer<Void> st, Pointer<Float> out, Pointer<Float> input);

/// Resolved librnnoise entry points from a loaded [DynamicLibrary]. Construction
/// looks up every symbol up front so a missing/incompatible library fails fast
/// (caught by the denoiser's load-probe) rather than mid-stream.
class RnnoiseBindings {
  final GetFrameSizeDart getFrameSize;
  final CreateDart create;
  final DestroyDart destroy;
  final ProcessFrameDart processFrame;

  RnnoiseBindings(DynamicLibrary lib)
      : getFrameSize = lib.lookupFunction<_GetFrameSizeC, GetFrameSizeDart>(
            'rnnoise_get_frame_size'),
        create = lib.lookupFunction<_CreateC, CreateDart>('rnnoise_create'),
        destroy = lib.lookupFunction<_DestroyC, DestroyDart>('rnnoise_destroy'),
        processFrame = lib.lookupFunction<_ProcessFrameC, ProcessFrameDart>(
            'rnnoise_process_frame');
}
