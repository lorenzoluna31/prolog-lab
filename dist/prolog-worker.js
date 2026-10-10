'use strict';
// Keep the interpreter off the UI thread, including debugger callbacks.
importScripts('swipl/swipl-web.js');
let interpreter;
const ready = (async () => {
  interpreter = await SWIPL({
    arguments: ['-q'],
    locateFile: (file) => new URL('swipl/' + file, self.location.href).href,
    print: () => {}, printErr: () => {}
  });
  const response = await fetch('engine.pl');
  if (!response.ok) throw new Error('No se pudo cargar el laboratorio de Prolog.');
  interpreter.FS.writeFile('/engine.pl', await response.text());
  if (!interpreter.prolog.query("set_prolog_flag(encoding,utf8),consult('/engine.pl').").once().success)
    throw new Error('No se pudo iniciar el laboratorio de Prolog.');
  const version = interpreter.prolog.query('current_prolog_flag(version_data,V),term_string(V,Version).').once().Version.v;
  self.postMessage({type:'ready',version});
})();
ready.catch(error => self.postMessage({type:'fatal',error:String(error.message || error)}));
self.onmessage = async ({data}) => {
  if (data.type !== 'run') return;
  try {
    await ready;
    const answer = interpreter.prolog.query('run_json(JSON,Text).', {JSON:JSON.stringify(data.request)}).once();
    if (!answer.success || !answer.Text) throw new Error('Prolog no devolvió un resultado.');
    self.postMessage({type:'result',id:data.id,result:JSON.parse(answer.Text.v)});
  } catch(error) {
    self.postMessage({type:'result',id:data.id,result:{ok:false,error:String(error.message || error),events:[],answers:[]}});
  }
};
