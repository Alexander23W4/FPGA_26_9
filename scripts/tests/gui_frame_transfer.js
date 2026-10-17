// Run real selection, mode and threshold events through HTTP/TCP and saved images.
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
const ctx = vm.createContext({document, URLSearchParams, performance, setInterval() {},
  window: {matchMedia: () => ({matches: false, addEventListener() {}})},
  alert: value => alerts.push(value), fetch: (url, options) => {
    if (url.startsWith('/api/network/') && url !== '/api/network/state') {
      calls.push(url);
      for (const id of ['imageFile', 'chooseImage', 'fpgaOutputMode', 'maskOpacityUpdate'])
        assert.strictEqual(elements[id].disabled, true);
    }
    return fetch(process.argv[3] + url, options);
  }});
vm.runInContext(fs.readFileSync(path.join(path.dirname(process.argv[2]), 'assets/heartcare.js'), 'utf8'), ctx);
vm.runInContext(script, ctx);
const input = Uint8Array.from({length: 65536}, (_, i) => i & 255);
elements.imageFile.files = [{name: 'gui_input.bin', size: 65536, arrayBuffer: async () => input.buffer}];
async function emit(id, event) {
  const target = elements[id];
  for (const listener of target.listeners[event]) await listener({target, currentTarget: target});
}
(async () => {
  await ctx.poll();
  const selected = process.argv[4] || '5';
  elements.fpgaOutputMode.value = selected;
  await emit('fpgaOutputMode', 'change'); // Configure mode before the first image.
  await emit('imageFile', 'change'); // Selection alone must upload and process.
  assert.deepStrictEqual(calls, ['/api/network/render?mode=' + selected,
    '/api/network/transfer?index=0&name=gui_input.bin&mode=' + selected]);
  assert.deepStrictEqual(alerts, []);
  for (const id of ['imageFile', 'chooseImage', 'fpgaOutputMode']) assert.strictEqual(elements[id].disabled, false);
  assert.strictEqual(elements.processingStatus.textContent, '');
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
  // Opacity success reruns the selected mode(s); failed readback sends no image.
  elements.fpgaOutputMode.value = selected;
  elements.maskOpacity.value = '35';
  await emit('maskOpacityUpdate', 'click');
  assert.strictEqual(calls.at(-1), '/api/network/transfer?index=0&name=gui_input.bin&mode=' + selected);
  assert.strictEqual(elements.dshRbAlpha.textContent, '35%');
  assert.strictEqual(elements.fpgaOutputMode.value, selected);
  assert.strictEqual(elements.maskOpacityUpdate.disabled, false);
  assert.deepStrictEqual(alerts, []);
  await emit('maskOpacityUpdate', 'click');
  assert.strictEqual(calls.length, 3, 'failed opacity write must not upload a frame');
  assert.strictEqual(alerts.length, 1);
  assert.match(alerts[0], /掩膜透明度更新失败/);
  alerts.length = 0;
  // A display change sends only RENDER, followed by a threshold-triggered UPLOAD.
  elements.fpgaOutputMode.value = '3';
  await emit('fpgaOutputMode', 'change');
  assert.strictEqual(calls.at(-1), '/api/network/render?mode=3');
  elements.thresholdMode.setAttribute('aria-checked', 'true');
  elements.threshold.value = '77';
  await ctx.dshThrUpdate();
  assert.strictEqual(calls.at(-1), '/api/network/transfer?index=0&name=gui_input.bin&mode=3');
  assert.deepStrictEqual(alerts, []);
  await ctx.dshThrUpdate(); // This time the mock PS reports a mismatched threshold.
  assert.strictEqual(calls.length, 5, 'failed threshold write must not upload a frame');
  assert.strictEqual(alerts.length, 1);
  assert.match(alerts[0], /阈值更新失败/);
  elements.imageFile.files[0].size = 65535;
  await emit('imageFile', 'change');
  assert.strictEqual(calls.length, 5);
  assert.strictEqual(alerts.length, 2);
  assert.match(alerts[1], /65536/);
  assert.strictEqual(elements.processingStatus.textContent, '');
  // A timeout response shows one modal and invalidates reuse of the old upload.
  const originalFetch = ctx.fetch;
  elements.imageFile.files[0].size = 65536;
  ctx.fetch = async url => {
    assert.strictEqual(url, '/api/network/render?mode=3');
    return {ok: true, json: async () => ({ok: false, timeout: true, results: [],
      log: '等待 FPGA 回传超时，本次任务已取消'})};
  };
  await ctx.dshRun(() => ctx.dshProcess(false));
  assert.strictEqual(alerts.length, 3);
  assert.match(alerts[2], /回传超时/);
  assert.strictEqual(elements.processingStatus.textContent, '');
  for (const id of ['imageFile', 'chooseImage', 'fpgaOutputMode']) assert.strictEqual(elements[id].disabled, false);
  let freshUpload = false;
  ctx.fetch = async (url, options) => {
    if (url.startsWith('/api/state')) return originalFetch(url, options);
    assert.strictEqual(url, '/api/network/transfer?index=0&name=gui_input.bin&mode=3');
    assert.strictEqual(options.method, 'POST');
    freshUpload = true;
    return {ok: true, json: async () => ({ok: true, frames: 1, results: []})};
  };
  await ctx.dshRun(() => ctx.dshProcess(false));
  assert.strictEqual(freshUpload, true, 'next operation starts a new upload after timeout');
  assert.strictEqual(alerts.length, 3);
  assert.strictEqual(elements.processingStatus.textContent, '');
  ctx.fetch = originalFetch;
  // HDMI OFF is just a checked register write; ON resends exactly one image.
  alerts.length=0;
  const beforeHdmi=calls.length;
  await emit('hdmiOutputToggle','click');
  assert.strictEqual(elements.hdmiOutputToggle.getAttribute('aria-checked'),'false');
  assert.strictEqual(calls.length,beforeHdmi,'HDMI OFF must not upload');
  await emit('hdmiOutputToggle','click');
  assert.strictEqual(elements.hdmiOutputToggle.getAttribute('aria-checked'),'true');
  assert.strictEqual(calls.length,beforeHdmi+1,'HDMI ON must upload exactly one image');
  assert.strictEqual(calls.at(-1),'/api/network/transfer?index=0&name=gui_input.bin&mode=3');
  await emit('hdmiOutputToggle','click');
  assert.strictEqual(elements.hdmiOutputToggle.getAttribute('aria-checked'),'true','failed write keeps confirmed state');
  assert.strictEqual(calls.length,beforeHdmi+1,'failed write must not upload');
  assert.strictEqual(alerts.length,1);assert.match(alerts[0],/HDMI/);
  console.log('GUI_FRAME_HTTP_OK: selection auto upload, opacity/threshold reupload after verified write, mode-only render, durable save, no success modal');
})().catch(error => {console.error(error); process.exitCode = 1;});
