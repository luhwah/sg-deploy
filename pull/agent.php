<?php
/* sg-deploy/pull/agent.php — THE PULL AGENT: a site that updates itself.
 *
 * WHY (Willy 2026-11-02, lindston-workspace docs/self-updating-sites-plan-2026-11-02.md).
 * A deploy used to be a GitHub runner that opened two SSH connections to the
 * account: a billed Actions minute or more, two logins SiteGround counts, and a
 * runner address that is sometimes blocked. This file runs from the account's own
 * Site Tools cron instead. It reads the newest SIGNED release for each app it is
 * told about from Luhwah's R2 bucket (an outbound download, so the Anti-Bot never
 * sees it), checks it, and installs it with deploy.sh's OWN server script — the
 * same lint, spare copy, switch, engine checks, ping, leak checks and automatic
 * rollback a runner deploy runs, because it is the same bytes (deploy.sh --pack).
 *
 * THE SIGNATURE IS THE WHOLE SECURITY STORY (the webavie updater's model). It
 * installs nothing whose manifest was not signed by the Ed25519 key that lives only
 * in lindston-cloud's and the PC's .secrets (luhwah-pull-release.key); the public
 * half is PUBKEY below. The manifest names every file's sha256 and size, the
 * account and the site, and a sequence number that only goes up. So a bucket
 * credential that leaks (it sits in config.json on each account) can stop a
 * release or replay an old one — which is refused as not newer — but it cannot
 * hand out code of its own. The site an app installs into is pinned here, in
 * config.json, too: a signed release for one app cannot be aimed at another site.
 *
 * ONE ATTEMPT PER RELEASE. A release that rolled back, or failed before the
 * switch, is never tried again by itself (that would be a deploy every 15 minutes);
 * the next, newer release is. A download that fails is tried on the next two runs,
 * then given up. Every outcome goes to the result file in R2 that the releasing
 * tool (tools/pull-release.mjs) waits for, and to the account's status file the
 * cloud's watcher reads; the watcher alarms when that file gets old, which is how a
 * cron that stopped is noticed.
 *
 *   php ~/lws-pull/agent.php [--every=5] [--account=u…]   the cron line (--every is reported;
 *                                          --account must be the user it runs as)
 *   php ~/lws-pull/agent.php --status       print the state, change nothing, upload nothing
 * Files, all in ~/lws-pull/ (beside www/, never web-served):
 *   config.json  0600  {"source": {...}, "apps": {"<app>": "<site>"}}
 *   hold               while it exists nothing is installed (status says so)
 *   state.json         what each app last installed, and the outcome
 *   agent.log          one line per event, kept under 512 KB
 * Tests: node C:/luhwah/tools/pull-check.mjs (a fake bucket, a fake account, real php and bash)
 */

const LWS_PULL_VERSION = '1.0.0';
const LWS_PULL_PUBKEY = 'JZ+nr8H7PFAU24udybgGjBKJXYx4GOZOi372miGVh6c=';   // Ed25519, raw 32 bytes: the public half of .secrets/luhwah-pull-release.key
const LWS_PULL_CONTEXT = "luhwah-pull/1\n";
const LWS_PULL_MAX_DOWNLOAD_TRIES = 3;

/* The account's home: the folder above ~/lws-pull/, where this file lives. Not $HOME,
 * which a cron may not set. */
function lp_userhome(): string { return rtrim(dirname(__DIR__), '/'); }
function lp_home(): string { return lp_userhome() . '/lws-pull'; }
/* The account is the system user this runs as (u2262-…), never a path: on SiteGround
 * the home folder is /home/customer for every account (measured 2026-11-02). */
function lp_account(): string {
    if (function_exists('posix_geteuid') && function_exists('posix_getpwuid')) {
        $p = posix_getpwuid(posix_geteuid());
        if (!empty($p['name'])) return (string)$p['name'];
    }
    return (string)get_current_user();
}

function lp_log(string $line): void {
    $f = lp_home() . '/agent.log';
    if (is_file($f) && filesize($f) > 512 * 1024) { @rename($f, $f . '.1'); }
    @file_put_contents($f, gmdate('Y-m-d H:i:s') . 'Z ' . $line . "\n", FILE_APPEND);
    if (getenv('LWS_PULL_ECHO')) { fwrite(STDOUT, $line . "\n"); }
}

function lp_read_json(string $f, $default) {
    if (!is_file($f)) return $default;
    $d = json_decode((string)file_get_contents($f), true);
    return is_array($d) ? $d : $default;
}

function lp_write_json(string $f, array $d): void {
    $t = $f . '.tmp';
    file_put_contents($t, json_encode($d, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    @chmod($t, 0600);
    rename($t, $f);
}

// ── the bucket ──────────────────────────────────────────────────────────────
// Two kinds: "r2" (Cloudflare R2's S3 API, SigV4, region auto) and "dir" (a local
// folder with the same keys — the tests, and a dry rehearsal).

function lp_sigv4(array $src, string $method, string $key, string $body, array &$headers): string {
    $host = parse_url($src['endpoint'], PHP_URL_HOST);
    $path = '/' . $src['bucket'] . '/' . implode('/', array_map('rawurlencode', explode('/', $key)));
    $amz = gmdate('Ymd\THis\Z');
    $day = substr($amz, 0, 8);
    $region = $src['region'] ?? 'auto';
    $hash = hash('sha256', $body);
    $canon = "$method\n$path\n\nhost:$host\nx-amz-content-sha256:$hash\nx-amz-date:$amz\n\nhost;x-amz-content-sha256;x-amz-date\n$hash";
    $scope = "$day/$region/s3/aws4_request";
    $sts = "AWS4-HMAC-SHA256\n$amz\n$scope\n" . hash('sha256', $canon);
    $k = hash_hmac('sha256', $day, 'AWS4' . $src['secret_access_key'], true);
    $k = hash_hmac('sha256', $region, $k, true);
    $k = hash_hmac('sha256', 's3', $k, true);
    $k = hash_hmac('sha256', 'aws4_request', $k, true);
    $sig = hash_hmac('sha256', $sts, $k);
    $headers = [
        "x-amz-date: $amz",
        "x-amz-content-sha256: $hash",
        "Authorization: AWS4-HMAC-SHA256 Credential={$src['access_key_id']}/$scope, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=$sig",
    ];
    return 'https://' . $host . $path;
}

/* [status, body]. status 0 = could not connect. */
function lp_http(string $method, string $url, array $headers, string $body = ''): array {
    if (function_exists('curl_init')) {
        $c = curl_init($url);
        curl_setopt_array($c, [
            CURLOPT_CUSTOMREQUEST => $method, CURLOPT_RETURNTRANSFER => true, CURLOPT_HTTPHEADER => $headers,
            CURLOPT_CONNECTTIMEOUT => 20, CURLOPT_TIMEOUT => 300, CURLOPT_FOLLOWLOCATION => false,
        ]);
        if ($method === 'PUT') { curl_setopt($c, CURLOPT_POSTFIELDS, $body); }
        $out = curl_exec($c);
        $code = (int)curl_getinfo($c, CURLINFO_RESPONSE_CODE);
        return [$out === false ? 0 : $code, $out === false ? curl_error($c) : (string)$out];
    }
    $ctx = stream_context_create(['http' => ['method' => $method, 'header' => implode("\r\n", $headers), 'content' => $body, 'ignore_errors' => true, 'timeout' => 300]]);
    $out = @file_get_contents($url, false, $ctx);
    $code = 0;
    foreach ($http_response_header ?? [] as $h) { if (preg_match('#^HTTP/\S+ (\d+)#', $h, $m)) $code = (int)$m[1]; }
    return [$code, (string)$out];
}

/* The object's bytes, or null when it is not there. Throws on any other failure. */
function lp_get(array $src, string $key): ?string {
    if (($src['type'] ?? '') === 'dir') {
        $f = rtrim($src['path'], '/') . '/' . $key;
        return is_file($f) ? (string)file_get_contents($f) : null;
    }
    $h = [];
    $url = lp_sigv4($src, 'GET', $key, '', $h);
    [$code, $body] = lp_http('GET', $url, $h);
    if ($code === 200) return $body;
    if ($code === 404) return null;
    throw new RuntimeException("the bucket answered $code for $key");
}

function lp_put(array $src, string $key, string $body): void {
    if (($src['type'] ?? '') === 'dir') {
        $f = rtrim($src['path'], '/') . '/' . $key;
        @mkdir(dirname($f), 0700, true);
        file_put_contents($f, $body);
        return;
    }
    $h = [];
    $url = lp_sigv4($src, 'PUT', $key, $body, $h);
    $h[] = 'Content-Type: application/json';
    [$code, $out] = lp_http('PUT', $url, $h, $body);
    if ($code !== 200) throw new RuntimeException("the bucket answered $code to the upload of $key");
}

// ── the release ─────────────────────────────────────────────────────────────

/* The manifest if the envelope is genuine, else a string saying why not. */
function lp_verify(string $envelope, string $pubkey_b64) {
    $e = json_decode($envelope, true);
    if (!is_array($e) || !isset($e['m'], $e['s'])) return 'the release pointer is not a signed envelope';
    $m = base64_decode((string)$e['m'], true);
    $s = base64_decode((string)$e['s'], true);
    $pk = base64_decode($pubkey_b64, true);
    if ($m === false || $s === false || strlen($s) !== 64) return 'the signature is malformed';
    if ($pk === false || strlen($pk) !== 32) return 'this agent has no release key';
    if (!function_exists('sodium_crypto_sign_verify_detached')) return 'php has no sodium, so nothing can be verified';
    if (!sodium_crypto_sign_verify_detached($s, LWS_PULL_CONTEXT . $m, $pk)) return 'the SIGNATURE DOES NOT MATCH the release key';
    $man = json_decode($m, true);
    if (!is_array($man) || ($man['v'] ?? 0) !== 1) return 'the signed manifest is not version 1';
    return $man;
}

/* '' when the manifest may be installed here, else why not. */
function lp_check_manifest(array $man, string $app, string $site, string $account, int $have_seq): string {
    if (($man['app'] ?? '') !== $app) return "the release is for app '" . ($man['app'] ?? '') . "', not $app";
    if (($man['account'] ?? '') !== $account) return "the release is for account " . ($man['account'] ?? '') . ", not this one";
    if (($man['site'] ?? '') !== $site) return "the release is for " . ($man['site'] ?? '') . ", but $app installs into $site here";
    $seq = (int)($man['seq'] ?? 0);
    if ($seq <= 0) return 'the release has no sequence number';
    if ($seq <= $have_seq) return "not newer than what is here ($seq <= $have_seq)";
    if (!isset($man['files']['remote.sh']) || !is_array($man['files'])) return 'the release names no server script';
    foreach ($man['files'] as $name => $f) {
        if (!preg_match('/^(remote\.sh|deploy-[A-Za-z0-9._-]+\.tgz)$/', (string)$name)) return "the release names an unexpected file ($name)";
        if (!isset($f['sha256'], $f['size']) || !preg_match('/^[0-9a-f]{64}$/', (string)$f['sha256'])) return "the release's entry for $name is incomplete";
    }
    return '';
}

/* Downloads every file into $dir; '' or why it failed. */
function lp_download(array $src, string $prefix, array $man, string $dir): string {
    @mkdir($dir, 0700, true);
    foreach ($man['files'] as $name => $f) {
        try { $b = lp_get($src, $prefix . $man['seq'] . '/' . $name); }
        catch (Throwable $t) { return "download of $name failed: " . $t->getMessage(); }
        if ($b === null) return "$name is missing from the bucket";
        if (strlen($b) !== (int)$f['size'] || hash('sha256', $b) !== $f['sha256']) return "$name does not match its fingerprint (got " . strlen($b) . " bytes)";
        file_put_contents("$dir/$name", $b);
    }
    return '';
}

/* Runs deploy.sh's server script as its ssh would: archives beside the docroot,
 * `bash remote.sh` from $HOME. [outcome, exit, log]. */
function lp_install(array $man, string $dir): array {
    $home = lp_userhome();
    $base = "$home/www/{$man['site']}";
    if (!is_dir($base) || is_link($base)) return ['failed', -1, "www/{$man['site']} is not a real directory on this account"];
    foreach (array_keys($man['files']) as $name) {
        if ($name === 'remote.sh') continue;
        if (!copy("$dir/$name", "$base/$name")) return ['failed', -1, "could not place $name in www/{$man['site']}"];
    }
    // The inherited PATH first (what an ssh login would have), then the php running
    // this one's folder and the usual places, because a cron's PATH can be bare.
    $path = trim((getenv('PATH') ?: '') . ':' . dirname(PHP_BINARY) . ':/usr/local/bin:/usr/bin:/bin', ':');
    $env = ['HOME' => $home, 'PATH' => $path, 'LANG' => 'C.UTF-8'];
    $p = proc_open(['bash', "$dir/remote.sh"], [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['redirect', 1]], $pipes, $home, $env);
    if (!is_resource($p)) return ['failed', -1, 'could not start bash'];
    $log = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    $rc = proc_close($p);
    return [lp_outcome($rc, (string)$log), $rc, (string)$log];
}

function lp_outcome(int $rc, string $log): string {
    if ($rc === 0) return 'ok';
    if (strpos($log, 'ROLLED BACK:') !== false) return 'rolled_back';
    if (strpos($log, 'NOTHING was switched') !== false) return 'refused_before_switch';
    return 'failed';
}

function lp_tail(string $log, int $lines = 150): string {
    $a = preg_split('/\r?\n/', rtrim($log));
    return implode("\n", array_slice($a, -$lines));
}

function lp_rmrf(string $d): void {
    if (!is_dir($d)) return;
    foreach (scandir($d) as $n) {
        if ($n === '.' || $n === '..') continue;
        $p = "$d/$n";
        is_dir($p) && !is_link($p) ? lp_rmrf($p) : @unlink($p);
    }
    @rmdir($d);
}

// ── one run ─────────────────────────────────────────────────────────────────

function lp_run(array $argv): int {
    $home = lp_home();
    @mkdir($home, 0700, true);
    $every = 0;
    foreach ($argv as $a) {
        if (preg_match('/^--every=(\d+)$/', $a, $m)) $every = (int)$m[1];
        // The cron line names the account it was written for (servercron), so a line
        // copied to the wrong account says so instead of quietly doing nothing.
        if (preg_match('/^--account=(.+)$/', $a, $m) && $m[1] !== lp_account()) { lp_log("this cron line is for {$m[1]}, but runs as " . lp_account() . '; nothing done'); return 1; }
    }
    $cfg = lp_read_json("$home/config.json", []);
    $state = lp_read_json("$home/state.json", ['apps' => []]);
    if (in_array('--status', $argv, true)) { echo json_encode($state, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), "\n"; return 0; }
    if (!isset($cfg['source']['type'], $cfg['apps']) || !is_array($cfg['apps'])) { lp_log('no usable config.json; nothing to do'); return 1; }

    $lock = fopen("$home/agent.lock", 'c');
    if (!$lock || !flock($lock, LOCK_EX | LOCK_NB)) { lp_log('another run is still going; this one stops'); return 0; }

    $src = $cfg['source'];
    $account = lp_account();
    $held = is_file("$home/hold");
    $pub = LWS_PULL_PUBKEY;   // never from the environment or config: the key IS the security
    $errors = [];

    foreach ($cfg['apps'] as $app => $site) {
        $app = (string)$app; $site = (string)$site;
        $st = $state['apps'][$app] ?? ['seq' => 0];
        $prefix = "rel/$account/$app/";
        try { $env = lp_get($src, $prefix . 'latest.json'); }
        catch (Throwable $t) { $errors[] = "$app: " . $t->getMessage(); lp_log("$app: could not read the release pointer: " . $t->getMessage()); continue; }
        if ($env === null) continue;
        $envHash = hash('sha256', $env);
        if (($st['refused'] ?? '') === $envHash) continue;          // already said no to exactly this pointer
        $man = lp_verify($env, $pub);
        if (!is_array($man)) {
            $st['refused'] = $envHash; $st['refused_why'] = $man; $st['refused_at'] = time();
            $st['refused_note'] = (string)(json_decode((string)base64_decode((string)(json_decode($env, true)['m'] ?? ''), true), true)['note'] ?? '');
            $state['apps'][$app] = $st;
            lp_log("$app: REFUSED a release: $man");
            continue;
        }
        $why = lp_check_manifest($man, $app, $site, $account, (int)($st['seq'] ?? 0));
        if ($why !== '') {
            if ((int)($man['seq'] ?? 0) > (int)($st['seq'] ?? 0)) {     // a newer one that is wrong: say it once
                $st['refused'] = $envHash; $st['refused_why'] = $why; $st['refused_at'] = time(); $st['refused_note'] = (string)($man['note'] ?? '');
                $state['apps'][$app] = $st;
                lp_log("$app: REFUSED release {$man['seq']}: $why");
            }
            continue;
        }
        $seq = (int)$man['seq'];
        if ($held) { $st['waiting'] = $seq; $state['apps'][$app] = $st; continue; }

        $work = "$home/work/$app-$seq";
        lp_rmrf($work);
        $dl = lp_download($src, $prefix, $man, $work);
        if ($dl !== '') {
            lp_rmrf($work);
            $tries = (($st['dl_seq'] ?? 0) === $seq ? (int)($st['dl_tries'] ?? 0) : 0) + 1;
            $st['dl_seq'] = $seq; $st['dl_tries'] = $tries; $st['dl_error'] = $dl;
            lp_log("$app: release $seq download failed (try $tries of " . LWS_PULL_MAX_DOWNLOAD_TRIES . "): $dl");
            if ($tries >= LWS_PULL_MAX_DOWNLOAD_TRIES) {
                $res = ['app' => $app, 'seq' => $seq, 'tag' => $man['tag'] ?? '', 'outcome' => 'download_failed', 'exit' => -1,
                        'at' => time(), 'agent' => LWS_PULL_VERSION, 'log' => $dl];
                $st = array_merge($st, ['seq' => $seq, 'result' => 'download_failed', 'at' => time(), 'tag' => $man['tag'] ?? '', 'note' => (string)($man['note'] ?? '')]);
                try { lp_put($src, "res/$account/$app/$seq.json", json_encode($res, JSON_UNESCAPED_SLASHES)); } catch (Throwable $t) { $errors[] = "$app: result upload: " . $t->getMessage(); }
            }
            $state['apps'][$app] = $st;
            continue;
        }

        lp_log("$app: installing release $seq (" . ($man['tag'] ?? 'untagged') . ")");
        $t0 = microtime(true);
        [$outcome, $rc, $log] = lp_install($man, $work);
        lp_rmrf($work);
        $secs = round(microtime(true) - $t0, 1);
        lp_log("$app: release $seq $outcome (exit $rc, {$secs}s)");
        $res = ['app' => $app, 'seq' => $seq, 'tag' => $man['tag'] ?? '', 'outcome' => $outcome, 'exit' => $rc,
                'seconds' => $secs, 'at' => time(), 'agent' => LWS_PULL_VERSION, 'note' => (string)($man['note'] ?? ''), 'log' => lp_tail($log)];
        $prev = ['seq' => $st['seq'] ?? 0, 'tag' => $st['tag'] ?? ''];
        $st = ['seq' => $seq, 'tag' => $man['tag'] ?? '', 'result' => $outcome, 'at' => time(), 'note' => (string)($man['note'] ?? ''), 'previous' => $prev];
        if ($outcome === 'ok') { $st['live_seq'] = $seq; $st['live_tag'] = $man['tag'] ?? ''; }
        else { $st['live_seq'] = $state['apps'][$app]['live_seq'] ?? 0; $st['live_tag'] = $state['apps'][$app]['live_tag'] ?? ''; }
        $state['apps'][$app] = $st;
        lp_write_json("$home/state.json", $state);    // before the upload: the install happened either way
        try { lp_put($src, "res/$account/$app/$seq.json", json_encode($res, JSON_UNESCAPED_SLASHES)); }
        catch (Throwable $t) { $errors[] = "$app: result upload: " . $t->getMessage(); lp_log("$app: could not upload the result: " . $t->getMessage()); }
    }

    $state['last_run'] = time();
    lp_write_json("$home/state.json", $state);
    $status = [
        'account' => $account, 'at' => time(), 'every' => $every, 'agent' => LWS_PULL_VERSION,
        'held' => $held, 'php' => PHP_VERSION, 'disk_free_mb' => (int)(@disk_free_space($home) / 1048576),
        'apps' => $state['apps'], 'errors' => $errors,
    ];
    try { lp_put($src, "status/$account.json", json_encode($status, JSON_UNESCAPED_SLASHES)); }
    catch (Throwable $t) { lp_log('could not upload the status file: ' . $t->getMessage()); return 1; }
    flock($lock, LOCK_UN);
    return $errors ? 1 : 0;
}

if (PHP_SAPI === 'cli' && realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__ && !getenv('LWS_PULL_NO_MAIN')) {
    exit(lp_run(array_slice($argv, 1)));
}
