/* Executes the production view's interaction logic in jsdom.
 * Does not make claims about browser rendering, CSS, or real LuCI sessions.
 */
const { JSDOM, VirtualConsole } = require('jsdom');
const { harness } = require('./ui_test.cjs');
const assert = require('node:assert/strict');
let count=0;
function check(ok,label){assert.ok(ok,label);console.log(`ok ${++count} - ${label}`);}
const tick=()=>new Promise(r=>setImmediate(r));
(async()=>{
  const errors=[];
  const vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
  const dom=new JSDOM(harness,{runScripts:'dangerously',url:'http://wgmanager-test.invalid/',virtualConsole:vc,beforeParse(w){
    w.Blob=global.Blob;w.downloads=[];w.blobs={};
    w.URL.createObjectURL=b=>{const url='blob:test-'+Object.keys(w.blobs).length;w.blobs[url]=b;return url;};
    w.URL.revokeObjectURL=url=>{delete w.blobs[url];};
    w.HTMLAnchorElement.prototype.click=function(){w.downloads.push({url:this.href,filename:this.download});};
  }});
  const w=dom.window,d=w.document;
  try{
    for(let i=0;i<30&&!w.ready&&!w.bootstrapError;i++)await tick();
    check(w.ready&&!w.bootstrapError,'view boots with DOM/LuCI API shim');
    const cards=()=>[...d.querySelectorAll('.wgm-peer')];
    function btn(text,scope=d){const b=[...scope.querySelectorAll('button')].find(x=>x.textContent===text);assert.ok(b,'button '+text);return b;}
    const modal=()=>d.querySelector('#modal');
    const card=name=>cards().find(x=>x.querySelector('.wgm-name').textContent===name);
    async function click(text,scope){btn(text,scope).click();await tick();await tick();}
    check(cards().length===3,'renders all three existing clients');
    check(btn('＋ 新增客户端').disabled,'initial mode disables creation');
    check(cards().every(x=>x.querySelectorAll('.wgm-actions button').length===1),'protected clients expose no lifecycle or secret-export controls');
    check([...d.querySelectorAll('.wgm-ip')].map(x=>x.textContent).join(' ').includes('192.168.66.2/32 192.168.66.3/32 192.168.66.10/32'),'IPv4 sort does not sort the /32 suffix');
    let p=w.mock.peers[0];w.app.last[p.public_key]={rx:p.transfer_rx,tx:p.transfer_tx,time:w.performance.now()-2000};p.transfer_tx+=4096;await w.app.reload();
    check(w.app.peers.find(x=>x.name==='旧客户端 2').download>1500,'client download uses server TX delta');
    w.mock.failStatus=true;await w.poller();
    check(d.querySelector('.wgm-message').textContent.includes('旧数据'),'poll failure labels displayed data stale');
    w.mock.failStatus=false;w.mock.peers[0].transfer_tx+=999999;await w.app.reload();
    check(w.app.peers.every(x=>x.download===0),'recovery from polling error suppresses bandwidth spike');
    check(!w.mock.calls.some(c=>c.method==='export'),'status polling does not fetch client secrets');
    w.mock.mode='manage';await w.app.reload();
    await click('＋ 新增客户端');
    const name='Phone <img src=x onerror=window.XSS=1>';
    modal().querySelectorAll('input')[0].value=name;
    await click('预览变更',modal());
    check(!w.mock.calls.some(c=>c.method==='apply'),'preview performs no apply RPC');
    const confirm=btn('确认执行',modal());confirm.click();confirm.click();await tick();await tick();await tick();
    check(w.mock.calls.filter(c=>c.method==='apply').length===1,'rapid duplicate submit is sent once');
    check(cards().length===4,'confirmed new client is shown');
    check(!w.XSS&&d.querySelectorAll('.wgm-name img').length===0,'untrusted name remains plain text');
    check(d.querySelector('.wgm-secret').value.includes('DEMO_PRIVATE_KEY'),'secret fetched only into explicit export dialog');
    await click('下载 .conf',modal());
    check(w.downloads.length===1&&w.downloads[0].filename.endsWith('.conf'),'configuration download uses .conf filename');
    check((await w.blobs[w.downloads[0].url].text()).includes('Address = 192.168.66.5/32'),'download blob preserves exported configuration');
    await click('关闭',modal());
    check(d.querySelector('.wgm-secret').value===''&&!d.querySelector('.wgm-qr').hasAttribute('src'),'close wipes private config and QR source from hidden modal');
    await click('禁用',card(name));await click('确认执行',modal());
    check(card(name).textContent.includes('已禁用')&&btn('启用',card(name)),'disabled client stays listed and can be enabled');
    await click('启用',card(name));await click('确认执行',modal());
    await click('编辑',card(name));let fields=modal().querySelectorAll('input');fields[0].value='Updated iPhone';fields[1].value='192.168.66.8';
    await click('预览变更',modal());await click('确认执行',modal());
    check(card('Updated iPhone').textContent.includes('192.168.66.8/32'),'edit updates displayed name and address');
    await click('删除',card('Updated iPhone'));
    check(modal().textContent.includes('持久配置'),'delete preview identifies persistent peer removal');
    await click('确认执行',modal());
    check(cards().length===3&&w.mock.peers.every(x=>x.protected),'delete keeps the three originals');
    let search=d.querySelector('.wgm-search');search.value='旧客户端 10';search.dispatchEvent(new w.Event('input'));
    check(cards().length===1,'search filters the requested client');search.value='';search.dispatchEvent(new w.Event('input'));
    await click('导出设置');fields=modal().querySelectorAll('input');fields[0].value='new-vpn.example.com';fields[1].value='192.168.95.1';
    await click('预览保存',modal());await click('确认执行',modal());
    check(w.mock.settings.endpoint==='new-vpn.example.com','export settings are sent through preview and apply');
    await click('＋ 新增客户端');modal().querySelectorAll('input')[0].value='stale-test';await click('预览变更',modal());
    w.mock.failApply=true;await click('确认执行',modal());
    check(d.querySelector('#notifications').textContent.includes('重新预览')&&cards().length===3,'stale apply errors are visible and do not create a client');
    await click('深色 / 浅色');check(d.querySelector('.wgm-root').classList.contains('wgm-dark'),'theme control toggles the intended class');
    check(errors.length===0,'no JavaScript/DOM execution errors: '+errors.join('; '));
    console.log(`PASS ${count} DOM interaction checks; layout/native LuCI not validated`);
  }finally{w.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
