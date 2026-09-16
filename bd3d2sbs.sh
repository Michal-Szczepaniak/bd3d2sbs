#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${HOME}/.config/bd3d2sbs/config.sh"
OUTDIR=""

default_config() {
  cat <<'EOF'
# Empty = look up PATH, fall back to a build tree next to this script.
TSMUXER_BIN=""
VSPIPE_BIN=""
MVC_SOURCE_PLUGIN=""

# Expected on PATH (distro packages).
X264_BIN="x264"
FFMPEG_BIN="ffmpeg"
MKVMERGE_BIN="mkvmerge"
FZF_BIN="fzf"

# Encoding defaults.
SBS_MODE="full"        # full|half
ENCODER="x264"          # x264|vaapi
VAAPI_DEVICE="/dev/dri/renderD128"
X264_PRESET="slow"      # only used by the x264 encoder
X264_CRF="12"           # x264 CRF, or the VAAPI QP when ENCODER=vaapi
X264_EXTRA_OPTS=""      # appended verbatim to the x264/ffmpeg command line

KEEP_INTERMEDIATES="false"

# Shorter playlists are hidden from the picker (menus/trailers/bonus clips).
MIN_PLAYLIST_MINUTES="40"
EOF
}

find_tool() {
  local override="$1" name="$2" fallback="$3"
  if [[ -n "$override" ]]; then echo "$override"; return; fi
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
  echo "$fallback"
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    default_config > "$CONFIG_FILE"
    echo "Wrote default config to $CONFIG_FILE"
  fi
  source "$CONFIG_FILE"

  TSMUXER_BIN="$(find_tool "${TSMUXER_BIN:-}" tsMuxeR "$SCRIPT_DIR/tsMuxer/bin/tsMuxeR")"
  VSPIPE_BIN="$(find_tool "${VSPIPE_BIN:-}" vspipe "$SCRIPT_DIR/vapoursynth/.libs/vspipe")"
  MVC_SOURCE_PLUGIN="${MVC_SOURCE_PLUGIN:-$SCRIPT_DIR/mvc-source/libvsmvc.so}"

  : "${X264_BIN:=x264}"
  : "${FFMPEG_BIN:=ffmpeg}"
  : "${MKVMERGE_BIN:=mkvmerge}"
  : "${FZF_BIN:=fzf}"
  : "${SBS_MODE:=full}"
  : "${ENCODER:=x264}"
  : "${VAAPI_DEVICE:=/dev/dri/renderD128}"
  : "${X264_PRESET:=slow}"
  : "${X264_CRF:=12}"
  : "${X264_EXTRA_OPTS:=}"
  : "${KEEP_INTERMEDIATES:=false}"
  : "${MIN_PLAYLIST_MINUTES:=40}"
}

pick_encode_settings() {
  local choice
  choice="$(printf '%s\n' full half | "$FZF_BIN" --header="SBS mode (current: $SBS_MODE)" --height='~20%' --border --layout=reverse)"
  if [[ -n "$choice" ]]; then SBS_MODE="$choice"; fi

  choice="$(printf '%s\n' x264 vaapi | "$FZF_BIN" --header="Encoder (current: $ENCODER)" --height='~20%' --border --layout=reverse)"
  if [[ -n "$choice" ]]; then ENCODER="$choice"; fi

  if [[ "$ENCODER" == "x264" ]]; then
    choice="$(printf '%s\n' ultrafast superfast veryfast faster fast medium slow slower veryslow placebo \
      | "$FZF_BIN" --header="x264 preset (current: $X264_PRESET)" --height='~40%' --border --layout=reverse)"
    if [[ -n "$choice" ]]; then X264_PRESET="$choice"; fi
    read -rp "x264 CRF [$X264_CRF]: " choice
  else
    read -rp "VAAPI QP [$X264_CRF]: " choice
  fi
  if [[ -n "$choice" ]]; then X264_CRF="$choice"; fi

  read -rp "Extra $([[ "$ENCODER" == "vaapi" ]] && echo ffmpeg || echo x264) options [$X264_EXTRA_OPTS]: " choice
  if [[ -n "$choice" ]]; then X264_EXTRA_OPTS="$choice"; fi

  echo "Using: sbs=$SBS_MODE encoder=$ENCODER preset=$X264_PRESET crf/qp=$X264_CRF extra-opts=\"$X264_EXTRA_OPTS\""
}

usage() {
  cat <<EOF
Usage: $0 [options] <BDMV-dir-or-.mkv-file>

Options:
  --config PATH        Config file to use (default: $CONFIG_FILE)
  --outdir PATH         Working/output directory (default: sibling of source)
  --sbs full|half        Full or half side-by-side output
  --encoder x264|vaapi    Encoder to use (default: x264)
  --preset NAME          x264 preset (ignored for vaapi)
  --crf N                 x264 CRF, or VAAPI QP when --encoder vaapi
  --x264-opts "STRING"    Extra x264/ffmpeg options, appended verbatim
  --keep-intermediates    Don't delete demuxed streams after a successful mux
  -h, --help              Show this help
EOF
}

parse_args() {
  SOURCE_PATH=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) CONFIG_FILE="$2"; shift 2 ;;
      --outdir) OUTDIR="$2"; shift 2 ;;
      --sbs) SBS_MODE="$2"; shift 2 ;;
      --encoder) ENCODER="$2"; shift 2 ;;
      --preset) X264_PRESET="$2"; shift 2 ;;
      --crf) X264_CRF="$2"; shift 2 ;;
      --x264-opts) X264_EXTRA_OPTS="$2"; shift 2 ;;
      --keep-intermediates) KEEP_INTERMEDIATES="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) SOURCE_PATH="$1"; shift ;;
    esac
  done
  if [[ -z "$SOURCE_PATH" ]]; then usage; exit 1; fi
}

resolve_source() {
  SOURCE_PATH="$(realpath "$SOURCE_PATH")"
  if [[ -d "$SOURCE_PATH" && -d "$SOURCE_PATH/BDMV/PLAYLIST" ]]; then
    SOURCE_TYPE="bdmv"
    SOURCE_BASENAME="$(basename "$SOURCE_PATH")"
  elif [[ -f "$SOURCE_PATH" && "$SOURCE_PATH" == *.mkv ]]; then
    SOURCE_TYPE="mkv"
    SOURCE_BASENAME="$(basename "${SOURCE_PATH%.mkv}")"
  else
    echo "Error: '$SOURCE_PATH' is neither a BDMV directory (with BDMV/PLAYLIST) nor a .mkv file" >&2
    exit 1
  fi

  WORKDIR="${OUTDIR:-$(dirname "$SOURCE_PATH")/${SOURCE_BASENAME}.bd3d2sbs}"
  mkdir -p "$WORKDIR"
}

list_playlists() {
  local mpls
  for mpls in "$SOURCE_PATH"/BDMV/PLAYLIST/*.mpls; do
    local info duration ssif
    info="$("$TSMUXER_BIN" "$mpls" 2>&1)"
    duration="$(grep -oP 'Duration:\s*\K[0-9:]+' <<<"$info" | head -1)"
    ssif="no"
    if grep -qi '\.ssif' <<<"$info"; then ssif="yes"; fi
    if [[ -n "$duration" ]]; then printf '%s|%s|%s\n' "$mpls" "$duration" "$ssif"; fi
  done
}

duration_to_seconds() {
  awk -F: '{ s=0; for (i=1;i<=NF;i++) s = s*60 + $i; print s }' <<<"$1"
}

pick_playlist() {
  local candidates
  candidates="$(list_playlists | awk -F'|' '$3=="yes"')"
  if [[ -z "$candidates" ]]; then
    echo "Error: no .mpls with an .ssif reference found under $SOURCE_PATH/BDMV/PLAYLIST" >&2
    exit 1
  fi

  local min_seconds=$((MIN_PLAYLIST_MINUTES * 60))
  local sorted
  sorted="$(while IFS='|' read -r path duration ssif; do
    printf '%s|%s|%s\n' "$(duration_to_seconds "$duration")" "$path" "$duration"
  done <<<"$candidates" | awk -F'|' -v min="$min_seconds" '$1+0 >= min' | sort -t'|' -k1,1 -rn)"

  if [[ -z "$sorted" ]]; then
    echo "Error: no .ssif playlist under $SOURCE_PATH/BDMV/PLAYLIST is >= ${MIN_PLAYLIST_MINUTES} minutes long." >&2
    echo "Lower MIN_PLAYLIST_MINUTES in $CONFIG_FILE if the real feature is shorter than that." >&2
    exit 1
  fi

  local count picked
  count="$(wc -l <<<"$sorted")"
  if [[ "$count" -eq 1 ]]; then
    picked="$sorted"
  else
    picked="$(awk -F'|' '{printf "%s|%s|%s\n", $2, $3, $1}' <<<"$sorted" \
      | "$FZF_BIN" --delimiter='|' --with-nth=1,2 \
          --header='Select the main-feature playlist' \
          --height='~40%' --border --layout=reverse)"
    picked="$(awk -F'|' '{printf "%s|%s|%s\n", $3, $1, $2}' <<<"$picked")"
  fi

  PLAYLIST_PATH="$(cut -d'|' -f2 <<<"$picked")"
  echo "Selected playlist: $PLAYLIST_PATH ($(cut -d'|' -f3 <<<"$picked"))"
}

run_tsmuxer_scan() {
  TSMUXER_SCAN="$("$TSMUXER_BIN" "$1" 2>&1)"
}

scan_tracks() {
  # "Stream ID:" is the meta-file codec code (e.g. V_MPEG4/ISO/AVC); "Stream type:" is just a display name.
  awk '
    /^Track ID:/ { if (id != "") print id"|"codec"|"lang"|"desc; id=$0; sub(/^Track ID:[ \t]*/,"",id); codec=""; lang=""; desc="" }
    /^Stream ID:/ { codec=$0; sub(/^Stream ID:[ \t]*/,"",codec) }
    /^Stream lang:/ { lang=$0; sub(/^Stream lang:[ \t]*/,"",lang) }
    /^Stream info:/ { desc=$0; sub(/^Stream info:[ \t]*/,"",desc) }
    END { if (id != "") print id"|"codec"|"lang"|"desc }
  ' <<<"$TSMUXER_SCAN"
}

scan_chapter_marks() {
  awk '/^Marks:/ { sub(/^Marks:[ \t]*/,""); print }' <<<"$TSMUXER_SCAN" \
    | tr -s '[:space:]' '\n' | grep -v '^$' || true
}

build_chapters() {
  CHAPTERS_FILE=""
  local marks; marks="$(scan_chapter_marks)"
  if [[ -z "$marks" ]]; then return 0; fi

  CHAPTERS_FILE="$WORKDIR/chapters.txt"
  local n=0
  : > "$CHAPTERS_FILE"
  while IFS= read -r t; do
    n=$((n + 1))
    printf 'CHAPTER%02d=%s\n' "$n" "$t" >> "$CHAPTERS_FILE"
    printf 'CHAPTER%02dNAME=Chapter %02d\n' "$n" "$n" >> "$CHAPTERS_FILE"
  done <<<"$marks"
}

pick_video_track_ids() {
  local tracks="$1"
  if [[ "$SOURCE_TYPE" == "bdmv" ]]; then
    AVC_TRACK_ID="$(awk -F'|' '$2 ~ /V_MPEG4\/ISO\/AVC/ {print $1; exit}' <<<"$tracks")"
    MVC_TRACK_ID="$(awk -F'|' '$2 ~ /V_MPEG4\/ISO\/MVC/ {print $1; exit}' <<<"$tracks")"
    if [[ -z "$AVC_TRACK_ID" || -z "$MVC_TRACK_ID" ]]; then
      echo "Error: could not find both an AVC base view and an MVC dependent view in $PLAYLIST_PATH" >&2
      exit 1
    fi
  else
    AVC_TRACK_ID="$(awk -F'|' '$2 ~ /V_MPEG4\/ISO\/(AVC|MVC)/ {print $1; exit}' <<<"$tracks")"
    MVC_TRACK_ID="$AVC_TRACK_ID"
    if [[ -z "$AVC_TRACK_ID" ]]; then
      echo "Error: could not find a combined AVC/MVC video track in $SOURCE_PATH" >&2
      exit 1
    fi
  fi
}

pick_many() {
  # fzf returns the hovered line on Enter when zero items are selected; the "(none)" row
  # (ctrl-a parks the cursor on it) gives an explicit, filterable stand-in for "select nothing".
  local prompt="$1"; shift
  if [[ $# -eq 0 ]]; then return 0; fi
  printf '%s\n' "NONE|(none)|--|--" "$@" | "$FZF_BIN" --multi \
    --delimiter='|' --with-nth=2,3,4 \
    --bind 'load:select-all' --bind 'ctrl-a:toggle-all+first' \
    --header="$prompt  [all selected by default - tab: toggle one, ctrl-a: toggle all, enter: confirm]" \
    --height='~40%' --border --layout=reverse | awk -F'|' '$1 != "NONE"'
}

pick_audio_tracks() {
  local tracks="$1" lines=()
  mapfile -t lines < <(awk -F'|' '$2 ~ /^A_/' <<<"$tracks")
  SELECTED_AUDIO="$(pick_many "Select audio track(s)" "${lines[@]}")" || true
}

pick_subtitle_tracks() {
  local tracks="$1" lines=()
  mapfile -t lines < <(awk -F'|' '$2 ~ /^S_/' <<<"$tracks")
  SELECTED_SUBS="$(pick_many "Select subtitle track(s)" "${lines[@]}")" || true
}

meta_source_path() {
  if [[ "$SOURCE_TYPE" == "bdmv" ]]; then echo "$PLAYLIST_PATH"; else echo "$SOURCE_PATH"; fi
}

build_demux_meta() {
  META_FILE="$WORKDIR/demux.meta"
  local src; src="$(meta_source_path)"

  {
    echo 'MUXOPT --demux --new-audio-pes --vbr'
    if [[ "$SOURCE_TYPE" == "bdmv" ]]; then
      echo "V_MPEG4/ISO/AVC, \"$src\", track=$AVC_TRACK_ID"
      echo "V_MPEG4/ISO/MVC, \"$src\", track=$MVC_TRACK_ID"
    else
      echo "V_MPEG4/ISO/AVC, \"$src\", track=$AVC_TRACK_ID, subTrack=2"
      echo "V_MPEG4/ISO/MVC, \"$src\", track=$MVC_TRACK_ID, subTrack=1"
    fi

    if [[ -n "${SELECTED_AUDIO:-}" ]]; then
      while IFS='|' read -r id codec lang desc; do
        echo "$codec, \"$src\", track=$id, lang=$lang"
      done <<<"$SELECTED_AUDIO"
    fi

    if [[ -n "${SELECTED_SUBS:-}" ]]; then
      while IFS='|' read -r id codec lang desc; do
        echo "$codec, \"$src\", track=$id, lang=$lang"
      done <<<"$SELECTED_SUBS"
    fi
  } > "$META_FILE"
}

run_demux() {
  "$TSMUXER_BIN" "$META_FILE" "$WORKDIR"
}

find_demuxed_files() {
  BASE_264="$(find "$WORKDIR" -maxdepth 1 -iname "*track_${AVC_TRACK_ID}*.264" | head -1)"
  DEP_MVC="$(find "$WORKDIR" -maxdepth 1 -iname "*track_${MVC_TRACK_ID}*.mvc" | head -1)"
  if [[ -z "$BASE_264" || -z "$DEP_MVC" ]]; then
    echo "Error: couldn't locate demuxed .264/.mvc files in $WORKDIR - check tsMuxeR's actual output naming" >&2
    exit 1
  fi
}

build_vpy() {
  VPY_FILE="$WORKDIR/script.vpy"
  {
    echo "import vapoursynth as vs"
    echo "core = vs.core"
    echo "core.std.LoadPlugin(r\"$MVC_SOURCE_PLUGIN\")"
    echo "clip = core.mvc.Source(r\"$BASE_264\", dependent=r\"$DEP_MVC\", stack=\"sbs\")"
    if [[ "$SBS_MODE" == "half" ]]; then
      echo "clip = core.resize.Bicubic(clip, width=clip.width//2, height=clip.height)"
    fi
    echo "clip.set_output()"
  } > "$VPY_FILE"
}

probe_encoded_video() {
  local info; info="$("$VSPIPE_BIN" --info "$VPY_FILE" 2>&1)"
  ENC_WIDTH="$(grep -oP '^Width:\s*\K[0-9]+' <<<"$info")"
  ENC_HEIGHT="$(grep -oP '^Height:\s*\K[0-9]+' <<<"$info")"
  ENC_FPS_NUM="$(grep -oP '^FPS:\s*\K[0-9]+(?=/)' <<<"$info")"
  ENC_FPS_DEN="$(grep -oP '^FPS:\s*[0-9]+/\K[0-9]+' <<<"$info")"
}

run_encode() {
  ENCODED_FILE="$WORKDIR/encoded.264"
  if [[ "$ENCODER" == "vaapi" ]]; then
    "$VSPIPE_BIN" --y4m "$VPY_FILE" - \
      | "$FFMPEG_BIN" -vaapi_device "$VAAPI_DEVICE" -f yuv4mpegpipe -i - \
          -vf 'format=nv12,hwupload' -c:v h264_vaapi -qp "$X264_CRF" $X264_EXTRA_OPTS \
          -f h264 -y "$ENCODED_FILE"
  else
    "$VSPIPE_BIN" --y4m "$VPY_FILE" - \
      | "$X264_BIN" --demuxer y4m --frame-packing 3 \
          --preset "$X264_PRESET" --crf "$X264_CRF" $X264_EXTRA_OPTS \
          -o "$ENCODED_FILE" -
  fi
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

build_mkvmerge_json() {
  MUX_JSON="$WORKDIR/mux_options.json"
  FINAL_MKV="$WORKDIR/${SOURCE_BASENAME}.sbs.mkv"

  local sbs_label="Full SBS"
  if [[ "$SBS_MODE" == "half" ]]; then sbs_label="Half SBS"; fi
  local encoder_label="x264 CRF $X264_CRF preset $X264_PRESET"
  if [[ "$ENCODER" == "vaapi" ]]; then encoder_label="h264_vaapi QP $X264_CRF"; fi

  local args=()
  args+=("--title" "$SOURCE_BASENAME")

  args+=("--track-name" "0:$sbs_label ($encoder_label)")
  args+=("--stereo-mode" "0:1")  # side by side, left eye first
  args+=("--language" "0:und")
  if [[ -n "${ENC_WIDTH:-}" && -n "${ENC_HEIGHT:-}" ]]; then args+=("--aspect-ratio" "0:$ENC_WIDTH/$ENC_HEIGHT"); fi
  if [[ -n "${ENC_FPS_NUM:-}" && -n "${ENC_FPS_DEN:-}" ]]; then args+=("--default-duration" "0:${ENC_FPS_NUM}/${ENC_FPS_DEN}p"); fi
  args+=("--default-track" "0:yes")
  args+=("$ENCODED_FILE")

  local first=1
  if [[ -n "${SELECTED_AUDIO:-}" ]]; then
    while IFS='|' read -r id codec lang desc; do
      local f; f="$(find "$WORKDIR" -maxdepth 1 -iname "*track_${id}*" ! -iname "*.264" ! -iname "*.mvc" | head -1)"
      if [[ -n "$f" ]]; then
        args+=("--track-name" "0:$desc" "--language" "0:$lang" \
               "--default-track" "0:$([[ $first -eq 1 ]] && echo yes || echo no)" \
               "--compression" "0:none" "$f")
        first=0
      fi
    done <<<"$SELECTED_AUDIO"
  fi

  first=1
  if [[ -n "${SELECTED_SUBS:-}" ]]; then
    while IFS='|' read -r id codec lang desc; do
      local f; f="$(find "$WORKDIR" -maxdepth 1 -iname "*track_${id}*.sup" | head -1)"
      if [[ -n "$f" ]]; then
        args+=("--track-name" "0:$desc" "--language" "0:$lang" \
               "--default-track" "0:$([[ $first -eq 1 ]] && echo yes || echo no)" \
               "--forced-track" "0:no" "--compression" "0:none" "$f")
        first=0
      fi
    done <<<"$SELECTED_SUBS"
  fi

  if [[ -n "${CHAPTERS_FILE:-}" ]]; then args+=("--chapter-language" "und" "--chapters" "$CHAPTERS_FILE"); fi

  args+=("--engage" "no_cue_duration")
  args+=("--engage" "no_cue_relative_position")
  args+=("--disable-track-statistics-tags")
  args+=("-o" "$FINAL_MKV")

  {
    echo "["
    local i last=$((${#args[@]} - 1))
    for i in "${!args[@]}"; do
      printf '  "%s"%s\n' "$(json_escape "${args[$i]}")" "$([[ $i -lt $last ]] && echo ,)"
    done
    echo "]"
  } > "$MUX_JSON"
}

run_mux() {
  "$MKVMERGE_BIN" "@$MUX_JSON"
}

cleanup_intermediates() {
  if [[ "$KEEP_INTERMEDIATES" == "true" ]]; then return 0; fi
  find "$WORKDIR" -maxdepth 1 -type f \( -iname "*.264" -o -iname "*.mvc" -o -iname "*.sup" -o -iname "*track_*" \) -delete
}

main() {
  parse_args "$@"
  load_config
  resolve_source

  if [[ "$SOURCE_TYPE" == "bdmv" ]]; then
    pick_playlist
    run_tsmuxer_scan "$PLAYLIST_PATH"
  else
    run_tsmuxer_scan "$SOURCE_PATH"
  fi
  local tracks; tracks="$(scan_tracks)"

  pick_video_track_ids "$tracks"
  pick_audio_tracks "$tracks"
  pick_subtitle_tracks "$tracks"
  pick_encode_settings
  build_chapters

  build_demux_meta
  run_demux
  find_demuxed_files
  build_vpy
  probe_encoded_video
  run_encode
  build_mkvmerge_json
  run_mux
  cleanup_intermediates

  echo "Done: $FINAL_MKV"
}

main "$@"
