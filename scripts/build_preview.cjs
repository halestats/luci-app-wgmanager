const fs = require('fs');
const path = require('path');
const root=path.resolve(__dirname, '..');
const out=path.resolve(process.env.WGM_DIST || path.join(root, '..', 'dist'));
fs.mkdirSync(out,{recursive:true});
let {harness}=require(root+'/tests/ui_test.cjs');
const css=fs.readFileSync(root+'/root/www/luci-static/resources/wgmanager/dashboard.css','utf8');
harness=harness.replace("resource:()=>'/style.css'",'resource:()=>'+JSON.stringify('data:text/css;charset=utf-8,'+encodeURIComponent(css)+'#'));
harness=harness.replace('<title>WireGuard Manager test harness</title>', '<title>WireGuard Manager 0.3.1 · 离线布局预览</title>');
harness=harness.replace('<main id="app">','<p style="max-width:1160px;margin:0 auto 16px;color:#64748b;font-size:12px">0.3.1 布局预览 · 所有数据均为演示，按钮仅操作本页模拟数据，不连接路由器。</p><main id="app">');
harness=harness.replace('background:#2466dc!important;color:white!important;border-color:#2466dc!important','background:#147d66;color:white;border-color:#147d66');
harness=harness.replace("mode:'monitor'", "mode:'manage'");
harness=harness.replace('const rpc={declare:', `
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
const target=path.join(out, 'WireGuard-Manager-0.3.1-preview.html');
fs.writeFileSync(target,harness);
console.log(target);
