#!/bin/bash
set -euo pipefail

REPO_LIST="packages.list"
TMP_DIR="downloaded_packages"
MANIFEST_FILE=".package-manifest"
NEED_UPDATE=false
MAX_RETRIES=3
RETRY_DELAY=5

mkdir -p "$TMP_DIR"

# ─── Helper: robust curl with retry and rate-limit awareness ───
robust_curl() {
    local url="$1"
    local attempt=1
    local response
    local http_code

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        response=$(curl -sS -w "\n%{http_code}" "$url" 2>&1) || true
        http_code=$(echo "$response" | tail -1)
        body=$(echo "$response" | sed '$d')

        # Rate limited
        if [ "$http_code" = "429" ] || [ "$http_code" = "403" ]; then
            local reset_time
            reset_time=$(echo "$body" | jq -r '.message // empty' 2>/dev/null || true)
            echo "::warning::GitHub API rate limited (HTTP $http_code), attempt $attempt/$MAX_RETRIES" >&2
            if echo "$reset_time" | grep -qi "rate limit"; then
                sleep "$((RETRY_DELAY * attempt * 2))"
            else
                sleep "$((RETRY_DELAY * attempt))"
            fi
            attempt=$((attempt + 1))
            continue
        fi

        # Success
        if [ "$http_code" = "200" ]; then
            echo "$body"
            return 0
        fi

        # Server error → retry
        if [ "$http_code" -ge 500 ] 2>/dev/null; then
            echo "::warning::GitHub API server error (HTTP $http_code), attempt $attempt/$MAX_RETRIES" >&2
            sleep "$((RETRY_DELAY * attempt))"
            attempt=$((attempt + 1))
            continue
        fi

        # Client error (404 etc) → don't retry
        echo "::error::GitHub API error (HTTP $http_code) for $url" >&2
        echo "$body"
        return 1
    done

    echo "::error::Failed after $MAX_RETRIES attempts for $url" >&2
    return 1
}

# ─── Generate manifest ───
# Manifest format (one line per repo):
#   owner/repo|tag_name|published_at|release_id|download_url|filename
generate_manifest() {
    local manifest="$1"
    > "$manifest"

    while IFS= read -r repo_url; do
        [ -z "$repo_url" ] && continue
        # Skip comment lines
        [[ "$repo_url" =~ ^[[:space:]]*# ]] && continue

        repo_owner=$(echo "$repo_url" | cut -d'/' -f4)
        repo_name=$(echo "$repo_url" | cut -d'/' -f5)

        if [ -z "$repo_owner" ] || [ -z "$repo_name" ]; then
            echo "::warning::Invalid repo URL: $repo_url" >&2
            continue
        fi

        echo "  Checking ${repo_owner}/${repo_name} ..."

        # Fetch latest release info
        release_info=$(robust_curl "https://api.github.com/repos/${repo_owner}/${repo_name}/releases/latest") || {
            echo "::warning::Failed to fetch release for ${repo_owner}/${repo_name}, skipping" >&2
            continue
        }

        # Extract key fields for change detection
        tag_name=$(echo "$release_info" | jq -r '.tag_name // empty')
        published_at=$(echo "$release_info" | jq -r '.published_at // empty')
        release_id=$(echo "$release_info" | jq -r '.id // empty')

        if [ -z "$tag_name" ] || [ -z "$published_at" ]; then
            echo "::warning::Missing tag_name or published_at for ${repo_owner}/${repo_name}, skipping" >&2
            continue
        fi

        # ─── Asset selection with priority patterns ───
        patterns=(
            "100:.*amd64.*\\.deb$"
            "50:.*x86_64.*\\.deb$"
            "45:.*x64.*\\.deb$"
            "40:.*ubuntu.*\\.deb$"
        )

        best_match=""
        best_weight=0

        for pattern in "${patterns[@]}"; do
            weight=$(echo "$pattern" | cut -d: -f1)
            regex=$(echo "$pattern" | cut -d: -f2)

            match=$(echo "$release_info" | jq -r --arg re "$regex" '
                .assets[] | select(.name | test($re; "i")) | .browser_download_url
            ' | head -1)

            if [ -n "$match" ] && [ "$weight" -gt "$best_weight" ]; then
                best_match="$match"
                best_weight="$weight"
            fi
        done

        if [ -n "$best_match" ]; then
            filename=$(basename "$best_match")
            # Store: repo|tag|published_at|release_id|download_url|filename
            echo "${repo_owner}/${repo_name}|${tag_name}|${published_at}|${release_id}|${best_match}|${filename}" >> "$manifest"
        else
            echo "::warning::No matching asset for ${repo_owner}/${repo_name} (tag: ${tag_name})" >&2
        fi

        # Small delay to be nice to GitHub API
        sleep 0.5

    done < "$REPO_LIST"
}

# ─── Compare manifests by key fields (tag, published_at, release_id) ───
compare_manifests() {
    local old="$1"
    local new="$2"

    if [ ! -f "$old" ] || [ ! -f "$new" ]; then
        return 1  # different
    fi

    # Extract repo|tag|published_at|release_id (first 4 fields) and sort
    local old_keys new_keys
    old_keys=$(cut -d'|' -f1-4 "$old" | sort)
    new_keys=$(cut -d'|' -f1-4 "$new" | sort)

    if [ "$old_keys" = "$new_keys" ]; then
        return 0  # same
    else
        return 1  # different
    fi
}

# ─── Main logic ───

if [ ! -f "$MANIFEST_FILE" ]; then
    echo "First run: No previous manifest found. Will perform full fetch."
    generate_manifest "${MANIFEST_FILE}"
    NEED_UPDATE=true
else
    echo "Comparing with previous packages..."
    generate_manifest "${MANIFEST_FILE}.new"

    if ! compare_manifests "$MANIFEST_FILE" "${MANIFEST_FILE}.new"; then
        echo "✓ Release changes detected (tag/time/id):"
        echo ""
        echo "  --- Old ---"
        while IFS='|' read -r repo tag pub_at rel_id url fname; do
            printf "  %-40s tag=%-20s published=%-25s id=%s\n" "$repo" "$tag" "$pub_at" "$rel_id"
        done < "$MANIFEST_FILE"
        echo ""
        echo "  +++ New +++"
        while IFS='|' read -r repo tag pub_at rel_id url fname; do
            printf "  %-40s tag=%-20s published=%-25s id=%s\n" "$repo" "$tag" "$pub_at" "$rel_id"
        done < "${MANIFEST_FILE}.new"
        echo ""
        NEED_UPDATE=true
        mv "${MANIFEST_FILE}.new" "$MANIFEST_FILE"
    else
        echo "✓ No release changes detected (same tag, published_at, release_id). Skipping fetch."
        NEED_UPDATE=false
        rm -f "${MANIFEST_FILE}.new"
    fi
fi

echo "NEED_UPDATE=$NEED_UPDATE" >> "$GITHUB_OUTPUT"
exit 0
