#!/bin/sh
LOCKDIR=/var/run/umb-watch.lock
mkdir "$LOCKDIR" 2>/dev/null || exit 0
cleanup() { rmdir "$LOCKDIR" 2>/dev/null; exit 0; }
trap cleanup HUP INT TERM
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
while :; do
    CHANGED=0
    for DEV in $(/sbin/ifconfig -l | /usr/bin/tr ' ' '\n' | /usr/bin/awk '/^umb[0-9]+$/ {print}'); do
        PEER=$(/sbin/ifconfig "$DEV" 2>/dev/null | /usr/bin/awk '/inet / {print $4; exit}')
        STATE="/var/run/umb-watch.${DEV}.peer"
        ERRSTATE="/var/run/umb-watch.${DEV}.err"
        if [ -z "$PEER" ]; then
            /bin/rm -f "$STATE" "$ERRSTATE"
            continue
        fi
        OLD=$(/bin/cat "$STATE" 2>/dev/null)
        if [ "$PEER" = "$OLD" ]; then
            continue
        fi
        /usr/local/bin/php -r 'require_once "/usr/local/etc/inc/config.inc"; require_once "/usr/local/etc/inc/util.inc"; global $config; if (isset($config["interfaces"]) === false || is_array($config["interfaces"]) === false || isset($config["OPNsense"]["Gateways"]["gateway_item"]) === false || is_array($config["OPNsense"]["Gateways"]["gateway_item"]) === false) exit(2); $dev=$argv[1]; $peer=$argv[2]; $ifid=null; foreach ($config["interfaces"] as $id=>$cfg) { if (($cfg["if"] ?? "") === $dev) { $ifid=$id; break; } } if ($ifid === null) exit(3); $matches=[]; foreach ($config["OPNsense"]["Gateways"]["gateway_item"] as $idx=>$gw) { if (($gw["interface"] ?? "") === $ifid && ($gw["ipprotocol"] ?? "") === "inet" && ($gw["disabled"] ?? "0") !== "1") $matches[]=$idx; } if (count($matches) === 0) exit(4); if (count($matches) > 1) exit(5); $idx=$matches[0]; if (($config["OPNsense"]["Gateways"]["gateway_item"][$idx]["gateway"] ?? "") !== $peer) { $config["OPNsense"]["Gateways"]["gateway_item"][$idx]["gateway"]=$peer; write_config("Update ".$dev." MBIM gateway"); } exit(0);' "$DEV" "$PEER"
        RC=$?
        if [ "$RC" = "0" ]; then
            echo "$PEER" > "$STATE"
            /bin/rm -f "$ERRSTATE"
            CHANGED=1
        else
            ERRKEY="${PEER}:${RC}"
            OLDERR=$(/bin/cat "$ERRSTATE" 2>/dev/null)
            if [ "$ERRKEY" != "$OLDERR" ]; then
                case "$RC" in
                    2) MSG="OPNsense configuration structure incompatible" ;;
                    3) MSG="no OPNsense interface assignment found for $DEV" ;;
                    4) MSG="no IPv4 gateway found for $DEV" ;;
                    5) MSG="multiple IPv4 gateways found for $DEV - refusing ambiguous update" ;;
                    *) MSG="gateway update failed for $DEV with PHP exit code $RC" ;;
                esac
                /usr/bin/logger -t umb-watch "$MSG"
                echo "$ERRKEY" > "$ERRSTATE"
            fi
        fi
    done
    if [ "$CHANGED" = "1" ]; then
        /usr/local/sbin/configctl interface routes configure >/dev/null 2>&1
    fi
    sleep 10
done
