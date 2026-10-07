/* OpenWalls panel.
 *
 * The panel never computes geometry and never holds authoritative state. It
 * renders whatever record Ruby sends and posts back a sparse patch of what
 * the user touched. Keeping it that dumb is why a mixed selection can be
 * edited safely: unspecified fields are simply not in the patch, so nothing
 * gets flattened to the first wall's values.
 */
(function () {
  'use strict';

  var state = { types: [], defaults: {}, selection: [], wallCount: 0 };
  var editingType = null;

  var bridge = (typeof window.sketchup === 'object' && window.sketchup) || null;

  function call(name, payload) {
    if (!bridge || typeof bridge[name] !== 'function') {
      console.log('[OpenWalls] ' + name, payload);
      return;
    }
    bridge[name](payload === undefined ? '' : JSON.stringify(payload));
  }

  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (key) {
      if (key === 'text') { node.textContent = attrs[key]; }
      else if (key === 'html') { node.innerHTML = attrs[key]; }
      else { node.setAttribute(key, attrs[key]); }
    });
    (children || []).forEach(function (child) { node.appendChild(child); });
    return node;
  }

  function mm(value) {
    if (value === null || value === undefined || value === '') { return '--'; }
    return Math.round(value * 10) / 10 + ' mm';
  }

  /* ---------------------------------------------------------------- tabs */

  $$('.tab').forEach(function (tab) {
    tab.addEventListener('click', function () {
      $$('.tab').forEach(function (t) { t.classList.remove('is-active'); });
      $$('.panel').forEach(function (p) { p.classList.remove('is-active'); });
      tab.classList.add('is-active');
      $('[data-panel="' + tab.dataset.tab + '"]').classList.add('is-active');
      if (tab.dataset.tab === 'takeoff') { call('ow_takeoff'); }
    });
  });

  /* --------------------------------------------------------------- tools */

  $$('.tool').forEach(function (button) {
    button.addEventListener('click', function () {
      call('ow_tool', { tool: button.dataset.tool, shape: button.dataset.shape || null });
    });
  });

  /* ------------------------------------------------------------ defaults */

  $$('[data-default]').forEach(function (input) {
    input.addEventListener('change', function () {
      var patch = {};
      patch[input.dataset.default] = input.type === 'number' ? parseFloat(input.value) : input.value;
      call('ow_defaults', patch);
    });
  });

  /* ---------------------------------------------------------------- wall */

  $('#apply').addEventListener('click', function () {
    var patch = {};
    $$('[data-patch]').forEach(function (input) {
      var key = input.dataset.patch;
      if (input.value === '' && key === 'height_mid') { patch[key] = null; return; }
      if (input.value === '') { return; }
      patch[key] = input.type === 'number' ? parseFloat(input.value) : input.value;
    });
    call('ow_apply', patch);
  });

  function fillTypeSelect(select, selectedId) {
    select.innerHTML = '';
    state.types.forEach(function (type) {
      var total = type.layers.reduce(function (sum, l) { return sum + l.thickness; }, 0);
      var option = el('option', { value: type.id, text: type.name + '  (' + Math.round(total) + ' mm)' });
      if (type.id === selectedId) { option.selected = true; }
      select.appendChild(option);
    });
  }

  function renderWall() {
    var walls = state.selection;
    $('#wall-empty').hidden = walls.length > 0;
    $('#wall-form').hidden = walls.length === 0;
    if (!walls.length) { return; }

    var first = walls[0];
    $('#wall-status').textContent = walls.length === 1
      ? first.name + ' -- ' + mm(first.type.layers.reduce(function (s, l) { return s + l.thickness; }, 0)) + ' thick'
      : walls.length + ' walls selected. Only the fields you change are applied.';

    $('#w-name').value = walls.length === 1 ? (first.name || '') : '';
    fillTypeSelect($('#w-type'), first.type.id);
    $('#w-just').value = first.justification;
    $('#w-hs').value = first.height_start;
    $('#w-he').value = first.height_end;
    $('#w-hm').value = first.height_mid === null || first.height_mid === undefined ? '' : first.height_mid;
    $('#w-base').value = first.base_z;

    drawProfile(first);
    renderOpenings(walls);
  }

  /* A small elevation of the top profile, so a gable is obvious at a glance
     instead of being three numbers you have to picture. */
  function drawProfile(record) {
    var svg = $('#profile');
    var hs = record.height_start;
    var he = record.height_end;
    var hm = record.height_mid;
    var peak = Math.max(hs, he, hm || 0) || 1;
    var y = function (h) { return 80 - (h / peak) * 66; };

    var top = hm === null || hm === undefined
      ? '10,' + y(hs) + ' 290,' + y(he)
      : '10,' + y(hs) + ' 150,' + y(hm) + ' 290,' + y(he);

    svg.innerHTML =
      '<polygon points="10,80 ' + top + ' 290,80" fill="rgba(76,154,255,.22)" stroke="#4c9aff" stroke-width="1.5"/>' +
      '<line x1="10" y1="80" x2="290" y2="80" stroke="#8b94a6" stroke-width="1"/>' +
      '<text x="12" y="' + (y(hs) - 4) + '" fill="#8b94a6" font-size="9">' + Math.round(hs) + '</text>' +
      (hm ? '<text x="140" y="' + (y(hm) - 4) + '" fill="#8b94a6" font-size="9">' + Math.round(hm) + '</text>' : '') +
      '<text x="262" y="' + (y(he) - 4) + '" fill="#8b94a6" font-size="9">' + Math.round(he) + '</text>';
  }

  function renderOpenings(walls) {
    var host = $('#openings');
    host.innerHTML = '';
    var all = [];
    walls.forEach(function (wall) {
      (wall.openings || []).forEach(function (op) { all.push(op); });
    });
    $('#op-count').textContent = all.length ? '(' + all.length + ')' : '';

    if (!all.length) {
      host.appendChild(el('p', { class: 'hint', text: 'No openings yet. Use the Door or Window tool.' }));
      return;
    }

    all.forEach(function (op) {
      var info = el('div', {}, [
        el('b', { text: op.name + ' ' + op.id }),
        el('small', {
          text: op.shape + ' -- ' + Math.round(op.width) + ' x ' + Math.round(op.height) +
            ' mm, sill ' + Math.round(op.sill) + ', at ' + Math.round(op.station) + ' mm'
        })
      ]);
      var kill = el('button', { class: 'kill', text: '\u00d7', title: 'Delete this opening' });
      kill.addEventListener('click', function () { call('ow_delete_opening', { id: op.id }); });
      host.appendChild(el('div', { class: 'opening' }, [info, kill]));
    });
  }

  /* ------------------------------------------------------------- build-up */

  var LAYER_KINDS = ['structure', 'masonry', 'insulation', 'cavity', 'membrane', 'finish', 'cladding', 'sheathing'];

  var KIND_COLOURS = {
    structure: '#a0a09e', masonry: '#96543f', insulation: '#e2c678', cavity: '#2b303a',
    membrane: '#5f7fa5', finish: '#ece8de', cladding: '#966e46', sheathing: '#c6a670'
  };

  $('#t-pick').addEventListener('change', function () {
    editingType = JSON.parse(JSON.stringify(
      state.types.filter(function (t) { return t.id === $('#t-pick').value; })[0]
    ));
    renderType();
  });

  $('#add-layer').addEventListener('click', function () {
    if (!editingType) { return; }
    editingType.layers.push({ name: 'New layer', kind: 'structure', thickness: 100, material: 'Concrete' });
    renderType();
  });

  $('#save-type').addEventListener('click', function () {
    if (!editingType) { return; }
    editingType.id = $('#t-id').value.trim() || editingType.id;
    editingType.name = $('#t-name').value.trim() || editingType.name;
    call('ow_save_type', editingType);
  });

  function renderType() {
    if (!editingType) { return; }
    $('#t-name').value = editingType.name;
    $('#t-id').value = editingType.id;

    var total = editingType.layers.reduce(function (sum, l) { return sum + Number(l.thickness || 0); }, 0);
    $('#t-total').textContent = Math.round(total * 10) / 10 + ' mm total';

    var stack = $('#stack');
    stack.innerHTML = '';
    editingType.layers.forEach(function (layer) {
      var share = total ? (Number(layer.thickness) / total) * 100 : 0;
      var cell = el('div', { text: share > 9 ? Math.round(layer.thickness) : '' });
      cell.style.width = share + '%';
      cell.style.background = KIND_COLOURS[layer.kind] || '#999';
      cell.title = layer.name + ' -- ' + layer.kind + ' -- ' + mm(layer.thickness);
      stack.appendChild(cell);
    });

    var host = $('#layers');
    host.innerHTML = '';
    editingType.layers.forEach(function (layer, index) {
      var name = el('input', { type: 'text', value: layer.name });
      var thickness = el('input', { type: 'number', step: '0.5', value: layer.thickness });
      var kind = el('select');
      LAYER_KINDS.forEach(function (k) {
        var option = el('option', { value: k, text: k });
        if (k === layer.kind) { option.selected = true; }
        kind.appendChild(option);
      });
      var material = el('input', { type: 'text', value: layer.material || '', placeholder: 'material' });
      var kill = el('button', { class: 'kill', text: '\u00d7' });

      name.addEventListener('input', function () { layer.name = name.value; });
      thickness.addEventListener('input', function () { layer.thickness = parseFloat(thickness.value) || 0; renderType(); });
      kind.addEventListener('change', function () { layer.kind = kind.value; renderType(); });
      material.addEventListener('input', function () { layer.material = material.value; });
      kill.addEventListener('click', function () { editingType.layers.splice(index, 1); renderType(); });

      host.appendChild(el('div', { class: 'row' }, [name, thickness, kind, material, kill]));
    });
  }

  /* ------------------------------------------------------------- takeoff */

  $('#refresh-takeoff').addEventListener('click', function () { call('ow_takeoff'); });
  $('#export-takeoff').addEventListener('click', function () { call('ow_export'); });

  function renderSheets(sheets) {
    var host = $('#sheets');
    host.innerHTML = '';
    if (sheets.error) {
      host.appendChild(el('p', { class: 'hint', text: sheets.error }));
      return;
    }
    Object.keys(sheets).forEach(function (name) {
      var rows = sheets[name];
      if (!rows || !rows.length) { return; }
      host.appendChild(el('h2', { text: name }));

      var headers = Object.keys(rows[0]);
      var thead = el('tr', {}, headers.map(function (h) { return el('th', { text: h }); }));
      var body = rows.map(function (row) {
        return el('tr', {}, headers.map(function (h) {
          return el('td', { text: row[h] === null || row[h] === undefined ? '' : String(row[h]) });
        }));
      });
      host.appendChild(el('table', {}, [thead].concat(body)));
    });
  }

  /* -------------------------------------------------------------- inbound */

  window.OpenWalls = {
    receive: function (channel, payload) {
      if (channel === 'ow:state') {
        state = payload;
        $('#version').textContent = 'v' + (payload.version || '');
        $('#model-status').textContent = payload.wallCount + ' wall'
          + (payload.wallCount === 1 ? '' : 's') + ' in this model.';

        fillTypeSelect($('#d-type'), payload.defaults.type_id);
        $('#d-height').value = payload.defaults.height;
        $('#d-base').value = payload.defaults.base_z;
        $('#d-just').value = payload.defaults.justification;
        $('#d-tol').value = payload.defaults.tolerance;

        var picker = $('#t-pick');
        var keep = picker.value;
        picker.innerHTML = '';
        payload.types.forEach(function (type) {
          picker.appendChild(el('option', { value: type.id, text: type.name }));
        });
        picker.value = keep && payload.types.some(function (t) { return t.id === keep; })
          ? keep : (payload.defaults.type_id || (payload.types[0] || {}).id);
        if (!editingType || !payload.types.some(function (t) { return t.id === editingType.id; })) {
          editingType = JSON.parse(JSON.stringify(
            payload.types.filter(function (t) { return t.id === picker.value; })[0] || null
          ));
        }
        renderType();
        renderWall();
      } else if (channel === 'ow:takeoff') {
        renderSheets(payload);
      }
    }
  };

  call('ow_ready');
})();
