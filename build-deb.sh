#!/usr/bin/env bash
set -euo pipefail

# Build a .deb package for network-doctor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${VERSION:-1.0.0}"
ARCH="${ARCH:-all}"
PKG_NAME="network-doctor"
PKG_DIR="${SCRIPT_DIR}/build/${PKG_NAME}_${VERSION}_${ARCH}"
OUT_DIR="${SCRIPT_DIR}/dist"

echo "Building ${PKG_NAME} version ${VERSION}..."

# Clean and create directories
rm -rf "${SCRIPT_DIR}/build"
mkdir -p "${PKG_DIR}/DEBIAN"
mkdir -p "${PKG_DIR}/usr/local/bin"
mkdir -p "${PKG_DIR}/etc/systemd/system"
mkdir -p "${OUT_DIR}"

# Copy files
install -m 0755 "${SCRIPT_DIR}/network-doctor.sh" "${PKG_DIR}/usr/local/bin/network-doctor"
install -m 0644 "${SCRIPT_DIR}/network-doctor.service" "${PKG_DIR}/etc/systemd/system/network-doctor.service"

# Create control file
cat > "${PKG_DIR}/DEBIAN/control" << EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Depends: bash, network-manager
Maintainer: Chris <chris@localhost>
Description: Wi-Fi connectivity self-healer for NetworkManager
 Monitors NetworkManager connectivity and automatically recovers
 from WiFi failures using soft recovery (nmcli reconnect) and
 optional hard recovery (USB device reset).
Homepage: https://github.com/chris/network-doctor
EOF

# Create postinst script (runs after install)
cat > "${PKG_DIR}/DEBIAN/postinst" << 'EOF'
#!/bin/bash
set -e
systemctl daemon-reload
systemctl enable network-doctor.service
echo "network-doctor installed. Start with: sudo systemctl start network-doctor"
echo "Configure with: sudo systemctl edit network-doctor.service"
EOF
chmod 755 "${PKG_DIR}/DEBIAN/postinst"

# Create prerm script (runs before removal)
cat > "${PKG_DIR}/DEBIAN/prerm" << 'EOF'
#!/bin/bash
set -e
systemctl stop network-doctor.service 2>/dev/null || true
systemctl disable network-doctor.service 2>/dev/null || true
EOF
chmod 755 "${PKG_DIR}/DEBIAN/prerm"

# Create postrm script (runs after removal)
cat > "${PKG_DIR}/DEBIAN/postrm" << 'EOF'
#!/bin/bash
set -e
systemctl daemon-reload
EOF
chmod 755 "${PKG_DIR}/DEBIAN/postrm"

# Create conffiles (mark service file as config)
cat > "${PKG_DIR}/DEBIAN/conffiles" << EOF
/etc/systemd/system/network-doctor.service
EOF

# Build the package
dpkg-deb --build --root-owner-group "${PKG_DIR}" "${OUT_DIR}/${PKG_NAME}_${VERSION}_${ARCH}.deb"

echo ""
echo "Package built: ${OUT_DIR}/${PKG_NAME}_${VERSION}_${ARCH}.deb"
echo ""
echo "Install with: sudo dpkg -i ${OUT_DIR}/${PKG_NAME}_${VERSION}_${ARCH}.deb"

# Clean up build directory
rm -rf "${SCRIPT_DIR}/build"
