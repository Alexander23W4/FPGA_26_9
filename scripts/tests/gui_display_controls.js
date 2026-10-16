// Run the real GUI event handlers through HTTP and the Python UART bridge.
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const source = fs.readFileSync(process.argv[2], 'utf8');
const script = source.match(/TAIL_SCRIPT = r"""<script>([\s\S]*?)<\/script>"""/)[1];
const elements = {}, pending = new Set(), alerts = [];
function element() {
  return {value: '0', textContent: '', disabled: false, files: [], listeners: {},
    addEventListener(event, fn) {this.listeners[event] = fn;},
    replaceChildren(...children) {this.children = children;}};
}
const document = {
  getElementById(id) {return elements[id] ||= element();},
  createElement: element, createTextNode: text => ({textContent: text})
};
const ctx = vm.createContext({document, updateOverlayControls() {}, updatePreviewLayout() {},
  poll: async () => {},
  fetch: path => fetch(process.argv[3] + path), alert: text => alerts.push(text)});
vm.runInContext(script, ctx);
// The change handler schedules a readback without awaiting it; drain it here.
const readback = ctx.dshReadback;
ctx.dshReadback = () => {
  const task = readback(); pending.add(task);
  task.finally(() => pending.delete(task)); return task;
};
async function settle() {while (pending.size) await Promise.all([...pending]);}
(async () => {
  const select = elements.fpgaOutputMode;
  const names = ['去噪处理','轮廓处理','二值掩膜处理','叠加掩膜处理','伪彩色热力图处理'];
  for (const mode of [3, 4, 2, 0, 1]) {
    select.value = String(mode);
    await select.listeners.change({target: select}); await settle();
    assert.strictEqual(elements.dshRbVid.textContent, names[mode]);
    assert.strictEqual(elements.dshRbThr.textContent, 120, 'display the active STATUS threshold, not manual DATA_REG=37');
    assert.strictEqual(Number(select.value), mode);
  }
  for (const alpha of [0,45,100]) {
    elements.maskOpacity.value = String(alpha);
    await elements.maskOpacityUpdate.listeners.click({currentTarget: elements.maskOpacityUpdate});
    assert.strictEqual(elements.dshRbAlpha.textContent, alpha+'%');
    assert.strictEqual(elements.maskOpacityUpdate.disabled, false);
  }
  select.value = '5';
  await select.listeners.change({target: select});
  await ctx.dshReadback();
  assert.strictEqual(select.value, '5', 'hardware readback must preserve full-display selection');
  assert.deepStrictEqual(alerts, []);
  console.log('GUI_DISPLAY_HTTP_OK: V0..4, P0/45/100 and full-display readback');
})().catch(error => {console.error(error); process.exitCode = 1;});
