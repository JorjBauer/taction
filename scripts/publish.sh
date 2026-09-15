#!/bin/bash
# Upload the release artifacts in dist/ to GitHub as one draft release for the current version.
#
#   scripts/publish.sh            find or create the draft for v<VERSION>, upload dist/Taction-<VERSION>.{zip,dmg}
#   scripts/publish.sh --dry-run  say what would happen (works without a token on a public repo)
#
# Idempotent: run it again after a partial upload and it adds what is missing, replaces an asset
# whose size differs, leaves the rest, and removes any other draft carrying the same tag. The draft
# is left as a draft: review it on GitHub and publish it there, which is also what creates the tag
# on GitHub if it does not exist yet. A version with a hyphen (0.2.0-beta.1) becomes a prerelease.
#
# The repository comes from TactionUpdateRepo in Resources/Taction-Info.plist, so the updater and
# the publisher can never disagree. GH_TOKEN comes from, in order: the environment; the file
# $PUBLISH_ENV (default ~/.config/taction/publish.env, a shell file that sets GH_TOKEN); 1Password
# via `op read $OP_GH_TOKEN_REF`. The token needs the repo scope (classic) or Contents: read/write.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG_DIR"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
REPO="$(plutil -extract TactionUpdateRepo raw Resources/Taction-Info.plist)"
PRERELEASE=false; [[ "$VERSION" == *-* ]] && PRERELEASE=true
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
PUBLISH_ENV="${PUBLISH_ENV:-$HOME/.config/taction/publish.env}"
OP_GH_TOKEN_REF="${OP_GH_TOKEN_REF:-op://automatons/taction/token}"
API="https://api.github.com"

ASSETS=("dist/Taction-$VERSION.zip" "dist/Taction-$VERSION.dmg")
for f in "${ASSETS[@]}"; do
    [ -f "$f" ] || { echo "missing $f; run make release first" >&2; exit 2; }
done

# --- token ---------------------------------------------------------------------------------------
if [ -z "${GH_TOKEN:-}" ] && [ -r "$PUBLISH_ENV" ]; then
    echo "reading $PUBLISH_ENV"
    set -a; . "$PUBLISH_ENV"; set +a
fi
if [ -z "${GH_TOKEN:-}" ] && [ "$DRY" = "0" ] && command -v op >/dev/null 2>&1; then
    echo "reading GH_TOKEN from 1Password ($OP_GH_TOKEN_REF)"
    GH_TOKEN="$(op read "$OP_GH_TOKEN_REF")"
fi
if [ -z "${GH_TOKEN:-}" ] && [ "$DRY" = "0" ]; then
    echo "GH_TOKEN is not set; see the header of scripts/publish.sh" >&2; exit 2
fi

gh() {  # gh METHOD URL [curl args...]  -> body on stdout; fails on HTTP errors
    local method="$1" url="$2"; shift 2
    case "$url" in http*) ;; *) url="$API$url" ;; esac
    local auth=()
    [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")
    curl -sS --fail-with-body -X "$method" ${auth[@]+"${auth[@]}"} \
        -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@" "$url"
}
py() { python3 -c "$@"; }

echo "$VERSION: tag $TAG on $REPO, $($PRERELEASE && echo pre-release || echo full release)"

# --- find our releases (drafts carry no tag until published, so match by tag or by name) ---------
RELEASES="$(gh GET "/repos/$REPO/releases?per_page=100")"
read -r PUBLISHED_ID PUBLISHED_TAG DRAFT_ID DRAFT_ASSETS DRAFT_TAG DRAFT_PRE EXTRA_IDS <<< "$(printf '%s' "$RELEASES" | py '
import json, sys
rel = json.load(sys.stdin); tag = sys.argv[1]; ver = sys.argv[2]
mine = [r for r in rel if r["tag_name"] == tag or r["name"] == ver]
pub = next((r for r in mine if not r["draft"]), None)
drafts = sorted([r for r in mine if r["draft"]], key=lambda r: -len(r["assets"]))
d = drafts[0] if drafts else None
print(pub["id"] if pub else "-", pub["tag_name"] if pub else "-",
      d["id"] if d else "-", len(d["assets"]) if d else 0, d["tag_name"] if d else "-",
      str(d["prerelease"]).lower() if d else "-", ",".join(str(r["id"]) for r in drafts[1:]) or "-")
' "$TAG" "$VERSION")"

if [ "$PUBLISHED_ID" != "-" ]; then
    echo "$TAG is already published as release $PUBLISHED_ID (tag $PUBLISHED_TAG); bump VERSION" >&2; exit 2
fi

if [ "$DRAFT_ID" = "-" ]; then
    echo "creating the draft"
    if [ "$DRY" = "0" ]; then
        DRAFT="$(gh POST "/repos/$REPO/releases" -H "Content-Type: application/json" \
            -d "$(py 'import json,sys; print(json.dumps({"tag_name": sys.argv[1], "name": sys.argv[2], "draft": True, "prerelease": sys.argv[3] == "true"}))' "$TAG" "$VERSION" "$PRERELEASE")")"
        DRAFT_ID="$(printf '%s' "$DRAFT" | py 'import json,sys; print(json.load(sys.stdin)["id"])')"
    fi
else
    echo "draft $DRAFT_ID exists with $DRAFT_ASSETS asset(s)"
    if { [ "$DRAFT_TAG" != "$TAG" ] || [ "$DRAFT_PRE" != "$PRERELEASE" ]; } && [ "$DRY" = "0" ]; then
        echo "  setting tag $TAG, prerelease=$PRERELEASE"
        gh PATCH "/repos/$REPO/releases/$DRAFT_ID" -H "Content-Type: application/json" \
            -d "$(py 'import json,sys; print(json.dumps({"tag_name": sys.argv[1], "prerelease": sys.argv[2] == "true"}))' "$TAG" "$PRERELEASE")" >/dev/null
    fi
fi

# --- upload assets serially, replacing any whose size differs -------------------------------------
if [ "$DRY" = "0" ]; then
    DRAFT="$(gh GET "/repos/$REPO/releases/$DRAFT_ID")"
    UPLOAD_URL="$(printf '%s' "$DRAFT" | py 'import json,sys; print(json.load(sys.stdin)["upload_url"].split("{")[0])')"
fi
for f in "${ASSETS[@]}"; do
    name="$(basename "$f")"; size="$(stat -f %z "$f")"
    existing="-"; existing_size=0
    if [ "$DRY" = "0" ]; then
        read -r existing existing_size <<< "$(printf '%s' "$DRAFT" | py '
import json,sys
a = next((a for a in json.load(sys.stdin)["assets"] if a["name"] == sys.argv[1]), None)
print(a["id"] if a else "-", a["size"] if a else 0)' "$name")"
    fi
    if [ "$existing" != "-" ] && [ "$existing_size" = "$size" ]; then echo "  ok       $name"; continue; fi
    if [ "$existing" != "-" ]; then
        echo "  replace  $name ($existing_size -> $size bytes)"
        gh DELETE "/repos/$REPO/releases/assets/$existing" >/dev/null
    else
        echo "  upload   $name ($size bytes)"
    fi
    [ "$DRY" = "1" ] && continue
    gh POST "$UPLOAD_URL?name=$name" -H "Content-Type: application/octet-stream" --data-binary "@$f" >/dev/null
done

if [ "$EXTRA_IDS" != "-" ]; then
    for id in ${EXTRA_IDS//,/ }; do
        echo "deleting extra draft $id"
        [ "$DRY" = "0" ] && gh DELETE "/repos/$REPO/releases/$id" >/dev/null
    done
fi

if [ "$DRY" = "0" ]; then
    FINAL="$(gh GET "/repos/$REPO/releases/$DRAFT_ID")"
    printf '%s' "$FINAL" | py 'import json,sys; r=json.load(sys.stdin); print(f"draft {r[\"name\"]} has {len(r[\"assets\"])} assets: {r[\"html_url\"]}")'
    echo "review it on GitHub and publish it there"
else
    echo "dry run complete"
fi
