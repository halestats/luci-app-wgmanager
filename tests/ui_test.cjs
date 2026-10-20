/* Browser tests use the real dashboard JS with a small LuCI API shim.
 * This checks view behavior/layout; it is not an iStoreOS LuCI runtime test.
 */
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const code = fs.readFileSync(path.join(root, 'root/www/luci-static/resources/view/wgmanager/dashboard.js'), 'utf8');
const css = fs.readFileSync(path.join(root, 'root/www/luci-static/resources/wgmanager/dashboard.css'), 'utf8');
const screenshots = process.env.WGM_TEST_SCREENSHOTS;
let count = 0;
function check(ok, label) { assert.ok(ok, label); console.log(`ok ${++count} - ${label}`); }

const harness = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WireGuard Manager test harness</title><style>
*{box-sizing:border-box}body{font:14px system-ui,sans-serif;background:#f1f4f7;color:#202635;margin:0;padding:24px}main{max-width:1160px;margin:auto;padding:20px;background:white;border-radius:14px}.btn{font:inherit;padding:7px 12px;border:1px solid #d4dae2;border-radius:6px;background:#f7f8fa;cursor:pointer}.cbi-button-positive{background:#2466dc!important;color:white!important;border-color:#2466dc!important}.cbi-button-negative{background:#c64141;color:white}input,select,textarea{padding:8px;border:1px solid #ced6e0;border-radius:6px;font:inherit}.overlay{position:fixed;inset:0;background:#0006;z-index:5;overflow:auto;padding:28px 0}.modal{background:#fff;width:min(620px,calc(100vw - 32px));margin:auto;padding:24px;border-radius:12px}.modal h4{font-size:19px;margin:0 0 18px}.right{text-align:right}#notifications{max-width:1160px;margin:auto;color:#b83030}.overlay[hidden]{display:none}@media(max-width:520px){body{padding:8px}main{padding:10px}.modal{padding:18px}}
</style><main id="app"></main><div id="notifications"></div><div id="overlay" class="overlay" hidden><div id="modal" class="modal"></div></div>
<script>
function append(parent, child){if(child==null)return;if(Array.isArray(child))child.forEach(c=>append(parent,c));else parent.appendChild(child instanceof Node?child:document.createTextNode(String(child)));}
function E(tag,attrs,children){let el=document.createElement(tag);for(let [k,v] of Object.entries(attrs||{})){if(v==null)continue;if(typeof v==='function')el.addEventListener(k,v);else if(typeof v==='object')el.setAttribute(k,JSON.stringify(v));else el.setAttribute(k,String(v));}append(el,children);return el;}
const dom={content:(el,c)=>{el.replaceChildren();append(el,c);}};
const view={extend:o=>o};const poll={add:f=>{window.poller=f;}};
const ui={showModal:(title,children)=>{dom.content(document.querySelector('#modal'),[E('h4',{},[title]),children]);document.querySelector('#overlay').hidden=false;},hideModal:()=>{document.querySelector('#overlay').hidden=true;},addNotification:(_,c)=>{append(document.querySelector('#notifications'),c);}};
document.querySelector('#overlay').addEventListener('keydown',e=>{if(e.key==='Escape'){let b=document.querySelector('#modal .right button');if(b)b.click();}});
const L={bind:(f,t)=>f.bind(t),resource:()=>'/style.css'};
let sequence=0;
window.mock={mode:'monitor',failStatus:false,failApply:false,calls:[],revision:0,plans:{},settings:{endpoint:'vpn.example.com',dns:[],routes:['192.168.66.0/24','192.168.95.0/24'],keepalive:25},peers:[2,10,3].map(i=>({id:'',public_key:btoa(('legacy'+i).padEnd(32,'0')),name:'旧客户端 '+i,allowed_ips:['192.168.66.'+i+'/32'],endpoint:'203.0.113.8:45000',latest_handshake:Math.floor(Date.now()/1000)-30,transfer_rx:i*10000,transfer_tx:i*20000,total_rx:i*10000,total_tx:i*20000,enabled:true,managed:false,protected:true,present:true,drift:false,exportable:false}))};
function reply(data){return {ok:true,data:JSON.parse(JSON.stringify(data))};}
const rpc={declare:({method})=>(...args)=>Promise.resolve().then(()=>{
mock.calls.push({method,args});
if(method==='status'){if(mock.failStatus)throw Error('synthetic outage');return reply({version:'0.4.0',mode:mock.mode,existing_management:mock.existingManagement===true,revision:mock.revision,health:'ok',interface:'wg',up:true,listen_port:51820,network:{available:true,source:'interface',server_address:'192.168.66.1/24',server_ip:'192.168.66.1',subnet:'192.168.66.0/24',prefix:24,pool_start:'192.168.66.2',pool_end:'192.168.66.254',excluded_addresses:['192.168.66.1'],hint:'192.168.66.2–192.168.66.254；排除服务端地址 192.168.66.1'},default_routes:['192.168.66.0/24','192.168.95.0/24'],settings:mock.settings,peers:mock.peers,timestamp:Math.floor(Date.now()/1000),stats:{collector:false}});}
if(method==='prepare'){let [action,id,payload]=args,p=JSON.parse(payload),token='token'+(++sequence);mock.plans[token]={action,id,p};return reply({token,summary:{title:{create:'新增客户端',edit:'编辑客户端',disable:'禁用客户端',enable:'启用客户端',delete:'删除客户端',settings:'更新客户端导出设置'}[action],name:p.name||mock.peers.find(x=>x.id===id)?.name,address:p.address||'192.168.66.5',detail:'仅操作指定客户端'},expires_in:60});}
if(method==='apply'){if(mock.failApply)return {ok:false,error:{code:'STALE_PLAN',message:'配置在预览后发生变化，请重新预览'}};let plan=mock.plans[args[0]],{action,id,p}=plan;delete mock.plans[args[0]];let peer=mock.peers.find(x=>x.id===id);if(action==='create'){id='p'+String(sequence).padStart(24,'0');mock.peers.push({id,name:p.name,public_key:btoa(('managed'+sequence).padEnd(32,'0')),allowed_ips:[(p.address||'192.168.66.5')+'/32'],endpoint:'',latest_handshake:0,transfer_rx:0,transfer_tx:0,total_rx:0,total_tx:0,enabled:true,managed:true,protected:false,present:true,drift:false,exportable:true});}else if(action==='edit'){peer.name=p.name;peer.allowed_ips=[p.address+'/32'];}else if(action==='disable'||action==='enable'){peer.enabled=action==='enable';peer.present=peer.enabled;}else if(action==='delete'){mock.peers=mock.peers.filter(x=>x.id!==id);}else if(action==='settings')mock.settings=p;mock.revision++;return reply({peer_id:id,revision:mock.revision,action});}
if(method==='export'){return reply({filename:'wg-'+args[0]+'.conf',config:'[Interface]\\nPrivateKey = DEMO_PRIVATE_KEY\\nAddress = 192.168.66.5/32\\n\\n[Peer]\\nPublicKey = DEMO_PUBLIC_KEY\\nEndpoint = vpn.example.com:51820\\n',qr_svg:'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="white"/><path d="M10 10h30v30H10zM60 10h30v30H60zM10 60h30v30H10z" fill="black"/></svg>',disabled:false});}
throw Error('unexpected RPC');})};
window.app=(new Function('view','rpc','poll','dom','ui','L','E',${JSON.stringify(code)}))(view,rpc,poll,dom,ui,L,E);
app.load().then(d=>document.querySelector('#app').appendChild(app.render(d))).then(()=>{window.ready=true;}).catch(e=>{window.bootstrapError=e.message;});
</script>`;

module.exports = { harness };
if (require.main === module) (async () => {
  const { chromium } = require('playwright');
  const server = http.createServer((req, res) => {
    if (req.url.split('?')[0] === '/style.css') { res.setHeader('Content-Type', 'text/css'); res.end(css); }
    else { res.setHeader('Content-Type', 'text/html'); res.end(harness); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({ headless: true, executablePath: process.env.WGM_TEST_CHROME, args: ['--no-sandbox'] });
    const page = await browser.newPage({ viewport: { width: 1280, height: 980 } });
    const errors=[]; page.on('pageerror',e=>errors.push(e.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.waitForFunction(()=>window.ready||window.bootstrapError);
    check(!(await page.evaluate(()=>window.bootstrapError)), 'dashboard boots under LuCI API shim');
    check(await page.locator('.wgm-peer').count()===3, 'all original clients render');
    check(await page.getByRole('button',{name:'＋ 新增客户端',exact:true}).isDisabled(), 'new-client button disabled in initial monitor stage');
    check(await page.locator('.wgm-peer').first().locator('.wgm-actions button').count()===1, 'original client exposes details only');
    const ips=await page.locator('.wgm-ip').allTextContents();
    check(ips[0].includes('.2/')&&ips[1].includes('.3/')&&ips[2].includes('.10/'), 'IPv4 sorting compares addresses rather than CIDR suffix');
    await page.evaluate(()=>{let p=mock.peers[0];app.last[p.public_key]={rx:p.transfer_rx,tx:p.transfer_tx,time:performance.now()-2000};p.transfer_tx+=4096;return app.reload();});
    check(await page.evaluate(()=>app.peers.find(p=>p.name==='旧客户端 2').download>1500), 'download rate follows server TX deltas');
    await page.evaluate(()=>{mock.failStatus=true;return poller();});
    check((await page.locator('.wgm-message').textContent()).includes('旧数据'), 'poll error marks stale data');
    await page.evaluate(()=>{mock.failStatus=false;mock.peers[0].transfer_tx+=999999;return app.reload();});
    check(await page.evaluate(()=>app.peers.every(p=>p.download===0)), 'first sample after failed polling has no rate spike');
    check(await page.evaluate(()=>!mock.calls.some(c=>c.method==='export')), 'routine status polling never requests secrets');
    if(screenshots){fs.mkdirSync(screenshots,{recursive:true});await page.screenshot({path:path.join(screenshots,'desktop.png'),fullPage:true});}
    await page.setViewportSize({width:390,height:844});
    check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth), 'mobile dashboard has no horizontal overflow');
    if(screenshots)await page.screenshot({path:path.join(screenshots,'mobile.png'),fullPage:true});
    await page.evaluate(()=>{mock.mode='manage';return app.reload();});
    await page.getByRole('button',{name:'＋ 新增客户端',exact:true}).click();
    const name='Phone <img src=x onerror=window.XSS=1>';
    await page.locator('#modal input').nth(0).fill(name);
    await page.getByRole('button',{name:'预览变更',exact:true}).click();
    await page.getByRole('button',{name:'确认执行',exact:true}).waitFor();
    check(await page.evaluate(()=>!mock.calls.some(c=>c.method==='apply')), 'preview does not apply a live change');
    await page.getByRole('button',{name:'确认执行',exact:true}).dblclick({delay:5});
    await page.getByRole('button',{name:'下载 .conf',exact:true}).waitFor();
    check(await page.locator('.wgm-peer').count()===4, 'new client appears after confirmed action');
    check(await page.evaluate(()=>mock.calls.filter(c=>c.method==='apply').length===1), 'double click submits exactly once');
    check(await page.evaluate(()=>!window.XSS&&document.querySelectorAll('.wgm-name img').length===0), 'client names render as text, without HTML execution');
    const downloadPromise=page.waitForEvent('download');
    await page.getByRole('button',{name:'下载 .conf',exact:true}).click();
    const download=await downloadPromise;
    check(download.suggestedFilename().endsWith('.conf'), 'download uses a .conf attachment filename');
    const stream=await download.createReadStream();let content='';for await(const b of stream)content+=b.toString();
    check(content.includes('Address = 192.168.66.5/32'), 'downloaded configuration contains selected client address');
    await page.getByRole('button',{name:'关闭',exact:true}).click();
    check(await page.locator('.wgm-secret').inputValue()===''&&await page.locator('.wgm-qr').getAttribute('src')===null, 'closing secret dialog clears text and QR source');
    let card=page.locator('.wgm-peer').filter({hasText:name});
    await card.getByRole('button',{name:'禁用',exact:true}).click();
    await page.getByRole('button',{name:'确认执行',exact:true}).click();
    await card.getByRole('button',{name:'启用',exact:true}).waitFor();
    check((await card.textContent()).includes('已禁用'), 'disabled client stays listed with reserved address');
    await card.getByRole('button',{name:'启用',exact:true}).click();await page.getByRole('button',{name:'确认执行',exact:true}).click();
    await card.getByRole('button',{name:'编辑',exact:true}).click();
    await page.locator('#modal input').nth(0).fill('Updated iPhone');await page.locator('#modal input').nth(1).fill('192.168.66.8');
    await page.getByRole('button',{name:'预览变更',exact:true}).click();await page.getByRole('button',{name:'确认执行',exact:true}).click();
    card=page.locator('.wgm-peer').filter({hasText:'Updated iPhone'});await card.waitFor();
    check((await card.textContent()).includes('192.168.66.8/32'), 'edited address and name render');
    await card.getByRole('button',{name:'删除',exact:true}).click();
    check((await page.locator('#modal').textContent()).includes('持久配置'), 'delete preview explains persistent client removal');
    await page.getByRole('button',{name:'确认执行',exact:true}).click();
    await page.waitForFunction(()=>mock.peers.length===3&&document.querySelectorAll('.wgm-peer').length===3);
    check(await page.locator('.wgm-peer').count()===3, 'delete retains all three originals');
    await page.locator('.wgm-search').fill('旧客户端 10');check(await page.locator('.wgm-peer').count()===1, 'search filters client cards');
    await page.locator('.wgm-search').fill('');
    await page.getByRole('button',{name:'深色 / 浅色',exact:true}).click();
    check(await page.locator('.wgm-root').evaluate(el=>el.classList.contains('wgm-dark')), 'dark theme toggles');
    check(errors.length===0,'no browser JavaScript errors: '+errors.join('; '));
    console.log(`PASS ${count} browser interaction/layout checks (LuCI API shim)`);
  } finally {if(browser)await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exitCode=1;});
