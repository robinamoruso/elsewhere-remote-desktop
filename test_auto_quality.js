// node test_auto_quality.js — verifica la logica di qualità adattiva del client
const assert = require('assert');
const fs = require('fs');

const html = fs.readFileSync(`${__dirname}/static/index.html`, 'utf8');
const src = html.match(/function autoNext[\s\S]*?\n}/)[0];
const autoNext = new Function(`${src}; return autoNext;`)();

const MAX = 4;
// schermo fermo: nessun frame non significa rete lenta
assert.deepStrictEqual(autoNext(0, 20, 0, 1, 0, MAX), { step: 0, slow: 1, good: 0 });

// due secondi lenti di fila → scende di un gradino
let s = autoNext(5, 20, 0, 0, 0, MAX);
assert.strictEqual(s.slow, 1, 'primo secondo lento: solo conta');
s = autoNext(5, 20, 0, s.slow, s.good, MAX);
assert.strictEqual(s.step, 1, 'secondo secondo lento: degrada');

// un secondo buono azzera i lenti: un singolo calo non degrada
s = autoNext(5, 20, 0, 0, 0, MAX);
s = autoNext(20, 20, 0, s.slow, s.good, MAX);
assert.strictEqual(s.slow, 0, 'un secondo buono azzera il contatore');

// otto secondi buoni → risale di un gradino
let good = 0, step = 2;
for (let i = 0; i < 8; i++) ({ step, good } = autoNext(20, 20, step, 0, good, MAX));
assert.strictEqual(step, 1, 'dopo 8s buoni risale');

// non si scende sotto l'ultimo gradino né si sale sopra il primo
assert.strictEqual(autoNext(1, 20, MAX, 1, 0, MAX).step, MAX, 'niente oltre il gradino minimo');
assert.strictEqual(autoNext(20, 20, 0, 0, 7, MAX).step, 0, 'niente sopra la qualità piena');

console.log('✓ qualità adattiva: 6 casi ok');
