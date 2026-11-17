'use strict';
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const { spawn } = require('child_process');

const RES = GetCurrentResourceName();
const ROOT = GetResourcePath(RES);
const CACHE = path.join(ROOT, 'cache');
const BINDIR = path.join(ROOT, 'bin');

const DEFAULTS = {
    ytdlpPath: '', autoDownloadYtdlp: true,
    format: 'bestaudio[ext=webm][abr<=?100]/bestaudio[ext=m4a][abr<=?100]/bestaudio',
    maxDurationSec: 900, searchResults: 8, concurrentDownloads: 2,
    cacheHours: 72, maxCacheMB: 1500, cookiesFile: '', extraArgs: [], standalonePort: 0, verbose: false,
    mode: 'auto',
    searchConcurrency: 2,
    searchCacheMinutes: 10,
    verifyChecksum: true, autoUpdateYtdlp: true, updateHours: 24,
};
let CFG = { ...DEFAULTS };
try {
    CFG = { ...DEFAULTS, ...JSON.parse(LoadResourceFile(RES, 'backend.json') || '{}') };
} catch (e) {
    console.log(`^1[${RES}] backend.json is not valid JSON: ${e.message}^7`);
}
fs.mkdirSync(CACHE, { recursive: true });
fs.mkdirSync(BINDIR, { recursive: true });
const TMP = path.join(CACHE, '.tmp');
fs.mkdirSync(TMP, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function wipeTmp(olderThanMs = 0) {
    try {
        for (const f of fs.readdirSync(TMP)) {
            const full = path.join(TMP, f);
            try {
                if (olderThanMs && Date.now() - fs.statSync(full).mtimeMs < olderThanMs) continue;
                fs.rmSync(full, { recursive: true, force: true });
            } catch (e) {}
        }
    } catch (e) {}
}

class Sem {
    constructor(n) { this.n = Math.max(1, n | 0); this.active = 0; this.q = []; }
    async acquire() { if (this.active < this.n) { this.active++; return; } await new Promise((r) => this.q.push(r)); }
    release() { const w = this.q.shift(); if (w) w(); else this.active--; }
}

const log = (color, msg) => { if (color === 1 || CFG.verbose) console.log(`^${color}[${RES}]^7 ${msg}`); };

let BIN = null;
let binPromise = null;

function remoteName() {
    if (process.platform === 'win32') return 'yt-dlp.exe';
    if (process.platform === 'darwin') return 'yt-dlp_macos';
    return process.arch === 'arm64' ? 'yt-dlp_linux_aarch64' : 'yt-dlp_linux';
}

function run(bin, args, opts = {}) {
    return new Promise((resolve) => {
        let out = '', err = '', done = false;
        let p;
        const env = { ...process.env, TMPDIR: TMP, TEMP: TMP, TMP: TMP };
        try { p = spawn(bin, args, { windowsHide: true, env }); }
        catch (e) { return resolve({ code: -1, out, err: String(e.message) }); }
        const timer = setTimeout(() => { try { p.kill('SIGKILL'); } catch (e) {} }, opts.timeout || 120000);
        const finish = (code) => { if (done) return; done = true; clearTimeout(timer); resolve({ code, out, err }); };
        p.stdout.on('data', (d) => { out += d; });
        p.stderr.on('data', (d) => { err += d; });
        p.on('error', (e) => { err += String(e.message); finish(-1); });
        p.on('close', (code) => finish(code));
    });
}

const GH = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/';
const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

async function fetchSums() {
    const r = await fetch(GH + 'SHA2-256SUMS', { redirect: 'follow' });
    if (!r.ok) throw new Error('could not get the yt-dlp checksum list (HTTP ' + r.status + ')');
    const map = {};
    for (const line of (await r.text()).split('\n')) {
        const m = /^([a-f0-9]{64})\s+\*?(\S+)\s*$/i.exec(line.trim());
        if (m) map[m[2]] = m[1].toLowerCase();
    }
    return map;
}

async function fetchFile(asset, target) {
    const want = CFG.verifyChecksum === false ? null : (await fetchSums())[asset];
    if (CFG.verifyChecksum !== false && !want) throw new Error('no checksum is published for ' + asset);
    const r = await fetch(GH + asset, { redirect: 'follow' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const buf = Buffer.from(await r.arrayBuffer());
    const size = Number(r.headers.get('content-length') || 0);
    if (size && !r.headers.get('content-encoding') && buf.length !== size) throw new Error(`incomplete download (${buf.length}/${size} bytes)`);
    if (buf.length < 1024 * 1024) throw new Error('downloaded file is too small (' + buf.length + ' bytes)');
    if (want && sha256(buf) !== want) throw new Error('checksum mismatch for ' + asset + ', the file was rejected');
    const part = target + '.part';
    fs.writeFileSync(part, buf);
    fs.renameSync(part, target);
}

async function findPython() {
    for (const cmd of ['python3', 'python']) {
        const v = await run(cmd, ['--version'], { timeout: 8000 });
        const m = /Python (\d+)\.(\d+)/.exec(v.out + v.err);
        if (v.code === 0 && m && (Number(m[1]) > 3 || (Number(m[1]) === 3 && Number(m[2]) >= 9))) return cmd;
    }
    return null;
}

async function prepareBinary() {
    if (CFG.ytdlpPath) {
        const target = path.isAbsolute(CFG.ytdlpPath) ? CFG.ytdlpPath : path.join(ROOT, CFG.ytdlpPath);
        if (!fs.existsSync(target)) { log(1, 'yt-dlp not found at ' + target); return false; }
        try { fs.chmodSync(target, 0o755); } catch (e) {}
        const v = await run(target, ['--version'], { timeout: 30000 });
        if (v.code !== 0) { log(1, 'yt-dlp cannot run here: ' + (v.err || v.out).trim().slice(0, 300)); return false; }
        BIN = { cmd: target, pre: [], file: target, auto: false };
        log(2, 'yt-dlp ready (' + v.out.trim() + ')');
        return true;
    }

    if (CFG.mode !== 'binary' && process.platform !== 'win32') {
        const py = await findPython();
        if (py) {
            const script = path.join(BINDIR, 'yt-dlp-py');
            try {
                if (!fs.existsSync(script)) { log(3, 'Downloading yt-dlp (python version)'); await fetchFile('yt-dlp', script); }
                const v = await run(py, [script, '--version'], { timeout: 30000 });
                if (v.code === 0) {
                    BIN = { cmd: py, pre: [script], file: script, auto: true, asset: 'yt-dlp' };
                    log(2, `yt-dlp ready via ${py} (${v.out.trim()})`);
                    return true;
                }
                log(3, 'yt-dlp python mode did not start (' + (v.err || v.out).trim().slice(0, 160) + '), using the standalone binary');
                try { fs.unlinkSync(script); } catch (e) {}
            } catch (e) { log(3, 'yt-dlp python mode failed (' + e.message + '), using the standalone binary'); }
        } else if (CFG.mode === 'python') { log(1, 'mode is "python" but python 3.9+ was not found on this machine.'); return false; }
    }

    const target = path.join(BINDIR, process.platform === 'win32' ? 'yt-dlp.exe' : 'yt-dlp');
    if (!fs.existsSync(target)) {
        if (!CFG.autoDownloadYtdlp) { log(1, 'yt-dlp not found at ' + target); return false; }
        log(3, 'Downloading yt-dlp from ' + GH + remoteName());
        try { await fetchFile(remoteName(), target); }
        catch (e) { log(1, 'Could not download yt-dlp: ' + e.message + '. Put the binary in ' + target + ' manually.'); return false; }
    }
    try { fs.chmodSync(target, 0o755); } catch (e) {}
    wipeTmp();
    let v = await run(target, ['--version'], { timeout: 60000 });
    if (v.code !== 0 && /PYI-\d+/.test(v.err)) {
        log(1, 'yt-dlp binary is damaged (' + v.err.trim().slice(-120) + '). Downloading a fresh copy...');
        try { fs.unlinkSync(target); await fetchFile(remoteName(), target); fs.chmodSync(target, 0o755); wipeTmp(); }
        catch (e) { log(1, 'Could not download yt-dlp: ' + e.message); return false; }
        v = await run(target, ['--version'], { timeout: 60000 });
    }
    if (v.code !== 0) {
        log(1, 'yt-dlp cannot run here: ' + (v.err || v.out).trim().slice(0, 300)
            + ' | Free disk space / RAM on the host and check the "cache" folder is writable. If python3 is installed, restart: python mode is used automatically.');
        return false;
    }
    BIN = { cmd: target, pre: [], file: target, auto: true, asset: remoteName() };
    log(2, 'yt-dlp ready (' + v.out.trim() + ')');
    return true;
}

function ensureBinary() {
    if (BIN) return Promise.resolve(true);
    if (!binPromise) binPromise = prepareBinary().finally(() => { binPromise = null; });
    return binPromise;
}

let updating = false;
async function updateYtdlp() {
    if (updating || !BIN || !BIN.auto || !BIN.asset || CFG.autoUpdateYtdlp === false) return;
    if (inflight.size || searchInflight.size) return;
    updating = true;
    try {
        const want = (await fetchSums())[BIN.asset];
        if (!want) return;
        if (sha256(fs.readFileSync(BIN.file)) === want) return;
        log(3, 'A newer yt-dlp is available, updating...');
        await fetchFile(BIN.asset, BIN.file);
        try { fs.chmodSync(BIN.file, 0o755); } catch (e) {}
        const v = await run(BIN.cmd, [...BIN.pre, '--version'], { timeout: 60000 });
        if (v.code === 0) log(2, 'yt-dlp updated (' + v.out.trim() + ')');
        else log(1, 'yt-dlp was updated but does not start: ' + (v.err || v.out).trim().slice(0, 200));
    } catch (e) {
        log(1, 'yt-dlp update failed: ' + e.message);
    } finally {
        updating = false;
    }
}

let healed = false;
async function yt(args, opts = {}) {
    if (!(await ensureBinary())) return { code: -1, out: '', err: 'backend not ready' };
    let r = await run(BIN.cmd, [...BIN.pre, ...args], opts);
    if (r.code !== 0 && /PYI-\d+/.test(r.err)) {
        log(1, 'yt-dlp could not unpack itself (' + r.err.trim().slice(-160) + '). Clearing temp files and retrying...');
        wipeTmp();
        await sleep(400);
        r = await run(BIN.cmd, [...BIN.pre, ...args], opts);
        if (r.code !== 0 && /PYI-\d+/.test(r.err) && BIN.auto && !healed) {
            healed = true;
            log(1, 'Still failing, downloading a fresh yt-dlp binary...');
            try { fs.unlinkSync(BIN.file); } catch (e) {}
            BIN = null;
            if (await ensureBinary()) r = await run(BIN.cmd, [...BIN.pre, ...args], opts);
        }
    }
    return r;
}

function baseArgs() {
    const a = ['--ignore-config', '--no-warnings', '--no-colors', '--cache-dir', path.join(CACHE, '.ytdlp')];
    if (CFG.cookiesFile) {
        const p = path.isAbsolute(CFG.cookiesFile) ? CFG.cookiesFile : path.join(ROOT, CFG.cookiesFile);
        if (fs.existsSync(p)) a.push('--cookies', p);
    }
    return a.concat(CFG.extraArgs || []);
}

const ERR_GENERIC = 'song.notFound';
function friendlyError(text) {
    text = String(text || '');
    if (/unavailable|private video|removed/i.test(text)) return 'dl.unavailable';
    if (/does not pass filter/i.test(text)) return 'dl.tooLong';
    if (/HTTP Error 429|Too Many Requests/i.test(text)) return 'dl.rateLimit';
    return ERR_GENERIC;
}

const searchSem = new Sem(CFG.searchConcurrency);
const searchCache = new Map();
const searchInflight = new Map();

async function searchUncached(q, n) {
    await searchSem.acquire();
    let r;
    try { r = await yt([...baseArgs(), '--flat-playlist', '--dump-json', '--skip-download', `ytsearch${n}:${q}`], { timeout: 45000 }); }
    finally { searchSem.release(); }
    const results = [];
    for (const line of r.out.split('\n')) {
        if (!line.startsWith('{')) continue;
        try {
            const j = JSON.parse(line);
            if (!j.id || !/^[\w-]{11}$/.test(j.id)) continue;
            if (j.live_status === 'is_live' || j.live_status === 'is_upcoming') continue;
            if (j.duration && j.duration > CFG.maxDurationSec) continue;
            results.push({
                id: j.id, title: j.title || '', channel: j.channel || j.uploader || '',
                duration: j.duration || 0, thumb: `https://i.ytimg.com/vi/${j.id}/mqdefault.jpg`,
            });
        } catch (e) {}
    }
    if (!results.length) {
        if (r.code !== 0) log(1, 'search failed: ' + r.err.trim().slice(-300));
        if (r.code !== 0) {
            const key = friendlyError(r.err);
            return { ok: false, error: key === ERR_GENERIC ? 'search.retry' : key };
        }
        return { ok: false, error: 'search.none' };
    }
    return { ok: true, results };
}

async function searchRaw(q, n) {
    if (!(await ensureBinary())) return { ok: false, error: 'backend.notReady' };
    const key = n + ':' + q.toLowerCase();
    const hit = searchCache.get(key);
    if (hit && Date.now() - hit.t < CFG.searchCacheMinutes * 60000) return { ok: true, results: hit.results };
    if (searchInflight.has(key)) return searchInflight.get(key);
    const p = searchUncached(q, n).then((r) => {
        if (r.ok) {
            searchCache.set(key, { t: Date.now(), results: r.results });
            if (searchCache.size > 200) searchCache.delete(searchCache.keys().next().value);
        }
        return r;
    }).finally(() => searchInflight.delete(key));
    searchInflight.set(key, p);
    return p;
}

function search(q) {
    q = String(q || '').trim().slice(0, 100);
    if (q.length < 2) return { ok: false, error: 'search.short' };
    return searchRaw(q, CFG.searchResults);
}

function parseRef(ref) {
    ref = String(ref || '').trim().slice(0, 300);
    if (/^[A-Za-z0-9_-]{11}$/.test(ref)) return { type: 'yt', id: ref };
    let u;
    try { u = new URL(ref); } catch (e) { return ref.length >= 2 ? { type: 'query', q: ref } : { type: 'bad' }; }
    const host = u.hostname.replace(/^(www|m|music)\./, '');
    let id = null;
    if (host === 'youtu.be') id = u.pathname.slice(1, 12);
    else if (host === 'youtube.com') {
        if (u.pathname === '/watch') id = u.searchParams.get('v');
        else { const m = u.pathname.match(/^\/(shorts|embed|live)\/([\w-]{11})/); if (m) id = m[2]; }
    }
    if (id && /^[\w-]{11}$/.test(id)) return { type: 'yt', id };
    if (host === 'open.spotify.com') {
        if (/\/track\/\w+/.test(u.pathname)) return { type: 'spotify', url: u.origin + u.pathname.replace(/^\/intl-[a-z-]+/, '') };
        return { type: 'unsupported', error: 'ref.spotifyTrackOnly' };
    }
    return { type: 'unsupported', error: 'ref.unsupported' };
}

const decodeHtml = (s) => String(s || '')
    .replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#x27;|&#39;/g, "'")
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>');

async function spotifyQuery(url) {
    const r = await fetch(url, { headers: { 'User-Agent': 'Mozilla/5.0', 'Accept-Language': 'en' } });
    if (!r.ok) throw new Error('Spotify page HTTP ' + r.status);
    const html = await r.text();
    const t = html.match(/<title>([^<]*)<\/title>/);
    if (t) {
        const m = decodeHtml(t[1]).match(/^(.*) - song(?: and lyrics)? by (.*?) \| Spotify$/);
        if (m) return `${m[2]} ${m[1]}`;
    }
    const og = html.match(/<meta property="og:title" content="([^"]*)"/);
    const desc = html.match(/<meta property="og:description" content="([^"]*)"/);
    if (og) return decodeHtml(og[1]) + ' ' + decodeHtml((desc ? desc[1] : '').split('·')[0]);
    throw new Error('could not read the Spotify track');
}

const dlSem = new Sem(CFG.concurrentDownloads);

const metaPath = (id) => path.join(CACHE, id + '.json');

function findAudio(id) {
    try {
        for (const f of fs.readdirSync(CACHE)) {
            if (f.startsWith(id + '.') && !/\.(json|part|ytdl|temp)$/.test(f) && !f.includes('.part')) return f;
        }
    } catch (e) {}
    return null;
}

function readCached(id) {
    const f = findAudio(id);
    if (!f) return null;
    try {
        const meta = JSON.parse(fs.readFileSync(metaPath(id), 'utf8'));
        const now = new Date();
        fs.utimesSync(path.join(CACHE, f), now, now);
        fs.utimesSync(metaPath(id), now, now);
        return meta;
    } catch (e) { return null; }
}

const RETRY_ARGS = [
    [],
    [],
    ['--extractor-args', 'youtube:player_client=ios,web_safari'],
    ['--extractor-args', 'youtube:player_client=tv,android_vr'],
];
const isRetryable = (t) => /HTTP Error 403|Forbidden|HTTP Error 5\d\d|unable to download|timed out|Connection (reset|aborted)|Unable to connect|no audio|Got error|fragment/i.test(String(t || ''));

function cleanPartial(id) {
    try {
        for (const f of fs.readdirSync(CACHE)) {
            if (!f.startsWith(id + '.') || f.endsWith('.json')) continue;
            const full = path.join(CACHE, f);
            let small = false;
            try { small = fs.statSync(full).size < 1024; } catch (e) {}
            if (/\.(part|ytdl|temp)/.test(f) || small) { try { fs.unlinkSync(full); } catch (e) {} }
        }
    } catch (e) {}
}

async function downloadOnce(id, extra, fmt) {
    const args = [
        ...baseArgs(), ...extra, '-f', fmt || CFG.format, '--no-playlist', '--no-progress',
        '--retries', '3', '--fragment-retries', '3',
        '--match-filter', `!is_live & duration<=${CFG.maxDurationSec}`,
        '-o', path.join(CACHE, '%(id)s.%(ext)s'),
        '--dump-json', '--no-simulate',
        'https://www.youtube.com/watch?v=' + id,
    ];
    const r = await yt(args, { timeout: 180000 });
    let info = null;
    for (const line of r.out.split('\n')) {
        if (line.startsWith('{')) { try { info = JSON.parse(line); } catch (e) {} }
    }
    const text = (r.err + ' ' + (info ? '' : r.out)).trim();
    if (!info) return { ok: false, text, retry: isRetryable(text) };
    const file = findAudio(id);
    let size = 0;
    try { if (file) size = fs.statSync(path.join(CACHE, file)).size; } catch (e) {}
    if (!file || size < 1024) {
        cleanPartial(id);
        return { ok: false, text: r.err.trim() || '(nothing)', code: r.code, noFile: true, retry: true };
    }
    return {
        ok: true,
        track: {
            id, title: info.title || '', channel: info.channel || info.uploader || '',
            duration: Math.floor(info.duration || 0), thumb: `https://i.ytimg.com/vi/${id}/mqdefault.jpg`,
        },
    };
}

async function download(id) {
    let last = null, fmt = CFG.format;
    for (let i = 0; i < RETRY_ARGS.length; i++) {
        if (i > 0) await sleep(700 * i);
        last = await downloadOnce(id, RETRY_ARGS[i], fmt);
        if (!last.ok && /Invalid filter specification|Requested format is not available|format.*not available/i.test(last.text)) {
            fmt = 'bestaudio/best';
            last.retry = true;
        }
        if (last.ok) {
            fs.writeFileSync(metaPath(id), JSON.stringify(last.track));
            log(2, `cached ${id} - ${last.track.title}` + (i ? ` (attempt ${i + 1})` : ''));
            return { ok: true, track: last.track };
        }
        if (!last.retry || /unavailable|private video|removed|does not pass filter|Sign in to confirm/i.test(last.text)) break;
        if (i < RETRY_ARGS.length - 1) log(3, `download ${id} attempt ${i + 1} failed, retrying: ` + last.text.slice(-160).replace(/\s+/g, ' '));
    }
    log(1, `download ${id} failed after retries${last.noFile ? ' (no audio file)' : ''}. yt-dlp said: ` + String(last.text).slice(-700));
    cleanPartial(id);
    return { ok: false, error: friendlyError(last.text) };
}

const inflight = new Map();
function ensureId(id) {
    if (inflight.has(id)) return inflight.get(id);
    const p = (async () => {
        const cached = readCached(id);
        if (cached) return { ok: true, track: cached };
        if (!(await ensureBinary())) return { ok: false, error: 'backend.notReady' };
        await dlSem.acquire();
        try { return await download(id); } finally { dlSem.release(); }
    })().finally(() => inflight.delete(id));
    inflight.set(id, p);
    return p;
}

async function ensure(ref) {
    const p = parseRef(ref);
    if (p.type === 'bad') return { ok: false, error: 'play.nothing' };
    if (p.type === 'unsupported') return { ok: false, error: p.error };
    let id = p.id;
    if (p.type === 'spotify') {
        let q;
        try { q = await spotifyQuery(p.url); }
        catch (e) { log(1, 'spotify: ' + e.message); return { ok: false, error: 'ref.spotifyRead' }; }
        const s = await searchRaw(q, 1);
        if (!s.ok) return s;
        id = s.results[0].id;
    } else if (p.type === 'query') {
        const s = await searchRaw(p.q, 1);
        if (!s.ok) return s;
        id = s.results[0].id;
    }
    return ensureId(id);
}

function cleanup() {
    try {
        const groups = new Map();
        for (const f of fs.readdirSync(CACHE)) {
            const full = path.join(CACHE, f);
            const st = fs.statSync(full);
            if (!st.isFile() || f.startsWith('.')) continue;
            const id = f.split('.')[0];
            const g = groups.get(id) || { id, size: 0, mtime: 0, files: [] };
            g.size += st.size; g.mtime = Math.max(g.mtime, st.mtimeMs); g.files.push(full);
            groups.set(id, g);
        }
        const list = [...groups.values()].sort((a, b) => a.mtime - b.mtime);
        const maxAge = CFG.cacheHours * 3600 * 1000;
        let total = list.reduce((n, g) => n + g.size, 0);
        let removed = 0;
        for (const g of list) {
            const old = Date.now() - g.mtime > maxAge;
            const over = total > CFG.maxCacheMB * 1024 * 1024;
            if (!old && !over) continue;
            if (inflight.has(g.id)) continue;
            for (const f of g.files) { try { fs.unlinkSync(f); } catch (e) {} }
            total -= g.size; removed++;
        }
        if (removed) log(3, `cache cleanup removed ${removed} track(s)`);
    } catch (e) { log(1, 'cleanup: ' + e.message); }
}

const CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Range',
    'Access-Control-Expose-Headers': 'Content-Range, Accept-Ranges, Content-Length',
};
const MIME = { '.webm': 'audio/webm', '.m4a': 'audio/mp4', '.opus': 'audio/ogg', '.ogg': 'audio/ogg', '.mp3': 'audio/mpeg' };
const CHUNK = 2 * 1024 * 1024;

function serveRange(req, res) {
    const finish = (code, headers, body) => {
        res.writeHead(code, headers);
        res.end(body);
    };
    try {
        const urlPath = String(req.url || '').split('?')[0];
        if (req.method === 'OPTIONS') return finish(204, CORS, '');
        const m = urlPath.match(/\/audio\/([A-Za-z0-9_-]{11})$/);
        if (!m) return finish(404, CORS, 'not found');
        const file = findAudio(m[1]);
        if (!file) return finish(404, CORS, 'not cached');

        const full = path.join(CACHE, file);
        const total = fs.statSync(full).size;
        const rh = (req.headers && (req.headers.range || req.headers.Range)) || '';
        let start = 0, end = total - 1, status = 200;
        const rm = /bytes=(\d*)-(\d*)/.exec(rh);
        if (rm) {
            status = 206;
            if (rm[1] === '' && rm[2] !== '') start = Math.max(0, total - parseInt(rm[2], 10));
            else {
                start = parseInt(rm[1] || '0', 10);
                if (rm[2] !== '') end = Math.min(parseInt(rm[2], 10), total - 1);
            }
            if (start >= total || start > end) return finish(416, { ...CORS, 'Content-Range': `bytes */${total}` }, '');
            end = Math.min(end, start + CHUNK - 1);
        }
        const len = end - start + 1;
        const buf = Buffer.alloc(len);
        const fd = fs.openSync(full, 'r');
        try { fs.readSync(fd, buf, 0, len, start); } finally { fs.closeSync(fd); }

        const headers = {
            ...CORS, 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream',
            'Accept-Ranges': 'bytes', 'Content-Length': String(len),
        };
        if (status === 206) headers['Content-Range'] = `bytes ${start}-${end}/${total}`;
        finish(status, headers, buf);
    } catch (e) {
        log(1, 'http: ' + (e.stack || e));
        try { finish(500, CORS, 'error'); } catch (e2) {}
    }
}

const CHUNK_BIN = 98304;

const chunkCache = new Map();
const CHUNK_CACHE_MAX = 240;
const CHUNK_CACHE_TTL = 5 * 60 * 1000;

function readChunk(arg) {
    const id = String((arg && arg.id) || '');
    const n = Number(arg && arg.n);
    if (!/^[A-Za-z0-9_-]{11}$/.test(id) || !Number.isInteger(n) || n < 0 || n > 9999) return { ok: false, error: 'bad request' };
    const file = findAudio(id);
    if (!file) return { ok: false, error: 'not cached' };
    const full = path.join(CACHE, file);
    const stt = fs.statSync(full);
    const total = stt.size;
    const start = n * CHUNK_BIN;
    if (start >= total) return { ok: false, error: 'out of range' };
    const key = id + ':' + stt.mtimeMs + ':' + n;
    const hit = chunkCache.get(key);
    if (hit && Date.now() - hit.t < CHUNK_CACHE_TTL) {
        chunkCache.delete(key); hit.t = Date.now(); chunkCache.set(key, hit);
        return hit.res;
    }
    const len = Math.min(CHUNK_BIN, total - start);
    const buf = Buffer.alloc(len);
    const fd = fs.openSync(full, 'r');
    try { fs.readSync(fd, buf, 0, len, start); } finally { fs.closeSync(fd); }
    const res = {
        ok: true, data: buf.toString('base64'), n,
        chunks: Math.ceil(total / CHUNK_BIN), size: total,
        mime: MIME[path.extname(file)] || 'audio/webm',
    };
    chunkCache.set(key, { t: Date.now(), res });
    while (chunkCache.size > CHUNK_CACHE_MAX) chunkCache.delete(chunkCache.keys().next().value);
    return res;
}

if (CFG.standalonePort > 0) {
    require('http').createServer((req, res) => serveRange(req, res))
        .listen(CFG.standalonePort, '0.0.0.0', () => log(2, 'standalone audio server on port ' + CFG.standalonePort));
}

const wrap = (fn) => (arg, cb) => {
    Promise.resolve().then(() => fn(arg)).then((r) => cb(r)).catch((e) => {
        log(1, String(e && e.stack || e));
        cb({ ok: false, error: 'err.generic' });
    });
};
const fxExport = typeof globalThis.exports === 'function' ? globalThis.exports : exports;
fxExport('search', wrap(search));
fxExport('ensure', wrap(ensure));
fxExport('chunk', wrap(readChunk));

on('onResourceStart', (name) => {
    if (name !== RES) return;
    wipeTmp(10 * 60 * 1000);
    ensureBinary().then(() => updateYtdlp());
    cleanup();
});
setInterval(cleanup, 30 * 60 * 1000);
setInterval(updateYtdlp, Math.max(1, Number(CFG.updateHours) || 24) * 3600 * 1000);
