// Runs harness.lua in fengari (a Lua VM in JS) against stubbed WoW APIs,
// with reference checksums computed independently here in JS.
// Usage: node tests/run.js [addonDir]
const fs = require('fs'), path = require('path');
const { lua, lauxlib, lualib, to_luastring } = require('fengari');

const KEY = Buffer.from('SelfFound|v1|9c41e7a2b05d');
function fnv(buf, h) {
  for (const b of buf) { h = (h ^ b) >>> 0; h = Math.imul(h, 16777619) >>> 0; }
  return h;
}
const hex = n => n.toString(16).padStart(8, '0');
function hash(buf) {
  return hex(fnv(Buffer.concat([KEY, buf]), 2166136261)) + hex(fnv(Buffer.concat([buf, KEY]), 3735928559));
}
const samples = ['', 'a', 'hello world', 'Trade with Bob-Realm éè |cffffffff|Hitem:2589|h[Linen]|h|r', 'x'.repeat(5000),
  Buffer.from([0, 1, 2, 31, 127, 128, 200, 255]).toString('latin1')];
const esc = b => Array.from(b).map(c => '\\' + c).join('');
let ref = 'return {\n';
for (const s of samples) {
  const buf = Buffer.from(s, s.startsWith('\u0000') ? 'latin1' : 'utf8');
  ref += `{ s = "${esc(buf)}", h = "${hash(buf)}" },\n`;
}
ref += '}\n';

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
const addonDir = path.resolve(process.argv[2] || path.join(__dirname, '..')).replace(/\\/g, '/');
lua.lua_pushstring(L, to_luastring(addonDir));
lua.lua_setglobal(L, to_luastring('ADDON_DIR'));
lua.lua_pushstring(L, to_luastring(fs.readFileSync(path.join(addonDir, 'SelfFound.toc'), 'utf8')));
lua.lua_setglobal(L, to_luastring('TOC_SOURCE'));
lua.lua_pushstring(L, to_luastring(ref));
lua.lua_setglobal(L, to_luastring('REF_SOURCE'));
const status = lauxlib.luaL_dofile(L, to_luastring(path.join(__dirname, 'harness.lua')));
if (status !== lua.LUA_OK) {
  console.log('HARNESS ERROR: ' + lua.lua_tojsstring(L, -1));
  process.exit(1);
}
lua.lua_getglobal(L, to_luastring('FAILURES'));
process.exit(lua.lua_tointeger(L, -1) > 0 ? 1 : 0);
