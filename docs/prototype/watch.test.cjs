// 原型状态机的无依赖回归检查；不启动浏览器或声称验证 WatchConnectivity。
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const {join} = require('node:path');
const vm = require('node:vm');
const {randomUUID} = require('node:crypto');
const source = readFileSync(join(__dirname, 'watch.html'), 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
function app(saved = new Map()) {
  const elements = new Map(), handlers = {}, storage = {failed: false};
  const element = id => {
    if (!elements.has(id)) elements.set(id, {dataset:{},classList:{toggle(){},add(){}},scrollTop:0,innerHTML:'',contains(){return false;},querySelector(){return null;}});
    return elements.get(id);
  };
  const context = vm.createContext({crypto:{randomUUID}, URLSearchParams, location:{search:''},
    document:{getElementById:element,activeElement:null,body:element('body'),addEventListener:(type,fn)=>handlers[type]=fn,querySelectorAll:()=>[]},
    localStorage:{getItem:key=>saved.get(key)||null,setItem:(key,value)=>{if(storage.failed)throw Error('disk');saved.set(key,value);}},
    setTimeout:()=>1,clearTimeout(){},setInterval(){}});
  vm.runInContext(source, context);
  const run = code => vm.runInContext(code, context);
  return {run,storage,saved,action:(name,value='')=>run(`action(${JSON.stringify(name)},${JSON.stringify(value)})`),
    state:()=>JSON.parse(run('JSON.stringify(S)')),deliver:()=>run('deliver()'),
    input:value=>handlers.input({target:{id:'candidate',value}}),
    change:(id,value,type='select-one')=>handlers.change({target:{id,value,type,checked:value}})};
}
function start(a){a.action('select','dumbbell_curl');a.action('start');}
function save(a,n){a.action('inject',String(n));a.action('stop');a.action('save');}

test('未选择、不支持动作、权限拒绝均不能开组',()=>{
 const a=app();a.action('start');assert.equal(a.state().current,null);
 a.action('select','dumbbell_squat');a.action('start');assert.equal(a.state().current,null);
 a.change('permission',false,'checkbox');start(a);assert.equal(a.state().current,null);
 assert.match(a.state().notice,/权限/);a.change('permission',true,'checkbox');a.action('start');assert.equal(a.state().page,'count');
});
test('重复开始、停顿和组后注入不产生额外组或计次',()=>{
 const a=app();start(a);const id=a.state().current.id;a.action('start');assert.equal(a.state().current.id,id);
 a.action('inject','1');a.action('pause');a.action('inject','8');assert.equal(a.state().current.estimate,1);
 a.action('pause');a.action('inject','1');a.action('stop');a.action('inject','8');assert.equal(a.state().current.estimate,2);
});
test('1、2 次短组可保存；0、负数、小数被拒绝',()=>{
 for(const n of ['0','-1','2.5','']){const a=app();start(a);a.action('stop');a.change('candidate',n,'number');a.action('save');assert.equal(a.state().workouts[0].sets.length,0);assert.equal(a.state().page,'review');}
 for(const n of [1,2]){const a=app();start(a);save(a,n);assert.equal(a.state().workouts[0].sets[0].final,n);}
});
test('8 + 估计9修正10 = 18；重复确认不新增，原估计保留',()=>{
 const a=app();start(a);save(a,8);a.action('start');a.action('inject','9');a.action('stop');const rest=a.state().restAt;
 a.action('plus');assert.equal(a.state().restAt,rest);a.action('save');a.action('save');const sets=a.state().workouts[0].sets;
 assert.equal(sets.length,2);assert.deepEqual(sets.map(s=>s.final),[8,10]);assert.equal(sets[1].estimate,9);assert.equal(sets[1].source,'automatic');
});
test('本地模拟写入失败保留候选，重试仅保存一次',()=>{
 const a=app();start(a);a.action('inject','9');a.action('stop');a.action('localFail');a.action('save');
 assert.equal(a.state().current.candidate,9);assert.equal(a.state().workouts[0].sets.length,0);a.action('save');assert.equal(a.state().workouts[0].sets.length,1);
});
test('浏览器存储真实失败也不报告保存成功',()=>{
 const a=app();start(a);a.action('inject','9');a.action('stop');a.storage.failed=true;a.action('save');
 assert.equal(a.state().page,'review');assert.equal(a.state().workouts[0].sets.length,0);a.storage.failed=false;a.action('save');assert.equal(a.state().page,'rest');
});
test('断连两组在刷新恢复后仍在，恢复不重复',()=>{
 let a=app();a.change('connected',false,'checkbox');start(a);save(a,8);a.action('start');save(a,10);a.deliver();
 assert.equal(Object.keys(a.state().phone).length,0);a=app(a.saved);assert.equal(a.state().workouts[0].sets.length,2);
 a.change('connected',true,'checkbox');a.deliver();a.action('duplicate');a.deliver();const p=Object.values(a.state().phone)[0];
 assert.equal(Object.keys(p.sets).length,2);assert.equal(Object.values(p.sets).reduce((n,s)=>n+s.final,0),18);
});
test('未登录不接收，登录后补发；已有训练归原账号',()=>{
 const a=app();a.change('account','');start(a);save(a,8);a.deliver();assert.equal(Object.keys(a.state().phone).length,0);
 a.change('account','A');a.deliver();a.change('account','B');a.action('start');save(a,10);a.deliver();
 const p=Object.values(a.state().phone)[0];assert.equal(p.account,'A');assert.equal(Object.keys(p.sets).length,2);
});
test('手机写库失败不确认；确认丢失后重试只补确认',()=>{
 const a=app();start(a);save(a,9);a.action('phoneFail');a.deliver();assert.equal(Object.keys(a.state().phone).length,0);
 a.action('ackLost');a.deliver();assert.equal(a.state().workouts[0].sets[0].status,'pending');
 assert.equal(Object.keys(Object.values(a.state().phone)[0].sets).length,1);a.deliver();assert.equal(a.state().workouts[0].sets[0].status,'received');
});
test('明确传输失败保持数据，重试恢复',()=>{
 const a=app();start(a);save(a,9);a.action('transferFail');a.deliver();assert.equal(a.state().workouts[0].sets[0].status,'failed');
 a.deliver();assert.equal(a.state().workouts[0].sets[0].status,'received');
});
test('采样中断停止估计，结束后仍能核对并保留前组',()=>{
 const a=app();start(a);save(a,8);a.action('start');a.action('inject','9');a.action('sensor');a.action('inject','8');
 assert.equal(a.state().current.estimate,9);a.action('stop');a.action('plus');a.action('save');assert.deepEqual(a.state().workouts[0].sets.map(s=>s.final),[8,10]);
});
test('放弃需要确认，取消不丢候选，确认不影响已保存组',()=>{
 const a=app();start(a);save(a,8);a.action('start');a.action('stop');a.action('discard');a.action('cancel');assert.ok(a.state().current);
 a.action('discard');a.action('discardYes');assert.equal(a.state().current,null);assert.equal(a.state().workouts[0].sets.length,1);
});
test('计次中结束先核对，放弃并结束保留待传任务',()=>{
 const a=app();a.change('connected',false,'checkbox');start(a);save(a,8);a.action('start');a.action('inject','9');a.action('end');
 assert.equal(a.state().page,'count');a.action('stop');a.action('end');a.action('cancel');assert.equal(a.state().current.candidate,9);
 a.action('end');a.action('discardEnd');assert.equal(a.state().page,'summary');assert.equal(a.state().workouts[0].sets[0].status,'pending');
 a.change('connected',true,'checkbox');a.deliver();assert.equal(a.state().workouts[0].endStatus,'received');
});
test('结束状态写入失败不丢候选，重试才结束',()=>{
 const a=app();start(a);a.action('stop');a.action('end');a.action('localFail');a.action('discardEnd');assert.ok(a.state().current);
 assert.match(a.state().notice,/尚未保存/);a.action('discardEnd');assert.equal(a.state().page,'summary');
});
test('空训练不生成手机记录，新训练使用新身份',()=>{
 const a=app();start(a);const first=a.state().active;a.action('stop');a.action('discard');a.action('discardYes');a.action('end');a.deliver();
 assert.equal(a.state().workouts.length,0);assert.equal(Object.keys(a.state().phone).length,0);a.action('new');start(a);assert.notEqual(a.state().active,first);
});
test('关闭 Should 休息计时不阻断 Must 主流程',()=>{
 const a=app();a.change('rest-demo',false,'checkbox');start(a);save(a,9);assert.equal(a.state().page,'rest');a.action('end');a.deliver();assert.equal(a.state().workouts[0].endStatus,'received');
});

test('直接输入未失焦时也保存最新候选，非法输入不回退旧值',()=>{
 const a=app();start(a);a.action('inject','9');a.action('stop');a.input('0');a.action('save');assert.equal(a.state().page,'review');
 a.input('2');a.action('save');assert.equal(a.state().workouts[0].sets[0].final,2);assert.equal(a.state().workouts[0].sets[0].estimate,9);
});
