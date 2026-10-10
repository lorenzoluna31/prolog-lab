'use strict';
// The server hosts only public assets. Programs execute on the visitor's device.
window.PrologRuntime = (() => {
  let worker = null, boot = null, bootTimer = null, bootReject = null, sequence = 0;
  const pending = new Map();
  const failure = error => ({ok:false,error,events:[],answers:[]});
  function reset(error) {
    worker?.terminate(); worker = null;
    clearTimeout(bootTimer); bootReject?.(new Error(error)); bootReject = null; boot = null;
    for (const request of pending.values()) { clearTimeout(request.timer); request.resolve(failure(error)); }
    pending.clear();
  }
  function ensure() {
    if (boot) return boot;
    boot = new Promise((resolve,reject) => {
      bootReject = reject;
      if (!window.Worker || !window.WebAssembly) { reject(new Error('Este navegador no admite WebAssembly. Abrí el enlace en un navegador actualizado.')); return; }
      worker = new Worker(new URL('prolog-worker.js',document.baseURI));
      bootTimer = setTimeout(() => reset('No se pudo cargar Prolog a tiempo. Revisá la conexión y volvé a intentar.'),45000);
      worker.onmessage = ({data}) => {
        if (data.type === 'ready') {
          clearTimeout(bootTimer); bootReject = null;
          resolve({ok:true,engine:'SWI-Prolog',version:data.version});
        } else if (data.type === 'fatal') reset(data.error);
        else if (data.type === 'result') {
          const request = pending.get(data.id);
          if (request) { clearTimeout(request.timer); pending.delete(data.id); request.resolve(data.result); }
        }
      };
      worker.onerror = () => reset('No se pudo iniciar Prolog. Revisá la conexión y recargá la página.');
    });
    return boot;
  }
  async function run(code,query,trace=true,options={}) {
    if (typeof code!=='string' || typeof query!=='string') return failure('El programa y la consulta deben ser texto.');
    if (code.length>120000 || query.length>6000) return failure('El programa o la consulta supera el tamaño permitido.');
    query=query.trim().replace(/^\?-\s*/, '');
    if (!query) return failure('Escribí una consulta.');
    if (!query.endsWith('.')) query+='.';
    try { await ensure(); } catch(error) { return failure(error.message); }
    return new Promise(resolve => {
      const id=++sequence;
      const timer=setTimeout(() => reset('La consulta superó el límite de tiempo. Revisá el caso base o probá una entrada menor.'),5000);
      pending.set(id,{resolve,timer});
      worker.postMessage({type:'run',id,request:{code,query,trace,maxAnswers:options.maxAnswers||30,inferences:options.inferences||1500000}});
    });
  }
  return {ready:ensure,run};
})();
