// Syntax-checks every addon .lua file as Lua 5.1 (WoW's dialect).
// Usage: node tests/check.js [addonDir]
const fs=require('fs'),path=require('path'),lp=require('luaparse');
const dir=process.argv[2]||path.join(__dirname,'..');let bad=0;
for(const f of fs.readdirSync(dir).filter(f=>f.endsWith('.lua'))){
  try{lp.parse(fs.readFileSync(path.join(dir,f),'utf8'),{luaVersion:'5.1'});console.log('OK  ',f)}
  catch(e){bad++;console.log('FAIL',f,e.message)}
}
process.exit(bad);
