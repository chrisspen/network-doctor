#!/usr/bin/env bash
set -euo pipefail

# Publish network-doctor .deb to GitHub Pages as an APT repository
#
# Usage: ./publish.sh [version]
#
# Prerequisites:
#   - gh CLI authenticated
#   - GPG key for signing (optional, set GPG_KEY_ID)
#
# After publishing, users can install with:
#   curl -fsSL https://<user>.github.io/network-doctor/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/network-doctor.gpg
#   echo "deb [signed-by=/usr/share/keyrings/network-doctor.gpg] https://<user>.github.io/network-doctor ./" | sudo tee /etc/apt/sources.list.d/network-doctor.list
#   sudo apt update && sudo apt install network-doctor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-1.0.0}"
GPG_KEY_ID="${GPG_KEY_ID:-}"  # Set to sign the repo, leave empty for unsigned
REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "")
GITHUB_USER=$(echo "$REPO_URL" | sed -n 's#.*github.com[:/]\([^/]*\)/.*#\1#p')

echo "Publishing network-doctor v${VERSION} to GitHub Pages..."
echo ""

# Build the .deb if not already built
DEB_FILE="${SCRIPT_DIR}/dist/network-doctor_${VERSION}_all.deb"
if [[ ! -f "$DEB_FILE" ]]; then
    echo "Building .deb package..."
    VERSION="$VERSION" "${SCRIPT_DIR}/build-deb.sh"
fi

if [[ ! -f "$DEB_FILE" ]]; then
    echo "ERROR: Failed to build $DEB_FILE"
    exit 1
fi

# Create temporary directory for gh-pages content
PAGES_DIR=$(mktemp -d)
trap "rm -rf $PAGES_DIR" EXIT

echo "Preparing APT repository in $PAGES_DIR..."

# Copy .deb file
cp "$DEB_FILE" "$PAGES_DIR/"

# Generate Packages file
cd "$PAGES_DIR"
dpkg-scanpackages --multiversion . > Packages
gzip -k -f Packages

# Generate Release file
cat > Release << EOF
Origin: network-doctor
Label: network-doctor
Suite: stable
Codename: stable
Version: ${VERSION}
Architectures: all amd64 arm64 armhf
Components: main
Description: Network Doctor APT Repository
Date: $(date -Ru)
EOF

# Add checksums to Release
{
    echo "MD5Sum:"
    for f in Packages Packages.gz; do
        echo " $(md5sum "$f" | cut -d' ' -f1) $(wc -c < "$f") $f"
    done
    echo "SHA256:"
    for f in Packages Packages.gz; do
        echo " $(sha256sum "$f" | cut -d' ' -f1) $(wc -c < "$f") $f"
    done
} >> Release

# Sign if GPG key provided
if [[ -n "$GPG_KEY_ID" ]]; then
    echo "Signing repository with GPG key $GPG_KEY_ID..."
    gpg --default-key "$GPG_KEY_ID" -abs -o Release.gpg Release
    gpg --default-key "$GPG_KEY_ID" --clearsign -o InRelease Release
    gpg --armor --export "$GPG_KEY_ID" > KEY.gpg
    SIGNED="yes"
else
    echo "WARNING: No GPG_KEY_ID set, repository will be unsigned"
    echo "         Users will need to use [trusted=yes] in sources.list"
    SIGNED="no"
fi

# Create index.html with instructions
if [[ -n "$GITHUB_USER" ]]; then
    PAGES_URL="https://${GITHUB_USER}.github.io/network-doctor"
else
    PAGES_URL="https://<username>.github.io/network-doctor"
fi

cat > index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Network Doctor APT Repository</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }
        pre { background: #f4f4f4; padding: 15px; border-radius: 5px; overflow-x: auto; }
        code { background: #f4f4f4; padding: 2px 6px; border-radius: 3px; }
        h1 { border-bottom: 2px solid #333; padding-bottom: 10px; }
    </style>
</head>
<body>
    <h1>Network Doctor</h1>
    <p>Wi-Fi connectivity self-healer for NetworkManager on Ubuntu/Debian.</p>

    <h2>Installation</h2>
EOF

if [[ "$SIGNED" == "yes" ]]; then
    cat >> index.html << EOF
    <pre><code># Add GPG key
curl -fsSL ${PAGES_URL}/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/network-doctor.gpg

# Add repository
echo "deb [signed-by=/usr/share/keyrings/network-doctor.gpg] ${PAGES_URL} ./" | sudo tee /etc/apt/sources.list.d/network-doctor.list

# Install
sudo apt update
sudo apt install network-doctor</code></pre>
EOF
else
    cat >> index.html << EOF
    <pre><code># Add repository (unsigned)
echo "deb [trusted=yes] ${PAGES_URL} ./" | sudo tee /etc/apt/sources.list.d/network-doctor.list

# Install
sudo apt update
sudo apt install network-doctor</code></pre>
EOF
fi

cat >> index.html << EOF

    <h2>Configuration</h2>
    <pre><code>sudo systemctl edit network-doctor.service</code></pre>
    <p>See <a href="https://github.com/${GITHUB_USER}/network-doctor">GitHub repository</a> for configuration options.</p>

    <h2>Direct Download</h2>
    <p><a href="network-doctor_${VERSION}_all.deb">network-doctor_${VERSION}_all.deb</a></p>

    <p><small>Version: ${VERSION} | Built: $(date -u +"%Y-%m-%d %H:%M UTC")</small></p>
</body>
</html>
EOF

# Check if gh-pages branch exists, create if not
cd "$SCRIPT_DIR"
if ! git show-ref --verify --quiet refs/heads/gh-pages; then
    echo "Creating gh-pages branch..."
    git checkout --orphan gh-pages
    git rm -rf . 2>/dev/null || true
    git checkout main 2>/dev/null || git checkout master
fi

# Deploy to gh-pages
echo "Deploying to gh-pages branch..."
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git stash --include-untracked 2>/dev/null || true

git checkout gh-pages 2>/dev/null || git checkout --orphan gh-pages

# Clear gh-pages and copy new content
git rm -rf . 2>/dev/null || true
cp -r "$PAGES_DIR"/* .
touch .nojekyll  # Disable Jekyll processing

# Commit and push
git add -A
git commit -m "Publish network-doctor v${VERSION}" || echo "No changes to commit"
git push -u origin gh-pages --force

# Return to original branch
git checkout "$CURRENT_BRANCH"
git stash pop 2>/dev/null || true

echo ""
echo "=========================================="
echo "Published to GitHub Pages!"
echo "=========================================="
echo ""
echo "Repository URL: ${PAGES_URL}"
echo ""
if [[ "$SIGNED" == "yes" ]]; then
    echo "Install with:"
    echo "  curl -fsSL ${PAGES_URL}/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/network-doctor.gpg"
    echo "  echo \"deb [signed-by=/usr/share/keyrings/network-doctor.gpg] ${PAGES_URL} ./\" | sudo tee /etc/apt/sources.list.d/network-doctor.list"
    echo "  sudo apt update && sudo apt install network-doctor"
else
    echo "Install with:"
    echo "  echo \"deb [trusted=yes] ${PAGES_URL} ./\" | sudo tee /etc/apt/sources.list.d/network-doctor.list"
    echo "  sudo apt update && sudo apt install network-doctor"
fi
echo ""
echo "Don't forget to enable GitHub Pages in repository settings!"
echo "  Settings -> Pages -> Source: Deploy from branch -> gh-pages"
