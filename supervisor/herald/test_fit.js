// Offline mismatch test for the broadsheet: runs real gamelog announcements through overlay.html's own selection code
// (evFacts/itemCat/fits/choose/eventText, extracted from the page) and flags every printed template whose words assume a
// different item, material, death cause, mood or mineral than the event.  Usage (from supervisor/):
//   node herald/test_fit.js [corpus.json] [--before] [--show N]
// corpus.json: [{type, text}] (default: herald/test_corpus.json, built from gamelog.txt plus synthetic strings).
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const SUP = path.resolve(__dirname, '..');
const args = process.argv.slice(2), BEFORE = args.includes('--before'), SHOW = +(args[args.indexOf('--show') + 1] || 0) || 0;
const SAMPLE = args.includes('--sample') ? new RegExp(args[args.indexOf('--sample') + 1], 'i') : null;
const corpusPath = args.find(a => a.endsWith('.json')) || path.join(__dirname, 'test_corpus.json');
const html = fs.readFileSync(process.env.OVERLAY || path.join(SUP, 'overlay.html'), 'utf8');
const cut = (a, b) => { const i = html.indexOf(a), j = html.indexOf(b, i); if (i < 0 || j < 0) throw new Error('marker ' + a); return html.slice(i, j); };
const line = re => { const m = html.match(re); if (!m) throw new Error('line ' + re); return m[0]; };
// the page's own code
const src = [
  line(/^const esc = .*$/m), line(/^const clean = .*$/m), line(/^const cap = .*$/m), line(/^function rng\(seed\).*$/m),
  line(/^const pick = .*$/m), line(/^function shuffle\(r, a\).*$/m),
  'let LIB = {}, SEEN = {}, issueUsed = new Set();', line(/^const NEWSY = .*$/m), 'const TESTPAGE = true; const __seen = []; function markSeen(ids) { __seen.push(...ids); }',
  'let memLoaded = false; function mem() { return {arcs: {}}; } function context(r) { return __baseCtx(); }',
  'const ownName = s => s;',
  cut('// ==FIT-BEGIN==', 'const T = x =>'), line(/^const T = x =>.*$/m),
  cut('const KINDS = [', 'function drawEvent('),
].join('\n');
// library, merged the way overlay.py does
const LIBD = path.join(SUP, 'herald', 'library'), lib = {};
const merge = (a, b) => { for (const [k, v] of Object.entries(b)) { if (Array.isArray(a[k]) && Array.isArray(v)) a[k] = a[k].concat(v); else if (a[k] && typeof a[k] === 'object' && !Array.isArray(a[k]) && v && typeof v === 'object' && !Array.isArray(v)) merge(a[k], v); else a[k] = v; } };
for (const f of fs.readdirSync(LIBD).filter(f => f.endsWith('.json')).sort()) merge(lib, JSON.parse(fs.readFileSync(path.join(LIBD, f), 'utf8')));
const baseCtx = () => ({sl: {fort: 'Testfort', pop: 40, season: 'Spring', weather: 'clear', citizen: 'Urist Testson', citizen2: 'Kel Probe', citizen_first: 'Dodok', _people: ['Urist Testson', 'Kel Probe', 'Dodok Mock']}, conds: new Set(['spring', 'clear', 'peace'])});
const ctxv = {console, Math, JSON, Date, Set, Map, Object, Array, String, Number, RegExp, Boolean, Error};
vm.createContext(ctxv);
vm.runInContext(src + '\nLIB = __lib; var __api = {seen: __seen, evFacts, itemCat, itemMat, mineralClass, fits, choose, choose1, eventText, kindOf, T, evWho, evWho, setOff: v => { FIT_OFF = v; }, reset: () => { issueUsed = new Set(); }, evText, slotFacts, KINDS, ' +
  (html.includes('// ==SCENES-BEGIN==') ? 'pickScene, sceneText, SCENES' : 'pickScene: null, sceneText: null, SCENES: []') + '};', Object.assign(ctxv, {__lib: lib, __baseCtx: () => baseCtx()}));
const A = ctxv.__api;
A.setOff(BEFORE);
// ---- the independent checker: cue words in the TEMPLATE text vs the event's facts ----
const C = lib.itemcats;
const rx = l => new RegExp('(?<![A-Za-z])(?:' + l.join('|') + ')(?![A-Za-z])', 'i');
const ITEM = Object.fromEntries(Object.entries(C.cues).filter(([k]) => !k.startsWith('mat_')).map(([k, v]) => [k, rx(v)]));
const MAT = Object.fromEntries(Object.entries(C.cues).filter(([k]) => k.startsWith('mat_')).map(([k, v]) => [k, rx(v)]));
const DEATH = Object.fromEntries(Object.entries(C.deathcues).map(([k, v]) => [k, rx(v)]));
const MOODC = Object.fromEntries(Object.entries(C.moodcues).map(([k, v]) => [k, rx(v)]));
const MIN = {gem: rx(['gems?', 'gemstones?', 'jewels?', 'facet\\w*']), ore: rx(['ores?', 'smelt\\w*']), coal: rx(['coal', 'lignite', 'fuel']), cavern: rx(['caverns?', 'fungus forest']), magma: rx(['magma', 'lava'])};
const PAR = C.parents || {};
// specific nouns (same rule as tag_library.py): naming a throne means the item must be a throne
const syn = C.synonyms || {}, comp = C.compound || [], skip = new Set(C.nounskip || []);
const baseOf = n => { n = syn[n] || n; return comp.includes(n) ? n : (syn[n.split(' ').pop()] || n.split(' ').pop()); };
const NOUNW = {};
for (const l of Object.values(C.nouns)) for (const n of l) { const b = baseOf(n); if (skip.has(b) || skip.has(n)) continue; (NOUNW[b] = NOUNW[b] || new Set()).add(comp.includes(b) ? n : n.split(' ').pop()); }
for (const [s_, b] of Object.entries(syn)) if (NOUNW[b]) NOUNW[b].add(s_);
const NOUN_RX = Object.fromEntries(Object.entries(NOUNW).map(([b, ws]) => [b, rx([...ws].sort((x, y) => y.length - x.length).map(w => w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(?:s|es)?'))]));
// hand-reviewed generic entries (tag_library.py MANUAL) are exempt from the word scan
const manual = {}; { const py = fs.readFileSync(path.join(__dirname, 'tag_library.py'), 'utf8'); const blk = py.slice(py.indexOf('MANUAL = {'), py.indexOf('\n}', py.indexOf('MANUAL = {')));
  for (const m of blk.matchAll(/"([\w-]+)":\s*(\[[^\]]*\])/g)) manual[m[1]] = JSON.parse(m[2]); }
for (const [k, v] of Object.entries(JSON.parse(fs.readFileSync(path.join(__dirname, 'fit_manual.json'), 'utf8')))) if (!k.startsWith('_')) manual[k] = v;
// every adoption story and every non-butcher pet line is tagged by rule in tag_library.py; mirror that here
const byId = {}; (function walk(o) { if (Array.isArray(o)) o.forEach(walk); else if (o && typeof o === 'object') { if (o.id) byId[o.id] = o; else Object.values(o).forEach(walk); } })(lib);
const SKIPK = new Set(['id', 'when', 'fit', 'world', 'bg', 'who', 'pos', 'pose']);
const bare = e => { const out = []; (function w(v) { if (typeof v === 'string') out.push(v.replace(/\{\w+\}/g, ' ')); else if (Array.isArray(v)) v.forEach(w); else if (v && typeof v === 'object') for (const [k, x] of Object.entries(v)) if (!SKIPK.has(k)) w(x); })(e); return out.join(' '); };
function expand(facts) { const f = new Set(facts); for (const x of facts) if (PAR[x]) f.add(PAR[x]); const sh = C.shops || {}; for (const x of facts) if (x.startsWith('shop_') && sh[x.slice(5)]) sh[x.slice(5)].forEach(c => f.add(c)); return f; }
// returns a reason string when the template's own words contradict the facts
function contradiction(id, scope, facts, sceneFit) {
  const e = byId[id]; if (!e) return null;
  if (id.startsWith('lb-pet-') && scope === 'pet') return A.fits({fit: ['ev_adopt']}, facts) ? null : 'adoption story';
  if (id in manual) { const ok = A.fits({fit: manual[id]}, facts); return ok ? null : `manual fit ${manual[id]} vs ${[...facts]}`; }
  const t = bare(e), fx = expand(facts), bad = [];
  if (scope === 'item' || scope === 'scene') {
    const cats = Object.entries(ITEM).filter(([, r]) => r.test(t)).map(([k]) => k), mats = Object.entries(MAT).filter(([, r]) => r.test(t)).map(([k]) => k);
    if (cats.length && !cats.some(c => fx.has(c))) bad.push('item ' + cats.join('/'));
    if (mats.length && !mats.some(c => fx.has(c))) bad.push('material ' + mats.join('/'));
    let ns = Object.entries(NOUN_RX).filter(([, r]) => r.test(t)).map(([k]) => k); ns = ns.filter(x => !ns.some(y => y !== x && y.includes(x)));
    if (ns.length && !ns.some(x => fx.has('n_' + x))) bad.push('names ' + ns.join('/'));
  }
  if (scope === 'death') { const d = Object.entries(DEATH).filter(([, r]) => r.test(t)).map(([k]) => 'die_' + k); if (d.length && !d.some(c => fx.has(c))) bad.push('cause ' + d.join('/')); }
  if (scope === 'mood') { const d = Object.entries(MOODC).filter(([, r]) => r.test(t)).map(([k]) => 'mood_' + k); if (d.length && !d.some(c => fx.has(c))) bad.push('mood ' + d.join('/'));
    for (const [k, shops] of Object.entries({gem: ["Jeweler's Workshop"], cloth: ["Clothier's Shop", 'Loom'], leather: ['Leather Works', "Tanner's Shop"]})) if (ITEM[k].test(t) && !shops.some(s => fx.has('shop_' + s))) bad.push('mood demands ' + k); }
  if (scope === 'mineral') { const d = Object.entries(MIN).filter(([, r]) => r.test(t)).map(([k]) => k); if (d.length && !d.some(c => fx.has(c))) bad.push('mineral ' + d.join('/')); }
  if (scope === 'pet') { if (/adopt/i.test(t)) bad.push('adoption story for a death'); if (/\b(dog|puppy|good boy|bark|fetch|kennel)\b/i.test(t) && !fx.has('sp_dog')) bad.push('dog words'); if (/\b(cats?|kitten|purr)\b/i.test(t) && !fx.has('sp_cat')) bad.push('cat words');
    if (fx.has('die_slaughter') && /\b(mourn\w*|grie\w+|rest in peace|beloved|funeral|tears?)\b/i.test(t)) bad.push('mourning a slaughter'); }
  return bad.length ? bad.join('; ') : null;
}
const SCOPE = {master: 'item', artifact: 'item', mood: 'mood', death: 'death', strike: 'mineral', pet: 'pet'};
// ---- run ----
const corpus = JSON.parse(fs.readFileSync(corpusPath, 'utf8'));
const stats = {events: 0, outputs: 0, bad: 0, unparsed: 0, sceneBad: 0, fold: 0, foldBad: 0}, badList = [], unparsed = {}, byKind = {};
let n = 0;
for (const ev0 of corpus) {
  const ev = {id: 1000 + n++, type: ev0.type, text: ev0.text};
  const k = A.kindOf(ev); if (!k) continue;
  stats.events++;
  const fx = A.evFacts(ev);
  if (/MASTERPIECE|ARTIFACT/.test(ev.type) && fx.item && !A.itemCat(fx.item)) { stats.unparsed++; unparsed[fx.item] = (unparsed[fx.item] || 0) + 1; }
  for (let s = 0; s < 4; s++) {
    A.reset(); delete A.evText[ev.id];
    ev.id = 1000 + n * 10 + s;
    const L = (lib.kinds || {})[k.k] || {}, r = (() => { let a = ev.id * 7 + s; return () => { a = (a * 1103515245 + 12345) % 2147483648; return a / 2147483648; }; })();
    const ctx = baseCtx(), who = A.evWho(ev);
    const extra = {who, first: who ? who.split(' ')[0] : null, event: ev.text, item: fx.item, _facts: fx.facts};
    let got = [], texts = [], scene = null;
    if (BEFORE) {   // the old page: one fixed drawing per kind, every kind text eligible
      for (const part of ['heads', 'caps', 'reps', 'labels', 'kickers']) { const e = A.choose1(L[part], ctx, r, extra); if (e) { got.push(e.id); texts.push(part + ': ' + A.T(e)); } }
    } else {        // the live page's own eventText (drawing first, then its words)
      A.seen.length = 0;
      const t = A.eventText(ev, k); got = [...A.seen]; scene = t.scene;
      texts = ['scene: ' + (scene ? scene.id : '-'), 'head: ' + t.head, 'cap: ' + t.cap, 'label: ' + t.label, 'say: ' + t.say, 'rep: ' + t.rep, 'kicker: ' + t.kicker];
      if (scene && scene.fit && !A.fits({fit: scene.fit}, fx.facts)) { stats.sceneBad++; badList.push([ev.text, 'scene ' + scene.id, 'drawing fit ' + scene.fit]); }
    }
    if (SAMPLE && s === 0 && SAMPLE.test(ev.text)) console.log(['', '# ' + ev.text, '  facts: ' + [...fx.facts].join(','), ...texts.map(x => '  ' + x)].join('\n'));
    stats.outputs++;
    // scene words describe their own drawing (props included); the scene itself must fit the facts (checked above)
    const reasons = got.filter(id => !id.startsWith('sc-')).map(id => [id, contradiction(id, SCOPE[k.k], fx.facts)]).filter(x => x[1]);
    if (scene && !scene.id.startsWith('k-')) { const own = new Set(((lib.scenes || {})[scene.id] ? Object.values(lib.scenes[scene.id]).flat().map(e => e.id) : [])); for (const id of got.filter(i => i.startsWith('sc-'))) if (!own.has(id)) reasons.push([id, 'scene text from another drawing']); }
    byKind[k.k] = byKind[k.k] || {out: 0, bad: 0}; byKind[k.k].out++;
    if (reasons.length) { stats.bad++; byKind[k.k].bad++; badList.push([ev.text, reasons.map(x => x[0]).join(','), reasons.map(x => x[1]).join(' | ') + '  facts=' + [...fx.facts].join(',')]); }
  }
  // fold entries that name the item/cause through a slot
  const sl = {};
  if (k.k === 'master' && fx.item) Object.assign(sl, {masterwork: fx.item, masterwright: 'Urist Testson', masterwork_last: fx.item, masterwright_last: 'Urist Testson'});
  if (k.k === 'artifact' && fx.item) Object.assign(sl, {artifact_item: fx.item, artifact_new_item: fx.item, artifact: 'Testname', artifact_new: 'Testname', artifact_maker: 'Urist Testson', moodname: 'Urist Testson', moody: 'Urist Testson'});
  if (k.k === 'death') { const m = ev.text.match(/^[^,]+,\s*(.+?) has (.+?)[.!]*$/); if (m) Object.assign(sl, {cause: m[2], lastdead_cause: m[2], deadname: 'Urist Testson', prof: m[1].toLowerCase(), lastdead: 'Urist Testson'}); }
  if (k.k === 'strike') { const m = ev.text.match(/struck (.+?)!/); if (m) sl.mineral = m[1]; }
  if (Object.keys(sl).length) {
    const lists = [];
    (function walk(o, p) { if (Array.isArray(o)) { if (o.some(e => e && e.id && /\{(masterwork|masterwork_last|artifact_item|artifact_new_item|cause|lastdead_cause|mineral)\}/.test(JSON.stringify(e)))) lists.push([p, o]); else o.forEach(x => walk(x, p)); } else if (o && typeof o === 'object' && !o.id) for (const [kk, v] of Object.entries(o)) if (kk !== 'kinds' && kk !== 'itemcats' && kk !== 'scenes') walk(v, p + '.' + kk); })(lib, '');
    for (const [p, list] of lists) {
      A.reset();
      const ctx = baseCtx(); Object.assign(ctx.sl, sl, {lore: 1, past_fort: 'Oldfort', past_fort_fate: 'fell', record: 'x', record_fort: 'Oldfort', liaison: 'Liaison', civ: 'Civ', enemy: 'Gobs', enemy_race: 'goblin', site: 'Site', source: 'a traveller', hf: 'Someone', region: 'Region', ago: 'last year', site_kind: 'town', entity: 'Ent', fort_days: 100});
      ['has_past_fort', 'at_war', 'artifact_week', 'masterpiece_week', 'death_week', 'mood_done', 'recent_death', 'recent_masterpiece', 'recent_strike'].forEach(c => ctx.conds.add(c));
      const r = (() => { let a = n * 31 + p.length; return () => { a = (a * 1103515245 + 12345) % 2147483648; return a / 2147483648; }; })();
      for (const e of A.choose(list.filter(x => /\{(masterwork|masterwork_last|artifact_item|artifact_new_item|cause|lastdead_cause|mineral)\}/.test(JSON.stringify(x))), ctx, r, 3)) {
        stats.fold++;
        const sc = /\{(cause|lastdead_cause)\}/.test(JSON.stringify(byId[e.id])) ? 'death' : /\{mineral\}/.test(JSON.stringify(byId[e.id])) ? 'mineral' : 'item';
        const why = contradiction(e.id, sc, A.slotFacts(byId[e.id], sl));
        if (why) { stats.foldBad++; badList.push([ev.text, p + ' ' + e.id, why]); }
      }
    }
  }
}
console.log(BEFORE ? 'BEFORE (fit filter off)' : 'AFTER (fit filter on)', JSON.stringify(stats));
console.log('by kind', JSON.stringify(byKind));
const un = Object.entries(unparsed).sort((a, b) => b[1] - a[1]);
if (un.length) console.log('unparsed item nouns:', un.slice(0, 30).map(x => x[0]).join(' | '));
for (const b of badList.slice(0, SHOW)) console.log(' X', b[0].slice(0, 80), '=>', b[1], '::', b[2]);
process.exitCode = BEFORE ? 0 : (stats.bad + stats.foldBad + stats.sceneBad ? 1 : 0);   // unparsed nouns (DF's invented instruments) only get generic text
