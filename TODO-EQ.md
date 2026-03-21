# EQ Pipeline - Future Work

## Channel count support
- Driver and app pipeline are hardcoded to stereo (2ch)
- Mono devices (e.g. some Bluetooth headsets) and multichannel/surround (5.1, 7.1) won't work correctly
- Would need: dynamic channel count in driver (`kChannelCount`), ring buffer, CaptureBuffer deinterleaving, and NBandEQ format setup
- Sample rate is already handled automatically (output AUHAL converts from 44100 to whatever the real device uses)

## Move EQ processing into the driver
- Currently the app captures audio input from the virtual device, which requires `NSMicrophoneUsageDescription` (macOS TCC treats all audio input as "microphone")
- If EQ processing moved into the HAL plugin driver itself, no microphone permission would be needed
- Significantly more complex: driver runs in coreaudiod's address space with limited framework access
