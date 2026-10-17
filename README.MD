<div align="center">

# 🎙️ Audio Biometrics

**Speaker verification using pure DSP. No AI, no ML, no training.**

![MATLAB](https://img.shields.io/badge/MATLAB-R2016b%2B-orange?style=for-the-badge&logo=mathworks&logoColor=white)
![DSP](https://img.shields.io/badge/Pure-DSP-blue?style=for-the-badge)
![ML](https://img.shields.io/badge/Machine%20Learning-None-red?style=for-the-badge)
![Toolboxes](https://img.shields.io/badge/Toolboxes-Not%20Required-green?style=for-the-badge)

*Is this voice the same person as the reference voice? Yes or no.*

</div>

---

## ✨ What it does

Record or load a few samples of someone saying the same phrase, then test a new voice against them. The system tells you whether it **matches** or not. This is **verification** (is it person A?), not identification (who is it?).

The threshold is calibrated automatically from how much your own enrollment samples differ from each other, so there is nothing to train and nothing to tune by hand.

---

## 🧠 How it works

Four independent views of a voice are scored and fused into one decision.

| # | View | What it captures |
|---|------|------------------|
| 1 | **MFCC + deltas, compared with DTW** | Overall spectral shape of the voice over time |
| 2 | **Formants F1 to F3** (LPC) | Vocal tract resonances |
| 3 | **Voice quality** | Pitch F0, jitter, shimmer, HNR |
| 4 | **Spectral shape** | Centroid, rolloff, flatness, flux, zero-crossing rate |

### Pipeline

```
audio → mono → normalize → spectral subtraction → pre-emphasis
      → framing (25 ms / 10 ms step) → Hamming window → FFT
      → Mel filter bank (26) → log → DCT → MFCC (c1..c12 + deltas)
      → speech detection (VAD) → feature views 1 to 4
      → distances vs enrollment → z-scores → weighted fusion → MATCH / NO MATCH
```

### Decision rule

Each feature distance is turned into a z-score using the spread between the enrollment samples. The scores are fused with weights:

| DTW-MFCC | Formants | Voice quality | Spectral |
|:--:|:--:|:--:|:--:|
| 0.55 | 0.15 | 0.15 | 0.15 |

A voice is accepted as a match when:

```
fused z ≤ 1.0   AND   DTW z ≤ 2.0
```

---

## 🚀 Getting started

### Requirements

- MATLAB R2016b or newer
- A microphone, or audio files to load
- No toolboxes needed
- *(Optional)* [FFmpeg](https://ffmpeg.org) on your PATH to read formats MATLAB can't open natively (m4a, opus, webm, and so on)

### Run

```matlab
audio_biometrics
```

### Usage

1. **Enroll** 2 to 5 samples of the **same phrase** (`Record Enrollment` or `Load Enrollment File(s)`)
2. **Provide a test voice** (`Record Test` or `Load Test File`)
3. Press **VERIFY**

---

## 📊 Output

After verification you get a 9-panel dashboard:

1. Denoised waveform with speech detection
2. Spectrogram with F1, F2, F3 tracks
3. Pitch track vs enrolled pitch
4. MFCC heat-map
5. DTW cost matrix with the alignment path
6. Per-feature z-scores against the threshold
7. Long-term average spectrum
8. Formant comparison
9. Final result with fused score and confidence

A text report is also printed in the MATLAB console.

---

## 🎛️ Options

| Option | Default | Notes |
|--------|:-------:|-------|
| Noise reduction | On | Spectral subtraction |
| RASTA filter | Off | Off by default because it removes voice colour |

Toggling either re-analyses your enrollment samples automatically.

## 🗂️ Project structure

```
audio_biometrics.m    # GUI + full DSP pipeline in a single file
README.md
```

---

## 🔧 Parameters

Set at the top of `audio_biometrics.m`:

| Parameter | Value |
|-----------|-------|
| Sampling rate | 16 kHz |
| Frame / step | 25 ms / 10 ms |
| Pre-emphasis α | 0.97 |
| Mel filters | 26 |
| MFCC coefficients | 13 (c0 dropped) |
| FFT size | 512 |
| Max audio length | 12 s |
| Threshold `zThr` | 1.0 |