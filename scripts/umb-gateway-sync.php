<?php
// CLI helper for umb-watch.sh. No changes unless --apply is supplied.
if (PHP_SAPI !== 'cli') { exit(1); }
require_once('/usr/local/etc/inc/config.inc');
require_once('/usr/local/etc/inc/util.inc');
$device = $argv[1] ?? '';
$peer = $argv[2] ?? '';
$apply = ($argv[3] ?? '') === '--apply';
if (!preg_match('/^umb[0-9]+$/D', $device) || !filter_var($peer, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
    fwrite(STDERR, "Invalid device or IPv4 peer\n"); exit(2);
}
if (!is_array($config['interfaces'] ?? null) || !is_array($config['OPNsense']['Gateways']['gateway_item'] ?? null)) {
    fwrite(STDERR, "Unsupported configuration structure\n"); exit(2);
}
$interfaces = [];
foreach ($config['interfaces'] as $id => $item) {
    if (($item['if'] ?? '') === $device && isset($item['enable']) && $item['enable'] !== '0') {
        $interfaces[] = $id;
    }
}
if (count($interfaces) !== 1) { fwrite(STDERR, "Expected one enabled interface assignment\n"); exit(3); }
$id = $interfaces[0];
$matches = [];
foreach ($config['OPNsense']['Gateways']['gateway_item'] as $idx => $gateway) {
    if (($gateway['interface'] ?? '') === $id && ($gateway['ipprotocol'] ?? '') === 'inet' && ($gateway['disabled'] ?? '0') !== '1') {
        $matches[] = $idx;
    }
}
if (count($matches) !== 1) { fwrite(STDERR, "Expected one enabled IPv4 gateway\n"); exit(4); }
$idx = $matches[0];
$name = $config['OPNsense']['Gateways']['gateway_item'][$idx]['name'] ?? '';
$link = $config['interfaces'][$id]['gateway'] ?? '';
if ($name === '' || !in_array($link, ['', 'none', $name], true)) {
    fwrite(STDERR, "Conflicting interface gateway assignment; refusing overwrite\n"); exit(5);
}
$addressChanged = ($config['OPNsense']['Gateways']['gateway_item'][$idx]['gateway'] ?? '') !== $peer;
$linkChanged = $link !== $name;
echo json_encode(['device' => $device, 'interface' => $id, 'gateway' => $name,
    'peer' => $peer, 'address_changed' => $addressChanged, 'link_changed' => $linkChanged,
    'apply_requested' => $apply], JSON_UNESCAPED_SLASHES) . PHP_EOL;
if (!$apply || (!$addressChanged && !$linkChanged)) { exit(0); }
// Record the reload requirement before saving, so a failed reload can be retried.
if (file_put_contents('/var/run/umb-watch.reload-pending', "pending\n", LOCK_EX) === false) {
    fwrite(STDERR, "Cannot record pending reload\n"); exit(6);
}
$config['OPNsense']['Gateways']['gateway_item'][$idx]['gateway'] = $peer;
$config['interfaces'][$id]['gateway'] = $name;
$saved = write_config('Synchronize ' . $device . ' MBIM peer and interface gateway for automatic NAT');
if (!is_array($saved)) { fwrite(STDERR, "Configuration save failed\n"); exit(7); }
exit(10);
