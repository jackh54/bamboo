// Converts the visible page to Markdown for agents and the Claude panel. Runs
// in the isolated "bamboo-agent" content world; returns the Markdown string.
(() => {
  const MAX_CHARS = 60000;
  const SKIPPED = new Set(['script', 'style', 'noscript', 'template', 'svg', 'canvas', 'iframe', 'button',
    'select', 'input', 'textarea', 'nav', 'bamboo-agent-highlight']);
  const BLOCKS = new Set(['p', 'div', 'section', 'article', 'main', 'header', 'footer', 'aside', 'figure',
    'figcaption', 'dl', 'dt', 'dd', 'details', 'summary', 'address', 'center']);

  function isHidden(el) {
    if (el.getAttribute('aria-hidden') === 'true' || el.hidden) return true;
    return typeof el.checkVisibility === 'function' ? !el.checkVisibility() : getComputedStyle(el).display === 'none';
  }

  function absolute(url) {
    try {
      return new URL(url, document.baseURI).href;
    } catch {
      return url;
    }
  }

  function children(node) {
    return [...(node.shadowRoot ?? node).childNodes];
  }

  // Inline content: text with emphasis, code and links, whitespace collapsed.
  function inline(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.data.replace(/\s+/g, ' ');
    if (node.nodeType !== Node.ELEMENT_NODE || SKIPPED.has(node.localName) || isHidden(node)) return '';
    const inner = () => children(node).map(inline).join('');
    switch (node.localName) {
      case 'br': return '\n';
      case 'strong': case 'b': return wrap(inner(), '**');
      case 'em': case 'i': return wrap(inner(), '*');
      case 's': case 'del': return wrap(inner(), '~~');
      case 'code': case 'kbd': case 'samp': return '`' + node.textContent.replace(/`/g, 'ˋ') + '`';
      case 'img': {
        const alt = (node.getAttribute('alt') || '').trim();
        return alt ? `![${alt}](${absolute(node.getAttribute('src') || '')})` : '';
      }
      case 'a': {
        const text = inner().trim();
        const href = node.getAttribute('href');
        if (!text) return '';
        if (!href || href.startsWith('javascript:') || href.startsWith('#')) return text;
        return `[${text}](${absolute(href)})`;
      }
      default: return inner();
    }
  }

  function wrap(text, marker) {
    const trimmed = text.trim();
    return trimmed ? `${marker}${trimmed}${marker}` : '';
  }

  function tidy(text) {
    return text.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').replace(/ {2,}/g, ' ').trim();
  }

  function table(el) {
    const rows = [...el.querySelectorAll(':scope > tr, :scope > thead > tr, :scope > tbody > tr, :scope > tfoot > tr')];
    if (!rows.length) return '';
    const cells = rows.map((row) => [...row.children].map((cell) => tidy(inline(cell)).replace(/\|/g, '\\|').replace(/\n/g, ' ')));
    const width = Math.max(...cells.map((row) => row.length));
    const line = (row) => '| ' + Array.from({ length: width }, (_, i) => row[i] ?? '').join(' | ') + ' |';
    return [line(cells[0]), '|' + ' --- |'.repeat(width), ...cells.slice(1).map(line)].join('\n');
  }

  function list(el, depth) {
    const ordered = el.localName === 'ol';
    let index = Number(el.getAttribute('start') || 1);
    const lines = [];
    for (const item of el.children) {
      if (item.localName !== 'li' || isHidden(item)) continue;
      const nested = [];
      const own = [];
      for (const child of children(item)) {
        if (child.nodeType === Node.ELEMENT_NODE && (child.localName === 'ul' || child.localName === 'ol')) {
          nested.push(list(child, depth + 1));
        } else if (child.nodeType === Node.ELEMENT_NODE && BLOCKS.has(child.localName)) {
          own.push(tidy(blocks(child, depth)));
        } else {
          own.push(inline(child));
        }
      }
      const marker = ordered ? `${index++}.` : '-';
      const text = tidy(own.join(' ')).replace(/\n+/g, ' ');
      lines.push('  '.repeat(depth) + `${marker} ${text}`);
      lines.push(...nested.filter(Boolean));
    }
    return lines.join('\n');
  }

  // Block content: each block becomes a paragraph separated by blank lines.
  function blocks(root, depth = 0) {
    const out = [];
    let paragraph = '';
    const flush = () => {
      const text = tidy(paragraph);
      if (text) out.push(text);
      paragraph = '';
    };
    for (const node of children(root)) {
      if (node.nodeType === Node.TEXT_NODE) {
        paragraph += inline(node);
        continue;
      }
      if (node.nodeType !== Node.ELEMENT_NODE || SKIPPED.has(node.localName) || isHidden(node)) continue;
      const tag = node.localName;
      const heading = /^h([1-6])$/.exec(tag);
      if (heading) {
        flush();
        const text = tidy(inline(node)).replace(/\n+/g, ' ');
        if (text) out.push('#'.repeat(Number(heading[1])) + ' ' + text);
      } else if (tag === 'ul' || tag === 'ol') {
        flush();
        out.push(list(node, depth));
      } else if (tag === 'pre') {
        flush();
        const language = (node.querySelector('code')?.className.match(/language-([\w-]+)/) || [])[1] || '';
        out.push('```' + language + '\n' + node.innerText.replace(/\n+$/, '') + '\n```');
      } else if (tag === 'blockquote') {
        flush();
        out.push(blocks(node, depth).split('\n').map((line) => '> ' + line).join('\n'));
      } else if (tag === 'table') {
        flush();
        out.push(table(node));
      } else if (tag === 'hr') {
        flush();
        out.push('---');
      } else if (BLOCKS.has(tag) || getComputedStyle(node).display.startsWith('block') || node.shadowRoot) {
        flush();
        out.push(blocks(node, depth));
      } else {
        paragraph += inline(node);
      }
    }
    flush();
    return out.filter(Boolean).join('\n\n');
  }

  const root = document.querySelector('main, [role="main"]') ?? document.querySelector('article') ?? document.body;
  if (!root) return '';
  const markdown = blocks(root);
  return markdown.length > MAX_CHARS
    ? markdown.slice(0, MAX_CHARS) + `\n\n… (page text cut at ${MAX_CHARS} characters)`
    : markdown;
})()
