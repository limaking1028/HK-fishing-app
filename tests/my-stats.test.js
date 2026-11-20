const assert = require('node:assert/strict');
const { test } = require('node:test');
const { compute } = require('../lib/myStats');

test('totals count all distinct groups while existing result limits are preserved', () => {
  const catches = Array.from({ length: 6 }, (_, i) => ({
    isMine: true,
    date: `2026-${String(i + 6).padStart(2, '0')}-01`,
    spot: `釣點${i}`,
    species: `魚種${i}`,
    method: `釣法${i % 5}`,
    bait: `魚餌${i % 5}`,
    weight: i + 1,
  }));
  catches.push({ ...catches[0], spot: '釣點0（碼頭）' });
  catches.push({ ...catches[0], isDemo: true, spot: '示範', method: '示範', bait: '示範' });
  catches.push({ ...catches[0], isMine: false, spot: '其他', method: '其他', bait: '其他' });

  const result = compute(catches, [], { nowMs: Date.UTC(2026, 10, 20) });
  assert.deepEqual(
    [result.spotCount, result.speciesCount, result.methodCount, result.baitCount],
    [6, 6, 5, 5],
  );
  assert.deepEqual(result.monthly.map(m => m.n), [2, 1, 1, 1, 1, 1]);
  assert.deepEqual(result.spots.map(x => x.name), ['釣點0', '釣點5', '釣點4', '釣點3', '釣點2']);
  assert.deepEqual(result.species.map(x => x.name), ['魚種0', '魚種5', '魚種4', '魚種3', '魚種2']);
  assert.equal(result.methods.length, 3);
  assert.equal(result.baits.length, 3);

  const empty = compute([], []);
  assert.deepEqual([empty.spotCount, empty.methodCount, empty.baitCount], [0, 0, 0]);
});
