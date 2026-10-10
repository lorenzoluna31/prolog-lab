'use strict';
// Move the original editor, including its input handlers, into the dialog.
// There is only one draft and one textarea in both layouts.
window.PrologEditor = (() => {
  let mount = null;
  const element = id => document.getElementById(id);
  const dialog = element('editor-dialog');
  function updateButton(expanded) {
    const button=element('expand-editor');
    if (!button) return;
    button.setAttribute('aria-expanded',String(expanded));
    button.setAttribute('aria-label',expanded?'Salir del editor ampliado':'Ampliar editor');
    button.querySelector('span').textContent=expanded?'Volver':'Ampliar';
  }
  function restore(focus=true) {
    if (!mount) return;
    const {content,parent,next}=mount;
    mount=null;
    parent.insertBefore(content,next?.parentNode===parent?next:null);
    document.body.classList.remove('editor-expanded');
    updateButton(false);
    if (focus) element('expand-editor')?.focus({preventScroll:true});
    element('line-numbers').scrollTop=element('code').scrollTop;
  }
  function close(focus=true) {
    if (dialog.open) dialog.close();
    restore(focus);
  }
  function open() {
    if (mount) return;
    const content=element('editor-content'),code=element('code');
    if (!content || !code) return;
    const start=code.selectionStart,end=code.selectionEnd,direction=code.selectionDirection;
    const top=code.scrollTop,left=code.scrollLeft;
    mount={content,parent:content.parentNode,next:content.nextSibling};
    element('expanded-editor-body').append(content);
    document.body.classList.add('editor-expanded');
    updateButton(true);
    dialog.showModal();
    code.focus({preventScroll:true});
    code.setSelectionRange(start,end,direction);
    code.scrollTop=top;code.scrollLeft=left;
    element('line-numbers').scrollTop=top;
  }
  element('close-expanded-editor').onclick=()=>close();
  dialog.addEventListener('cancel',event=>{event.preventDefault();close();});
  dialog.addEventListener('close',()=>restore());
  return {
    open,close,
    get expanded(){return !!mount;},
    bind(){element('expand-editor').onclick=()=>mount?close():open();}
  };
})();
