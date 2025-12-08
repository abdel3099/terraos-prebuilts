#!/usr/bin/env bash
set -euo pipefail

# Improved download_images.sh
# - Validates inputs and required commands
# - Fetches recovery URLs robustly (single python invocation)
# - Verifies archives contain expected files before extracting
# - Uses pv when available to show progress
# - Exports paths in a safe manner

usage() {
  echo "Usage: $0 <board>"
  exit 2
}

if [ "${1-}" = "" ]; then
  usage
fi

board="$1"
quiet="${QUIET-}"    # set QUIET=1 in env to suppress wget --show-progress/pv
boards_url="https://chromiumdash.appspot.com/cros/fetch_serving_builds?deviceCategory=ChromeOS"

command -v wget >/dev/null 2>&1 || { echo "wget not found"; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "unzip not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found"; exit 1; }

# Download board zip from dl.cros.download (if needed)
echo "Downloading file from https://dl.cros.download/files/${board}/${board}.zip..."
if [ ! -f "./${board}.zip" ]; then
  if [ -z "$quiet" ]; then
    wget --show-progress "https://dl.cros.download/files/${board}/${board}.zip" -O "./${board}.zip"
  else
    wget -q "https://dl.cros.download/files/${board}/${board}.zip" -O "./${board}.zip"
  fi
fi

if [ ! -f "./${board}.zip" ]; then
  echo "Failed to download ${board}.zip"
  exit 1
fi

# Get first file name inside the board zip (useful for debugging / further processing).
shim=$(unzip -Z1 "./${board}.zip" | head -n1 || true)
echo "Top entry in ${board}.zip: ${shim:-(none)}"

# Fetch recovery URLs in one python invocation. Prints two lines:
#   reco_url
#   reven_url (if available, otherwise same as reco_url)
read -r reco_url reven_url <<EOF
$(wget -qO- --show-progress "$boards_url" | python3 - "$board" <<'PY'
import json,sys
data = json.load(sys.stdin)
board_name = sys.argv[1]
if board_name not in data.get("builds", {}):
    print("", end="")  # no output -> handled by caller
    sys.exit(1)
board = data["builds"][board_name]
# If there's a models mapping, try to pick a model that has pushRecoveries
if "models" in board:
    for device in board["models"].values():
        if device.get("pushRecoveries"):
            board = device
            break
push = board.get("pushRecoveries") or {}
urls = list(push.values())
if not urls:
    print("", end="")
    sys.exit(1)
# Use last URL as reco. If there's another, use second-last as reven; otherwise reven=reco
reco = urls[-1]
reven = urls[-2] if len(urls) > 1 else urls[-1]
print(reco)
print(reven)
PY
)
EOF

if [ -z "$reco_url" ]; then
  echo "Could not determine reco_url for board ${board}"
  exit 1
fi
if [ -z "$reven_url" ]; then
  reven_url="$reco_url"
fi

reco="../reco_${board}.bin"
reco_zip="../reco_${board}.zip"
reven="../reven_${board}.bin"
reven_zip="../reven_${board}.zip"

# Extract a single relevant file from a zip archive into a target path.
# Ensures the file exists inside the zip before extracting to avoid tar/python KeyError-like errors.
extract_zip() {
  local zip_path="$1"
  local bin_path="$2"

  if [ ! -f "$zip_path" ]; then
    echo "Zip '$zip_path' not found"
    return 1
  fi

  # Find a candidate entry inside the zip we want to extract (bin/img/json)
  local candidate
  candidate=$(unzip -Z1 "$zip_path" | grep -E '\.(bin|img|json|lf|tar|zip)$' | head -n1 || true)

  if [ -z "$candidate" ]; then
    echo "No expected file (.bin/.img/.json/.tar/.zip) found inside $zip_path"
    echo "Contents:"
    unzip -Z1 "$zip_path" || true
    return 2
  fi

  echo "Extracting $candidate from $zip_path -> $bin_path"

  if command -v pv >/dev/null 2>&1 && [ -z "$quiet" ]; then
    # Get estimated size for progress
    total_bytes=$(unzip -lq "$zip_path" | tail -n1 | awk '{print $1}')
    # If unable to determine total_bytes, fall back to no pv size
    if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ]; then
      unzip -p "$zip_path" "$candidate" | pv -s "$total_bytes" > "$bin_path"
    else
      unzip -p "$zip_path" "$candidate" > "$bin_path"
    fi
  else
    unzip -p "$zip_path" "$candidate" > "$bin_path"
  fi

  # verify output
  if [ ! -s "$bin_path" ]; then
    echo "Extraction created empty file: $bin_path"
    return 3
  fi

  # remove zip after successful extraction
  rm -f "$zip_path"
}

download_and_unzip() {
  local url="$1"
  local zip_path="$2"
  local bin_path="$3"

  if [ ! -f "$bin_path" ]; then
    if [ ! -f "$zip_path" ]; then
      if [ -z "$quiet" ]; then
        wget --show-progress "$url" -O "$zip_path" -c
      else
        wget -q "$url" -O "$zip_path" -c
      fi
    fi
  fi

  if [ ! -f "$zip_path" ]; then
    echo "Download failed or zip not present: $zip_path"
    return 1
  fi

  if [ ! -f "$bin_path" ]; then
    extract_zip "$zip_path" "$bin_path"
  else
    echo "Skipping extraction; already have: $bin_path"
  fi
}

download_and_unzip "$reco_url" "$reco_zip" "$reco"
download_and_unzip "$reven_url" "$reven_zip" "$reven"

# Export the produced paths so downstream scripts can use these variables.
# Use uppercase exported names to avoid clobbering shell variables.
export RECO_BIN="$reco"
export REVEN_BIN="$reven"

echo "Done. RECO_BIN=$RECO_BIN"
echo "Done. REVEN_BIN=$REVEN_BIN"
