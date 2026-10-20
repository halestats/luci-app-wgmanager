/* Regression for LuCI.dom.attr(): false becomes an attribute, null is omitted.
 * Reference: OpenWrt LuCI openwrt-24.10 resources/luci.js, dom.attr().
 * Uses production view with simulated RPC and browser-native boolean semantics.
 */
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'..');
const current=fs.readFileSync(path.join(root,'root/www/luci-static/resources/view/wgmanager/dashboard.js'),'utf8');
let {harness}=require('./ui_test.cjs');
if(process.env.WGM_TEST_REFERENCE_VIEW){
 const old=fs.readFileSync(process.env.WGM_TEST_REFERENCE_VIEW,'utf8');
 assert.ok(harness.includes(JSON.stringify(current)));
 harness=harness.replace(JSON.stringify(current),JSON.stringify(old));
}
const css=fs.readFileSync(path.join(root,'root/www/luci-static/resources/wgmanager/dashboard.css'),'utf8');
harness=harness.replace("resource:()=>'/style.css'",'resource:()=>'+JSON.stringify('data:text/css;charset=utf-8,'+encodeURIComponent(css)+'#'));
(async()=>{
 const browser=await chromium.launch({headless:true,executablePath:process.env.WGM_TEST_CHROME,args:['--disable-gpu']});
 let count=0; const check=(ok,note)=>{assert.ok(ok,note);console.log(`ok ${++count} - ${note}`);};
 try{
  const page=await browser.newPage();await page.setContent(harness,{waitUntil:'load'});await page.waitForFunction(()=>window.ready||window.bootstrapError);
  check(await page.evaluate(()=>window.ready&&!window.bootstrapError),'view starts');
  await page.evaluate(()=>{mock.mode='manage';mock.peers.push({...mock.peers[0],id:'attr-test',public_key:btoa('attrs-test'.padEnd(32,'0')),name:'attr-test',managed:true,protected:false,exportable:true,allowed_ips:['192.168.66.5/32']});return app.reload();});
  const buttons=()=>page.locator('.wgm-peer').filter({hasText:'attr-test'}).locator('.wgm-actions button');
  const attributes=await buttons().evaluateAll(bs=>bs.map(b=>({text:b.textContent,disabled:b.disabled,attribute:b.getAttribute('disabled')})));
  console.log('managed buttons: '+JSON.stringify(attributes));
  check(attributes.length===5&&attributes.every(b=>!b.disabled&&b.attribute===null),'all five managed controls are enabled without a disabled attribute');
  await page.evaluate(()=>{app.busy=true;app.refresh(app.data);});
  check(await buttons().evaluateAll(bs=>bs.slice(1).every(b=>b.disabled)),'busy mode disables management and export');
  await page.evaluate(()=>{app.busy=false;app.refresh(app.data);});
  check(await buttons().evaluateAll(bs=>bs.every(b=>!b.disabled&&!b.hasAttribute('disabled'))),'busy reset omits attributes and restores controls');
  await page.evaluate(()=>{mock.mode='monitor';return app.reload();});
  check(await buttons().evaluateAll(bs=>!bs[1].disabled&&bs.slice(2).every(b=>b.disabled)),'read-only permits explicit export but blocks lifecycle changes');
  await page.evaluate(()=>{mock.mode='manage';mock.peers.find(p=>p.id==='attr-test').drift=true;return app.reload();});
  check(await buttons().evaluateAll(bs=>bs.slice(2).every(b=>b.disabled)),'drift still blocks lifecycle changes');
  await page.evaluate(()=>{mock.peers=mock.peers.filter(p=>p.id!=='attr-test');return app.reload();});
  check(await page.locator('.wgm-name').filter({hasText:'attr-test'}).count()===0,'a successful status refresh removes clients absent from the backend');
  console.log(`PASS ${count} LuCI attribute and status consistency checks`);
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
