// node test_auto_quality.js — verifica la logica di qualità adattiva del client
const assert = require('assert');
const fs = require('fs');

const html = fs.readFileSync(`${__dirname}/static/index.html`, 'utf8');
const src = html.match(/const BUSY_BYTES[\s\S]*?\nfunction autoNext[\s\S]*?\n}/)[0];
const autoNext = new Function(`${src}; return autoNext;`)();

const MAX = 4, TARGET = 20;
const BIG = 300000;   // traffico vero: lo schermo sta cambiando
const IDLE = 5000;    // quasi niente: schermo fermo

// schermo fermo → non si degrada mai, per quanti secondi passino
let s = { step: 0, slow: 0, good: 0 };
for (let i = 0; i < 20; i++) s = autoNext(2, IDLE, TARGET, s.step, s.slow, s.good, MAX);
assert.strictEqual(s.step, 0, 'schermo fermo non deve degradare');

// nessun frame → gradino invariato e contatore dei lenti azzerato
assert.deepStrictEqual(autoNext(0, 0, TARGET, 1, 2, 0, MAX), { step: 1, slow: 0, good: 0 });

// traffico vero ma pochi fps → degrada solo dopo 4 secondi, non subito
s = { step: 0, slow: 0, good: 0 };
for (let i = 0; i < 3; i++) s = autoNext(5, BIG, TARGET, s.step, s.slow, s.good, MAX);
assert.strictEqual(s.step, 0, 'tre secondi lenti non bastano');
s = autoNext(5, BIG, TARGET, s.step, s.slow, s.good, MAX);
assert.strictEqual(s.step, 1, 'al quarto secondo lento degrada');

// un secondo buono in mezzo azzera il conteggio
s = { step: 0, slow: 0, good: 0 };
for (let i = 0; i < 3; i++) s = autoNext(5, BIG, TARGET, s.step, s.slow, s.good, MAX);
s = autoNext(20, BIG, TARGET, s.step, s.slow, s.good, MAX);
assert.strictEqual(s.slow, 0, 'un secondo buono azzera i lenti');

// sei secondi buoni → risale di un gradino
s = { step: 2, slow: 0, good: 0 };
for (let i = 0; i < 6; i++) s = autoNext(20, BIG, TARGET, s.step, s.slow, s.good, MAX);
assert.strictEqual(s.step, 1, 'dopo 6s buoni risale');

// limiti
assert.strictEqual(autoNext(1, BIG, TARGET, MAX, 3, 0, MAX).step, MAX, 'non si scende oltre il minimo');
assert.strictEqual(autoNext(20, BIG, TARGET, 0, 0, 5, MAX).step, 0, 'non si sale oltre la qualità piena');

console.log('\u2713 qualità adattiva: 7 casi ok');
