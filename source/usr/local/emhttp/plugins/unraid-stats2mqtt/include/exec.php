<?php
/* unraid-stats2mqtt - action handler for toggle / test / clear_cert */

$plugin   = "unraid-stats2mqtt";
$cfg_file = "/boot/config/plugins/{$plugin}/config.cfg";
$cert_dir = "/boot/config/plugins/{$plugin}/certs";

function load_cfg($file) {
  $cfg = [];
  if (!file_exists($file)) return $cfg;
  foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    if ($line[0] === '#' || strpos($line, '=') === false) continue;
    list($k, $v) = explode('=', $line, 2);
    $cfg[trim($k)] = trim($v, " \"\t\n\r");
  }
  return $cfg;
}

function save_cfg($file, $data) {
  $lines = ["# unraid-stats2mqtt config - managed by WebUI"];
  foreach ($data as $k => $v) $lines[] = "{$k}=\"{$v}\"";
  file_put_contents($file, implode("\n", $lines) . "\n");
}

$action            = $_POST['action'] ?? '';
$cfg               = load_cfg($cfg_file);
$restart_flag_file = '/tmp/unraid-stats2mqtt.restart_pending';

if ($action === 'daemon_start') {
  @unlink($restart_flag_file);
  exec('/etc/rc.d/rc.unraid-stats2mqtt start > /dev/null 2>&1 &');
  echo 'Daemon starting…';
  exit;
}

if ($action === 'daemon_stop') {
  exec('/etc/rc.d/rc.unraid-stats2mqtt stop > /dev/null 2>&1 &');
  echo 'Daemon stopping…';
  exit;
}

if ($action === 'daemon_restart') {
  @unlink($restart_flag_file);
  exec('/etc/rc.d/rc.unraid-stats2mqtt restart > /dev/null 2>&1 &');
  echo 'Daemon restarting…';
  exit;
}

if ($action === 'mark_restart_pending') {
  touch($restart_flag_file);
  echo 'ok';
  exit;
}

if ($action === 'set_enabled') {
  $val = ($_POST['enabled'] ?? 'true') === 'true' ? 'true' : 'false';
  $cfg['PLUGIN_ENABLED'] = $val;
  save_cfg($cfg_file, $cfg);
  echo $val === 'true' ? 'Plugin enabled.' : 'Plugin disabled.';
  exit;
}

if ($action === 'generate_api_key') {
  $output = [];
  // Try to fetch existing key first; create if absent
  exec("unraid-api apikey --name Stats2MQTT 2>&1", $output, $rc);
  if ($rc !== 0) {
    $output = [];
    exec("unraid-api apikey --create --name 'Stats2MQTT' --roles VIEWER 2>&1", $output, $rc);
  }
  $text = implode("\n", $output);
  // Extract 64-char hex key from output
  if (preg_match('/\b([0-9a-f]{64})\b/', $text, $m)) {
    $key = $m[1];
    // Persist to config so the daemon picks it up without a manual save
    $cfg['UNRAID_API_KEY'] = $key;
    save_cfg($cfg_file, $cfg);
    echo json_encode(['ok' => true, 'key' => $key]);
  } else {
    echo json_encode(['ok' => false, 'msg' => htmlspecialchars($text)]);
  }
  exit;
}

if ($action === 'test') {
  $output = [];
  exec('timeout 10 /usr/local/emhttp/plugins/unraid-stats2mqtt/scripts/mqtt_monitor.sh test 2>&1', $output, $rc);
  echo $rc === 0
    ? implode("\n", $output)
    : 'Test failed: ' . implode(' ', $output);
  exit;
}

if ($action === 'test_connection') {
  $output = [];
  exec('timeout 10 /usr/local/emhttp/plugins/unraid-stats2mqtt/scripts/mqtt_monitor.sh check_connection 2>&1', $output, $rc);
  $msg = implode(' ', $output);
  echo $rc === 0 ? $msg : 'Connection failed: ' . $msg;
  exit;
}

if ($action === 'get_logs') {
  $log   = '/var/log/unraid-stats2mqtt.log';
  $lines = max(1, min(2000, (int)($_POST['lines'] ?? 40)));
  if (file_exists($log)) {
    echo htmlspecialchars(implode('', array_slice(file($log), -$lines)));
  } else {
    echo 'Log file not found yet.';
  }
  exit;
}

if ($action === 'clear_logs') {
  $log = '/var/log/unraid-stats2mqtt.log';
  if (file_exists($log)) {
    file_put_contents($log, '');
    echo 'Logs cleared.';
  } else {
    echo 'No log file found.';
  }
  exit;
}

if ($action === 'clear_cert') {
  $key = $_POST['cert_key'] ?? '';
  if (in_array($key, ['MQTT_CA_CERT', 'MQTT_CLIENT_CERT', 'MQTT_CLIENT_KEY'])) {
    if (!empty($cfg[$key]) && file_exists($cfg[$key])) unlink($cfg[$key]);
    $cfg[$key] = '';
    save_cfg($cfg_file, $cfg);
    echo 'Certificate cleared.';
  } else {
    http_response_code(400);
    echo 'Invalid cert key.';
  }
  exit;
}

if ($action === 'upload_cert') {
  $map = [
    'ca_cert_file'     => ['MQTT_CA_CERT',     'ca.crt'],
    'client_cert_file' => ['MQTT_CLIENT_CERT', 'client.crt'],
    'client_key_file'  => ['MQTT_CLIENT_KEY',  'client.key'],
  ];
  if (!is_dir($cert_dir)) mkdir($cert_dir, 0700, true);
  foreach ($map as $field => list($cfg_key, $filename)) {
    if (!empty($_FILES[$field]['tmp_name'])) {
      $dest = "{$cert_dir}/{$filename}";
      move_uploaded_file($_FILES[$field]['tmp_name'], $dest);
      chmod($dest, 0600);
      $cfg[$cfg_key] = $dest;
    }
  }
  save_cfg($cfg_file, $cfg);
  echo 'Certificates uploaded.';
  exit;
}

if ($action === 'save_yaml') {
  $yaml    = $_POST['yaml'] ?? '';
  $new_cfg = [];
  foreach (explode("\n", $yaml) as $line) {
    $line = trim($line);
    if ($line === '' || $line[0] === '#') continue;
    if (preg_match('/^([A-Z0-9_]+):\s*"?(.*?)"?\s*$/', $line, $m)) {
      $new_cfg[$m[1]] = $m[2];
    }
  }
  // Preserve cert file paths — not editable via YAML
  foreach (['MQTT_CA_CERT', 'MQTT_CLIENT_CERT', 'MQTT_CLIENT_KEY'] as $k) {
    if (isset($cfg[$k]) && $cfg[$k] !== '') $new_cfg[$k] = $cfg[$k];
  }
  save_cfg($cfg_file, $new_cfg);
  echo 'Settings saved.';
  exit;
}

if ($action === 'get_yaml') {
  $cfg = load_cfg($cfg_file);
  $skip = ['MQTT_CA_CERT', 'MQTT_CLIENT_CERT', 'MQTT_CLIENT_KEY'];
  $lines = ['# unraid-stats2mqtt config'];
  foreach ($cfg as $k => $v) {
    if (in_array($k, $skip)) continue;
    $lines[] = $k . ': "' . addslashes($v) . '"';
  }
  echo implode("\n", $lines);
  exit;
}

http_response_code(400);
echo 'Unknown action.';
