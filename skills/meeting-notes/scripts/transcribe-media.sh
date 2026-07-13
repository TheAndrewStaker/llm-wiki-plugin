#!/usr/bin/env bash
# Convert a local audio/video recording into transcript artifacts suitable for wiki ingestion.
# Requires ffmpeg + mlx_whisper. The source recording stays outside the git-backed wiki.
set -euo pipefail

usage() {
	printf 'Usage: %s <audio-or-video> [output-directory]\n' "$(basename "$0")" >&2
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	usage
	exit 2
fi

input=$1
if [ ! -f "$input" ]; then
	printf 'transcribe-media: input does not exist: %s\n' "$input" >&2
	exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
	printf 'transcribe-media: ffmpeg is required (macOS: brew install ffmpeg)\n' >&2
	exit 1
fi
if ! command -v mlx_whisper >/dev/null 2>&1; then
	printf 'transcribe-media: mlx_whisper is required (uv tool install mlx-whisper)\n' >&2
	exit 1
fi

stem=$(basename "$input")
stem=${stem%.*}
output_dir=${2:-"$(dirname "$input")/${stem}-transcript"}
mkdir -p "$output_dir"

data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
local_model="$data_home/mlx-whisper/models/large-v3-mlx"
if [ -n "${WIKI_TRANSCRIPTION_MODEL:-}" ]; then
	model=$WIKI_TRANSCRIPTION_MODEL
elif [ -f "$local_model/weights.npz" ]; then
	model=$local_model
else
	model=mlx-community/whisper-large-v3-mlx
fi

args=(
	"$input"
	--model "$model"
	--word-timestamps True
	--output-format all
	--output-dir "$output_dir"
	--output-name "$stem"
)
if [ -n "${WIKI_TRANSCRIPTION_LANGUAGE:-}" ]; then
	args+=(--language "$WIKI_TRANSCRIPTION_LANGUAGE")
fi
if [ -n "${WIKI_TRANSCRIPTION_PROMPT:-}" ]; then
	args+=(--initial-prompt "$WIKI_TRANSCRIPTION_PROMPT")
fi

mlx_whisper "${args[@]}"

for extension in txt vtt srt tsv json; do
	artifact="$output_dir/$stem.$extension"
	if [ ! -s "$artifact" ]; then
		printf 'transcribe-media: expected artifact was not created: %s\n' "$artifact" >&2
		exit 1
	fi
done

printf 'Transcript artifacts: %s\n' "$output_dir"
printf 'Wiki raw source: %s\n' "$output_dir/$stem.vtt"
