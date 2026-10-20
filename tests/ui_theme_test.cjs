/* Reproduce heading backgrounds injected by a LuCI theme in a real browser. */
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');
const { harness } = require('./ui_test.cjs');
const root = path.resolve(__dirname, '..');
const css = fs.readFileSync(path.join(root, 'root/www/luci-static/resources/wgmanager/dashboard.css'), 'utf8');
const document = harness.replace("resource:()=>'/style.css'", 'resource:()=>'+JSON.stringify('data:text/css;charset=utf-8,'+encodeURIComponent(css)+'#'));
(async()=>{
 const browser = await chromium.launch({headless:true,executablePath:process.env.WGM_TEST_CHROME,args:['--disable-gpu']});
 let count=0; const check=(ok,note)=>{assert.ok(ok,note);console.log(`ok ${++count} - ${note}`);};
 try {
  const page=await browser.newPage({viewport:{width:1280,height:960}});
  await page.setContent(document,{waitUntil:'load'});
  await page.waitForFunction(()=>window.ready||window.bootstrapError);
  check(await page.evaluate(()=>window.ready&&!window.bootstrapError),'production view boots');
  await page.addStyleTag({content:'body h2, body h3, body [role=heading] { background: #fff !important; box-shadow: 0 0 0 2px #fff !important; }'});
  const headings='.wgm-head .wgm-title, .wgm-section-heading .wgm-section-title';
  for(const theme of ['light','dark']) {
   if(theme==='dark')await page.getByRole('button',{name:'深色 / 浅色',exact:true}).click();
   const styles=await page.locator(headings).evaluateAll(els=>els.map(el=>({background:getComputedStyle(el).backgroundColor,shadow:getComputedStyle(el).boxShadow})));
   check(styles.length===2&&styles.every(s=>s.background==='rgba(0, 0, 0, 0)'&&s.shadow==='none'),theme+' headings remain transparent under overriding theme styles');
  }
  check((await page.locator('.wgm-banner').textContent()).includes('wgmanager enable-management'),'monitor banner gives the actual management unlock command');
  check(await page.getByRole('button',{name:'＋ 新增客户端',exact:true}).isDisabled(),'read-only mode retains the management gate');
  await page.evaluate(()=>{mock.mode='manage';return app.reload();});
  check(await page.getByRole('button',{name:'＋ 新增客户端',exact:true}).isEnabled(),'creation becomes available with manage mode');
  check((await page.locator('.wgm-peer .wgm-actions').evaluateAll(els=>els.every(el=>el.querySelectorAll('button').length===1))),'original clients retain details-only controls');
  if(process.env.WGM_TEST_SCREENSHOTS){
   fs.mkdirSync(process.env.WGM_TEST_SCREENSHOTS,{recursive:true});
   await page.waitForTimeout(200);
   await page.screenshot({path:path.join(process.env.WGM_TEST_SCREENSHOTS,'headings-dark.png'),fullPage:false});
  }
  console.log(`PASS ${count} theme and mode checks (simulated LuCI RPC; no router changes)`);
 } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
