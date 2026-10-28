# OPNsense UMB/MBIM LTE WAN support

This repository documents a custom integration for using FreeBSD `umb(4)` / MBIM cellular interfaces as WAN interfaces on OPNsense. It synchronizes the modem's current IPv4 peer with the configured gateway and maintains the interface gateway assignment required for automatic outbound NAT.

The integration was developed with a Sierra Wireless MC7455. Interface and gateway discovery uses generic `umbX` device names; it is not hard-coded to `opt3` or `WAN_LTE_PPP`.

## What this solves

A connected MBIM modem exposes a point-to-point interface, for example:

```text
inet 10.xxx.xxx.225 --> 10.xxx.xxx.226
```

The right-hand address is the current peer and is used as the IPv4 gateway. It can change after a reconnect.

Updating the gateway address alone is insufficient for automatic outbound NAT in the tested OPNsense configuration. The gateway must also be assigned to the corresponding OPNsense interface. A working default route does not by itself confirm that NAT exists for LAN clients.

For every active `umbX` interface, the updated watcher:

1. Reads the current IPv4 peer.
2. Finds its enabled OPNsense interface assignment.
3. Finds the single enabled IPv4 gateway for that interface.
4. Synchronizes the gateway address and the interface's gateway assignment.
5. Saves the configuration only when either value changes.
6. Reapplies routing and firewall rules after changes, retrying failed reloads.

The configuration is checked every 10 seconds even when the peer is unchanged. This allows a missing gateway assignment to be restored after an interface settings save. Restoration may take one polling interval plus the reload time; it is not instantaneous. The watcher also reapplies routing and firewall rules once after startup when it finds a valid UMB configuration.

## Why MBIM instead of PPP

On the original MC7455 installation, PPP could establish a session but data traffic suffered from FCS errors. Native `umb(4)` / MBIM provided working IP traffic.

The tested modem exposed USB functions `diag,nmea,modem,mbim`, with USB ID `1199:9071`.

## 1. Load the driver

Add this to `/boot/loader.conf.local`:

```text
umb_load="YES"
```

After reboot, check:

```sh
ifconfig umb0
```

## 2. Configure the APN

Use your operator's APN. For example:

```sh
umbctl umb0 apn internet
umbctl umb0
```

Verify that the modem reconnects with the correct APN after reboot. APN persistence and any local startup configuration should be checked on the actual installation.

## 3. Assign the interface

Assign the `umbX` device in OPNsense and enable the interface. Set **IPv4 Configuration Type** to **None**. The modem supplies its address and point-to-point peer directly; do not enable DHCP on this interface.

## 4. Create the gateway

Create exactly one enabled IPv4 gateway for each assigned UMB interface. Initially use the modem's current peer as its gateway address. The watcher will update it when the peer changes.

The gateway name is arbitrary. Configure monitoring and failover policy according to your network; the watcher does not create gateway groups or change their tiers.

## 5. Install the watcher and PHP helper

Both files are required. Run these commands as root from the repository directory:

```sh
cp scripts/umb-gateway-sync.php /usr/local/sbin/umb-gateway-sync.php
chmod 0644 /usr/local/sbin/umb-gateway-sync.php
cp scripts/umb-watch.sh /usr/local/sbin/umb-watch.sh
chmod 0755 /usr/local/sbin/umb-watch.sh
```

Validate the files before starting them:

```sh
php -l /usr/local/sbin/umb-gateway-sync.php
sh -n /usr/local/sbin/umb-watch.sh
```

The PHP helper is executed through PHP, so it does not need executable permissions. Keep both files owned by root and not writable by unprivileged users.

For an existing installation, back up the installed scripts and OPNsense configuration before replacing them. After replacing both files, reboot during your maintenance window to start the new watcher through the existing startup hook. Replacing files does not restart an already running watcher.

## 6. Install the startup hook

```sh
cp scripts/rc.syshook.d/50-umb.sh /usr/local/etc/rc.syshook.d/start/50-umb.sh
chmod 0755 /usr/local/etc/rc.syshook.d/start/50-umb.sh
```

The existing hook brings UMB interfaces up and launches the watcher using `daemon(8)`. No change to the hook is required for the NAT fix. Retain any working local APN handling in your installed hook.

## 7. Optional dashboard label

The optional widget patch replaces the displayed UMB media label `<unknown type>` with `LTE / MBIM`. It does not configure routing or NAT.

```sh
cp scripts/umb-widget-patch.sh /usr/local/sbin/umb-widget-patch.sh
chmod 0755 /usr/local/sbin/umb-widget-patch.sh
cp scripts/rc.syshook.d/40-umb-widget-patch.sh /usr/local/etc/rc.syshook.d/start/40-umb-widget-patch.sh
chmod 0755 /usr/local/etc/rc.syshook.d/start/40-umb-widget-patch.sh
```

The patch checks for its marker before modifying the widget. It refuses to patch when the expected insertion point is absent. Core updates can replace the widget file, so check this optional component after upgrades.

## Behaviour and safeguards

- Supports discovery of multiple UMB interfaces in one watcher process.
- Does not reset the modem while waiting for an address.
- Defers synchronization when an interface has no IPv4 peer.
- Refuses ambiguous interface or gateway mappings.
- Refuses to overwrite a conflicting explicit interface gateway assignment.
- Does not change APNs, interface addressing mode, gateway priorities, NAT mode, or gateway groups.
- Uses OPNsense's automatic outbound NAT generation rather than adding manual NAT rules.
- Requires automatic outbound NAT to be enabled through **Automatic** or **Hybrid** mode.

The helper defaults to a read-only check. Example using the actual current peer:

```sh
php /usr/local/sbin/umb-gateway-sync.php umb0 10.161.237.226 --check
```

Only `--apply` requests configuration writes. The watcher supplies this flag. Helper exit codes are:

| Code | Meaning |
| --- | --- |
| 0 | Read-only check completed, or no changes required |
| 2 | Invalid input or unsupported configuration structure |
| 3 | Expected exactly one enabled interface assignment |
| 4 | Expected exactly one enabled IPv4 gateway |
| 5 | Missing gateway name or conflicting gateway assignment |
| 6 | Could not record the pending reload |
| 7 | Configuration save failed |
| 10 | Configuration changed and saved |

Messages use the log tag `umb-watch`. Runtime state is stored under:

```text
/var/run/umb-watch.umbX.peer
/var/run/umb-watch.umbX.err
/var/run/umb-watch.reload-pending
/var/run/umb-watch.lock
```

## Verification

Check the interface, watcher, routing, and loaded NAT rules:

```sh
ifconfig umb0
ps axww | grep '[u]mb-watch'
netstat -rn -f inet
pfctl -sn
```

With an active LTE connection and automatic NAT enabled, expect `nat on umb0` rules for the internal networks.

Test Internet access from a LAN client while the primary WAN is disconnected, then test failback and another failover. A successful request originating on the firewall alone does not verify client NAT.

Also verify behaviour after reboot and after saving the UMB interface settings. Check that the gateway assignment and NAT rules are present after the watcher has had time to run.

The NAT fix was tested on OPNsense **26.7.7**: automatic NAT rules appeared after the interface gateway assignment was added, LAN client Internet access over LTE worked, WAN/LTE switching worked, and the rules were present after reboot with the updated watcher installed. This does not establish compatibility with every OPNsense version or modem.

## Upgrade and backup considerations

This is a custom integration using OPNsense's PHP configuration structure and these commands:

```sh
configctl interface routes configure
configctl filter reload
```

After upgrades, verify driver loading, modem addressing, watcher startup, gateway synchronization, automatic NAT, and client traffic. Future changes to OPNsense may require updates to the integration.

Back up the scripts and startup hooks separately: an OPNsense XML configuration export does not include these custom files.

## Repository layout

```text
.
├── README.md
└── scripts
    ├── umb-watch.sh
    ├── umb-gateway-sync.php
    ├── umb-widget-patch.sh
    └── rc.syshook.d
        ├── 40-umb-widget-patch.sh
        └── 50-umb.sh
```
