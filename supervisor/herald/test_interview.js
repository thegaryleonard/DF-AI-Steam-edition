// Offline coherence test for the Society Pages interview: runs overlay.html's own interview code (==IV-BEGIN== block plus
// the library picker) on real citizens dumped from the live fort, and checks that every answer belongs to its question's
// topic, numbers come from live data, no raw DF job/thought codes leak, nothing repeats, and the headline is about the
// interview.  Usage (from supervisor/):  node herald/test_interview.js [citizens.json] [--show N] [--seeds N]
// citizens.json: an array of dfai-overlay-state unit cards (default herald/test_citizens.json; refresh it read-only with
// unit_card() over every citizen, see herald-overlay.md).
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const SUP = path.resolve(__dirname, '..');
const args = process.argv.slice(2), SHOW = +(args[args.indexOf('--show') + 1] || 0) || 0, SEEDS = +(args[args.indexOf('--seeds') + 1] || 0) || 3;
const citPath = args.find(a => a.endsWith('.json')) || path.join(__dirname, 'test_citizens.json');
const html = fs.readFileSync(process.env.OVERLAY || path.join(SUP, 'overlay.html'), 'utf8');
const cut = (a, b) => { const i = html.indexOf(a), j = html.indexOf(b, i); if (i < 0 || j < 0) throw new Error('marker ' + a); return html.slice(i, j); };
const line = re => { const m = html.match(re); if (!m) throw new Error('line ' + re); return m[0]; };
const src = [
  line(/^const esc = .*$/m), cut('const levels = [', 'const clean = '), line(/^const clean = .*$/m), line(/^const cap = .*$/m),
  line(/^const firstName = .*$/m), line(/^const an = .*$/m), line(/^function rng\(seed\).*$/m), line(/^const pick = .*$/m), line(/^function shuffle\(r, a\).*$/m),
  'let LIB = {}, SEEN = {}, issueUsed = new Set();', line(/^const NEWSY = .*$/m), 'const TESTPAGE = true; function markSeen() {}',
  'let memLoaded = false; function mem() { return {arcs: {}}; }', 'const ownName = s => s;',
  cut('// ==FIT-BEGIN==', 'const T = x =>'), line(/^const T = x =>.*$/m),
  cut('function mood(stress)', '// DF thought type'), cut('// ==IV-BEGIN==', '// ==IV-END=='),
].join('\n');
const LIBD = path.join(SUP, 'herald', 'library'), lib = {};
const merge = (a, b) => { for (const [k, v] of Object.entries(b)) { if (Array.isArray(a[k]) && Array.isArray(v)) a[k] = a[k].concat(v); else if (a[k] && typeof a[k] === 'object' && !Array.isArray(a[k]) && v && typeof v === 'object' && !Array.isArray(v)) merge(a[k], v); else a[k] = v; } };
for (const f of fs.readdirSync(LIBD).filter(f => f.endsWith('.json')).sort()) merge(lib, JSON.parse(fs.readFileSync(path.join(LIBD, f), 'utf8')));
const ctxv = {console, Math, JSON, Date, Set, Map, Object, Array, String, Number, RegExp, Boolean, Error};
vm.createContext(ctxv);
vm.runInContext(src + '\nLIB = __lib; var __api = {buildInterview, ivFacts, jobPhrase, reset: () => { issueUsed = new Set(); }};', Object.assign(ctxv, {__lib: lib}));
const A = ctxv.__api;
const cits = JSON.parse(fs.readFileSync(citPath, 'utf8').replace(/^[^[]*/, ''));
// the live fort's own numbers (Showerwheels when the fixture was dumped); past forts only through the lore slots
const pop = cits.length, soldiers = cits.filter(d => d.squad).length;
const PAST = ['Searabbeys', 'Quakefocus', 'Creaturemirrored'];
const fmt = v => Number(v).toLocaleString();
const SCEN = [   // condition sets the live fort can be in, with the slots they need
  {conds: ['peace', 'drinks_high', 'thread_glut', 'pop_big', 'old_fort', 'has_past_fort', 'herd_big'], sl: {}},
  {conds: ['at_war', 'drinks_low', 'food_low', 'pop_big', 'death_week', 'has_past_fort'], sl: {lastdead: 'Urist Lastson', lastdead_ago: '3 days ago'}},
  {conds: ['peace', 'caverns', 'young_fort', 'mood_open', 'migrants_week'], sl: {moody: 'Kogan Moodsmith', moody_shop: "Craftsdwarf's Workshop"}},
  {conds: ['peace', 'mood_done', 'caravan_here', 'birth_week', 'marriage_week', 'food_high'], sl: {artifact_new: 'Thedoorsofdawn', artifact_maker: 'Kogan Moodsmith', artifact_new_item: 'granite door'}},
  {conds: ['peace'], sl: {past_fort: null, record: null}},
];
const baseSl = s => Object.assign({fort: 'Showerwheels', pop, year: 130, month: 'Felsite', season: 'Early Summer', weather: 'heavy rain', world: 'The Enchanted Planes',
  drinks: fmt(2093), meals: fmt(412), thread: fmt(8042), herd: fmt(64), fort_days: 244, soldiers, squads: 12, citizen: 'Urist Testson', citizen2: 'Kel Probe',
  citizen_first: 'Dodok', _people: ['Urist Testson', 'Kel Probe', 'Dodok Mock'],
  past_fort: 'Searabbeys', past_fort_fate: 'is now occupied by The Torments of Hating (goblins)', past_fort_years: '5 years',
  record: '16,000 smoothing jobs queued for 3 smoothers', record_fort: 'Quakefocus', enemy: 'The Honest Wanderers', enemy_race: 'human', civ: 'The Chambers of Steel'}, s.sl);
const RAWCODE = /\b(WatchPerform|NeedsUnfulfilled|SatisfiedAtWork|ImproveSkill|AdmireBuilding|BedroomQuality|Syndrome|AcquireObject|CraftObject|BeWithFriends|BeExtravagant|watch perform)\b|\b[a-z]+[A-Z][a-z]+[A-Z]\w*/;
const stats = {interviews: 0, qas: 0, topicBad: 0, slotBad: 0, numBad: 0, rawBad: 0, dupBad: 0, headBad: 0, pastBad: 0, contraBad: 0, sizeBad: 0, crash: 0};
const bad = [], samples = [], topicUse = {}, variantUse = {};
let n = 0;
for (let si = 0; si < SCEN.length; si++) for (const d of cits) for (let s = 0; s < SEEDS; s++) {
  const sc = SCEN[si], sl = baseSl(sc), conds = new Set(sc.conds);
  const ctx = {sl, conds};
  let a = (++n * 2654435761 + s * 97 + si) >>> 0; const r = () => { a = (a * 1103515245 + 12345) % 2147483648; return a / 2147483648; };
  A.reset();
  let iv; try { iv = A.buildInterview(d, ctx, r); } catch (e) { stats.crash++; bad.push([d.name, 'crash', e.stack.split('\n').slice(0, 3).join(' ')]); continue; }
  stats.interviews++;
  const QA = lib.qa, texts = [iv.head, iv.deck, iv.pull, ...iv.QAs.flatMap(x => [x.q, x.a])], all = texts.join(' \u2016 ');
  const fail = (k, why) => { stats[k]++; bad.push([d.name.split(',')[0], k, why]); };
  // 1. every answer belongs to its question's topic, and the question allows that variant
  for (const x of iv.QAs) {
    stats.qas++; topicUse[x.topic] = (topicUse[x.topic] || 0) + 1; variantUse[x.topic + '.' + x.variant] = (variantUse[x.topic + '.' + x.variant] || 0) + 1;
    const q = (QA[x.topic].q || []).find(e => e.id === x.qid), an = ((QA[x.topic].a || {})[x.variant] || []).find(e => e.id === x.aid);
    if (!q || !an) fail('topicBad', `${x.topic}.${x.variant}: q ${x.qid} a ${x.aid}`);
    else if (q.for && !q.for.includes(x.variant)) fail('topicBad', `${x.qid} is for ${q.for} but variant is ${x.variant}`);
    else if (QA[x.topic].strict && !q.for && QA[x.topic].q.some(e => e.for && e.for.includes(x.variant))) fail('topicBad', `${x.qid} is generic but ${x.topic}.${x.variant} names its subject`);
  }
  // 2. no unfilled or junk slots
  if (/[{}]|\bundefined\b|\bnull\b|\bNaN\b|\[object/.test(all)) fail('slotBad', all.match(/.{0,30}([{}]|undefined|null|NaN|\[object).{0,30}/)[0]);
  // 3. every number comes from live data (this dwarf, this fort)
  const ok = new Set([String(d.age), String(d.born), ...Object.values(sl).filter(v => v != null && typeof v !== 'object').flatMap(v => String(v).match(/\d[\d,]*/g) || []),
    ...String(d.squad || '').match(/\d+/g) || [], ...(d.family || []).flatMap(f => f.name.match(/\d+/g) || [])]);
  for (const num of all.match(/\d[\d,]*\d|\d/g) || []) if (!ok.has(num)) fail('numBad', `${num} in: ${all.slice(0, 200)}`);
  // 4. no raw job / thought codes
  const job = String(d.job || '');
  if (RAWCODE.test(all) || (job && !/^(Idle|Sleep|Eat|Drink)$/.test(job) && all.includes(job))) fail('rawBad', (all.match(RAWCODE) || [job])[0]);
  // 5. nothing twice: one answer per topic, no repeated answer or sentence
  const tops = iv.QAs.map(x => x.topic), ans = iv.QAs.map(x => x.a);
  if (new Set(tops).size !== tops.length) fail('dupBad', 'topic twice: ' + tops);
  if (new Set(ans).size !== ans.length) fail('dupBad', 'answer twice');
  const sents = ans.flatMap(x => x.split(/(?<=[.!?])\s+/)).filter(x => x.length > 25);
  if (new Set(sents).size !== sents.length) fail('dupBad', 'sentence twice');
  // 6. the headline is about something in this interview
  if (!iv.head || !iv.headTopic || !tops.includes(iv.headTopic)) fail('headBad', `${iv.head} (${iv.headTopic}) not in ${tops}`);
  // 7. past forts only in the past-forts answer, and named as past
  for (const x of iv.QAs) for (const pf of PAST) if ((x.q + x.a).includes(pf) && x.topic !== 'past') fail('pastBad', `${pf} in ${x.topic}: ${x.a}`);
  // 8. no contradictions between answers about the same facts
  const V = Object.fromEntries(iv.QAs.map(x => [x.topic, x.variant]));
  if (V.needs === 'romance' && /spouse|lover/.test(V.family || '')) fail('contraBad', 'married and looking for romance');
  if (V.needs === 'family' && /none|orphan/.test(V.family || '')) fail('contraBad', 'no family but missing family');
  if (V.military && /soldier|drills/.test(V.work)) fail('contraBad', 'squad covered twice');
  if (d.squad && V.military && V.military !== 'in_squad') fail('contraBad', 'in a squad but answered as a civilian');
  if (!d.squad && /in_squad|soldier|drills/.test((V.military || '') + V.work)) fail('contraBad', 'not in a squad but answered as a soldier');
  if (V.needs === 'drink' && V.highlight === 'drunk') fail('contraBad', 'drink');
  // 9. fits the card: 3-7 questions (babies 3), and not a wall of text
  const len = all.length;
  if (iv.QAs.length < 3 || iv.QAs.length > 7 || len > 1250) fail('sizeBad', `${iv.QAs.length} QAs, ${len} chars`);
  if (samples.length < SHOW && s === 0 && n % 17 === 0) samples.push(iv);
}
console.log('citizens', cits.length, 'pop', pop, 'soldiers', soldiers, JSON.stringify(stats));
console.log('topics', JSON.stringify(topicUse));
console.log('variants', Object.keys(variantUse).length, JSON.stringify(variantUse));
for (const b of bad.slice(0, 25)) console.log(' X', b.join(' :: ').slice(0, 220));
for (const iv of samples) {
  console.log(`\n${iv.who.toUpperCase()}: ${iv.head}\n  ${iv.deck}`);
  for (const x of iv.QAs) console.log(`  Q [${x.topic}.${x.variant}] ${x.q}\n  A ${x.a}`);
  console.log(`  pull: "${iv.pull}"`);
}
const nbad = Object.entries(stats).filter(([k]) => !['interviews', 'qas'].includes(k)).reduce((a, [, v]) => a + v, 0);
process.exitCode = nbad || stats.interviews < 300 ? 1 : 0;
