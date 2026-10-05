# Extending `transcode.sh` to re-encode audio → AC-3 2.0

Status: **implemented** (see "What was built" below). Evidence gathered 2026-09-29
against the live library and the installed ffmpeg 7.1.4.

## What was built

Agreed settings: **AC-3 2.0 @ 224k (256k for movies), plain downmix, one audio track,
same-pass audio plus a catch-up pass for already-encoded video.**

Phases 1–4 of the plan below are implemented in `transcode.sh`:

- One ffprobe per file drives the video decision, the audio decision, the shm
  reservation and the job itself (previously the file was probed twice).
- New audio policy: `decide_audio_action` returns `encode`, `prune` or `none`;
  `parse_media_meta` picks the track and reports the audio situation;
  `build_ffmpeg_cmd` assembles the command; `strip_audio_opts` removes audio options
  from the configured `ffmpeg_output_params` so the script owns audio.
- Two job modes: `video_action=encode` (video + audio, `/dev/shm` staging as before)
  and `video_action=copy` (audio-only remux, in-place staging, atomic `mv`, no GPU
  device required, capped by `audio_max_jobs`).
- Skip file migrated to a path-keyed format 2 with a `#format,2` header. Terminal
  errors are kept; video-only outcomes (`transcoded`, `codec-skip`, early-abort,
  min/max-reduction, killed-by-monitor) are dropped so those files are re-probed.
- `--dry-run` / `--limit N` / `--config PATH`, with `--dry-run` guaranteed not to
  write the log, the skip file, the media tree, or `/dev/shm`.
- New global settings + per-config `audio_bitrate` / `audio_max_tracks`; the shipped
  and example configs no longer carry `-c:a copy`.
- Docs updated: `README.md`, `bash/README.md`.

### Deviations from the options originally presented

| Original recommendation | What was built | Why |
|---|---|---|
| D3: track order default-flag → language → first | **language → default flag → first** | Measured on the live library: Black Mirror S07E03 flags **Ukrainian** as its only default track, Sonic Prime S03E07 flags **Arabic** (English sits unflagged at index 4 and 7). Default-first would have produced foreign-language-only audio. |
| D4: two separate skip files | **one path-keyed file with a format header and a one-time migration** | Smaller change, no new files, keeps legacy basename entries working, and achieves the same thing: "video is AV1" no longer implies "file is done". |
| D6: in-place staging as an option | **in-place staging, implemented** | Halves the I/O of the catch-up pass (no `/dev/shm` write and no second full copy back) and removes the shm bottleneck entirely. Verified safe under `SIGTERM` mid-write. |

### Bugs found and fixed while testing

1. `zero file size` was decided after rounding bytes to MB, so any legitimate output
   under 1 MB was rejected and blacklisted.
2. The final drain loop did `wait "$pid"` without a guard; `set -e` aborted the script
   on the first failed job, skipping the remaining slots and leaving jobs running.
3. The audio-only "did it actually shrink?" check compared MB-rounded sizes; now
   compared in bytes.
4. Removed dead code (`gb_per_minute`, computed and never used).
5. `strip_hwaccel_opts` was added so audio-only jobs do not inherit
   `-hwaccel vaapi` from `ffmpeg_input_params` and therefore have no GPU dependency.

### Verification performed

`.probe/run_all_tests.sh` (all passing) covers: the decision matrix; a full pipeline
run over synthetic fixtures including a 3-track AV1 file, a DTS 5.1 file, an
already-compliant AV1 file, a pruned 2-track file and an mp4; legacy skip-file
migration; idempotent re-run; dry-run isolation (skip file, media, `/dev/shm`
sentinel, log); and exact argv construction through the `eval` layer with a path
containing spaces, brackets, braces, parentheses, an apostrophe and an ampersand.

`.probe/test_abort.sh` sends `SIGTERM` mid-remux and asserts the source is
byte-identical, both original tracks survive, no staging file is left behind and
`/dev/shm` is cleaned (handled in 215 ms).

**Not exercised:** the VAAPI video path itself, because this machine exposes no
`/dev/dri` to the test environment. The video branch was exercised with a software
AV1 encoder (`libsvtav1`) using the real configuration's parameter string.

---

## Follow-up investigation: the three deferred issues

### 1. `ffmpeg-crash-218` — root cause found, fixed

Nine files failed with `Terminating thread with return code -38 (Function not
implemented)`. Exit status 218 is `(256 - 38)`: ffmpeg's `main` returned `-ENOSYS`.

**Root cause (confirmed).** A mid-stream video parameter change makes ffmpeg try to
rebuild its filter graph mid-encode; with a hardware encoder the rebuild fails:

```
[vf#0:0] Reconfiguring filter graph because video parameters changed to yuv420p(unknown, bt709), 1920x960
[vf#0:0] Error reinitializing filters!
[vf#0:0] Task finished with error code: -38 (Function not implemented)
[vf#0:0] Terminating thread with return code -38 (Function not implemented)
```

Evidence: Hijack S01E04 changes resolution from 1920x1080 to 1920x960 after ~190
frames, and the crash was logged at **frame 192**. Hijack S01E01 reproduces the
`Reconfiguring filter graph` line on demand. This matches the failure documented in
the [Unmanic hardware-decode guide](https://docs.unmanic.app/docs/guides/handling_colorspace_changes_hw_decode/).

The script made this undiagnosable by keeping only `tail -1` of ffmpeg's stderr (the
generic last line) and deleting the rest, then blacklisting the file forever.

**Prevalence:** a stratified sample of 22 h264/hevc files showed **0** parameter
changes in the first 150 s, so this is rare and concentrated in "assembled"
releases (multi-language WEB-DLs, hybrid remuxes) — which are over-represented
among the largest files the size-sorted queue reaches first.

**Fix implemented:**
- `first_ffmpeg_error` logs the first (informative) line plus the last; the full
  stderr of every attempt is kept under `error_log_dir`.
- A three-rung retry ladder: 1) as configured, 2) fixed canvas
  (`scale`/`pad` from the source geometry) plus `-reinit_filter 0`, 3) rung 2 plus
  software decode. Rung 2 was verified to produce **0 reconfigurations** and a
  constant output size. Rungs are built by `prefix_vf`/`strip_hwaccel_opts` and
  asserted in `.probe/argv/attempttest.sh`.
- `--retry-failed` re-queues previously blacklisted `ffmpeg-crash-*` files (with a
  `.bak` of the skip file) so they get one pass through the ladder.

Not resolvable here: **6 of the 9 failures are adult mp4s whose trigger is not a
frame-parameter change** (no change in the first 900 s of two of them). They share
the same symptom and the same remedy, but the precise trigger is
hardware-specific and cannot be reproduced without a VAAPI device.

### 2. Subtitle pruning — measured, low value, recommended against for now

Measured over 105 stratified files:

| metric | value |
|---|---|
| mean subtitle tracks per file | 3.6 |
| files with 0 / 1 / 2 tracks | 27 / 40 / 15 |
| long tail | one file with 39 tracks, two with 25, two with 20 |
| subtitle bytes | negligible except PGS: 20 MB, 77 MB, 188 MB, 271 MB on the four worst Blu-ray remuxes |

So subtitle tracks cost ~nothing in space except for image-based (PGS) subtitles on
a small number of Blu-ray remuxes, and the case for pruning is UI tidiness rather
than storage. Pruning is also the one change here that can annoy the user (losing a
forced/SDH/foreign track) and is hard to undo once the file is rewritten.
Recommendation: leave `-map 0:s? -c:s copy` as it is; add an opt-in
`subtitle_max_tracks` only if the 20-39 track files become a nuisance.

### 3. Container policy (mp4 vs mkv) — recommended no change

41% of the library is `.mp4` (20,320 of 21,661 adult files, plus 1,956 series and
289 movies). AAC-LC and AC-3 in MP4 are both legal, are written correctly by
ffmpeg, and Plex plays them — verified by test.

An earlier draft of this section claimed a container change would **"lose watched
state and date added"**. That is too strong and has been corrected. Plex attaches
watched state to the *item's* `guid` (the agent match), not to the filename, and it
keeps a file-hash fallback for renames, so a rename normally preserves watched
state. The genuine caveats are operational rather than inherent:

* disable "Empty trash automatically after every scan" for the duration — it is on
  by default, and it is what actually turns a rename into a re-add;
* disable automatic and periodic library scans while renaming;
* back up the primary Plex database first;
* unmatched / personal-media libraries are the weak case, because there is no agent
  match anchoring the guid — and that is exactly where most of the adult `.mp4`s live.

This is nevertheless **moot for the current pipeline**: `inplace_temp_path` keeps the
source extension and the final `mv` restores the *same path*, so no file is ever
renamed and there is no watched-state exposure at all.

Recommendation: keep the container as-is — not to protect watched state, but
because MP4 already carries everything this pipeline writes (AAC-LC or AC-3 stereo,
plus copied subtitles). Note the reverse direction *is* genuinely unsafe: forcing
MKV sources into MP4 would break `-c:s copy` for PGS subtitles, which run to
hundreds of MB on Blu-ray remuxes.

### Bonus finding: exact per-track byte sizes are already in the probe

Matroska track-statistics tags (written by mkvmerge) expose exact
`NUMBER_OF_BYTES` per stream, and the main loop already fetches them in
`get_media_info`. Measured across 56 sampled files with tags: **17.8% of bytes are
audio** — corroborating the 4.5–5.5 TB estimate from the top of this document.

This makes two things possible without any extra I/O: skipping the audio decision
for already-small tracks, and prioritising the queue by reclaimable bytes instead
of total size. The latter is blocked by the `min_video_size` early-exit, which
depends on the queue being size-sorted; changing it is a larger design change and
has not been done.

---

## TL;DR

The script currently does `-map 0:a?` + `-c:a copy` ([transcode.sh:372](transcode.sh#L372), [transcode.sh:391](transcode.sh#L391)):
it copies **every** audio track and never re-encodes any of them. In this library that is
the single largest remaining waste — measured at **~14% of series bytes and ~8% of movie bytes**,
i.e. an estimated **4.5–5.5 TB** of the 49 TB library, concentrated in a small number of files
with 12–34 full-bitrate audio tracks.

Recommended shape of the work:

1. Do the audio job **in the same ffmpeg pass** as the video job (one write, no second I/O).
2. **Select one audio track** (default/English/first) instead of `0:a?`; drop the rest.
3. Re-encode the kept track to **AC-3 2.0 @ 224 kbps** (measured cost: ~145× realtime, ≈1.3 CPU
   cores ≈ 50 s of CPU for a 2-hour movie — negligible next to the AV1 encode).
4. Add a **second job type** for files whose video is already AV1 but whose audio is not
   (today those are permanently blocked by `codec-skip` — 114 files already).
5. Fix four existing checks that will **actively sabotage** audio-only jobs
   (early-abort, output-too-large, `calc_reserve`, `min_diff`).

---

## 1. What the library actually looks like

Measured with ffprobe, stratified samples (every 500th series file, every 50th movie file)
so the sample is not size-biased.

| | files | bytes | mean size |
|---|---|---|---|
| series | 29,818 | 25.95 TB | 870 MB |
| movies | 3,152 | 9.99 TB | 3.1 GB |
| adult | 21,661 | 13.29 TB | 613 MB |
| **total** | **54,631** | **49.22 TB** | |

NFS is at **96% full (2.8 TB free)** — reclaiming space is the whole point.

### Audio is a large, skewed share of bytes

"Excess audio" below = audio bytes above what a single AC-3 2.0 track at 224 kbps would occupy.

| sample | files | bytes | audio bytes | excess above one 224k AC-3 2.0 | excess share |
|---|---|---|---|---|---|
| series (stratified) | 60 | 60.3 GB | 11.8 GB | **8.6 GB** | **14.3%** |
| movies (stratified) | 46 | 189.8 GB | 23.0 GB | **15.7 GB** | **8.3%** |

Extrapolated: series ≈ **3.7 TB**, movies ≈ **0.8 TB**, adult unknown but low (its processed
files are overwhelmingly aac 2.0) → **~4.5–5.5 TB total, ~10% of the library**.
(Lossless bitrates — DTS-HD MA / TrueHD — are estimates in the movie figure; a spot check of
Barbarian's DTS-HD MA 5.1 measured 2.99 Mbps vs the 3.0 Mbps assumed.)

### It is concentrated in pathological multi-track releases

These are real files in the library today:

| file | size | duration | audio tracks | audio as % of file |
|---|---|---|---|---|
| Black Mirror S07E05 (already AV1) | 4,979 MB | 46 min | 22 × EAC3 5.1 @640k | **97.7%** |
| Black Mirror S07E04 (already AV1) | 4,989 MB | 46 min | 22 × EAC3 5.1 @640k | **94.0%** |
| Black Mirror S07E03 (already AV1) | 9,980 MB | 77 min | 22 × EAC3 5.1 @640k | **79.1%** |
| Sonic Prime S03E07 (still h264) | 4,708 MB | 25 min | 34 × EAC3 5.1 @640k (34 languages) | **83.4%** |
| Hijack S01E01 (still h264) | 6,309 MB | 51 min | 12 tracks | **51.1%** |

The Black Mirror ones are the important warning: the script already re-encoded their **video**
to AV1 (~0.9 Mbps) and then wrote them to `skip.csv` as `codec-skip`, while keeping all 22 audio
tracks. A 46-minute AV1 episode is 5 GB because 4.7 GB of it is 22 copies of the same 5.1 mix in
different languages. Those files can never be revisited under the current design.

### Filename markers are not a reliable pre-filter

`[DTS-HD` 87 files, `[TrueHD` 26, `[DTS` 232, `[FLAC` 71, `[EAC3` 9,297, `[AC3` 1,184, `[AAC` 2,799
— only ~19% of the library carries an audio marker, so the decision has to come from ffprobe,
not the filename. (`[EAC3 5.1]` is a decent *optional* fast-path for a first sweep.)

---

## 2. Environment facts that constrain the design

| fact | value | consequence |
|---|---|---|
| ffmpeg | 7.1.4 | — |
| AC-3 encoder | present (`ac3`) | target codec is available |
| **E-AC-3 encoder** | **absent** | DD+ is not an option without a different ffmpeg build |
| Other encoders | `aac`, `libfdk_aac`, `libopus`, `flac`, `dca`, `truehd` | alternatives exist |
| AC-3 channel layouts | incl. `stereo`, `2.1` (2/0+LFE) | discrete LFE is possible |
| AC-3 encode cost | 300 s audio in 2.07 s @ 1 thread (≈145×, 130% CPU) | ~50 s CPU per 2 h movie |
| `/dev/shm` | 16 GB | 3–4 concurrent jobs at current reservation |
| CPU | Ryzen 5 7600X, 12 threads | headroom for audio alongside 3 GPU jobs |
| GPU | 2× amdgpu; log shows VCN pegged at 99–100% with 3 jobs | GPU is already the bottleneck; audio must not consume GPU slots |
| NFS free | 2.8 TB | in-place staging for large audio-only jobs is feasible |

Currently 114 files are `codec-skip` (AV1 video, audio untouched), 108 are `transcoded`
(also with audio copied verbatim), 30 `early-abort-size-inefficient`, 9 `ffmpeg-crash-218`.

---

## 3. Gotchas in the current code that will break audio work

These are not optional; each one will silently corrupt or block the feature.

| # | Where | Problem |
|---|---|---|
| G1 | [transcode.sh:554-581](transcode.sh#L554-L581) | **10% early-abort compares total output bytes to source bytes.** For a `-c:v copy` job the output reaches ~100% of source size at ~0% elapsed → instant false abort. Must be gated on "video is being encoded". |
| G2 | [transcode.sh:583-594](transcode.sh#L583-L594) | **"output > original + 5 MB" kill.** Same problem for remux jobs. Gate it too. |
| G3 | [transcode.sh:224-237](transcode.sh#L224-L237) | **`calc_reserve` sizes shm from the *video* target bitrate.** A `-c:v copy` job needs ≈ the full source size in shm (a 5 GB AV1 file = 5 GB of the 16 GB budget → concurrency collapses). Needs a copy-mode reservation, or in-place staging (see D6). |
| G4 | [transcode.sh:690](transcode.sh#L690) | **`min_diff` 5% rejects the output.** An audio-only remux that saves 2% is discarded *and* written to `skip.csv` as `below-min-reduction`, i.e. never retried. Needs a separate, much lower threshold for audio-only jobs (recommend: accept anything smaller). |
| G5 | [transcode.sh:891-899](transcode.sh#L891-L899) | **`codec-skip` is terminal.** AV1 + fat audio ⇒ skipped forever. An audio axis is needed in the state (see D4). |
| G6 | [transcode.sh:111-118](transcode.sh#L111-L118) + [:855](transcode.sh#L855) | **`skip.csv` is keyed by basename**, not path. Two files with the same name collide. As we add more skip states this gets riskier; worth fixing while we are in here. |
| G7 | [transcode.sh:372](transcode.sh#L372) | `-map 0:a?` keeps every track. |
| G8 | [transcode.sh:386-394](transcode.sh#L386-L394) | `-c:a copy` comes from the JSON blob and the script appends after it. Verified that later options win, so appending works — but it is implicit. Strip audio options from `ffmpeg_output_params`, or at minimum delete `-c:a copy` from the shipped config. |

Separately noted (pre-existing, unrelated to audio): 9 files fail with
`ffmpeg failed (exit 218) — [vf#0:0] Terminating thread with return code -38 (Function not
implemented)`. That is the VAAPI `format=nv12,hwupload` filter chain, not audio. Worth a
separate look; the affected files (Hijack S01E01/E04, etc.) are exactly the kind of large
multi-track files this work targets, so they will come up again.

---

## 4. Decisions to make

### D1 — Target codec and bitrate — **DECIDED: AAC-LC via libfdk_aac, VBR 5**

This supersedes the original AC-3 recommendation, which was made before the playback
chain was established: **Google TV → HDMI → very old LG TV → optical → 2.1 soundbar**.
Optical S/PDIF carries only 2-channel PCM, AC-3 and (sometimes) DTS, so whatever
reaches the soundbar is either PCM stereo or an AC-3 bitstream.

The decisive point is that this pipeline *already* downmixes to stereo, which removes
AC-3's only real advantage — letting the soundbar bitstream-decode 5.1 and run its own
bass management. A stereo AC-3 track gives the bar nothing a stereo PCM track does
not, so the choice reduces to size and reliability: AAC-LC is ~30% smaller at equal
quality, is Plex's baseline Direct Play audio codec, and is decoded to PCM on the
Google TV device — the one thing an old LG TV's optical port always handles correctly.

| option | verdict |
|---|---|
| **AAC-LC (libfdk_aac) VBR 5 — CHOSEN** | ~195 kbps worst case on incompressible content, lower on real program audio; transparent at that rate |
| AC-3 2.0 @ 224k (previous) | works as a bitstream everywhere, but ~2x the bytes for equal quality and no advantage once downmixed to stereo |
| AC-3 2.0 @ 256k / 384k | AC-3's bit-rate table tops out at 384 kbps for 2/0; above that is off-table |
| AC-3 **2.1** (`pan=2.1`) | the only portable discrete-LFE layout, but 2/0+LFE is uncommon and more likely to be mishandled |
| Opus 2.0 @ 128k | technically the best codec here, but patchy Plex direct-play support and **no usable Opus-in-MP4** — which matters because 41% of the library is `.mp4`. Measured benefit is ~0.5% of the total reclaim |
| E-AC-3 2.0 | **encoder not present in this ffmpeg build**, and it cannot cross optical anyway |

There is **no discrete 2.1 in AAC** (its layouts are mono/stereo/3.0/4.0/5.0/5.1/7.1),
and `-ac 3` silently yields **3.0** — a centre channel, not an LFE — in libfdk_aac,
libopus *and* ac3. The bass is therefore preserved by folding LFE into the stereo pair
(D2), not by signalling a 2.1 layout.

### D2 — What to do with LFE (the "2.1" question)

AC-3 2.0 has no LFE channel, so an LFE-heavy mix loses its sub content unless folded in.

| option | command |
|---|---|
| plain downmix (default ffmpeg matrix, **drops LFE**) | `-ac 2` |
| **fold LFE into L/R (recommended if you want the sub to work hard)** | `-af "pan=stereo\|FL=FL+0.707*FC+0.5*BL+0.5*LFE\|FR=FR+0.707*FC+0.5*BR+0.5*LFE"` |
| keep discrete LFE | `-af "pan=2.1\|FL=FL\|FR=FR\|LFE=LFE"` |

All three verified to encode cleanly at 224k on this box. The LFE-fold keeps the file a
100%-standard stereo AC-3 (maximum compatibility) while preserving bass. Mild clipping risk
exists; `alimiter` can follow the pan if you want belt and braces.

### D3 — Which audio track to keep

| option | notes |
|---|---|
| ~~default-flagged, else first `eng`, else first~~ **SUPERSEDED — see "What was built"** | measured to select Ukrainian/Arabic on real releases, because the default flag is set on a foreign track |
| first track (`0:a:0`) only | simplest; usually the same answer |
| keep default + commentary tracks | nice for movies; a few lines more |
| keep all tracks under N languages | smaller win, more complexity |

Recommendation as presented: pick **one** track by default, with `keep_commentary` as a
config toggle. **As built:** one track, selected language-first. Commentary tracks are
currently dropped; `audio_max_tracks` is the knob to keep more.

### D4 — Skip/state model (this is the part that makes it retryable)

| option | notes |
|---|---|
| A. Compound reasons in `skip.csv` (`video-done-audio-pending`, `transcoded-both`) | smallest change; keeps the existing file; still basename-keyed |
| **B. Two skip files** (`skip.video.csv`, `skip.audio.csv`), path-keyed | simple logic, fixes G6, easy to reason about |
| C. JSON-lines state file: path, size, mtime, video_ok, audio_ok | most robust; enables re-running when policy changes and validates the file has not changed since |

Recommendation as presented: **B now**, with C as a later upgrade. **As built** (see
"What was built"): one path-keyed file with a format header plus a one-time migration, which
achieves B's outcome with a smaller change. The important behavioural change — "video is AV1"
no longer implies "file is done" — is implemented.

### D5 — When to run the audio job

| option | notes |
|---|---|
| **Same ffmpeg pass as the video (recommended)** | zero extra I/O, no extra scheduler, no extra shm; ~50 s CPU per movie; prevents new `AV1 + fat audio` files from being created |
| Audio-only second pass for everything | doubles I/O for every file, and re-opens files already finished; only worth it as catch-up |
| Both | same-pass for files that still need video work; a catch-up pass for the 114 already-AV1 files |

Recommendation: **same pass by default**, plus a bounded **catch-up mode** for files whose
video is already compliant. The catch-up set starts at 114 files and grows only until the
same-pass change ships — so ship them together.

### D6 — Where audio-only remux output is staged

| option | notes |
|---|---|
| `/dev/shm` as today | with `-c:v copy` this reserves the full file size → 3 jobs max at 16 GB, and a wasteful second copy |
| **write to `<source>.tmp.mkv` beside the source, then `mv`** | no shm at all, atomic rename on the same filesystem, I/O-bound concurrency (can run far more than 3 in parallel), needs transient free space equal to the file (2.8 TB available) |
| a staging dir on the NFS share | same as above but avoids polluting the media dir with temp files on a crash |

Recommendation as presented: **in-place temp file in the same directory**. **As built:**
exactly that, with the temp file named `<source>.transcode-tmp.<ext>`, removed from the media
scan, cleaned up on failure and on signal, and with audio-only jobs capped by
`audio_max_jobs`.

### D7 — What actually qualifies for audio work

Without a gate, ~22,000 adult files of aac 2.0 get pointlessly re-encoded (quality loss, no
space gain) and the skip list churns. Proposed gate — audio work is needed if **any** of:

* `channels > 2`
* codec is lossless/high-bitrate: `truehd`, `mlp`, `dts`, `flac`, `pcm_*`, `wavpack`, `alac`
* more than `max_audio_tracks` (default 1) tracks present
* kept track's bitrate > `audio_min_bitrate_kbps` (default 448)

and **not** needed if the kept track is already `ac3`/`eac3`/`aac`/`opus` at ≤256 kbps with
≤2 channels and it is the only track. Note that *pruning* (dropping extra tracks) and
*re-encoding* are separate actions: a file whose kept track is already fine but which carries
21 extra tracks gets a free remux with no re-encode at all.

---

## 5. Recommended implementation plan

### Phase 1 — same-pass audio (the 80% win)

1. Extend the pre-dispatch probe at [transcode.sh:877](transcode.sh#L877) (which already runs
   per file) to return the full stream list: audio count, per-track codec/channels/bitrate/
   language/default-disposition, plus video codec and duration. Same cost (header-only probe),
   and it removes the duplicate probe currently done inside `run_job_transcode`.
2. Decide per file: `video_action ∈ {encode, skip}`, `audio_action ∈ {none, prune, encode}`.
3. New helper `build_audio_args` returning e.g.
   `-map 0:a:7 -c:a ac3 -ac 2 -ar 48000 -b:a 224k` (or `-c:a copy` for a prune-only file, or
   nothing for `none`).
4. Sanitise `ffmpeg_output_params` of audio options (or just remove `-c:a copy` from
   `transcode-config.json`) and append the built args — verified that the appended options win.
5. Log the decision (`audio: eac3 5.1 x22 -> ac3 2.0 @224k, keeping track 7 (eng)`).

### Phase 2 — state model and catch-up mode

6. Split the skip list into video/audio axes (D4-B), path-keyed, with a one-time migration of
   the existing `skip.csv` (the 114 `codec-skip` entries all become `audio: pending`).
7. Add `--audio-only` / `audio_catchup` mode: iterate files whose video is compliant but whose
   audio is not, running `-c:v copy` remux jobs. Exclude these from GPU slot accounting.

### Phase 3 — checks and scheduling for remux jobs

8. Gate G1/G2 (early-abort and output-too-large) on `video_action == encode`.
9. Give remux jobs their own size check: accept if output < source (with a small epsilon) and
   duration is within tolerance; bypass `min_diff`/`max_diff` (G4).
10. Give remux jobs their own concurrency (e.g. `audio_max_jobs`, default 2–4), their own
    staging path (D6), and no VCN dependency.

### Phase 4 — hardening, optional but cheap

11. `--dry-run` that prints the constructed ffmpeg command and the decision, writes nothing.
    This script rewrites source files in place; a dry-run is long overdue and makes piloting safe.
12. Consider replacing the `eval` + string command assembly with a bash array. We are touching
    this code anyway, and it removes the manual single-quote escaping at
    [transcode.sh:382-385](transcode.sh#L382-L385) and the class of bugs that comes with it.
13. Update both READMEs, `transcode-config.json.example`, and `show_state`.

### Phase 5 — pilot

14. Run against a copy of ~10 representative files (one 22-track AV1, one DTS-HD MA movie, one
    aac 2.0 series episode, one mp4) with `--dry-run`, then for real, then verify in Plex that
    they direct play and the soundbar gets audio.

---

## 6. Proposed config additions

```jsonc
"global_settings": {
  "audio_codec": "ac3",              // ac3 only in this ffmpeg build
  "audio_bitrate": "224k",
  "audio_channels": 2,               // 2 = stereo; use pan=2.1 for discrete LFE
  "audio_lfe_fold": 0,               // 1 = fold LFE/centre into L/R via pan
  "audio_sample_rate": 48000,
  "audio_max_tracks": 1,             // keep at most this many
  "audio_keep_commentary": 1,
  "audio_preferred_languages": "eng",
  "audio_min_bitrate_kbps": 448,     // re-encode above this even if <=2ch
  "audio_always_reencode_codecs": "truehd,mlp,dts,flac,pcm_s16le,pcm_s24le,pcm_bluray,wavpack,alac",
  "audio_max_jobs": 3,               // concurrency for remux-only jobs
  "audio_catchup": 0,                // 1 = also fix files whose video is already done
  "audio_only_accept_any_reduction": 1
}
```

Per-configuration override (`audio_bitrate`, `audio_channels`, `audio_max_tracks`) via the
existing `configurations[]` entries; add the same keys to `ffmpeg_output_params`' siblings.

`ffmpeg_output_params` for all three configs should drop `-c:a copy` — the script owns audio now.

---

## 7. Verification plan

* Unit-ish: for each of 34-track, DTS-HD MA 5.1, aac 2.0, ac3 2.0, flac 2.0, 96 kHz and mp4
  inputs, assert on the *output* probe: exactly 1 audio stream, codec `ac3`, 2 channels,
  224 kbps, duration within tolerance, video codec unchanged (or AV1 for encode jobs).
* Confirm the AC-3 stream is playable and correctly downmixed (listen once on the soundbar;
  check Plex shows "Direct Play" and no audio transcode).
* Confirm a remux job is not killed by the 10% monitor (regression test for G1/G2): run one
  AV1+22-track file and watch for the early-abort log line.
* Confirm skip state: after a video+audio job, the file is not revisited; after a
  video-only job (catch-up not yet run), it is.
* Space check: measure actual reclaimed bytes on the pilot set and extrapolate.

---

## 8. Open questions

1. AC-3 2.0 @224k, or do you want 256k / a discrete-LFE 2.1 track?
2. Keep exactly one audio track (recommended), or the default plus commentary?
3. Should the catch-up pass for already-AV1 files run automatically, or only on a flag?
4. Is `.mp4` → `.mkv` remuxing acceptable for mp4 sources (AC-3-in-MP4 works but MKV is the
   safer container for Plex), or should containers be left alone?
