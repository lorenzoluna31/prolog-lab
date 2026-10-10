const fs=require('node:fs');
const assert=require('node:assert/strict');
const path=require('node:path');
const SWIPL=require('./dist/swipl/swipl-web.js');
(async()=>{
  const diagnostics=[];
  const swipl=await SWIPL({arguments:['-q'],locateFile:file=>path.resolve('dist/swipl',file),printErr:line=>diagnostics.push(line)});
  swipl.FS.writeFile('/engine.pl',fs.readFileSync('./dist/engine.pl','utf8'));
  assert(swipl.prolog.query("consult('/engine.pl').").once().success);
  const run=(code,query,trace=false,options={})=>{
    const JSONInput=JSON.stringify({code,query,trace,maxAnswers:30,inferences:1500000,...options});
    const answer=swipl.prolog.query('run_json(JSON,Text).',{JSON:JSONInput}).once();
    assert(answer.success);
    return JSON.parse(answer.Text.v);
  };
  const catalog=JSON.parse(fs.readFileSync('./dist/catalog.json','utf8'));
  let count=0;
  for(const exercise of catalog.exercises){
    for(const variant of [{label:'principal',code:exercise.solution},...exercise.variants]){
      for(const test of exercise.tests){
        const result=run(variant.code,test.query);
        assert(result.ok && result.answers.length>0,`${exercise.id} ${variant.label} ${test.label}: ${result.error||'false'}`);
        count++;
      }
    }
  }
  const code='pertenece(X,[X|_]).\npertenece(X,[_|Xs]):-pertenece(X,Xs).';
  const trace=run(code,'pertenece(X,[a,b]).',true);
  assert.deepEqual(trace.answers.map(a=>a.text),['X = a','X = b']);
  assert(trace.events.some(e=>e.port==='redo'));
  assert(trace.events.some(e=>e.line===2&&e.clause));
  assert(trace.events.every(e=>e.goal.startsWith('pertenece(')));
  assert.equal(trace.events.length,15); count++;
  const cut=run('p(a):-!.\np(b).','p(X).',true);
  assert.deepEqual(cut.answers.map(a=>a.text),['X = a']);
  assert(cut.events.some(e=>e.port==='cut'));count++;
  assert(!run('', 'pertenece(a,[a]).').ok,'Prior code must be removed');count++;
  assert(!run(':- initialization(halt).\np.','p.').ok);count++;
  assert(!run('p:-js_run_script("fetch(\'https://example.org\')").','p.').ok);count++;
  assert(!run('p:-open("/tmp/x",write,_).','p.').ok);count++;
  assert(!run('p:-halt.','p.').ok);count++;
  assert(!run('p:-p.','p.',false,{inferences:2000}).ok);count++;
  assert(run('p(a).','p(X).').ok,'Recover after failed execution');count++;
  assert(!run('p(', 'true.').ok);count++;
  assert(run('p(b).','p(X).').answers[0].text==='X = b');count++;
  const output=run('p:-write(hola),nl.','p.');
  assert.equal(output.output,'hola\n');count++;
  const tail=run('sum([],0).\nsum([X|Xs],S):-sum(Xs,T),S is X+T.','sum([1,2],S).');
  assert.equal(tail.analysis.find(a=>a.predicate==='sum/2').tail,false);count++;
  const limit=run('p(a).\np(b).','p(X).',false,{maxAnswers:1});
  assert(limit.limited && limit.answers.length===1);count++;
  console.log(`${count} comprobaciones aprobadas en SWI-Prolog WebAssembly; ${catalog.exercises.length} actividades.`);
  if(diagnostics.length)console.log('Diagnósticos:',diagnostics.slice(0,4));
})().catch(error=>{console.error(error);process.exitCode=1});
