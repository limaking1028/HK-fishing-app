// Copies the static web app (repo root) into www/ for Capacitor iOS.
// Root files are only READ; the web site / Android TWA are unaffected.
const fs = require('fs'), path = require('path');
const root = path.resolve(__dirname, '..'), out = path.join(root, 'www');
const FILES = ['index.html', 'privacy.html', 'delete-account.html', 'manifest.json', 'sw.js',
  'apple-touch-icon.png', 'icon-192.png', 'icon-512.png', 'icon-maskable-512.png'];
const DIRS = ['lib', 'photos'];
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out);
for (const f of FILES) if (fs.existsSync(path.join(root, f))) fs.copyFileSync(path.join(root, f), path.join(out, f));
for (const d of DIRS) if (fs.existsSync(path.join(root, d))) fs.cpSync(path.join(root, d), path.join(out, d), { recursive: true });
console.log('www/ ready:', fs.readdirSync(out).join(', '));
