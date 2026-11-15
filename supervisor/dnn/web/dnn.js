/* DNN - Dwarf News Network: the rundown engine.
   Data: /feed.json (fort state via dnn.py), /copy.json (all prose; never hard-code lines here).
   Modes: ?obs=1 transparent video box for an OBS scene (Game Capture under it);
          default = TV/browser: live video from /hls/index.m3u8, fallback /game.jpg stills.
   Remote: OK or Right = next line, Left = replay line, Down = sound on/off, Back = exit.
   ES2017 only (webOS 5 / Chrome 68 floor). */
(function () {
  'use strict';
  var Q = {};
  location.search.replace(/^\?/, '').split('&').forEach(function (kv) { if (kv) { var p = kv.split('='); Q[p[0]] = decodeURIComponent(p[1] || '1'); } });
  var OBS = Q.obs === '1';
  if (OBS) document.body.className += ' obs';

  var $ = function (id) { return document.getElementById(id); };
  var S = { feed: null, copy: null, lastEvt: null, breaking: [], justIn: [], issueUsed: {}, prevStocks: null,
            seg: 0, beat: null, skip: null, lastBreak: 0, videoOk: null };
  var SEEN = {};
  try { SEEN = JSON.parse(localStorage.getItem('dnn.seen') || '{}'); } catch (e) { SEEN = {}; }
  function saveSeen() {
    var ids = Object.keys(SEEN);
    if (ids.length > 6000) { ids.sort(function (a, b) { return SEEN[a] - SEEN[b]; }).slice(0, ids.length - 5000).forEach(function (k) { delete SEEN[k]; }); }
    try { localStorage.setItem('dnn.seen', JSON.stringify(SEEN)); } catch (e) { /* full: fine */ }
  }

  // ------------------------------------------------------------ fit 1920x1080 to the window
  function fit() {
    var s = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
    var el = $('screen');
    el.style.transform = 'scale(' + s + ')';
    el.style.left = Math.round((window.innerWidth - 1920 * s) / 2) + 'px';
    el.style.top = Math.round((window.innerHeight - 1080 * s) / 2) + 'px';
  }
  window.addEventListener('resize', fit); fit();

  // ------------------------------------------------------------ helpers
  function num(v) { return v == null ? null : Number(v).toLocaleString('en-US'); }
  function rnd(n) { return Math.floor(Math.random() * n); }
  function pickArr(a) { return a && a.length ? a[rnd(a.length)] : null; }
  function esc(t) { return String(t).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function getJSON(url, cb) {
    var x = new XMLHttpRequest();
    x.open('GET', url, true); x.timeout = 20000;
    x.onload = function () { if (x.status === 200) { try { cb(JSON.parse(x.responseText)); return; } catch (e) { /* fallthrough */ } } cb(null); };
    x.onerror = x.ontimeout = function () { cb(null); };
    x.send();
  }
  // DF text: drop quality marks and diagnostics, tidy names
  function clean(t) {
    return String(t || '').replace(/[☼«»≡]/g, '')
      .replace(/(^|\s)([+*-])([^\s+*-][^+*-]*?)\2(?=\s|$|[!.,])/g, '$1$3')
      .replace(/\s*\((Tame|Trained|Wild|Stray)\)/g, '').replace(/\[\d+\]/g, '').replace(/\s+/g, ' ').trim();
  }
  function shortName(n) { // 'Erib Kolmubun "Wheeledpractice", Dwarven Child' -> 'Erib Kolmubun'
    return String(n || '').split(',')[0].replace(/\s*"[^"]*"/, '').trim();
  }
  function profOf(n) { var p = String(n || '').split(','); return p.length > 1 ? p.slice(1).join(',').trim().toLowerCase() : ''; }

  // ------------------------------------------------------------ slots and conditions
  function ctx(extra) {
    var f = S.feed || {}, st = f.state || {}, fort = st.fort || {}, wx = st.weather || {};
    var cast = f.cast || [];
    var names = (st.names || []).slice();
    function castName(i) {
      var c = cast[i];
      if (c && c.name) return c.name;
      return names.length ? shortName(names[(i * 5) % names.length]) : null;
    }
    var stocks = ((f.stocks || {}).stocks) || {}, animals = ((f.stocks || {}).animals) || {};
    var season = String(wx.season || '').toLowerCase();
    var sl = {
      fort: fort.name, world: fort.world, month: fort.month, year: fort.year,
      season: season || null, civ: f.civ || null,
      anchor: castName(0), anchor2: castName(1), reporter: castName(2),
      citizen: names.length ? shortName(pickArr(names)) : null, citizen2: names.length ? shortName(pickArr(names)) : null,
      drinks: num(stocks.drinks), meals: num(stocks.meals), meat: num(stocks.meat), plants: num(stocks.plants), gems: num(stocks.gems),
      bars: num(stocks.bars), wood: num(stocks.wood), stone: num(stocks.stone), cats: num(animals.cats), pop: num(fort.population),
      weather: wx.kind && wx.kind !== 'none' ? wx.kind : null
    };
    if (sl.citizen && sl.citizen === sl.citizen2 && names.length > 1) sl.citizen2 = shortName(names[(names.indexOf(sl.citizen) + 1) % names.length]);
    var c = {};
    var dr = stocks.drinks, food = stocks.meals;
    if (dr != null) { c.drinks_low = dr < 200; c.drinks_high = dr > 2000; }
    if (food != null) { c.food_low = food < 300; c.food_high = food > 2000; }
    if (stocks.meat != null) c.meat_low = stocks.meat < 100;
    c.cats_many = (animals.cats || 0) >= 20;
    var pop = fort.population || 0;
    c.pop_small = pop > 0 && pop < 50; c.pop_big = pop > 120;
    var age = fort.age_days || 0;
    c.young_fort = age > 0 && age < 336; c.old_fort = age > 3 * 336;
    c.raining = wx.kind === 'rain'; c.snowing = wx.kind === 'snow'; c.clear = !wx.kind || wx.kind === 'none' || wx.kind === 'clear';
    ['spring', 'summer', 'autumn', 'winter'].forEach(function (s) { c[s] = season.indexOf(s) >= 0; });
    var rec = f.recent || {};
    c.recent_death = (rec.deaths || []).some(function (d) { return !d.pet && d.y === fort.year; });
    c.peace = !S.breaking.concat(S.justIn).some(function (e) { return e.kind === 'siege' || e.kind === 'beast'; });
    if (extra) for (var k in extra) if (extra[k] != null && extra[k] !== '') sl[k] = extra[k];
    return { sl: sl, c: c };
  }

  var VOWEL = /^[aeiouAEIOU]/;
  function fill(text, cx) {
    var miss = false;
    var out = String(text).replace(/\b([Aa]n?) \{([a-z_0-9]+)\}/g, function (m, art, k) {
      var v = cx.sl[k]; if (v == null || v === '') { miss = true; return m; }
      var a = VOWEL.test(String(v)) ? 'an' : 'a';
      return (art.charAt(0) === 'A' ? a.charAt(0).toUpperCase() + a.slice(1) : a) + ' ' + v;
    }).replace(/\{([a-z_0-9]+)\}/g, function (m, k) {
      var v = cx.sl[k]; if (v == null || v === '') { miss = true; return m; }
      return String(v);
    });
    if (miss) return null;
    out = out.replace(/([Tt]he) [Tt]he/g, '$1');
    return out.charAt(0).toUpperCase() + out.slice(1);
  }

  // least recently aired first, conditions must hold, every slot must fill
  function choose(list, cx, field) {
    if (!list || !list.length) return null;
    field = field || 'text';
    var now = Date.now(), best = null, bestScore = Infinity;
    for (var i = 0; i < list.length; i++) {
      var e = list[i];
      if (!e || S.issueUsed[e.id]) continue;
      if (e.when && e.when.length && !e.when.every(function (w) { return cx.c[w]; })) continue;
      var score = (SEEN[e.id] || 0) + Math.random() * 600000 - (e.when && e.when.length ? 3600000 : 0);
      if (score >= bestScore) continue;
      var ok = true;
      (field === 'ab' ? ['a', 'b'] : field === 'debate' ? ['topic'].concat((e.lines || []).map(function (_, j) { return j; })) : [field]).forEach(function (f) {
        var t = typeof f === 'number' ? e.lines[f] : e[f];
        if (t == null || fill(t, cx) == null) ok = false;
      });
      if (!ok) continue;
      best = e; bestScore = score;
    }
    if (best) { SEEN[best.id] = now; S.issueUsed[best.id] = 1; saveSeen(); }
    return best;
  }
  function line(sec, kind, cx) {
    var L = S.copy || {};
    var list = kind ? ((L[sec] || {})[kind]) : L[sec];
    var e = choose(list, cx);
    return e ? fill(e.text, cx) : null;
  }

  // ------------------------------------------------------------ events -> stories
  var BIG = { death: 1, beast: 1, siege: 1, artifact: 1, mood: 1, migrants: 1, caravan: 1, diplomat: 1, birth: 1, marriage: 1, noble: 1 };
  function classify(ev) {
    var t = clean(ev.text), ty = String(ev.type || ''), m;
    var e = { id: ev.id, text: t, kind: 'generic', sl: {} };
    if (/^\[|DFHack|Watchdog/.test(t)) { e.kind = 'skip'; return e; }   // tool diagnostics, not news
    function nameBefore(re) { var mm = t.match(re); if (mm) { e.sl.name = shortName(mm[1]); var p = profOf(mm[1]); if (p) e.sl.prof = p; } }
    if (ty === 'CITIZEN_DEATH' || /has been found dead|has died|has been struck down|has bled to death|has been killed/i.test(t) && ty !== 'PET_DEATH') {
      e.kind = 'death'; nameBefore(/^(.+?) (?:has been found dead|has died|has been struck down|has bled to death|has been killed)/i);
    } else if (/has been slaughtered/i.test(t)) {
      e.kind = 'generic';   // butchering livestock: ticker material, not a story
    } else if (ty === 'PET_DEATH') {
      e.kind = 'pet_death'; m = t.match(/^(?:The )?(.+?) has been/i); if (m) { e.sl.name = m[1]; e.sl.creature = m[1].toLowerCase().replace(/^stray /, ''); }
    } else if (/BIRTH/.test(ty) || /has given birth/i.test(t)) {
      e.kind = 'birth'; nameBefore(/^(.+?) has given birth/i);
    } else if (/MIGRANT/.test(ty) || /migrants/i.test(t)) {
      e.kind = 'migrants'; m = t.match(/(\d+)/); if (m) e.sl.count = m[1];
    } else if (/CARAVAN|MERCHANT/.test(ty) || /merchants have arrived|caravan/i.test(t)) {
      e.kind = 'caravan';
    } else if (/DIPLOMAT|LIAISON/.test(ty) || /diplomat|liaison/i.test(t)) {
      e.kind = 'diplomat';
    } else if (ty === 'ARTIFACT_BEGUN' || /has begun a mysterious construction/i.test(t)) {
      e.kind = 'mood'; nameBefore(/^(.+?) has begun/i);
    } else if (/ARTIFACT/.test(ty) || /legendary|artifact/i.test(t)) {
      // 'Lor Ushrirodshith, Planter has created Katakegur Vucar Imsal, a willow scepter!  He offers it to ...'
      e.kind = 'artifact'; nameBefore(/^(.+?) has (?:created|completed)/i);
      m = t.match(/has (?:created|completed) [^,!]+, an? ([^!.,]+)/i) || t.match(/(?:created|completed) (?:an? |the )?([^!.,]+)/i);
      if (m) e.sl.thing = m[1].toLowerCase().trim();
      e.text = t.replace(/!\s+(He|She|It|They) offers? it to .*$/, '!');
    } else if (ty === 'MASTERPIECE_CRAFTED' || /masterpiece/i.test(t)) {
      e.kind = 'masterpiece'; nameBefore(/^(.+?) has (?:created|improved)/i); m = t.match(/masterpiece (.+?)[!.]?$/i); if (m) e.sl.thing = m[1].toLowerCase();
    } else if (/MOOD/.test(ty) || /fey mood|secretive mood|possessed|withdraws from society|macabre/i.test(t)) {
      e.kind = 'mood'; nameBefore(/^(.+?) (?:is taken|withdraws|has been possessed|looses|begins)/i);
    } else if (/BEAST|TITAN|MEGABEAST|DEMON/.test(ty) || /forgotten beast|titan|has come!|megabeast|demon/i.test(t)) {
      e.kind = 'beast'; m = t.match(/^(?:The )?(.+?)(?: has come| has emerged|,)/i); if (m) e.sl.creature = m[1].toLowerCase();
    } else if (/SIEGE|AMBUSH|INVASION/.test(ty) || /siege|ambush|vile force|invaders/i.test(t)) {
      e.kind = 'siege';
    } else if (ty === 'CITIZEN_BECOMES_SOLDIER') {
      e.kind = 'soldier'; nameBefore(/^(.+?) has become/i);
    } else if (ty === 'CITIZEN_BECOMES_NONSOLDIER') {
      e.kind = 'civilian'; nameBefore(/^(.+?) has (?:become|left)/i);
    } else if (ty === 'QUOTA_FILLED' || /quota|mandate/i.test(t)) {
      e.kind = 'quota';
    } else if (/MARRI/.test(ty) || /married/i.test(t)) {
      e.kind = 'marriage'; nameBefore(/^(.+?) (?:and .+? )?(?:have|has) (?:married|been married)/i);
    } else if (/NOBLE|ELECT|APPOINT/.test(ty) || /has been elected|has been appointed|has become (?:a |the )?(?:mayor|baron|count|duke|manager|bookkeeper|broker|sheriff|captain)/i.test(t)) {
      e.kind = 'noble'; nameBefore(/^(.+?) has (?:been|become)/i);
    }
    e.big = !!BIG[e.kind];
    return e;
  }

  // recent.json -> the night's top story candidates
  function topStories() {
    var r = (S.feed || {}).recent || {}, out = [];
    (r.deaths || []).forEach(function (d) {
      out.push(d.pet ? { kind: 'pet_death', sl: { name: d.name, creature: d.job }, w: 1 }
        : { kind: 'death', sl: { name: shortName(d.name), prof: d.job ? String(d.job).toLowerCase() : null }, w: 5 });
    });
    (r.artifact_info || []).forEach(function (a) {
      var m = String(a.item || '').match(/\(([^)]+)\)\s*$/);   // 'List Berul, The Gaze of Bastions (Figurine)'
      out.push({ kind: 'artifact', sl: { name: shortName(a.by), thing: m ? m[1].toLowerCase() : null }, w: 4, text: a.by && a.name ? shortName(a.by) + ' has made ' + a.name + (m ? ', a legendary ' + m[1].toLowerCase() : '') + '.' : null });
    });
    (r.beasts || []).forEach(function (b) { out.push({ kind: 'beast', sl: { creature: String(b.kind || b.name || b).toLowerCase() }, w: 4 }); });
    if (r.births) out.push({ kind: 'birth', sl: {}, w: 2 });
    var evs = ((S.feed || {}).state || {}).big || [];
    evs.slice(0, 6).forEach(function (ev) { var e = classify(ev); if (e.kind !== 'generic' && e.kind !== 'skip') out.push({ kind: e.kind, sl: e.sl, w: e.big ? 3 : 1, text: e.text }); });
    return out;
  }

  // ------------------------------------------------------------ people on screen
  function castPerson(i) {
    var c = ((S.feed || {}).cast || [])[i];
    var cx = ctx();
    var role = ['DNN anchor', 'DNN co-anchor', 'DNN field correspondent', 'DNN contributor', 'DNN contributor'][i] || 'DNN';
    if (c) return { id: c.id, name: c.name, title: (c.title ? c.title + ' \u00b7 ' : '') + role };
    var n = [cx.sl.anchor, cx.sl.anchor2, cx.sl.reporter][i] || 'DNN';
    return { id: null, name: n, title: role };
  }
  function guestPerson() {
    var st = (S.feed || {}).state || {}, d = st.dwarf || st.followed;
    if (!d || !d.name) return null;
    return { id: d.id, name: shortName(d.name), title: (d.profession || '') + (d.job ? ' \u00b7 ' + d.job : ''), unit: d };
  }
  var SIL = '<svg viewBox="0 0 100 100"><circle cx="50" cy="34" r="20" fill="#2b4a8a"/><path d="M18 100 Q22 60 50 58 Q78 60 82 100Z" fill="#2b4a8a"/><path d="M34 44 Q50 80 66 44 Q58 52 50 52 Q42 52 34 44Z" fill="#8a6a3a"/></svg>';
  function headHTML(p) {
    if (!p) return '';
    var img = p.id != null ? '<img src="/portrait.png?u=' + p.id + '" alt="" onerror="this.parentNode.innerHTML=window.DNN_SIL">' : SIL;
    return '<div class="th" data-pid="' + esc(p.id == null ? p.name : p.id) + '"><div class="face">' + img + '</div>' +
      '<div class="wave"><i></i><i></i><i></i></div><div class="plate"><b>' + esc(p.name) + '</b><i>' + esc(p.title || '') + '</i></div></div>';
  }
  window.DNN_SIL = SIL;

  // ------------------------------------------------------------ video
  var vid = null, stillTimer = null;
  // the game window: one long MJPEG connection; if it drops, 1 fps stills until it's back
  function startStill() {
    if (stillTimer || OBS) return;
    var img = $('still');
    img.style.display = '';
    var stills = function () {
      if (stillTimer) return;
      var tick = function () {
        var n = new Image();
        n.onload = function () { img.src = n.src; $('nosignal').className = 'hidden'; };
        n.onerror = function () { $('nosignal').className = ''; };
        n.src = '/game.jpg?t=' + Date.now();
      };
      tick(); stillTimer = setInterval(tick, 1000);
    };
    img.onload = function () { $('nosignal').className = 'hidden'; };
    img.onerror = function () { img.onerror = null; stillTimer = null; stills(); setTimeout(function () { if (stillTimer) { clearInterval(stillTimer); stillTimer = null; startStill(); } }, 60000); };
    img.src = '/game.mjpg?t=' + Date.now();
    stillTimer = 'mjpg';
  }
  function stopStill() { if (stillTimer && stillTimer !== 'mjpg') clearInterval(stillTimer); stillTimer = null; $('still').src = ''; $('still').style.display = 'none'; }
  function startVideo(src) {
    if (OBS) return;
    if (vid) vid.parentNode.removeChild(vid);
    // a fresh element per tune: reusing one across src changes can wedge webOS's pipeline
    vid = document.createElement('video');
    vid.autoplay = true; vid.setAttribute('playsinline', '');
    vid.src = src;
    vid.addEventListener('playing', function () { stopStill(); $('nosignal').className = 'hidden'; });
    vid.addEventListener('error', function () { S.videoOk = false; startStill(); });
    $('vidwrap').insertBefore(vid, $('vidtag'));
    var p = vid.play(); if (p && p.catch) p.catch(function () { vid.muted = true; vid.play(); });
  }
  function checkVideo() {
    var v = (S.feed || {}).video || {};
    var watching = vid && !vid.paused && vid.readyState >= 2 && !vid.error;
    if (v.ok && v.hls && !watching && S.videoOk !== true) { S.videoOk = true; startVideo(v.hls + '?t=' + Date.now()); }
    else if (v.ok && vid && (vid.error || (vid.readyState < 2 && S.videoStall++ > 6))) { S.videoStall = 0; startVideo(v.hls + '?t=' + Date.now()); }
    else if (!v.ok) { S.videoOk = null; if (vid) { vid.parentNode.removeChild(vid); vid = null; } startStill(); }
    if (vid && vid.readyState >= 2) S.videoStall = 0;
  }
  S.videoStall = 0;
  // the pip mirrors live video while the stage shows the studio
  function pipVideo() {
    if (OBS) { $('pip').innerHTML = '<div class="th"><div class="plate"><b>LIVE</b><i>' + esc(ctx().sl.fort || '') + '</i></div></div>'; return; }
    $('pip').innerHTML = '<img class="vid" alt="">';
    var img = $('pip').firstChild;
    img.onerror = function () { img.style.visibility = 'hidden'; };
    img.onload = function () { img.style.visibility = ''; };
    var t = function () { if (img.parentNode) { img.src = '/game.jpg?t=' + Date.now(); setTimeout(t, 1500); } };
    t();
  }


  // ------------------------------------------------------------ sound (synthesised, no files)
  // News music and stingers, plus a talking-head "voice": soft pitched blips while a
  // caption types, a different pitch per speaker. Down on the remote mutes/unmutes.
  // ?mute=1 starts muted (the OBS scene already has the game's sound).
  var SFX = (function () {
    var AC = window.AudioContext || window.webkitAudioContext;
    var ac = null, master = null, bedGain = null, muted = Q.mute === '1' || OBS;
    try { var sv = localStorage.getItem('dnn.muted'); if (sv === '1') muted = true; if (sv === '0' && !OBS) muted = false; } catch (e) { /* ignore */ }
    function ctx() {
      if (!AC) return null;
      if (!ac) {
        ac = new AC();
        master = ac.createGain(); master.gain.value = muted ? 0 : 0.8; master.connect(ac.destination);
      }
      if (ac.state === 'suspended' && ac.resume) ac.resume();
      return ac;
    }
    function tone(freq, t0, dur, type, vol, dest) {
      var o = ac.createOscillator(), g = ac.createGain();
      o.type = type || 'sine'; o.frequency.setValueAtTime(freq, t0);
      g.gain.setValueAtTime(0.0001, t0);
      g.gain.exponentialRampToValueAtTime(vol, t0 + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
      o.connect(g); g.connect(dest || master);
      o.start(t0); o.stop(t0 + dur + 0.05);
      return o;
    }
    function brass(freq, t0, dur, vol) {   // sawtooth through a lowpass: cheap TV-news brass
      var f = ac.createBiquadFilter(); f.type = 'lowpass'; f.frequency.setValueAtTime(400, t0);
      f.frequency.linearRampToValueAtTime(2400, t0 + 0.08); f.frequency.linearRampToValueAtTime(900, t0 + dur);
      f.connect(master);
      tone(freq, t0, dur, 'sawtooth', vol, f); tone(freq * 1.005, t0, dur, 'sawtooth', vol * 0.7, f);
    }
    function boom(t0, vol) {   // timpani-ish hit
      var o = ac.createOscillator(), g = ac.createGain();
      o.type = 'sine'; o.frequency.setValueAtTime(110, t0); o.frequency.exponentialRampToValueAtTime(42, t0 + 0.6);
      g.gain.setValueAtTime(vol, t0); g.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.9);
      o.connect(g); g.connect(master); o.start(t0); o.stop(t0 + 1);
    }
    var api = {
      sting: function () {   // BREAKING NEWS
        if (!ctx()) return; var t = ac.currentTime + 0.05;
        boom(t, 0.9); brass(293.7, t, 0.32, 0.18); brass(220, t + 0.36, 0.32, 0.18); brass(293.7, t + 0.72, 1.3, 0.2); brass(370, t + 0.72, 1.3, 0.12);
        boom(t + 0.72, 0.7);
      },
      bump: function () {    // into and out of the break
        if (!ctx()) return; var t = ac.currentTime + 0.05;
        [523.3, 659.3, 784, 1046.5].forEach(function (f, i) { tone(f, t + i * 0.14, 0.5, 'triangle', 0.12); });
        tone(261.6, t, 0.9, 'sine', 0.12);
      },
      whoosh: function () {  // stage change
        if (!ctx()) return; var t = ac.currentTime + 0.02;
        var n = ac.createBufferSource(), b = ac.createBuffer(1, Math.floor(ac.sampleRate * 0.5), ac.sampleRate), d = b.getChannelData(0);
        for (var i = 0; i < d.length; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / d.length);
        n.buffer = b;
        var f = ac.createBiquadFilter(); f.type = 'bandpass'; f.Q.value = 1.2;
        f.frequency.setValueAtTime(300, t); f.frequency.exponentialRampToValueAtTime(3000, t + 0.4);
        var g = ac.createGain(); g.gain.value = 0.18;
        n.connect(f); f.connect(g); g.connect(master); n.start(t);
      },
      voice: function (pid) {   // one syllable from the person speaking
        if (!ctx() || pid == null) return;
        var h = 0, k = String(pid); for (var i = 0; i < k.length; i++) h = (h * 31 + k.charCodeAt(i)) % 997;
        var base = 110 + (h % 9) * 18, t = ac.currentTime;
        var lp = ac.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 900 + (h % 5) * 150; lp.connect(master);
        tone(base * (0.9 + Math.random() * 0.35), t, 0.09, 'square', 0.035, lp);
      },
      bed: function () {     // quiet looping newsroom pulse under the show
        if (!ctx() || bedGain) return;
        bedGain = ac.createGain(); bedGain.gain.value = 0.05; bedGain.connect(master);
        var notes = [146.8, 146.8, 174.6, 130.8], step = 0;
        var loop = function () {
          var t = ac.currentTime + 0.05, f = notes[step++ % notes.length];
          tone(f, t, 1.9, 'triangle', 0.5, bedGain); tone(f * 1.5, t, 1.9, 'sine', 0.25, bedGain);
          for (var j = 0; j < 4; j++) tone(f * 4, t + j * 0.5, 0.08, 'sine', j % 2 ? 0.1 : 0.15, bedGain);
          setTimeout(loop, 2000);
        };
        loop();
      },
      duck: function (on) { if (bedGain && ac) bedGain.gain.setTargetAtTime(on ? 0.02 : 0.05, ac.currentTime, 0.3); },
      toggle: function () {
        muted = !muted;
        try { localStorage.setItem('dnn.muted', muted ? '1' : '0'); } catch (e) { /* ignore */ }
        if (ctx()) master.gain.setTargetAtTime(muted ? 0 : 0.8, ac.currentTime, 0.05);
        var el = $('mute'); el.textContent = muted ? 'SOUND OFF \u00b7 press \u25BC' : 'SOUND ON'; el.className = 'show';
        clearTimeout(api.mt); api.mt = setTimeout(function () { el.className = ''; }, 2500);
      },
      state: function () { return { ac: ac ? ac.state : 'none', muted: muted }; }
    };
    return api;
  })();
  window.DNN_SFX = SFX;

  // ------------------------------------------------------------ the screen
  function setStage(which) {
    ['vidwrap', 'studio', 'split', 'card'].forEach(function (id) { $(id).className = 'layer' + (id === which ? '' : ' hidden'); });
  }
  function setLower(slug, head, slugClass) {
    $('slug').textContent = slug || 'DNN';
    $('slug').className = slugClass || '';
    $('head').textContent = head || '';
    $('head').className = slugClass === 'breaking' ? 'breaking' : '';
  }
  function talking(pid, on) {
    var els = document.querySelectorAll('.th');
    for (var i = 0; i < els.length; i++) {
      var me = pid != null && els[i].getAttribute('data-pid') === String(pid);
      els[i].className = 'th' + (on && me ? ' talking' : '');
    }
    var a = $('splitA'), b = $('splitB');
    [a, b].forEach(function (box) { var th = box.querySelector('.th'); box.className = 'box' + (th && on && th.getAttribute('data-pid') === String(pid) ? ' on' : ''); });
  }

  // a beat: {who: person|null, text, stage, slug, head, slugClass, card, layout}
  function show(beat, done) {
    S.beat = beat;
    var who = beat.who;
    if (beat.stage === 'studio') { $('studiohead').innerHTML = headHTML(beat.studio || who); setStage('studio'); }
    else if (beat.stage === 'split') { $('splitA').innerHTML = headHTML(beat.left); $('splitB').innerHTML = headHTML(beat.right); $('splitvs').textContent = beat.vs || ''; setStage('split'); }
    else if (beat.stage === 'card') { if (/class="bumper"/.test(beat.card || '') && S.lastCard !== beat.card) SFX.bump(); $('card').innerHTML = beat.card || ''; setStage('card'); }
    else setStage('vidwrap');
    if (beat.stage !== S.lastStage && beat.stage !== 'card') SFX.whoosh();
    S.lastStage = beat.stage; S.lastCard = beat.stage === 'card' ? beat.card : null;
    // pip: the speaker while video is on stage, otherwise the live picture
    if (beat.stage === 'video' && who) $('pip').innerHTML = headHTML(who);
    else if (!$('pip').querySelector('img.vid') || OBS) pipVideo();
    setLower(beat.slug, beat.head, beat.slugClass);
    $('who').textContent = who ? who.name : (beat.voice || '');
    var text = beat.text || '', i = 0, el = $('line');
    el.textContent = '';
    var pid = who ? (who.id == null ? who.name : who.id) : null;
    talking(pid, true);
    var hold = Math.max(2600, text.split(' ').length * 260) + (beat.extra || 0);
    clearInterval(S.typer); clearTimeout(S.holdT);
    var finish = function () {
      clearInterval(S.typer); clearTimeout(S.holdT); el.textContent = text; talking(pid, false);
      S.skip = null; done();
    };
    var lastBlip = 0;
    SFX.duck(!!who);
    S.typer = setInterval(function () {
      i += 2; el.textContent = text.slice(0, i);
      if (who && i - lastBlip >= 3 && /[aeiouy]/i.test(text.charAt(i - 1))) { lastBlip = i; SFX.voice(pid); }
      if (i >= text.length) { clearInterval(S.typer); talking(pid, false); S.holdT = setTimeout(finish, hold); }
    }, 55);
    S.skip = finish;
  }

  function stinger(cb) {
    SFX.sting();
    var st = $('stinger');
    st.className = '';
    // restart the CSS animations
    var kids = st.children; for (var i = 0; i < kids.length; i++) { kids[i].style.animation = 'none'; void kids[i].offsetWidth; kids[i].style.animation = ''; }
    setTimeout(function () { st.className = 'hidden'; cb(); }, 2400);
  }

  // ------------------------------------------------------------ cards (full-stage graphics)
  function arrow(k, v) {
    var p = S.prevStocks && S.prevStocks[k];
    if (p == null || v == null || p === v) return '<em class="flat">\u25C6</em>';
    return v > p ? '<em class="up">\u25B2</em>' : '<em class="down">\u25BC</em>';
  }
  function marketsCard() {
    var s = (((S.feed || {}).stocks) || {}).stocks || {};
    var keys = ['drinks', 'meals', 'meat', 'plants', 'seeds', 'gems', 'bars', 'stone', 'wood', 'leather', 'cloth', 'eggs'];
    var h = '<div class="ctitle"><small>DNN MONEY \u00b7 STOCKPILE MARKETS</small>THE ALE INDEX</div><div class="tiles">';
    keys.forEach(function (k) { if (s[k] != null) h += '<div class="tile"><b>' + k + '</b><span>' + s[k].toLocaleString() + ' ' + arrow(k, s[k]) + '</span></div>'; });
    return h + '</div>';
  }
  function weatherCard() {
    var wx = ((S.feed || {}).state || {}).weather || {}, kind = wx.kind || 'clear';
    var art = '';
    if (kind === 'rain' || kind === 'snow') {
      art = '<div class="cloud"></div>';
      for (var i = 0; i < 14; i++) art += '<i class="' + (kind === 'rain' ? 'drop' : 'flake') + '" style="left:' + (60 + i * 22) + 'px;top:' + (240 + (i % 3) * 20) + 'px;animation-delay:' + (i % 5) * 0.2 + 's"></i>';
    } else art = '<div class="sun"></div>';
    return '<div class="ctitle"><small>DNN WEATHER CENTER \u00b7 SURFACE CONDITIONS</small>' + esc(wx.season || 'THE WEATHER') + '</div>' +
      '<div class="wx">' + art + '</div><div class="wxtext"><b>' + esc(kind === 'none' ? 'clear' : kind) + '</b><span>' +
      (wx.amount != null ? Math.round(wx.amount * 100) + '% of the sky \u00b7 ' : '') + 'underground: dry, as always</span></div>';
  }
  function bumperCard(sub) { return '<div class="bumper"><div class="big">DNN</div><div class="sub">' + esc(sub || 'Dwarf News Network') + '</div></div>'; }
  function listCard(title, sub, rows) {
    var h = '<div class="ctitle"><small>' + esc(sub) + '</small>' + esc(title) + '</div><div class="list">';
    rows.slice(0, 8).forEach(function (r) { h += '<div><b>' + esc(r[0]) + '</b>' + esc(r[1]) + '</div>'; });
    return h + '</div>';
  }

  // ------------------------------------------------------------ segments
  function A() { return castPerson(0); } function B() { return castPerson(1); } function R() { return castPerson(2); }
  function P1() { return castPerson(3); } function P2() { return castPerson(4); }
  function beatsFrom(list) { return list.filter(function (b) { return b && b.text; }); }

  var SEG = {};
  SEG.open = function () {
    var cx = ctx(), fort = (cx.sl.fort || 'THE FORT').toUpperCase();
    return beatsFrom([{ who: A(), text: line('open', null, cx), stage: 'studio', slug: 'DNN LIVE', slugClass: 'live', head: 'LIVE FROM ' + fort }]);
  };
  SEG.close = function () {
    var cx = ctx();
    return beatsFrom([{ who: A(), text: line('close', null, cx), stage: 'studio', slug: 'DNN', head: 'THANKS FOR WATCHING DNN' }]);
  };
  function story(kind, sl, slug, slugClass, text) {
    var cx = ctx(sl);
    var L = (S.copy || {}).breaking || {};
    var k = L[kind] ? kind : 'generic';
    var hd = choose((L[k] || {}).heads, cx), rd = choose((L[k] || {}).reads, cx);
    var rc = line('reaction', k, cx);
    var head = hd ? fill(hd.text, cx) : (text || '').toUpperCase();
    var beats = [];
    beats.push({ who: A(), text: rd ? fill(rd.text, cx) : text, stage: 'video', slug: slug, slugClass: slugClass, head: head });
    if (text && rd) beats.push({ who: null, voice: 'DNN WIRE', text: text, stage: 'video', slug: slug, slugClass: slugClass, head: head });
    if (rc) beats.push({ who: B(), text: rc, stage: 'studio', slug: slug, slugClass: slugClass, head: head });
    return beatsFrom(beats);
  }
  SEG.topstory = function () {
    var c = topStories();
    if (!c.length) return [];
    var tot = 0; c.forEach(function (s) { tot += s.w; });
    var r = Math.random() * tot, s = c[0];
    for (var i = 0; i < c.length; i++) { r -= c[i].w; if (r <= 0) { s = c[i]; break; } }
    return story(s.kind, s.sl, 'TOP STORY', '', s.text);
  };
  SEG.breaking = function (e) {
    return story(e.kind, e.sl, e.big ? 'BREAKING NEWS' : 'DEVELOPING STORY', e.big ? 'breaking' : 'dev', e.text);
  };
  function placeOf() {
    var st = (S.feed || {}).state || {}, t = st.tour && (st.tour.current || st.tour);
    var nm = t && (t.name || t.title), kind = String((t && (t.kind || t.type)) || '').toLowerCase();
    var map = [['tavern', 'tavern'], ['temple', 'temple'], ['library', 'library'], ['hospital', 'hospital'], ['guild', 'guildhall'],
      ['dining', 'dining'], ['barracks', 'barracks'], ['pen', 'pasture'], ['pasture', 'pasture'], ['depot', 'depot'],
      ['workshop', 'workshop'], ['forge', 'workshop'], ['furnace', 'workshop'], ['farm', 'farm'], ['dig', 'dig'],
      ['entrance', 'entrance'], ['pump', 'machine'], ['mist', 'machine'], ['windmill', 'machine']];
    var k = 'generic';
    var hay = kind + ' ' + String(nm || '').toLowerCase();
    for (var i = 0; i < map.length; i++) if (hay.indexOf(map[i][0]) >= 0) { k = map[i][1]; break; }
    return { place: nm || null, place_kind: k === 'generic' ? null : (kind || k), kind: k };
  }
  SEG.field = function () {
    var pl = placeOf(), g = guestPerson();
    var cx = ctx({ place: pl.place, place_kind: pl.place_kind, guest: g && g.name });
    var head = pl.place ? 'LIVE: ' + pl.place.toUpperCase() : 'LIVE ON THE SCENE';
    return beatsFrom([
      { who: A(), text: line('toss', null, cx), stage: 'studio', slug: 'LIVE', slugClass: 'live', head: head },
      { who: R(), text: line('field', pl.kind, cx) || line('field', 'generic', cx), stage: 'video', slug: 'LIVE', slugClass: 'live', head: head },
      { who: R(), text: line('field', 'generic', cx), stage: 'video', slug: 'LIVE', slugClass: 'live', head: head },
      { who: R(), text: line('toss_back', null, cx), stage: 'video', slug: 'LIVE', slugClass: 'live', head: head }
    ]);
  };
  SEG.interview = function () {
    var g = guestPerson();
    if (!g) return [];
    var u = g.unit || {}, prof = String(u.profession || '');
    var mood = /child|baby/i.test(prof) ? 'child' : /soldier|guard|captain|militia|lieutenant|wrestler|axe|sword|spear|hammer|bow|marks/i.test(prof) && Math.random() < 0.6 ? 'soldier'
      : (u.stress || 0) > 10000 ? 'stressed' : u.job && !/idle|sleep|no job|wander/i.test(u.job) && Math.random() < 0.35 ? 'busy'
      : (u.stress || 0) < -2000 ? 'happy' : 'neutral';
    var cx = ctx({ guest: g.name, guest_prof: prof ? prof.toLowerCase() : null, guest_job: u.job || null });
    var head = 'DNN SPEAKS TO ' + g.name.toUpperCase();
    var r = R();
    var base = { stage: 'split', left: r, right: g, vs: 'LIVE INTERVIEW', slug: 'LIVE INTERVIEW', slugClass: 'live', head: head };
    function b(who, text) { var o = {}; for (var k in base) o[k] = base[k]; o.who = who; o.text = text; return o; }
    return beatsFrom([
      { who: A(), text: line('segment', 'interview', cx), stage: 'studio', slug: 'LIVE INTERVIEW', slugClass: 'live', head: head },
      b(r, line('interview_q', null, cx)), b(g, line('interview_a', mood, cx)),
      b(r, line('interview_q', null, cx)), b(g, line('interview_a', mood, cx))
    ]);
  };
  SEG.markets = function () {
    var cx = ctx(), card = marketsCard();
    var beats = beatsFrom([
      { who: B(), text: line('segment', 'markets', cx), stage: 'studio', slug: 'DNN MONEY', head: 'THE ALE INDEX' },
      { who: B(), text: line('markets', null, cx), stage: 'card', card: card, slug: 'DNN MONEY', head: 'THE ALE INDEX' },
      { who: B(), text: line('markets', null, cx), stage: 'card', card: card, slug: 'DNN MONEY', head: 'THE ALE INDEX' }
    ]);
    S.prevStocks = ((((S.feed || {}).stocks) || {}).stocks) || S.prevStocks;
    try { localStorage.setItem('dnn.stocks', JSON.stringify(S.prevStocks)); } catch (e) { /* ignore */ }
    return beats;
  };
  SEG.weather = function () {
    var wx = ((S.feed || {}).state || {}).weather || {}, k = wx.kind === 'rain' ? 'rain' : wx.kind === 'snow' ? 'snow' : (!wx.kind || wx.kind === 'none' || wx.kind === 'clear') ? 'clear' : 'other';
    var cx = ctx(), card = weatherCard();
    return beatsFrom([
      { who: B(), text: line('segment', 'weather', cx), stage: 'studio', slug: 'WEATHER', head: 'DNN WEATHER CENTER' },
      { who: R(), text: line('weather', k, cx), stage: 'card', card: card, slug: 'WEATHER', head: 'DNN WEATHER CENTER' },
      { who: R(), text: line('weather', k, cx), stage: 'card', card: card, slug: 'WEATHER', head: 'DNN WEATHER CENTER' }
    ]);
  };
  SEG.bumper = function () {
    var cx = ctx();
    return beatsFrom([
      { who: A(), text: line('promo', null, cx), stage: 'studio', slug: 'COMING UP', head: 'STAY WITH US' },
      { who: null, voice: 'DNN', text: line('bumper', null, cx), stage: 'card', card: bumperCard('we\'ll be right back'), slug: 'DNN', head: 'WE\'LL BE RIGHT BACK' },
      { who: null, voice: 'SPONSOR', text: line('ads', null, cx), stage: 'card', card: bumperCard('a word from our sponsors'), slug: 'SPONSORED', head: 'A WORD FROM OUR SPONSORS' }
    ]);
  };
  SEG.crossfire = function () {
    var cx = ctx();
    var e = choose((S.copy || {}).debate, cx, 'debate');
    if (!e) return [];
    var a = P1(), b = P2(), topic = fill(e.topic, cx).toUpperCase();
    var head = 'TONIGHT: ' + topic;
    var beats = [{ who: A(), text: line('segment', 'crossfire', cx), stage: 'studio', slug: 'CROSSFIRE', head: head }];
    e.lines.forEach(function (ln, i) {
      beats.push({ who: i % 2 ? b : a, text: fill(ln, cx), stage: 'split', left: a, right: b, vs: topic, slug: 'CROSSFIRE', slugClass: 'breaking', head: head, extra: 400 });
    });
    return beatsFrom(beats);
  };
  SEG.sports = function () {
    var cx = ctx();
    return beatsFrom([
      { who: B(), text: line('segment', 'sports', cx), stage: 'studio', slug: 'DNN SPORTS', head: 'DNN SPORTS DESK' },
      { who: B(), text: line('sports', null, cx), stage: 'video', slug: 'DNN SPORTS', head: 'DNN SPORTS DESK' },
      { who: B(), text: line('sports', null, cx), stage: 'video', slug: 'DNN SPORTS', head: 'DNN SPORTS DESK' }
    ]);
  };
  SEG.world = function () {
    var cx = ctx();
    return beatsFrom([
      { who: A(), text: line('segment', 'world', cx), stage: 'studio', slug: 'WORLD', head: 'AROUND THE WORLD' },
      { who: A(), text: line('world', null, cx), stage: 'video', slug: 'WORLD', head: 'AROUND THE WORLD' },
      { who: B(), text: line('world', null, cx), stage: 'video', slug: 'WORLD', head: 'AROUND THE WORLD' }
    ]);
  };
  SEG.trade = function () {
    var f = S.feed || {}, tr = ((f.trade || {}).trades || []).slice(-1)[0];
    var cx = ctx({ caravan_civ: tr && tr.civ });
    var rows = ((f.trade || {}).trades || []).slice().reverse().map(function (t) {
      var r = t.result || {}; return [t.season + ' ' + t.year, (t.civ || 'a caravan') + ': gave ' + (r.gave || 0) + ', got ' + (r.got || 0)];
    });
    var card = rows.length ? listCard('THE TRADE DESK', 'DNN MONEY \u00b7 RECENT CARAVANS', rows) : bumperCard('the trade desk');
    return beatsFrom([
      { who: B(), text: line('segment', 'trade', cx), stage: 'studio', slug: 'DNN MONEY', head: 'THE TRADE DESK' },
      { who: B(), text: line('trade', null, cx), stage: 'card', card: card, slug: 'DNN MONEY', head: 'THE TRADE DESK' }
    ]);
  };
  SEG.works = function () {
    var w = (S.feed || {}).works || {}, built = w.built || [];
    var last = built.length ? built[built.length - 1] : null;
    var proj = last ? (last.name || last.title) : null;
    var cx = ctx({ project: proj });
    var rows = built.slice().reverse().map(function (b) { return [b.title || 'project', (b.name || '') + (b.workers && b.workers.length ? ' \u00b7 by ' + b.workers[0] : '')]; });
    ((w.deep || {}).log || []).slice().reverse().forEach(function (l) { rows.push(['DEEP DIG', l.text]); });
    var card = rows.length ? listCard('BUILDING THE FORT', 'DNN \u00b7 PROJECTS DESK', rows) : bumperCard('the projects desk');
    return beatsFrom([
      { who: A(), text: line('segment', 'works', cx), stage: 'studio', slug: 'PROJECTS', head: 'BUILDING THE FORT' },
      { who: R(), text: line('works', null, cx), stage: 'card', card: card, slug: 'PROJECTS', head: 'BUILDING THE FORT' }
    ]);
  };
  SEG.banter = function () {
    var cx = ctx();
    var e = choose((S.copy || {}).banter, cx, 'ab');
    if (!e) return [];
    var head = 'DNN TONIGHT';
    return beatsFrom([
      { who: A(), studio: A(), text: fill(e.a, cx), stage: 'studio', slug: 'DNN', head: head },
      { who: B(), studio: B(), text: fill(e.b, cx), stage: 'studio', slug: 'DNN', head: head }
    ]);
  };

  var RUNDOWN = ['open', 'topstory', 'field', 'markets', 'interview', 'bumper', 'crossfire', 'weather', 'sports',
    'topstory', 'world', 'banter', 'trade', 'bumper', 'interview', 'field', 'works', 'crossfire', 'banter', 'close'];
  var LABEL = { open: 'Top of the hour', topstory: 'Top story', field: 'Live: field report', markets: 'The Ale Index', interview: 'Live interview',
    bumper: 'Break', crossfire: 'Crossfire', weather: 'Weather', sports: 'Sports desk', world: 'World news', banter: 'At the desk',
    trade: 'Trade desk', works: 'Projects desk', close: 'Sign-off' };
  function drawRundown() {
    var h = '';
    for (var i = 0; i < 3; i++) h += '<li>' + esc(LABEL[RUNDOWN[(S.seg + i) % RUNDOWN.length]]) + '</li>';
    $('rundown').innerHTML = h;
  }
  function drawAle() {
    var s = (((S.feed || {}).stocks) || {}).stocks || {}, p = S.prevStocks || {};
    var h = '';
    ['drinks', 'meals', 'meat', 'gems'].forEach(function (k) {
      if (s[k] == null) return;
      var d = p[k] == null ? '' : s[k] > p[k] ? ' <em class="up">\u25B2</em>' : s[k] < p[k] ? ' <em class="down">\u25BC</em>' : '';
      h += '<div><b>' + k + '</b><span>' + s[k].toLocaleString() + '</span>' + d + '</div>';
    });
    $('aleindex').innerHTML = h;
  }

  // ------------------------------------------------------------ the show loop
  function nextSegment() {
    if (S.breaking.length && Date.now() - S.lastBreak > 45000) {
      var e = S.breaking.shift();
      S.lastBreak = Date.now();
      var bb = SEG.breaking(e);
      if (bb.length) { stinger(function () { play(bb, nextSegment); }); return; }
    }
    if (RUNDOWN[S.seg] === 'open') S.issueUsed = {};
    var name = RUNDOWN[S.seg];
    S.seg = (S.seg + 1) % RUNDOWN.length;
    drawRundown();
    var beats = [];
    try { beats = SEG[name](); } catch (err) { console.log('segment ' + name + ' failed: ' + err); }
    if (!beats.length) { setTimeout(nextSegment, 50); return; }
    play(beats, nextSegment);
  }
  function play(beats, done) {
    var i = 0;
    var step = function () {
      // breaking news cuts in between lines
      if (S.breaking.length && S.beat && S.beat.slug !== 'BREAKING NEWS' && Date.now() - S.lastBreak > 45000 && S.breaking[0].big) { done(); return; }
      if (i >= beats.length) { done(); return; }
      show(beats[i++], step);
    };
    step();
  }

  // ------------------------------------------------------------ ticker
  var TK = { x: 0, w: 0, last: 0 };
  function buildTicker() {
    var items = [];
    S.justIn.splice(0, 6).forEach(function (e) { items.push('<span class="hot">JUST IN: ' + esc(e.text) + '</span>'); });
    var st = (S.feed || {}).state || {};
    (st.events || []).slice(0, 5).forEach(function (ev) { var t = clean(ev.text); if (t && !/^\[|DFHack|Watchdog/.test(t)) items.push('<span>' + esc(t) + '</span>'); });
    var cx = ctx();
    for (var i = 0; i < 8; i++) { var l = line('ticker', null, cx); if (l) items.push('<span>' + esc(l) + '</span>'); }
    if (!items.length) items.push('<span>DNN: Dwarf News Network. All the news that fits, carved in stone.</span>');
    for (var j = items.length - 1; j > 0; j--) { var r = rnd(j + 1); var t2 = items[j]; items[j] = items[r]; items[r] = t2; }
    var tr = $('ttrack');
    tr.innerHTML = items.join('');
    TK.w = tr.offsetWidth; TK.x = tr.parentNode.offsetWidth;
  }
  function tickerFrame(ts) {
    var dt = TK.last ? Math.min(100, ts - TK.last) : 16; TK.last = ts;
    TK.x -= dt * 0.12;
    if (TK.x < -TK.w) buildTicker();
    $('ttrack').style.transform = 'translate3d(' + Math.round(TK.x) + 'px,0,0)';
    requestAnimationFrame(tickerFrame);
  }

  // ------------------------------------------------------------ data
  function onFeed(f) {
    if (!f || !f.state) return;
    S.feed = f;
    var st = f.state, fort = st.fort || {};
    $('bugfort').textContent = fort.name ? fort.name + (fort.dwarvish ? ' \u00b7 ' + fort.dwarvish : '') : 'DWARF NEWS NETWORK';
    $('fortdate').textContent = fort.month ? fort.day + ' ' + fort.month + ' ' + fort.year : '';
    $('pop').textContent = fort.population ? 'POP ' + fort.population : '';
    var evs = (st.big || []).slice().sort(function (a, b) { return a.id - b.id; });
    if (S.lastEvt == null) {
      S.lastEvt = evs.length ? evs[evs.length - 1].id : 0;
      try { var le = +localStorage.getItem('dnn.lastEvt'); if (le && le < S.lastEvt && S.lastEvt - le < 50) S.lastEvt = le; } catch (e) { /* ignore */ }
    }
    evs.forEach(function (ev) {
      if (ev.id <= S.lastEvt) return;
      S.lastEvt = ev.id;
      var e = classify(ev);
      if (e.kind === 'skip') return;
      if (e.big) S.breaking.push(e); else S.justIn.push(e);
    });
    if (S.breaking.length > 4) S.breaking = S.breaking.slice(-4);
    if (S.justIn.length > 20) S.justIn = S.justIn.slice(-20);
    try { localStorage.setItem('dnn.lastEvt', String(S.lastEvt)); } catch (e) { /* ignore */ }
    drawAle();
    checkVideo();
  }
  function pollFeed() { getJSON('/feed.json', function (f) { onFeed(f); setTimeout(pollFeed, 5000); }); }
  function loadCopy(cb) { getJSON('/copy.json', function (c) { if (c) S.copy = c; if (cb) cb(); }); }

  // ------------------------------------------------------------ remote
  document.addEventListener('keydown', function (ev) {
    var k = ev.keyCode;
    if (k === 461 || k === 27) { ev.preventDefault(); window.close(); return; }   // TV Back: leave DNN
    if (k === 40 || k === 77) { ev.preventDefault(); SFX.toggle(); return; }       // Down (or M): sound on/off
    if ((k === 13 || k === 39) && S.skip) { ev.preventDefault(); S.skip(); }
    if (k === 37 && S.beat) { ev.preventDefault(); clearInterval(S.typer); clearTimeout(S.holdT); var b = S.beat, s = S.skip; show(b, function () { if (s) s(); }); }
  });

  try { S.prevStocks = JSON.parse(localStorage.getItem('dnn.stocks') || 'null'); } catch (e) { S.prevStocks = null; }
  window.DNN = S;   // for debugging over CDP
  getJSON('/feed.json', function (f) {
    onFeed(f);
    loadCopy(function () {
      if (!OBS) startStill();
      buildTicker(); requestAnimationFrame(tickerFrame);
      SFX.bed();
      nextSegment();
      setTimeout(pollFeed, 5000);
      setInterval(loadCopy, 15 * 60000);
      setInterval(function () { var d = new Date(); $('tclock').textContent = ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2); }, 1000);
    });
  });
})();
