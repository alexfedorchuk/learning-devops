#!/bin/bash
set -euo pipefail

usage() {
	cat <<EOF
Usage: $0 -s <source-file> [-d <backup-dir>]

Create timestamped copy of config file.

Options:

-s, --source <file>   Backup file
-d, --dir <dir>       Catalog
-v, --verbose         Detailed
-h, --help            Help
EOF
}

die() {
	echo "Error: $*" >&2
	echo "Try '$0 --help' for reference" >&2
	exit 1
}

backup_dir="${HOME}/backups"
source_file=""
verbose=0


while [[ $# -gt 0 ]]; do
	case "$1" in
		-s|--source)
			[[ $# -ge 2 ]] || die "$1 at least one argument"
			source_file="$2"
			shift 2
			;;
		--source=*)
			source_file="${1#*=}"
			shift
			;;
		-d|--dir)
			[[ $# -ge 2 ]] || die "$1 at least one argument"
			backup_dir="$2"
			shift 2
			;;
		--dir=*)
			backup_dir="${1#*=}"
			shift
			;;
		-v|--verbose)
			verbose=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			die "unknown option: $1"
			;;
		*)
			die "unexpected argument position: $1"
			;;
	esac
done

[[ -n "$source_file" ]] || die "missing file (-s/--source)"
[[ -f "$source_file" ]] || die "file not fount: $source_file"

log () {
	(( verbose )) && echo "[log] $*" >&2
	return 0
}


tmpfile=""

cleanup() {
	[[ -n "$tmpfile" && -f "$tmpfile" ]] && rm -f "$tmpfile"
	return 0
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


backup_config() {
	local src="$1"
	local dest_dir="$2"
	local base
	base="$(basename "$src")"

	log "source: $src"
	log "catalog: $dest_dir"

	mkdir -p "$dest_dir"

	local latest
	latest="$(find "$dest_dir" -maxdepth 1 -name "${base}.*.bak" 2>/dev/null | sort | tail -n1 || true)"

	if [[ -n "$latest" ]] && cmp -s "$src" "$latest"; then
		echo "Without changes - latest copy (${latest}) is actual, skipping"
		return 0
	fi

	local timestamp
	timestamp="$(date +%Y%m%d-%H%M%S)"
	tmpfile="$(mktemp "${dest_dir}/.${base}.XXXXXX")"

	cp "$src" "$tmpfile"
	mv "$tmpfile" "${dest_dir}/${base}.${timestamp}.bak"
	tmpfile=""

	echo "Created: ${dest_dir}/${base}.${timestamp}.bak"
}

backup_config "$source_file" "$backup_dir"

