#!/bin/sh
# Deliberately does NOT change the system (Debian policy; don't disturb an
# existing WireGuard). The user runs the explicit, auditable setup step.
set -e
systemctl daemon-reload >/dev/null 2>&1 || true
cat <<'EOF'

StealthWG installed. To bring up a masked WireGuard server:

    sudo stealthwg init

Then add more devices with:

    sudo stealthwg add-client <name>

EOF
