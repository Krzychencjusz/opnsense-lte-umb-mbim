#!/bin/sh
TARGET=/usr/local/opnsense/www/js/widgets/Interfaces.js
MARKER="umb-media-patch"

/usr/bin/grep -Fq "$MARKER" "$TARGET" && exit 0

if /usr/bin/grep -Fq "let media = (" "$TARGET"; then
    /usr/bin/sed -i '' '/let media = (/a\
            if ((intf_data.device ?? "").startsWith("umb")) media = "LTE / MBIM"; // umb-media-patch' "$TARGET"
    /usr/bin/logger -t umb-widget-patch "Applied LTE / MBIM label patch for umb interfaces"
    exit 0
fi

/usr/bin/logger -t umb-widget-patch "Interfaces.js layout changed - patch not applied"
exit 1
