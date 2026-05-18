#!/bin/bash

REPO_LIST="packages.list"
TMP_DIR="downloaded_packages"
cat "$REPO_LIST"

while IFS= read -r repo_url; do
    repo_owner=$(echo "$repo_url" | cut -d'/' -f4)
    repo_name=$(echo "$repo_url" | cut -d'/' -f5)
    echo "PROCESSING: $repo_owner/$repo_name"

    release_info=$(curl -s "https://api.github.com/repos/${repo_owner}/${repo_name}/releases/latest")

    # Patterns (ignore capital)
    patterns=(
            "100:.*amd64.*\\.deb$"          # **amd64**.deb
            "50:.*x86_64.*\\.deb$"          # **x86_64**.deb
            "45:.*x64.*\\.deb$"             # Why
            "40:.*ubuntu.*\\.deb$"          # **ubuntu**.deb
    )

    best_match=""
    best_weight=0

    for pattern in "${patterns[@]}"; do
        weight=$(echo "$pattern" | cut -d: -f1)
        regex=$(echo "$pattern" | cut -d: -f2)
        
        match=$(echo "$release_info" | jq -r --arg re "$regex" '.assets[] | select(.name | test($re; "i")) | .browser_download_url' | head -1)
        
        if [ -n "$match" ] && [ "$weight" -gt "$best_weight" ]; then
            best_match="$match"
            best_weight="$weight"
        fi
    done
    
    if [ -n "$best_match" ]; then
        echo "Downloading (weight: $best_weight): $best_match"
        wget -q -P "$TMP_DIR" "$best_match"
        echo "DONE: $repo_owner/$repo_name"
    else
        echo "WARNING: No matching package found for $repo_owner/$repo_name"
    fi

done < "$REPO_LIST"
