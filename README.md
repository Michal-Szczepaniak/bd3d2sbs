# bd3d2sbs

## BASH SCRIPTS WRITTEN BY CLAUDE

Converts 3D Blu-rays into stereoscopic Full/Half-SBS MKV files on Linux. A
bash + fzf port of the workflow behind the Windows tool BD3D2MK3D.

Takes either a raw BDMV directory or a MakeMKV-ripped `.mkv`, lets you pick
the playlist, audio and subtitle tracks interactively, then runs the whole
pipeline end to end.

## Pipeline

```
tsMuxeR (demux) -> VapourSynth + mvc-source (MVC decode/stack) -> x264 or VAAPI (encode) -> mkvmerge (mux)
```

- **tsMuxeR** demuxes the base (AVC) and dependent (MVC) video views plus
  selected audio/subtitle tracks.
- **VapourSynth**, via the `mvc-source` plugin (built on the `edge264-mvc`
  decoder), decodes both views and stacks them side by side.
- **x264** (software) or **ffmpeg/VAAPI** (hardware) encodes the stacked
  frame. x264 embeds the frame-packing SEI the format expects; VAAPI is
  faster but doesn't, and mkvmerge's `--stereo-mode` tag is relied on
  instead for 3D playback detection.
- **mkvmerge** muxes the encoded video with the chosen audio/subtitle
  tracks and chapters into the final `.mkv`.

## Setup

Dependencies are vendored as git submodules and built from source:

```
git submodule update --init --recursive
./build_deps.sh
```

This builds tsMuxeR (`teaching-droid` fork), VapourSynth (pinned to `R65` -
newer tags require Python >=3.12 and drop the autotools build), and
`mvc-source`/`edge264-mvc`. `x264`, `mkvmerge`, and `fzf` are expected to
already be installed from your distro's packages.

`./build_deps.sh --force` rebuilds from source even if a usable system
install is already found. Run it for a single target with
`./build_deps.sh vapoursynth` (or `tsmuxer`, `mvc-source`).

## Usage

```
./bd3d2sbs.sh /path/to/BDMV
./bd3d2sbs.sh /path/to/rip.mkv
```

You'll be walked through picking the main-feature playlist (for a raw BDMV
source), audio and subtitle tracks, and encode settings (SBS mode, encoder,
preset/CRF). Output lands next to the source in a `<name>.bd3d2sbs/`
directory.

Options:

| Flag | Description |
| --- | --- |
| `--config PATH` | Config file to use (default: `~/.config/bd3d2sbs/config.sh`) |
| `--outdir PATH` | Working/output directory |
| `--sbs full\|half` | Full or half side-by-side output |
| `--encoder x264\|vaapi` | Encoder to use |
| `--preset NAME` | x264 preset (ignored for VAAPI) |
| `--crf N` | x264 CRF, or VAAPI QP |
| `--x264-opts "STRING"` | Extra encoder options, appended verbatim |
| `--keep-intermediates` | Keep demuxed streams after a successful mux |

## Config

A config file is created at `~/.config/bd3d2sbs/config.sh` on first run
with the available defaults (tool paths, SBS mode, encoder, preset, CRF,
minimum playlist length for the playlist picker). Edit it directly, or
override per run with the flags above.

## Scope

3D Full/Half-SBS output only. No 2D remux, re-encode, or subtitle
conversion.
