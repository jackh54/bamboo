// Page access for AI agents. Runs in the isolated "bamboo-agent" content world,
// so the page can't see or tamper with it, and installs itself once per
// document. Refs ("e1", "e2", …) live in this world and stay stable for an
// element across snapshots; a navigation starts a fresh world and fresh refs.
if (!globalThis.__bambooAgent) {
  globalThis.__bambooAgent = (() => {
    const MAX_SNAPSHOT_CHARS = 40000;
    const MAX_NAME_CHARS = 120;
    const MAX_OPTIONS = 40;
    const HIGHLIGHT_TAG = 'bamboo-agent-highlight';

    const refs = new Map();
    const refOf = new WeakMap();
    let nextRef = 1;

    function refFor(el) {
      let ref = refOf.get(el);
      if (!ref) {
        ref = 'e' + nextRef++;
        refOf.set(el, ref);
      }
      refs.set(ref, new WeakRef(el));
      return ref;
    }

    function resolve(ref) {
      const el = refs.get(ref)?.deref();
      if (!el || !el.isConnected) {
        throw new Error(`Ref ${ref} is not on the page any more. Call snapshot to get current refs.`);
      }
      return el;
    }

    // MARK: Roles, names and states

    const INPUT_ROLES = {
      button: 'button', submit: 'button', reset: 'button', image: 'button', file: 'button',
      checkbox: 'checkbox', radio: 'radio', range: 'slider', number: 'spinbutton', search: 'searchbox',
    };
    const NAME_FROM_CONTENT = new Set([
      'button', 'cell', 'checkbox', 'columnheader', 'gridcell', 'heading', 'link', 'menuitem',
      'menuitemcheckbox', 'menuitemradio', 'option', 'radio', 'rowheader', 'switch', 'tab', 'tooltip', 'treeitem',
    ]);
    // Roles whose content is summed up by their name; their subtree isn't listed.
    const LEAF_ROLES = new Set([
      'button', 'link', 'heading', 'textbox', 'searchbox', 'checkbox', 'radio', 'switch', 'slider',
      'spinbutton', 'img', 'option', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
      'progressbar', 'meter', 'separator', 'treeitem',
    ]);
    const SKIPPED_TAGS = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link', HIGHLIGHT_TAG]);

    function isSectioningAncestor(el) {
      for (let p = el.parentElement; p; p = p.parentElement) {
        if (['article', 'aside', 'main', 'nav', 'section'].includes(p.localName)) return true;
      }
      return false;
    }

    function implicitRole(el) {
      switch (el.localName) {
        case 'a': case 'area': return el.hasAttribute('href') ? 'link' : null;
        case 'button': return 'button';
        case 'input': {
          const type = (el.getAttribute('type') || 'text').toLowerCase();
          if (type === 'hidden') return null;
          if (el.hasAttribute('list') && ['text', 'search', 'email', 'tel', 'url'].includes(type)) return 'combobox';
          return INPUT_ROLES[type] ?? 'textbox';
        }
        case 'textarea': return 'textbox';
        case 'select': return el.multiple || el.size > 1 ? 'listbox' : 'combobox';
        case 'option': return 'option';
        case 'optgroup': case 'fieldset': case 'details': return 'group';
        case 'summary': return 'button';
        case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': return 'heading';
        case 'img': return el.getAttribute('alt') === '' ? null : 'img';
        case 'nav': return 'navigation';
        case 'main': return 'main';
        case 'header': return isSectioningAncestor(el) ? null : 'banner';
        case 'footer': return isSectioningAncestor(el) ? null : 'contentinfo';
        case 'aside': return 'complementary';
        case 'form': return 'form';
        case 'section': return el.hasAttribute('aria-label') || el.hasAttribute('aria-labelledby') ? 'region' : null;
        case 'article': return 'article';
        case 'ul': case 'ol': case 'menu': return 'list';
        case 'li': return 'listitem';
        case 'dt': return 'term';
        case 'dd': return 'definition';
        case 'table': return 'table';
        case 'thead': case 'tbody': case 'tfoot': return 'rowgroup';
        case 'tr': return 'row';
        case 'th': return el.getAttribute('scope') === 'row' ? 'rowheader' : 'columnheader';
        case 'td': return 'cell';
        case 'p': return 'paragraph';
        case 'blockquote': return 'blockquote';
        case 'code': return 'code';
        case 'dialog': return 'dialog';
        case 'hr': return 'separator';
        case 'progress': return 'progressbar';
        case 'meter': return 'meter';
        case 'figure': return 'figure';
        case 'iframe': case 'frame': return 'iframe';
        case 'output': return 'status';
        default: return el.isContentEditable && !el.parentElement?.isContentEditable ? 'textbox' : null;
      }
    }

    function roleOf(el) {
      const explicit = el.getAttribute('role')?.trim().split(/\s+/)[0];
      if (explicit === 'presentation' || explicit === 'none') return null;
      return explicit || implicitRole(el);
    }

    function clean(text, limit = MAX_NAME_CHARS) {
      const collapsed = (text || '').replace(/\s+/g, ' ').trim();
      return collapsed.length > limit ? collapsed.slice(0, limit - 1) + '…' : collapsed;
    }

    // Child nodes as rendered: a shadow root replaces the light DOM, and a slot
    // shows what is assigned to it.
    function renderedChildren(node) {
      if (node.shadowRoot) return [...node.shadowRoot.childNodes];
      if (node.localName === 'slot') {
        const assigned = node.assignedNodes({ flatten: true });
        return assigned.length ? assigned : [...node.childNodes];
      }
      return [...node.childNodes];
    }

    function isRendered(el) {
      if (el.getAttribute('aria-hidden') === 'true') return false;
      return typeof el.checkVisibility === 'function'
        ? el.checkVisibility()
        : getComputedStyle(el).display !== 'none';
    }

    function textOf(node, exclude) {
      if (node.nodeType === Node.TEXT_NODE) return node.data;
      if (node.nodeType !== Node.ELEMENT_NODE && node.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) return '';
      if (node === exclude) return '';
      if (node.nodeType === Node.ELEMENT_NODE) {
        if (SKIPPED_TAGS.has(node.localName) || !isRendered(node)) return '';
        const label = node.getAttribute('aria-label');
        if (label?.trim()) return ' ' + label + ' ';
        if (node.localName === 'img') return ' ' + (node.getAttribute('alt') || '') + ' ';
        if (['select', 'textarea'].includes(node.localName)) return '';
        if (node.localName === 'input') return ['submit', 'button', 'reset'].includes(node.type) ? ' ' + node.value + ' ' : '';
      }
      const block = node.nodeType === Node.ELEMENT_NODE && getComputedStyle(node).display !== 'inline';
      const inner = renderedChildren(node).map((child) => textOf(child, exclude)).join('');
      return block ? ' ' + inner + ' ' : inner;
    }

    function nameOf(el, role) {
      const doc = el.ownerDocument;
      const labelledBy = el.getAttribute('aria-labelledby');
      if (labelledBy) {
        const text = labelledBy.split(/\s+/).map((id) => doc.getElementById(id)).filter(Boolean)
          .map((labelElement) => textOf(labelElement)).join(' ');
        if (text.trim()) return clean(text);
      }
      const ariaLabel = el.getAttribute('aria-label');
      if (ariaLabel?.trim()) return clean(ariaLabel);

      const tag = el.localName;
      if (tag === 'input' || tag === 'textarea' || tag === 'select') {
        const type = el.type;
        if (type === 'submit' || type === 'reset' || type === 'button') {
          return clean(el.value || (type === 'submit' ? 'Submit' : type === 'reset' ? 'Reset' : ''));
        }
        if (type === 'image') return clean(el.alt || 'Submit');
        const labels = [...(el.labels ?? [])].map((label) => textOf(label, el)).join(' ');
        if (labels.trim()) return clean(labels);
        return clean(el.getAttribute('placeholder') || el.title);
      }
      if (tag === 'img' || tag === 'area') return clean(el.getAttribute('alt') || el.title);
      if (tag === 'fieldset') return clean(el.querySelector(':scope > legend')?.textContent);
      if (tag === 'table') return clean(el.querySelector(':scope > caption')?.textContent);
      if (tag === 'figure') return clean(el.querySelector(':scope > figcaption')?.textContent);
      if (tag === 'iframe') return clean(el.title);
      if (NAME_FROM_CONTENT.has(role)) return clean(textOf(el));
      return clean(el.title);
    }

    function isPassword(el) {
      return el.localName === 'input' && el.type === 'password';
    }

    function valueOf(el, role) {
      if (el.localName === 'select') {
        return [...el.selectedOptions].map((option) => clean(option.label || option.text)).join(', ');
      }
      if (el.localName === 'input' || el.localName === 'textarea') {
        if (['checkbox', 'radio', 'submit', 'reset', 'button', 'image', 'file'].includes(el.type)) return '';
        if (isPassword(el)) return el.value ? '••••••••' : '';
        return clean(el.value, 200);
      }
      if (role === 'textbox' && el.isContentEditable) return clean(el.innerText, 200);
      if (['slider', 'spinbutton', 'progressbar', 'meter', 'scrollbar'].includes(role)) {
        return el.getAttribute('aria-valuetext') || el.getAttribute('aria-valuenow') || (el.value ?? '').toString();
      }
      return '';
    }

    function statesOf(el, role) {
      const states = [];
      if (role === 'heading') {
        const level = el.getAttribute('aria-level') || (/^h([1-6])$/.exec(el.localName) || [])[1];
        if (level) states.push(`level=${level}`);
      }
      const ariaChecked = el.getAttribute('aria-checked');
      if (el.localName === 'input' && (el.type === 'checkbox' || el.type === 'radio')) {
        if (el.indeterminate) states.push('checked=mixed');
        else if (el.checked) states.push('checked');
      } else if (ariaChecked === 'true') {
        states.push('checked');
      } else if (ariaChecked === 'mixed') {
        states.push('checked=mixed');
      }
      if (el.matches(':disabled') || el.getAttribute('aria-disabled') === 'true') states.push('disabled');
      const expanded = el.localName === 'summary'
        ? String(el.parentElement?.open ?? false)
        : el.getAttribute('aria-expanded');
      if (expanded === 'true') states.push('expanded');
      if (expanded === 'false') states.push('collapsed');
      if ((el.localName === 'option' && el.selected) || el.getAttribute('aria-selected') === 'true') states.push('selected');
      const pressed = el.getAttribute('aria-pressed');
      if (pressed === 'true') states.push('pressed');
      if (el.required || el.getAttribute('aria-required') === 'true') states.push('required');
      if (el.ownerDocument.activeElement === el && el !== el.ownerDocument.body) states.push('focused');
      if (role === 'link') {
        const href = el.getAttribute('href');
        if (href) states.push(`href=${clean(href, 100)}`);
      }
      return states;
    }

    function hasPointerCursor(el) {
      if (getComputedStyle(el).cursor !== 'pointer') return false;
      const parent = el.parentElement;
      return !parent || getComputedStyle(parent).cursor !== 'pointer';
    }

    // MARK: Snapshot

    function walk(node, out) {
      if (node.nodeType === Node.TEXT_NODE) {
        // Whitespace-only nodes still separate words of neighbouring elements.
        if (node.data) out.push({ text: node.data.replace(/\s+/g, ' ') });
        return;
      }
      if (node.nodeType === Node.DOCUMENT_FRAGMENT_NODE) {
        renderedChildren(node).forEach((child) => walk(child, out));
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const el = node;
      if (SKIPPED_TAGS.has(el.localName) || !isRendered(el)) return;

      let role = roleOf(el);
      const visible = getComputedStyle(el).visibility !== 'hidden';
      if (!role && visible && (hasPointerCursor(el) || el.hasAttribute('onclick'))) role = 'generic';

      const children = [];
      if (role === 'iframe') {
        let frameDocument = null;
        try {
          frameDocument = el.contentDocument;
        } catch {
          // A cross-origin frame throws on access; it is reported as such below.
        }
        if (frameDocument?.body) walk(frameDocument.body, children);
        else children.push({ text: '(cross-origin frame, contents not shown)' });
      } else if (el.localName === 'select') {
        const options = [...el.options];
        for (const option of options.slice(0, MAX_OPTIONS)) {
          children.push({ role: 'option', name: clean(option.label || option.text), states: option.selected ? ['selected'] : [], children: [] });
        }
        if (options.length > MAX_OPTIONS) children.push({ text: `… ${options.length - MAX_OPTIONS} more options` });
      } else if (!LEAF_ROLES.has(role)) {
        renderedChildren(el).forEach((child) => walk(child, children));
      }

      if (!role || !visible) {
        const separate = getComputedStyle(el).display !== 'inline';
        if (separate) out.push({ text: ' ' });
        out.push(...children);
        if (separate) out.push({ text: ' ' });
        return;
      }
      const name = nameOf(el, role);
      const item = { role, name, states: statesOf(el, role), value: valueOf(el, role), ref: refFor(el), children: mergeText(children) };
      if (role === 'generic') item.states.push('cursor=pointer');
      // Name-from-content roles already show their text as the name.
      if (NAME_FROM_CONTENT.has(role) && name) item.children = children.filter((child) => child.role);
      out.push(item);
    }

    function quote(text) {
      return '"' + text.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
    }

    // Adjacent text runs (split by inline markup) read as one; blank runs go.
    function mergeText(items) {
      const merged = [];
      for (const item of items) {
        const last = merged[merged.length - 1];
        if (item.text !== undefined && last?.text !== undefined) last.text += item.text;
        else merged.push(item.text !== undefined ? { text: item.text } : item);
      }
      return merged.filter((item) => item.text === undefined || item.text.trim());
    }

    function render(items, depth, lines, budget) {
      const indent = '  '.repeat(depth);
      for (const item of items) {
        if (budget.used > MAX_SNAPSHOT_CHARS) {
          budget.truncated = true;
          return;
        }
        let line;
        if (item.text !== undefined) {
          const text = clean(item.text, 300);
          if (!text) continue;
          line = `${indent}- text: ${text}`;
        } else {
          line = `${indent}- ${item.role}`;
          if (item.name) line += ' ' + quote(item.name);
          for (const state of item.states) line += ` [${state}]`;
          if (item.ref) line += ` [ref=${item.ref}]`;
          const onlyText = !item.value && item.children.length === 1 && item.children[0].text !== undefined;
          if (item.value) line += ': ' + item.value;
          else if (onlyText) line += ': ' + clean(item.children[0].text, 300);
          else if (item.children.length) line += ':';
          lines.push(line);
          budget.used += line.length + 1;
          if (!onlyText) render(item.children, depth + 1, lines, budget);
          continue;
        }
        lines.push(line);
        budget.used += line.length + 1;
      }
    }

    function snapshot() {
      const items = [];
      if (document.body) walk(document.body, items);
      const lines = [];
      const budget = { used: 0, truncated: false };
      render(mergeText(items), 0, lines, budget);
      if (budget.truncated) {
        lines.push(`… (snapshot cut at ${MAX_SNAPSHOT_CHARS} characters; scroll, or use read_page for the text)`);
      }
      return lines.join('\n');
    }

    // MARK: Geometry and hit testing

    function describe(el) {
      let text = '<' + el.localName;
      if (el.id) text += ` id="${el.id}"`;
      const classes = el.getAttribute('class')?.trim().split(/\s+/).slice(0, 3).join(' ');
      if (classes) text += ` class="${classes}"`;
      text += '>';
      const role = roleOf(el);
      const name = role ? nameOf(el, role) : '';
      if (name) text += ` ${quote(clean(name, 60))}`;
      const ref = refOf.get(el);
      if (ref) text += ` [ref=${ref}]`;
      return text;
    }

    // Offset of the element's frame viewport within the top-level viewport.
    function frameOffset(el) {
      let x = 0;
      let y = 0;
      for (let win = el.ownerDocument.defaultView; win && win.frameElement; win = win.frameElement.ownerDocument.defaultView) {
        const frame = win.frameElement;
        const rect = frame.getBoundingClientRect();
        const style = getComputedStyle(frame);
        x += rect.left + frame.clientLeft + parseFloat(style.paddingLeft);
        y += rect.top + frame.clientTop + parseFloat(style.paddingTop);
      }
      return { x, y };
    }

    function deepElementFromPoint(doc, x, y) {
      let el = doc.elementFromPoint(x, y);
      while (el?.shadowRoot) {
        const inner = el.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === el) break;
        el = inner;
      }
      if (el && (el.localName === 'iframe' || el.localName === 'frame')) {
        let frameDocument = null;
        try {
          frameDocument = el.contentDocument;
        } catch {
          // Cross-origin: the frame itself is the deepest element we can see.
        }
        if (frameDocument) {
          const rect = el.getBoundingClientRect();
          return deepElementFromPoint(frameDocument, x - rect.left - el.clientLeft, y - rect.top - el.clientTop) ?? el;
        }
      }
      return el;
    }

    function composedContains(ancestor, node) {
      for (let current = node; current; current = current.parentNode || current.host) {
        if (current === ancestor) return true;
      }
      return false;
    }

    function highlight(el) {
      const rect = el.getBoundingClientRect();
      const offset = frameOffset(el);
      const host = document.createElement(HIGHLIGHT_TAG);
      host.style.cssText = `position:fixed;left:${rect.left + offset.x - 3}px;top:${rect.top + offset.y - 3}px;`
        + `width:${rect.width + 6}px;height:${rect.height + 6}px;z-index:2147483647;pointer-events:none;display:block;`;
      const box = document.createElement('div');
      box.style.cssText = 'box-sizing:border-box;width:100%;height:100%;border:2px solid #2FA36B;border-radius:6px;'
        + 'background:rgba(47,163,107,0.12);box-shadow:0 0 0 4px rgba(47,163,107,0.18);transition:opacity 0.4s ease;';
      host.attachShadow({ mode: 'closed' }).appendChild(box);
      document.documentElement.appendChild(host);
      setTimeout(() => {
        box.style.opacity = '0';
        setTimeout(() => host.remove(), 450);
      }, 700);
    }

    // The element's centre in top-level viewport CSS pixels, after scrolling it
    // into view and checking that a click there would reach it.
    //
    // For a right click the browser's own context menu is suppressed: it would
    // open a native menu nobody can see or close, and WebKit drops further
    // mouse input until it closes. The page's contextmenu handlers still run.
    function actionPoint(ref, blockContextMenu) {
      const el = resolve(ref);
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      const rects = el.getClientRects();
      const rect = rects.length ? rects[0] : el.getBoundingClientRect();
      if (rect.width === 0 || rect.height === 0) {
        throw new Error(`Element ${ref} has no size on screen, so it can't be clicked.`);
      }
      const x = rect.left + rect.width / 2;
      const y = rect.top + rect.height / 2;
      const hit = deepElementFromPoint(el.ownerDocument, x, y);
      if (!hit) throw new Error(`Element ${ref} is outside the visible part of the page.`);
      const reachesTarget = composedContains(el, hit)
        || [...(el.labels ?? [])].some((label) => composedContains(label, hit));
      if (!reachesTarget) throw new Error(`Element ${ref} is obscured by ${describe(hit)}.`);
      highlight(el);
      if (blockContextMenu) {
        const view = el.ownerDocument.defaultView;
        const block = (event) => event.preventDefault();
        view.addEventListener('contextmenu', block, { capture: true, once: true });
        setTimeout(() => view.removeEventListener('contextmenu', block, { capture: true }), 2000);
      }
      const offset = frameOffset(el);
      const viewport = window.visualViewport;
      return {
        x: x + offset.x, y: y + offset.y,
        scale: viewport?.scale ?? 1, offsetLeft: viewport?.offsetLeft ?? 0, offsetTop: viewport?.offsetTop ?? 0,
      };
    }

    // MARK: Forms

    function isTextField(el) {
      if (el.localName === 'textarea') return !el.readOnly;
      if (el.localName === 'input') {
        const nonText = ['checkbox', 'radio', 'submit', 'reset', 'button', 'image', 'file', 'range', 'color', 'hidden'];
        return !nonText.includes(el.type) && !el.readOnly;
      }
      return el.isContentEditable;
    }

    function focusTextField(ref) {
      const el = resolve(ref);
      if (!isTextField(el)) throw new Error(`Element ${ref} is not a text field: ${describe(el)}.`);
      if (el.matches(':disabled')) throw new Error(`Text field ${ref} is disabled.`);
      el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      el.focus();
      highlight(el);
      return el.ownerDocument.activeElement === el || composedContains(el, el.ownerDocument.activeElement);
    }

    function fieldValue(ref) {
      const el = resolve(ref);
      return { value: el.isContentEditable ? el.innerText : el.value, masked: isPassword(el) };
    }

    function fieldKind(ref) {
      const el = resolve(ref);
      if (el.localName === 'select') return 'select';
      if (el.localName === 'input' && (el.type === 'checkbox' || el.type === 'radio')) return el.type;
      if (isTextField(el)) return 'text';
      throw new Error(`Element ${ref} is not a form field: ${describe(el)}.`);
    }

    function selectOptions(ref, values) {
      const el = resolve(ref);
      if (el.localName !== 'select') {
        throw new Error(`Element ${ref} is not a <select>: ${describe(el)}. Click it and pick the option instead.`);
      }
      if (el.matches(':disabled')) throw new Error(`Select ${ref} is disabled.`);
      const options = [...el.options];
      const chosen = values.map((wanted) => {
        const option = options.find((o) => o.value === wanted || clean(o.label || o.text) === clean(wanted));
        if (!option) {
          const available = options.slice(0, 20).map((o) => quote(clean(o.label || o.text))).join(', ');
          throw new Error(`No option ${quote(wanted)} in ${ref}. Options: ${available}`);
        }
        return option;
      });
      if (!el.multiple && chosen.length > 1) throw new Error(`Select ${ref} accepts only one option.`);
      highlight(el);
      for (const option of options) option.selected = chosen.includes(option);
      // Events go out after this call returns: a handler that opens alert()
      // would otherwise block the call until the dialog is answered.
      setTimeout(() => {
        el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      });
      return chosen.map((option) => clean(option.label || option.text));
    }

    // Uses click() so the page sees the same click/input/change sequence as a
    // real toggle (and frameworks that track `checked` notice the change).
    function setChecked(ref, checked) {
      const el = resolve(ref);
      if (el.matches(':disabled')) throw new Error(`Element ${ref} is disabled.`);
      if (el.type === 'radio' && !checked) throw new Error(`Radio button ${ref} can't be unchecked; check another option instead.`);
      highlight(el);
      if (el.checked !== checked) setTimeout(() => el.click());
    }

    // MARK: Scrolling and text

    function scrollableAncestor(el) {
      for (let current = el; current && current !== document.documentElement; current = current.parentElement) {
        const style = getComputedStyle(current);
        const scrollsY = /(auto|scroll)/.test(style.overflowY) && current.scrollHeight > current.clientHeight;
        const scrollsX = /(auto|scroll)/.test(style.overflowX) && current.scrollWidth > current.clientWidth;
        if (scrollsY || scrollsX) return current;
      }
      return null;
    }

    function scroll(ref, direction, amount) {
      const dx = direction === 'left' ? -amount : direction === 'right' ? amount : 0;
      const dy = direction === 'up' ? -amount : direction === 'down' ? amount : 0;
      const target = ref ? scrollableAncestor(resolve(ref)) : null;
      if (ref && !target) {
        resolve(ref).scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
      } else if (target) {
        target.scrollBy({ left: dx, top: dy, behavior: 'instant' });
      } else {
        window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
      }
      const box = target ?? document.scrollingElement ?? document.documentElement;
      return {
        scrolledElement: target ? describe(target) : null,
        top: Math.round(box.scrollTop), left: Math.round(box.scrollLeft),
        height: Math.round(box.scrollHeight), viewportHeight: Math.round(target ? target.clientHeight : innerHeight),
      };
    }

    function pageText() {
      return document.body?.innerText ?? '';
    }

    return { snapshot, actionPoint, focusTextField, fieldValue, fieldKind, selectOptions, setChecked, scroll, pageText };
  })();
}
