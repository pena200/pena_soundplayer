(() => {
  const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'pena_soundplayer';
  const post = (name, data = {}) =>
    fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) })
      .then((r) => r.json()).catch(() => null);
  const rpc = (name, ...args) => post('rpc', { name, args });
  const $ = (s) => document.querySelector(s);
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const sfxAt = {};
  const sfx = (name, minGap = 0) => {
    const t = performance.now();
    if (minGap && sfxAt[name] && t - sfxAt[name] < minGap) return;
    sfxAt[name] = t;
    post('sfx', { name });
  };
  const fmt = (s) => { s = Math.max(0, Math.floor(s || 0)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };
  const esc = (t) => String(t ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  const BANDS = [
    { f: 60,    type: 'lowshelf',  label: '60' },
    { f: 250,   type: 'peaking',   label: '250', q: 1 },
    { f: 1000,  type: 'peaking',   label: '1k',  q: 1 },
    { f: 4000,  type: 'peaking',   label: '4k',  q: 1 },
    { f: 12000, type: 'highshelf', label: '12k' },
  ];
  const EQ_PRESETS = [
    { name: 'Flat',   bands: [0, 0, 0, 0, 0] },
    { name: 'Bass',   bands: [8, 4, 0, 0, 0] },
    { name: 'Treble', bands: [0, 0, 0, 4, 7] },
    { name: 'V-Shape', bands: [6, 2, -3, 2, 6] },
    { name: 'Vocal',  bands: [-2, 0, 4, 3, 0] },
    { name: 'Club',   bands: [7, 3, -1, 2, 5] },
  ];
  const ZERO = [0, 0, 0, 0, 0];

  let ctx = null;
  const engine = {};
  const meta = {};
  const pendingMix = {};

  const getCtx = () => {
    if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
    if (ctx.state === 'suspended') ctx.resume();
    return ctx;
  };

  let streamer = false, master = null, badgeTimer = null;
  const getMaster = () => {
    const c = getCtx();
    if (!master) { master = c.createGain(); master.gain.value = streamer ? 0 : 1; master.connect(c.destination); }
    return master;
  };
  function setStreamer(on, announce) {
    streamer = !!on;
    if (master) master.gain.setTargetAtTime(streamer ? 0 : 1, ctx.currentTime, 0.03);
    $('#app').classList.toggle('muted', streamer);
    if (!announce) return;
    const b = $('#streamer');
    $('#streamerTxt').textContent = streamer ? 'Streamer mode on, audio muted' : 'Streamer mode off, audio on';
    b.classList.toggle('on', streamer);
    b.classList.add('show');
    clearTimeout(badgeTimer);
    badgeTimer = setTimeout(() => b.classList.remove('show'), 2600);
  }

  const expected = (id) => {
    const m = meta[id];
    if (!m || !m.st || !m.st.track || m.st.loading) return 0;
    if (m.st.paused) return m.st.position;
    return m.st.position + (performance.now() - m.recvAt) / 1000;
  };

  const blobCache = new Map();
  const loadingBlobs = new Map();

  const b64ToBlob = async (txt) => {
    try { return await (await fetch('data:application/octet-stream;base64,' + txt)).blob(); }
    catch (e) {
      const bin = atob(txt), arr = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
      return new Blob([arr]);
    }
  };

  const getChunk = async (trackId, n) => {
    for (let attempt = 0; attempt < 3; attempt++) {
      const r = await post('chunk', { id: trackId, n });
      if (r && r.ok) return r;
      await new Promise((res) => setTimeout(res, 250 * (attempt + 1)));
    }
    throw new Error('chunk ' + n + ' failed');
  };

  function loadBlob(trackId) {
    if (blobCache.has(trackId)) { const u = blobCache.get(trackId); blobCache.delete(trackId); blobCache.set(trackId, u); return Promise.resolve(u); }
    if (loadingBlobs.has(trackId)) return loadingBlobs.get(trackId);
    const p = (async () => {
      const first = await getChunk(trackId, 0);
      const parts = new Array(first.chunks);
      parts[0] = await b64ToBlob(first.data);
      let next = 1;
      const worker = async () => {
        while (next < first.chunks) {
          const n = next++;
          parts[n] = await b64ToBlob((await getChunk(trackId, n)).data);
          await new Promise((res) => setTimeout(res, 30));
        }
      };
      await Promise.all([worker(), worker(), worker()]);
      const url = URL.createObjectURL(new Blob(parts, { type: first.mime }));
      blobCache.set(trackId, url);
      while (blobCache.size > 8) { const k = blobCache.keys().next().value; URL.revokeObjectURL(blobCache.get(k)); blobCache.delete(k); }
      return url;
    })().finally(() => loadingBlobs.delete(trackId));
    loadingBlobs.set(trackId, p);
    return p;
  }

  function applyMix(e, mix) {
    const c = getCtx(), t = c.currentTime;
    e.gain.gain.setTargetAtTime(mix.gain, t, 0.06);
    e.lp.frequency.setTargetAtTime(mix.lowpass, t, 0.08);
    e.pan.pan.setTargetAtTime(clamp(mix.pan, -1, 1), t, 0.08);
  }

  function applyEq(e, bands) {
    const c = getCtx(), t = c.currentTime;
    const b = Array.isArray(bands) && bands.length === 5 ? bands.map((x) => Number(x) || 0) : ZERO;
    b.forEach((g, i) => e.eqf[i].gain.setTargetAtTime(g, t, 0.03));
    e.inp.gain.setTargetAtTime(Math.pow(10, -(Math.max(0, ...b) * 0.6) / 20), t, 0.05);
  }

  function ensureEngine(id) {
    if (engine[id]) return engine[id];
    const c = getCtx();
    const inp = c.createGain();
    const eqf = BANDS.map((b) => {
      const f = c.createBiquadFilter();
      f.type = b.type; f.frequency.value = b.f; f.gain.value = 0;
      if (b.q) f.Q.value = b.q;
      return f;
    });
    const lp = c.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 22000;
    const pan = c.createStereoPanner();
    const gain = c.createGain(); gain.gain.value = 0;
    let node = inp;
    for (const f of eqf) { node.connect(f); node = f; }
    node.connect(lp); lp.connect(pan); pan.connect(gain); gain.connect(getMaster());
    const e = (engine[id] = { inp, eqf, lp, pan, gain, trk: null });
    if (pendingMix[id]) applyMix(e, pendingMix[id]);
    return e;
  }

  function dropTrack(e) {
    const t = e && e.trk;
    if (!t) return;
    e.trk = null;
    t.dead = true;
    if (t.el) {
      try { t.el.pause(); } catch (x) {}
      t.el.removeAttribute('src');
      try { t.el.load(); } catch (x) {}
    }
    if (t.node) { try { t.node.disconnect(); } catch (x) {} }
  }

  const wantAudio = (id) => (cur && cur.id === id) || !!(pendingMix[id] && pendingMix[id].gain > 0.0005);

  const setTime = (el, t) => { try { el.currentTime = Math.max(0, t); } catch (x) {} };

  function reconcile(id) {
    const m = meta[id], e = engine[id];
    if (!m || !e || !e.trk || !e.trk.ready || !e.trk.el) return;
    const st = m.st, el = e.trk.el;
    if (st.loading) { if (!el.paused) el.pause(); return; }
    if (st.paused) {
      if (!el.paused) el.pause();
      if (Math.abs(el.currentTime - st.position) > 0.3) setTime(el, st.position);
      return;
    }
    const want = expected(id);
    if (isFinite(el.duration) && want >= el.duration - 0.1) { if (!el.paused) el.pause(); return; }
    if (Math.abs(el.currentTime - want) > (el.paused ? 0.25 : 1.4)) setTime(el, want);
    if (el.paused) { const p = el.play(); if (p && p.catch) p.catch(() => {}); }
  }

  function preloadNext(id) {
    const m = meta[id];
    if (!m || m.mode === 'direct' || !wantAudio(id)) return;
    const nx = m.st.queue && m.st.queue[0];
    if (nx && nx.id && !blobCache.has(nx.id) && !loadingBlobs.has(nx.id)) loadBlob(nx.id).catch(() => {});
  }

  function maybeLoad(id) {
    const e = engine[id], trk = e && e.trk;
    if (!trk || trk.loading || trk.ready || trk.failed || !wantAudio(id)) return;
    trk.loading = true;
    const m = meta[id] || {};
    const finish = (url) => {
      if (trk.dead) return;
      const c = getCtx();
      const el = new Audio();
      el.preload = 'auto';
      el.crossOrigin = 'anonymous';
      trk.el = el;
      trk.node = c.createMediaElementSource(el);
      trk.node.connect(e.inp);
      el.addEventListener('canplay', () => {
        if (trk.dead || trk.ready) return;
        trk.ready = true;
        post('ready', { id, token: trk.token });
        reconcile(id);
        preloadNext(id);
      }, { once: true });
      el.addEventListener('error', () => {
        if (trk.dead) return;
        trk.failed = true;
        if (cur && cur.id === id) setStatus("Couldn't play that song. Try another one.", true);
      });
      el.src = url;
      el.load();
    };
    if (m.mode === 'direct') return finish(m.base + trk.trackId);
    if (cur && cur.id === id && !blobCache.has(trk.trackId)) setStatus('Loading audio...');
    loadBlob(trk.trackId).then((url) => {
      if (cur && cur.id === id && statusText() === 'Loading audio...') setStatus('');
      finish(url);
    }).catch(() => {
      trk.loading = false; trk.failed = true;
      if (cur && cur.id === id) setStatus("Couldn't load that song. Try again.", true);
    });
  }

  function applyState(id, st, base, mode) {
    meta[id] = { st, recvAt: performance.now(), mode, base };
    const e = ensureEngine(id);
    if (!(eqBusy() && cur && cur.id === id)) applyEq(e, st.eq);
    if (!st.track) { dropTrack(e); return; }
    const t = e.trk;
    if (!t || t.trackId !== st.track.id || t.token !== st.token) {
      dropTrack(e);
      e.trk = { trackId: st.track.id, token: st.token, el: null, node: null, ready: false, loading: false, failed: false, dead: false };
      maybeLoad(id);
    } else {
      maybeLoad(id);
    }
    reconcile(id);
    if (e.trk && e.trk.ready) preloadNext(id);
  }

  setInterval(() => { for (const id in engine) reconcile(id); }, 2000);

  const THEMES = ['apple', 'spotify', 'ytmusic'];
  const THEME_KEY = 'pena_soundplayer:theme';
  const rootEl = document.documentElement;

  function applyAccent(hex) {
    if (typeof hex === 'string' && /^#[0-9a-f]{6}$/i.test(hex)) {
      const n = parseInt(hex.slice(1), 16);
      rootEl.style.setProperty('--cy', hex);
      rootEl.style.setProperty('--accent-rgb', `${n >> 16}, ${(n >> 8) & 255}, ${n & 255}`);
    } else {
      rootEl.style.removeProperty('--cy');
      rootEl.style.removeProperty('--accent-rgb');
    }
  }

  function setTheme(t, save) {
    if (!THEMES.includes(t)) t = 'apple';
    rootEl.dataset.theme = t;
    document.querySelectorAll('#themes .sw-btn').forEach((b) => b.classList.toggle('on', b.dataset.t === t));
    if (save) { try { localStorage.setItem(THEME_KEY, t); } catch (e) {} }
  }

  function initTheme(def, switcher) {
    rootEl.classList.toggle('sw', !!switcher);
    let t = THEMES.includes(def) ? def : 'apple';
    if (switcher) { try { const s = localStorage.getItem(THEME_KEY); if (THEMES.includes(s)) t = s; } catch (e) {} }
    setTheme(t, false);
  }

  document.querySelectorAll('#themes .sw-btn').forEach((b) => {
    b.onclick = () => { sfx('select'); setTheme(b.dataset.t, true); };
  });
  setTheme('apple', false);

  let cur = null;
  let tab = 'search';
  let results = [];
  let viewRows = [];
  let plView = null;
  let data = { playlists: [], presets: [] };
  let dataLoaded = false;
  let statusTimer = null;

  const statusText = () => $('#status').textContent;
  function setStatus(text, isErr, autoClear) {
    const s = $('#status');
    s.textContent = text || '';
    s.classList.toggle('err', !!isErr);
    clearTimeout(statusTimer);
    if (text && (isErr || autoClear)) statusTimer = setTimeout(() => setStatus(''), isErr ? 6000 : 2800);
    else if (/^Preparing /.test(text || '')) statusTimer = setTimeout(() => { if (/^Preparing /.test(statusText())) setStatus(''); }, 45000);
  }
  const flash = (text, isErr) => setStatus(text, isErr, true);

  const curState = () => (cur && meta[cur.id] ? meta[cur.id].st : null);

  const ICON = (p) => `<svg viewBox="0 0 24 24">${p}</svg>`;
  const ICON_NOTE = ICON('<path d="M9 18V5l12-2v13M9 18a3 3 0 11-6 0 3 3 0 016 0zm12-2a3 3 0 11-6 0 3 3 0 016 0z"/>');
  const ICON_PLUS = ICON('<path d="M12 5v14M5 12h14"/>');
  const ICON_X = ICON('<path d="M6 6l12 12M18 6L6 18"/>');
  const ICON_PLAY = '<svg viewBox="0 0 24 24"><path d="M7 4l13 8-13 8z"/></svg>';
  const ICON_LISTPLUS = ICON('<path d="M4 6h11M4 12h7M4 18h7M17 13v6M14 16h6"/>');
  const ICON_QUEUE = ICON('<path d="M4 6h12M4 12h12M4 18h7M18 15l4 3-4 3z"/>');
  const ICON_SHARE = ICON('<path d="M12 3v12M7 8l5-5 5 5M5 14v5a2 2 0 002 2h10a2 2 0 002-2v-5"/>');
  const ICON_TRASH = ICON('<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 002 2h6a2 2 0 002-2l1-12M9 7V4h6v3"/>');
  const ICON_BACK = ICON('<path d="M15 5l-7 7 7 7"/>');
  const ICON_LIST = ICON('<path d="M4 6h16M4 12h16M4 18h10"/>');
  const ICON_EQ = ICON('<path d="M5 4v16M12 4v16M19 4v16M3 9h4M10 14h4M17 8h4"/>');

  function renderDeck() {
    const st = curState();
    const t = st && st.track;
    $('#title').textContent = t ? t.title : 'Nothing playing';
    $('#channel').textContent = t ? t.channel : 'Search for a song';
    const art = $('#art');
    if (t && t.thumb) {
      if (art.getAttribute('src') !== t.thumb) art.src = t.thumb;
      $('#artBox').classList.add('has');
      $('#ambient').style.setProperty('--art', 'url("' + String(t.thumb).replace(/["\\]/g, '') + '")');
    } else {
      art.removeAttribute('src'); $('#artBox').classList.remove('has');
      $('#ambient').style.removeProperty('--art');
    }
    const loading = !!(t && st.loading);
    const playing = !!t && !st.paused && !loading;
    $('#tdur').textContent = t ? fmt(t.duration) : '0:00';
    $('#artLoad').classList.toggle('on', loading);
    $('#eq').classList.toggle('on', playing);
    $('#card').classList.toggle('playing', playing);
    $('#playIco').innerHTML = t && !st.paused ? '<path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z"/>' : '<path d="M7 4l13 8-13 8z"/>';
    $('#bLoop').classList.toggle('on', !!(st && st.loop));
    $('#seek').classList.toggle('idle', !t);
    if (st && document.activeElement !== $('#vol')) { $('#vol').value = Math.round(st.volume * 100); $('#volVal').textContent = Math.round(st.volume * 100); }
    $('#qCount').textContent = st ? st.queue.length : 0;
    if (t && !st.loading && ['Preparing track...', 'Loading audio...', 'Preparing playlist...'].includes(statusText())) setStatus('');
    lastSecond = -1;
  }

  const seekEl = $('#seek');
  let seekDrag = false, seekPreview = 0, lastP = -1, lastSecond = -1, raf = 0;

  function measureSeek() { seekEl.style.setProperty('--w', String(seekEl.offsetWidth)); }
  window.addEventListener('resize', measureSeek);

  function renderProgress() {
    if (!cur) return;
    const st = curState();
    const t = st && st.track;
    const dur = t ? (t.duration || 1) : 1;
    let pos = t ? Math.min(expected(cur.id), dur) : 0;
    if (seekDrag) pos = seekPreview * dur;
    const p = t ? clamp(pos / dur, 0, 1) : 0;
    if (Math.abs(p - lastP) > 0.001) { lastP = p; seekEl.style.setProperty('--p', p.toFixed(4)); }
    const sec = Math.floor(pos);
    if (sec !== lastSecond) { lastSecond = sec; $('#tcur').textContent = fmt(pos); }
  }
  let lastTick = 0;
  function tick(now) {
    if (!cur) { raf = 0; return; }
    if (seekDrag || now - lastTick >= 33) { lastTick = now; renderProgress(); }
    raf = requestAnimationFrame(tick);
  }

  const seekRatio = (ev) => { const r = seekEl.getBoundingClientRect(); return clamp((ev.clientX - r.left) / r.width, 0, 1); };
  seekEl.addEventListener('pointerdown', (ev) => {
    if (!cur) return;
    sfx('select');
    const st = curState();
    if (!st || !st.track || st.loading) { flash('Nothing to seek yet.'); return; }
    seekDrag = true; seekPreview = seekRatio(ev);
    seekEl.classList.add('drag');
    seekEl.setPointerCapture(ev.pointerId);
    renderProgress();
  });
  seekEl.addEventListener('pointermove', (ev) => {
    if (!seekDrag) return;
    seekPreview = seekRatio(ev);
    sfx('tick', 90);
    renderProgress();
  });
  const endSeek = (ev, commit) => {
    if (!seekDrag) return;
    seekDrag = false;
    seekEl.classList.remove('drag');
    const st = curState();
    if (commit && cur && st && st.track) {
      const target = seekPreview * (st.track.duration || 0);
      const m = meta[cur.id];
      m.st.position = target; m.recvAt = performance.now();
      reconcile(cur.id);
      ctl('seek', target);
    }
    renderProgress();
  };
  seekEl.addEventListener('pointerup', (ev) => endSeek(ev, true));
  seekEl.addEventListener('pointercancel', (ev) => endSeek(ev, false));

  const btn = (a, icon, title, cls = '') => `<button class="add ${cls}" data-a="${a}" title="${title}">${icon}</button>`;

  function trackRow(kind, t, i) {
    const k = viewRows.push({ kind, t, i }) - 1;
    const img = t.thumb ? `<img src="${esc(t.thumb)}" alt="" onerror="this.style.visibility='hidden'">` : `<div class="ph">${ICON_NOTE}</div>`;
    const sub = t.duration ? `${esc(t.channel)} \u2022 ${fmt(t.duration)}` : esc(t.channel);
    let acts;
    if (kind === 'queue') acts = btn('rmq', ICON_X, 'Remove', 'rm');
    else if (kind === 'pltrack') acts = btn('queue', ICON_QUEUE, 'Add to queue') + btn('pl-rm', ICON_X, 'Remove from playlist', 'rm');
    else acts = (t.id ? btn('addpl', ICON_LIST, 'Add to playlist') : '') + btn('queue', ICON_PLUS, 'Add to queue');
    const pb = kind === 'queue' ? '' : `<span class="pb"><i>${ICON_PLAY}</i></span>`;
    return `<div class="row${kind === 'queue' ? ' nopb' : ''}" data-a="${kind === 'queue' ? 'none' : 'play'}" data-k="${k}" style="--i:${Math.min(i || 0, 12)}">`
      + `<div class="th">${img}${pb}</div><div class="t"><b>${esc(t.title)}</b><span>${sub}</span></div><div class="acts">${acts}</div></div>`;
  }

  const empty = (title, text) => `<div class="empty"><div><b>${title}</b>${text}</div></div>`;

  function renderSearch() {
    $('#list').innerHTML = results.length ? results.map((r, i) => trackRow('search', r, i)).join('')
      : empty('Find something to play', 'Start typing and results appear as you type. Or paste a YouTube / Spotify link. Enter or Search works too.');
  }

  function renderQueue() {
    const st = curState();
    const q = (st && st.queue) || [];
    $('#list').innerHTML = q.length ? q.map((r, i) => trackRow('queue', r, i + 1)).join('')
      : empty('Queue is empty', 'Hit + on a result and it plays after the current song.');
  }

  async function ensureData(force) {
    if (dataLoaded && !force) return;
    const r = await rpc('data');
    if (r && r.ok) { data = r.data; dataLoaded = true; if (tab === 'lists' || tab === 'eq') render(); }
  }

  const coverOf = (pl) => {
    const t = pl.tracks && pl.tracks[0];
    return `<div class="cover">${t && t.thumb ? `<img src="${esc(t.thumb)}" alt="" onerror="this.style.visibility='hidden'">` : ICON_LIST}</div>`;
  };

  function renderLists() {
    if (plView) {
      const pl = data.playlists.find((p) => p.id === plView);
      if (!pl) plView = null;
      else {
        const n = pl.tracks.length;
        $('#list').innerHTML =
          `<div class="back"><button class="ico" data-a="pl-back" title="Back">${ICON_BACK}</button><h2>${esc(pl.name)}</h2>`
          + `<button class="chip" data-a="pl-share" title="Share">Share</button><button class="chip danger" data-a="pl-del" title="Delete playlist">Delete</button></div>`
          + `<div class="chips" style="margin:6px 2px 8px"><button class="chip cy" data-a="pl-play">Play all</button><button class="chip" data-a="pl-shuffle">Shuffle</button><button class="chip" data-a="pl-queue">Add all to queue</button></div>`
          + (n ? pl.tracks.map((t, i) => trackRow('pltrack', t, i + 1)).join('') : empty('Empty playlist', 'Use the list button on a search result to add songs here.'));
        return;
      }
    }
    viewRows = [];
    let html =
      `<div class="bar"><input id="plName" class="mini" maxlength="40" placeholder="New playlist name" autocomplete="off"><button class="chip cy" data-a="pl-new">Create</button></div>`
      + `<div class="bar" style="margin-top:0"><input id="plCode" class="mini" maxlength="12" placeholder="Share code from a friend" autocomplete="off"><button class="chip" data-a="pl-import">Import</button></div>`;
    if (!dataLoaded) html += empty('Loading...', 'Getting your playlists.');
    else if (!data.playlists.length) html += empty('No playlists yet', 'Create one above, then add songs with the list button on any result.');
    else {
      html += '<div class="sect">Your playlists</div>';
      html += data.playlists.map((pl, i) => {
        const k = viewRows.push({ kind: 'pl', pl, i }) - 1;
        return `<div class="row" data-a="pl-open" data-k="${k}" style="--i:${Math.min(i, 12)}">${coverOf(pl)}<div class="t"><b>${esc(pl.name)}</b><span>${pl.tracks.length} song${pl.tracks.length === 1 ? '' : 's'}</span></div>`
          + `<div class="acts">${btn('pl-play', ICON_PLAY, 'Play')}${btn('pl-queue', ICON_QUEUE, 'Add all to queue')}${btn('pl-share', ICON_SHARE, 'Share', 'share')}${btn('pl-del', ICON_TRASH, 'Delete', 'rm')}</div></div>`;
      }).join('');
    }
    $('#list').innerHTML = html;
  }

  let eqLocal = ZERO.slice();
  let eqDrag = false, eqHoldUntil = 0, eqTimer = null, eqSendAt = 0;
  const eqBusy = () => eqDrag || performance.now() < eqHoldUntil;
  const eqValues = () => (eqBusy() ? eqLocal : ((curState() && curState().eq) || ZERO));
  const fmtDb = (v) => (v > 0 ? '+' : '') + (Math.round(v * 2) / 2).toFixed(v % 1 ? 1 : 0);
  const BAND_H = 138;

  function bandVisual(el, v) {
    const y = ((12 - v) / 24) * BAND_H;
    const mid = BAND_H / 2;
    el.querySelector('.g').textContent = fmtDb(v);
    const bz = el.querySelector('.bz');
    bz.style.top = (v >= 0 ? y : mid) + 'px';
    bz.style.height = Math.abs(y - mid) + 'px';
    el.querySelector('.bh').style.top = y + 'px';
  }

  function renderEq() {
    viewRows = [];
    const vals = eqValues();
    let html = `<div class="eqpage"><div class="eq-head"><b>Equalizer</b><span>Everyone hearing this radio gets it</span><button class="chip" data-a="eq-reset">Reset</button></div>`
      + `<div class="bands">${BANDS.map((b, i) => `<div class="band" data-i="${i}"><span class="g"></span><div class="bt"><div class="bz"></div><div class="bh"></div></div><span class="f">${b.label}</span></div>`).join('')}</div>`
      + `<div class="chips">${EQ_PRESETS.map((p, i) => `<button class="chip" data-a="eq-preset" data-p="${i}">${p.name}</button>`).join('')}</div>`
      + `<div class="sect">My presets</div>`
      + `<div class="bar"><input id="eqName" class="mini" maxlength="30" placeholder="Name this setting" autocomplete="off"><button class="chip cy" data-a="eq-save">Save</button></div>`
      + `<div class="bar" style="margin-top:0"><input id="eqCode" class="mini" maxlength="12" placeholder="Share code from a friend" autocomplete="off"><button class="chip" data-a="eq-import">Import</button></div>`;
    if (dataLoaded) {
      html += data.presets.map((p, i) => {
        const k = viewRows.push({ kind: 'preset', p, i }) - 1;
        return `<div class="row nopb" data-a="eq-apply" data-k="${k}" style="--i:${Math.min(i, 12)}"><div class="cover">${ICON_EQ}</div><div class="t"><b>${esc(p.name)}</b><span>${p.bands.map(fmtDb).join('  ')}</span></div>`
          + `<div class="acts">${btn('eq-share', ICON_SHARE, 'Share', 'share')}${btn('eq-del', ICON_TRASH, 'Delete', 'rm')}</div></div>`;
      }).join('');
    }
    html += '</div>';
    $('#list').innerHTML = html;
    document.querySelectorAll('#list .band').forEach((el, i) => bandVisual(el, vals[i]));
  }

  function updateBands() {
    const vals = eqValues();
    document.querySelectorAll('#list .band').forEach((el, i) => bandVisual(el, vals[i]));
  }

  function pushEq() {
    if (eqTimer) return;
    const wait = Math.max(0, 150 - (performance.now() - eqSendAt));
    eqTimer = setTimeout(() => { eqTimer = null; eqSendAt = performance.now(); ctl('eq', eqLocal.slice()); }, wait);
  }

  function setEq(vals) {
    eqLocal = vals.map((v) => clamp(Math.round(v * 2) / 2, -12, 12));
    eqHoldUntil = performance.now() + 700;
    if (cur && engine[cur.id]) applyEq(engine[cur.id], eqLocal);
    document.querySelectorAll('#list .band').forEach((el, i) => bandVisual(el, eqLocal[i]));
    pushEq();
  }

  const bandFromEvent = (bt, ev) => {
    const r = bt.getBoundingClientRect();
    return (0.5 - clamp((ev.clientY - r.top) / r.height, 0, 1)) * 24;
  };
  let dragBand = -1;
  $('#list').addEventListener('pointerdown', (ev) => {
    const bt = ev.target.closest('.bt');
    if (!bt || tab !== 'eq' || !cur) return;
    const band = bt.parentElement;
    dragBand = Number(band.dataset.i);
    eqLocal = (curState() && curState().eq ? curState().eq : ZERO).slice();
    eqDrag = true;
    band.classList.add('drag');
    bt.setPointerCapture(ev.pointerId);
    sfx('tick');
    const v = eqLocal.slice(); v[dragBand] = bandFromEvent(bt, ev); setEq(v);
  });
  $('#list').addEventListener('pointermove', (ev) => {
    if (!eqDrag || dragBand < 0) return;
    const bt = document.querySelector(`#list .band[data-i="${dragBand}"] .bt`);
    if (!bt) return;
    const v = eqLocal.slice(); v[dragBand] = bandFromEvent(bt, ev);
    if (v[dragBand] !== eqLocal[dragBand]) sfx('tick', 80);
    setEq(v);
  });
  const endBand = () => {
    if (!eqDrag) return;
    eqDrag = false; dragBand = -1;
    document.querySelectorAll('#list .band.drag').forEach((b) => b.classList.remove('drag'));
  };
  $('#list').addEventListener('pointerup', endBand);
  $('#list').addEventListener('pointercancel', endBand);
  $('#list').addEventListener('dblclick', (ev) => {
    const band = ev.target.closest('.band');
    if (!band || tab !== 'eq') return;
    const v = eqValues().slice(); v[Number(band.dataset.i)] = 0; sfx('select'); setEq(v);
  });

  function render() {
    $('#tSearch').classList.toggle('on', tab === 'search');
    $('#tQueue').classList.toggle('on', tab === 'queue');
    $('#tLists').classList.toggle('on', tab === 'lists');
    $('#tEq').classList.toggle('on', tab === 'eq');
    const list = $('#list');
    const sc = list.scrollTop;
    viewRows = [];
    if (tab === 'queue') renderQueue();
    else if (tab === 'lists') renderLists();
    else if (tab === 'eq') renderEq();
    else renderSearch();
    list.scrollTop = sc;
  }

  function setTab(t) {
    if (tab !== t) sfx('hover');
    tab = t; closePop();
    if (t === 'lists' || t === 'eq') ensureData();
    render();
  }

  let searchSeq = 0, typeTimer = null, lastQuery = '';
  const spin = (on) => $('#qSpin').classList.toggle('on', on);

  async function runSearch(q, live, seq = ++searchSeq) {
    if (/^https?:\/\//i.test(q)) {
      spin(false);
      results = [{ title: 'Use this link', channel: q.length > 70 ? q.slice(0, 67) + '...' : q, ref: q }];
      lastQuery = q;
      if (tab === 'search') render();
      return;
    }
    if (q.length < 2) { spin(false); return; }
    spin(true);
    const r = await post('search', { q });
    if (seq !== searchSeq || !cur) return;
    if (r && r.quiet) { setTimeout(() => { if (seq === searchSeq && cur) runSearch(q, live, seq); }, 450); return; }
    spin(false);
    if (r && r.ok) { results = r.results; lastQuery = q; if (!live) setStatus(''); }
    else {
      results = [];
      setStatus((r && r.error) || 'Search failed.', true);
      if (!live) sfx('error');
    }
    if (tab === 'search') render();
  }

  function explicitSearch() {
    clearTimeout(typeTimer);
    sfx('select');
    const q = $('#q').value.trim();
    if (tab !== 'search') { tab = 'search'; closePop(); }
    if (q.length < 2) { searchSeq++; spin(false); render(); flash('Type at least 2 characters.'); return; }
    if (q === lastQuery && results.length) { render(); return; }
    setStatus('');
    runSearch(q, false);
    render();
  }

  $('#q').addEventListener('input', () => {
    const q = $('#q').value.trim();
    clearTimeout(typeTimer);
    if (tab !== 'search') { tab = 'search'; closePop(); render(); }
    if (q.length < 2) { searchSeq++; spin(false); if (!q) { results = []; lastQuery = ''; render(); } return; }
    if (/^https?:\/\//i.test(q)) { runSearch(q, true); return; }
    if (q.length < 3) return;
    typeTimer = setTimeout(() => { if (q !== lastQuery) runSearch(q, true); }, 700);
  });
  $('#q').addEventListener('keydown', (e) => { if (e.key === 'Enter') explicitSearch(); });
  $('#bSearch').onclick = explicitSearch;


  const ctl = (type, value) => cur && post('ctl', { id: cur.id, type, value });

  let closeTimer = null;
  function open(id, kind) {
    clearTimeout(closeTimer);
    const app = $('#app');
    app.classList.remove('closing');
    if (!app.classList.contains('open')) { void app.offsetWidth; app.classList.add('open'); }
    cur = { id, kind };
    tab = 'search'; plView = null; dataLoaded = false; eqDrag = false; eqHoldUntil = 0;
    closePop(); closeModal(); spin(false); searchSeq++;
    setStatus('');
    renderDeck(); render(); measureSeek();
    for (const sid in engine) maybeLoad(sid);
    if (!raf) raf = requestAnimationFrame(tick);
    ensureData(true);
    setTimeout(() => $('#q').focus(), 120);
  }

  function hide() {
    const app = $('#app');
    if (!app.classList.contains('open') || app.classList.contains('closing')) return;
    app.classList.add('closing');
    closeTimer = setTimeout(() => { app.classList.remove('open', 'closing'); }, 210);
  }

  function close() {
    if (!cur) return;
    cur = null; seekDrag = false; eqDrag = false;
    closePop(); closeModal();
    hide();
    post('close');
  }

  $('#tSearch').onclick = () => setTab('search');
  $('#tQueue').onclick = () => setTab('queue');
  $('#tLists').onclick = () => { plView = null; setTab('lists'); };
  $('#tEq').onclick = () => setTab('eq');
  $('#bClose').onclick = close;

  $('#bPlay').onclick = () => {
    sfx('toggle');
    const st = curState();
    if (!st || !st.track) { flash('Nothing to play yet. Search for a song.'); return; }
    ctl(st.paused ? 'resume' : 'pause');
  };
  $('#bSkip').onclick = () => { sfx('next'); ctl('skip'); };
  $('#bStop').onclick = () => { sfx('stop'); ctl('stop'); };
  $('#bLoop').onclick = () => { sfx('toggle'); ctl('loop', !(curState() && curState().loop)); };

  let volTimer = null;
  $('#vol').addEventListener('input', (e) => {
    $('#volVal').textContent = e.target.value;
    sfx('tick', 90);
    clearTimeout(volTimer);
    volTimer = setTimeout(() => ctl('volume', Number(e.target.value) / 100), 130);
  });

  const pop = $('#pop');
  let popTrack = null;
  function closePop() { pop.classList.remove('on'); popTrack = null; }

  function popHtml() {
    return `<h4>Add to playlist</h4>`
      + (data.playlists.length ? data.playlists.map((p) => `<button class="opt" data-pl="${p.id}">${esc(p.name)}<small>${p.tracks.length}</small></button>`).join('')
        : `<div style="padding:6px 8px;color:var(--mist);font-size:12px">No playlists yet. Create one:</div>`)
      + `<div class="bar"><input class="mini" id="popName" maxlength="40" placeholder="New playlist" autocomplete="off"><button class="chip cy" data-new="1">Add</button></div>`;
  }

  async function openPop(button, track) {
    sfx('select');
    popTrack = track;
    await ensureData();
    pop.innerHTML = popHtml();
    pop.classList.add('on');
    const cr = $('#card').getBoundingClientRect(), br = button.getBoundingClientRect();
    let left = clamp(br.right - cr.left - 250, 8, cr.width - 258);
    let top = br.bottom - cr.top + 6;
    if (top + pop.offsetHeight > cr.height - 8) top = Math.max(8, br.top - cr.top - pop.offsetHeight - 6);
    pop.style.left = left + 'px'; pop.style.top = top + 'px';
  }

  async function addToPlaylist(plId) {
    const track = popTrack;
    if (!track) return;
    const r = await rpc('pl:add', plId, track);
    closePop();
    if (r && r.ok) {
      data = r.data; sfx('queue');
      const pl = data.playlists.find((p) => p.id === plId);
      flash(`Added to "${pl ? pl.name : 'playlist'}".`);
      if (tab === 'lists') render();
    } else { sfx('error'); flash((r && r.error) || 'Could not add it.', true); }
  }

  pop.addEventListener('click', async (e) => {
    e.stopPropagation();
    const o = e.target.closest('button.opt');
    if (o) return addToPlaylist(Number(o.dataset.pl));
    if (e.target.closest('button[data-new]')) {
      const name = $('#popName').value.trim();
      if (!name) { sfx('error'); return; }
      const track = popTrack;
      const r = await rpc('pl:create', name);
      if (r && r.ok) { data = r.data; popTrack = track; await addToPlaylist(r.id); }
      else { sfx('error'); flash((r && r.error) || 'Could not create it.', true); }
    }
  });
  pop.addEventListener('keydown', (e) => { if (e.key === 'Enter') { const b = pop.querySelector('button[data-new]'); if (b) b.click(); } });
  document.addEventListener('click', (e) => { if (pop.classList.contains('on') && !e.target.closest('#pop') && !e.target.closest('[data-a="addpl"]')) closePop(); });

  const modal = $('#modal');
  function closeModal() { modal.classList.remove('on'); modal.innerHTML = ''; }

  async function openShare(kind, id, name) {
    sfx('select');
    const r = await rpc(kind === 'pl' ? 'pl:share' : 'eq:share', id);
    if (!r || !r.ok) { sfx('error'); return flash((r && r.error) || 'Could not share.', true); }
    data = r.data;
    modal.innerHTML = `<div class="box"><h3>Share ${kind === 'pl' ? 'playlist' : 'preset'}</h3><p>${esc(name)}. Anyone with this code can import a copy.</p>`
      + `<div class="code"><b>${esc(r.code)}</b><button class="chip" data-m="copy">Copy</button></div>`
      + `<div class="foot"><button class="chip" data-m="close">Close</button></div></div>`;
    modal.dataset.code = r.code;
    modal.classList.add('on');
  }

  modal.addEventListener('click', async (e) => {
    if (e.target === modal) { sfx('stop'); return closeModal(); }
    const b = e.target.closest('button[data-m]');
    if (!b) return;
    if (b.dataset.m === 'close') { sfx('stop'); return closeModal(); }
    if (b.dataset.m === 'copy') { sfx('select'); post('copy', { text: modal.dataset.code }); return; }
  });

  const armed = {};
  const arm = (key, text) => {
    if (armed[key]) { clearTimeout(armed[key]); delete armed[key]; return true; }
    flash(text);
    armed[key] = setTimeout(() => delete armed[key], 3000);
    return false;
  };

  const absorb = (r) => { if (r && r.ok) { data = r.data; return true; } sfx('error'); flash((r && r.error) || 'Something went wrong.', true); return false; };

  $('#list').addEventListener('click', async (e) => {
    if (!cur) return;
    const b = e.target.closest('button[data-a]');
    const row = e.target.closest('.row[data-k]');
    const el = b || (row && row.dataset.a ? row : null);
    if (!el) return;
    const a = el.dataset.a;
    if (a === 'none') return;
    const r = row ? viewRows[Number(row.dataset.k)] : null;
    const plId = plView || (r && r.pl && r.pl.id);
    const pl = () => data.playlists.find((p) => p.id === plId);

    switch (a) {
      case 'play': {
        if (!r) return;
        sfx('select');
        post('play', { id: cur.id, ref: r.t.id || r.t.ref, mode: 'now' });
        setStatus('Preparing track...');
        break;
      }
      case 'queue': {
        if (!r) return;
        sfx('queue');
        post('play', { id: cur.id, ref: r.t.id || r.t.ref, mode: 'queue' });
        setStatus('Preparing track...');
        break;
      }
      case 'addpl': if (r) openPop(b, r.t); break;
      case 'rmq': sfx('stop'); ctl('remove', r.i); break;

      case 'pl-open': sfx('select'); plView = r.pl.id; render(); break;
      case 'pl-back': sfx('hover'); plView = null; render(); break;
      case 'pl-play': case 'pl-shuffle': case 'pl-queue': {
        if (!plId) return;
        sfx(a === 'pl-queue' ? 'queue' : 'select');
        post('playlist', { id: cur.id, plId, mode: a === 'pl-queue' ? 'queue' : 'play', shuffle: a === 'pl-shuffle' });
        setStatus('Preparing playlist...');
        break;
      }
      case 'pl-share': if (plId && pl()) openShare('pl', plId, pl().name); break;
      case 'pl-del': {
        if (!plId || !pl()) return;
        if (!arm('pl' + plId, 'Click delete again to remove "' + pl().name + '".')) { sfx('hover'); return; }
        sfx('stop');
        if (absorb(await rpc('pl:delete', plId))) { plView = null; render(); flash('Playlist deleted.'); }
        break;
      }
      case 'pl-rm': {
        if (!plId || !r) return;
        sfx('stop');
        if (absorb(await rpc('pl:remove', plId, r.i))) render();
        break;
      }
      case 'pl-new': {
        const name = $('#plName').value.trim();
        if (!name) { sfx('error'); return flash('Give the playlist a name.', true); }
        if (absorb(await rpc('pl:create', name))) { sfx('queue'); render(); flash('Playlist created.'); }
        break;
      }
      case 'pl-import': {
        const code = $('#plCode').value.trim();
        if (!code) { sfx('error'); return flash('Enter a share code.', true); }
        const res = await rpc('pl:import', code);
        if (absorb(res)) { sfx('queue'); render(); flash(`Imported "${res.name}".`); }
        break;
      }

      case 'eq-reset': sfx('select'); setEq(ZERO.slice()); break;
      case 'eq-preset': sfx('select'); setEq(EQ_PRESETS[Number(el.dataset.p)].bands.slice()); break;
      case 'eq-apply': sfx('select'); if (r) setEq(r.p.bands.slice()); break;
      case 'eq-save': {
        const name = $('#eqName').value.trim();
        if (!name) { sfx('error'); return flash('Name your preset first.', true); }
        if (absorb(await rpc('eq:save', name, eqValues().slice()))) { sfx('queue'); renderEq(); flash('Preset saved.'); }
        break;
      }
      case 'eq-import': {
        const code = $('#eqCode').value.trim();
        if (!code) { sfx('error'); return flash('Enter a share code.', true); }
        const res = await rpc('eq:import', code);
        if (absorb(res)) { sfx('queue'); renderEq(); flash(`Imported "${res.name}".`); }
        break;
      }
      case 'eq-share': if (r) openShare('eq', r.p.id, r.p.name); break;
      case 'eq-del': {
        if (!r) return;
        if (!arm('eq' + r.p.id, 'Click delete again to remove "' + r.p.name + '".')) { sfx('hover'); return; }
        sfx('stop');
        if (absorb(await rpc('eq:delete', r.p.id))) { renderEq(); flash('Preset deleted.'); }
        break;
      }
    }
  });

  $('#list').addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    const map = { plName: 'pl-new', plCode: 'pl-import', eqName: 'eq-save', eqCode: 'eq-import' };
    const a = map[e.target.id];
    if (a) { const b = document.querySelector(`#list button[data-a="${a}"]`); if (b) b.click(); }
  });
  $('#list').addEventListener('mouseover', (e) => {
    const row = e.target.closest('.row');
    if (row && !row.contains(e.relatedTarget)) sfx('hover', 70);
  });

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || !cur) return;
    if (modal.classList.contains('on')) return closeModal();
    if (pop.classList.contains('on')) return closePop();
    close();
  });

  let toastTimer = null;
  function toast(d) {
    $('#toastTitle').textContent = d.title || '';
    $('#toastChannel').textContent = d.channel || '';
    $('#toastImg').src = d.thumb || '';
    $('#toast').classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => $('#toast').classList.remove('show'), 5000);
  }

  window.addEventListener('message', (ev) => {
    const d = ev.data || {};
    switch (d.action) {
      case 'open':
        applyAccent(d.accent);
        initTheme(d.theme, d.themeSwitcher);
        open(d.id, d.kind); break;
      case 'close': cur = null; seekDrag = false; eqDrag = false; closePop(); closeModal(); hide(); break;
      case 'state':
        applyState(d.id, d.state, d.base, d.mode);
        if (cur && cur.id === d.id) {
          renderDeck();
          if (tab === 'queue') render();
          else if (tab === 'eq' && !eqBusy()) updateBands();
        }
        break;
      case 'mix': {
        const mix = { gain: d.gain, lowpass: d.lowpass, pan: d.pan };
        pendingMix[d.id] = mix;
        if (engine[d.id]) { applyMix(engine[d.id], mix); maybeLoad(d.id); }
        break;
      }
      case 'removed': {
        const e = engine[d.id];
        if (e) dropTrack(e);
        delete meta[d.id]; delete pendingMix[d.id];
        if (cur && cur.id === d.id) { renderDeck(); render(); }
        break;
      }
      case 'eq': {
        const m = meta[d.id];
        if (m && m.st) m.st.eq = d.eq;
        const e = engine[d.id];
        const mine = cur && cur.id === d.id;
        if (e && !(eqBusy() && mine)) applyEq(e, d.eq);
        if (mine && tab === 'eq' && !eqBusy()) updateBands();
        break;
      }
      case 'toast': if (!streamer) toast(d); break;
      case 'streamer': setStreamer(d.value, d.announce); break;
      case 'status': if (cur && cur.id === d.id) setStatus(d.text); break;
    }
  });

  render();
})();