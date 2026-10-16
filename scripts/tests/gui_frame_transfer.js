// Run both real browser scripts, the transfer button, polling and image rendering.
const fs = require('fs'), vm = require('vm'), assert = require('assert'), path = require('path');
const source = fs.readFileSync(process.argv[2], 'utf8');
const script = source.match(/TAIL_SCRIPT = r"""<script>([\s\S]*?)<\/script>"""/)[1];
const elements = {}, alerts = [], calls = [];
const names = ['去噪处理', '轮廓处理', '二值掩膜处理', '叠加掩膜处理', '伪彩色热力图处理', '全显示'];
function element() {
  return {value: '0', textContent: '', disabled: false, src: '', hidden: false, listeners: {}, attributes: {},
    get selectedOptions() {return [{textContent: names[Number(this.value)] || this.value}];},
    addEventListener(event, fn) {(this.listeners[event] ||= []).push(fn);},
    setAttribute(key, value) {this.attributes[key] = value;},
    getAttribute(key) {return this.attributes[key];},
    removeAttribute(key) {delete this.attributes[key]; if (key === 'src') this.src = '';},
    replaceChildren(...children) {this.children = children;},
    append() {}, appendChild() {}, querySelectorAll() {return [];}};
}
const document = {
  getElementById(id) {return elements[id] ||= element();},
  querySelector: element, querySelectorAll: () => [], addEventListener() {},
  createElement: element, createDocumentFragment: element, createTextNode: text => ({textContent: text}),
  body: {classList: {contains: () => false, toggle() {}, remove() {}}}
};
document.getElementById('systemMode').value = 'processing';
document.getElementById('width').value = '255';
document.getElementById('center').value = '128';
const ctx = vm.createContext({document, URLSearchParams, setInterval() {},
  window: {matchMedia: () => ({matches: false, addEventListener() {}})},
  alert: value => alerts.push(value), fetch: (url, options) => {
    if (url.startsWith('/api/network/transfer')) {
      calls.push(url);
      for (const id of ['transfer', 'imageFile', 'chooseImage', 'fpgaOutputMode', 'maskOpacityUpdate'])
        assert.strictEqual(elements[id].disabled, true);
    }
    return fetch(process.argv[3] + url, options);
  }});
vm.runInContext(fs.readFileSync(path.join(path.dirname(process.argv[2]), 'assets/heartcare.js'), 'utf8'), ctx);
vm.runInContext(script, ctx);
const input = Uint8Array.from({length: 65536}, (_, i) => i & 255);
elements.imageFile.files = [{name: 'gui_input.bin', size: 65536, arrayBuffer: async () => input.buffer}];
document.getElementById('transfer').textContent = '传输给FPGA';
(async () => {
  await ctx.poll();
  const selected = process.argv[4] || '5';
  elements.fpgaOutputMode.value = selected;
  ctx.updatePreviewLayout();
  await ctx.dshTransfer();
  assert.deepStrictEqual(calls, ['/api/network/transfer?index=0&name=gui_input.bin&mode=' + selected]);
  assert.deepStrictEqual(alerts, []);
  for (const id of ['transfer', 'imageFile', 'chooseImage', 'fpgaOutputMode']) assert.strictEqual(elements[id].disabled, false);
  assert.strictEqual(elements.transfer.textContent, '传输给FPGA');
  await ctx.poll();
  const modes = selected === '5' ? [0,1,2,3,4] : [Number(selected)];
  for (let mode = 0; mode < 5; mode++) {
    const image = elements['fullViewMode' + mode];
    assert.strictEqual(image.hidden, !modes.includes(mode));
    if (modes.includes(mode)) {
      assert.match(image.src, /^data:image\/png;base64,/);
      assert.match(image.title, /gui_input_.*\.bin$/);
    }
  }
  assert.strictEqual(elements.fullPreview.hidden, selected !== '5');
  if (selected === '5') {
    await ctx.dshReadback();
    assert.strictEqual(elements.fpgaOutputMode.value, '5');
    elements.fpgaOutputMode.value = '2';
    ctx.updatePreviewLayout();
    assert.strictEqual(elements.comparisonProcessed.src, elements.fullViewMode2.src);
    assert.strictEqual(elements.comparisonProcessed.hidden, false);
  } else {
    assert.strictEqual(elements.comparisonProcessed.src, elements['fullViewMode' + selected].src);
  }
  elements.imageFile.files[0].size = 65535;
  await ctx.dshTransfer();
  assert.strictEqual(calls.length, 1);
  assert.strictEqual(alerts.length, 1);
  assert.match(alerts[0], /65536/);
  console.log('GUI_FRAME_HTTP_OK: real scripts -> mode writes -> TCP -> saved BIN -> ACK -> displayed PNG');
})().catch(error => {console.error(error); process.exitCode = 1;});
