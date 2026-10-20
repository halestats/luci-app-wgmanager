const fs = require('fs');
const path = require('path');
const root=path.resolve(__dirname, '..');
const out=path.resolve(process.env.WGM_DIST || path.join(root, '..', 'dist'));
fs.mkdirSync(out,{recursive:true});
let {harness}=require(root+'/tests/ui_test.cjs');
const css=fs.readFileSync(root+'/root/www/luci-static/resources/wgmanager/dashboard.css','utf8');
harness=harness.replace("resource:()=>'/style.css'",'resource:()=>'+JSON.stringify('data:text/css;charset=utf-8,'+encodeURIComponent(css)+'#'));
harness=harness.replace('<title>WireGuard Manager test harness</title>', '<title>WireGuard Manager 0.5.0 · 离线布局预览</title>');
harness=harness.replace('<main id="app">','<p style="max-width:1160px;margin:0 auto 16px;color:#64748b;font-size:12px">0.5.0 布局预览 · 所有数据均为演示，按钮仅操作本页模拟数据，不连接路由器。</p><main id="app">');
harness=harness.replace('background:#2466dc!important;color:white!important;border-color:#2466dc!important','background:#147d66;color:white;border-color:#147d66');
harness=harness.replace("mode:'monitor'", "mode:'manage'");
harness=harness.replace('const rpc={declare:', `
// Two independent demo interfaces, with two IPv4 pools on wg.
const demoCatalog=[{name:'wg',configured:true,up:true},{name:'vpn0',configured:true,up:true}];
mock.interface='wg';mock.interfaces=demoCatalog;mock.listen_port=51820;
mock.network={available:true,source:'interface',server_address:'192.168.77.1/24',server_addresses:['192.168.77.1/24','192.168.66.1/24'],subnets:['192.168.77.0/24','192.168.66.0/24'],hint:'192.168.77.2–192.168.77.254；192.168.66.2–192.168.66.254；排除所有网段的网络/广播地址和服务端地址 192.168.77.1, 192.168.66.1'};
mock.defaultRoutes=['192.168.77.0/24','192.168.66.0/24','192.168.95.0/24'];
mock.settings.routes_mode='auto';mock.settings.routes=mock.defaultRoutes.slice();mock.nextAddress='192.168.77.2';
const alternate=JSON.parse(JSON.stringify(mock));alternate.interface='vpn0';alternate.listen_port=51821;alternate.peers=[];
alternate.network={available:true,source:'interface',server_address:'10.8.0.1/24',server_addresses:['10.8.0.1/24'],subnets:['10.8.0.0/24'],hint:'10.8.0.2–10.8.0.254；排除所有网段的网络/广播地址和服务端地址 10.8.0.1'};
alternate.defaultRoutes=['10.8.0.0/24','192.168.95.0/24'];alternate.settings.routes=alternate.defaultRoutes.slice();alternate.nextAddress='10.8.0.2';alternate.existingManagement=false;
const demoByName={wg:mock,vpn0:alternate};
mock.existingManagement=true;
mock.peers.forEach((p,i)=>{p.legacy=true;p.managed=true;p.protected=false;p.exportable=false;p.id='existing-'+i;p.name=['iPhone 16','MacBook Pro','Home NAS'][i];p.total_tx=[1825361100,839909376,10737418240][i];p.total_rx=[104857600,335544320,234881024][i];});
mock.peers[2].latest_handshake-=3600;
mock.peers.push({...mock.peers[0],id:'demo-client',public_key:btoa('demo-managed'.padEnd(32,'0')),name:'Pixel 9',allowed_ips:['192.168.66.5/32'],managed:true,protected:false,legacy:false,exportable:true,latest_handshake:0,total_tx:0,total_rx:0,transfer_tx:0,transfer_rx:0});
const rpc={declare:`);
harness=harness.replace("window.ready=true;",`window.ready=true;
let sample=0;
function animate(){sample++;mock.peers.forEach((p,i)=>{if(i>1)return;let down=Math.round((1+Math.sin(sample/3+i))*1000000/(i+1));let up=Math.round((1+Math.cos(sample/4+i))*180000/(i+1));p.transfer_tx+=down;p.transfer_rx+=up;p.total_tx+=down;p.total_rx+=up;});app.reload();}
app.last=Object.fromEntries(mock.peers.map(p=>[p.public_key,{rx:p.transfer_rx,tx:p.transfer_tx,time:performance.now()-2000}]));
for(let i=0;i<24;i++){mock.peers.forEach((p,j)=>{app.history[p.public_key]=(app.history[p.public_key]||[]).concat([{down:j<2?(1+Math.sin(i/3+j))*500000:0,up:j<2?(1+Math.cos(i/4+j))*90000:0}]);});}
animate();setInterval(animate,2000);`);
harness=harness.replace('mock.calls.push({method,args});', `
let requested=method==='status'?args[0]:args[args.length-1];
if(requested&&demoByName[requested])window.mock=demoByName[requested];
mock.calls.push({method,args});`);
// The preview is not a client configuration exporter; files are visibly demo-only.
harness=harness.replace('DEMO_PRIVATE_KEY','DEMO_PRIVATE_KEY_NOT_USABLE');
const target=path.join(out, 'WireGuard-Manager-0.5.0-preview.html');
fs.writeFileSync(target,harness);
console.log(target);
