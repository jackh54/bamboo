// Reports the resources a page references so Bamboo can count what shields blocked.
// WebKit blocks those requests before they start, so they never appear in the Performance
// API; the element that asked for each one is still in the DOM, though. Runs in Bamboo's
// shields world, in every frame.
(() => {
  const handler = window.webkit.messageHandlers.bambooShieldsRequests;
  const batchLimit = 500;
  const selector =
    'script[src], img[src], iframe[src], frame[src], video[src], audio[src], source[src], track[src], embed[src], object[data], link[href]';
  const typesByTag = {
    SCRIPT: 'script',
    IMG: 'image',
    IFRAME: 'subdocument',
    FRAME: 'subdocument',
    VIDEO: 'media',
    AUDIO: 'media',
    SOURCE: 'media',
    TRACK: 'media',
    EMBED: 'other',
    OBJECT: 'other',
  };
  const typesByPreload = {
    script: 'script',
    style: 'stylesheet',
    image: 'image',
    font: 'font',
    fetch: 'xhr',
    audio: 'media',
    video: 'media',
    track: 'media',
    document: 'subdocument',
  };
  const seen = new Set();
  let pending = [];
  let timer = 0;

  const linkType = (link) => {
    if (link.relList.contains('stylesheet')) return 'stylesheet';
    if (link.relList.contains('modulepreload')) return 'script';
    if (link.relList.contains('preload')) return typesByPreload[link.as] || 'other';
    if (link.relList.contains('icon')) return 'image';
    return null;
  };

  const flush = () => {
    timer = 0;
    handler.postMessage({ requests: pending.splice(0, batchLimit) });
    if (pending.length) timer = setTimeout(flush, 250);
  };

  const note = (element) => {
    let type;
    let url;
    if (element.tagName === 'LINK') {
      type = linkType(element);
      url = element.href;
    } else {
      type = typesByTag[element.tagName];
      url = element.tagName === 'OBJECT' ? element.data : element.src;
    }
    if (!type || !url || !/^https?:/.test(url) || seen.has(url)) return;
    seen.add(url);
    pending.push({ url, type });
    if (!timer) timer = setTimeout(flush, 250);
  };

  const scan = (node) => {
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    if (node.matches(selector)) note(node);
    node.querySelectorAll(selector).forEach(note);
  };

  // Runs at document start, so the parser's insertions arrive here too.
  new MutationObserver((records) => {
    for (const record of records) {
      if (record.type === 'attributes') note(record.target);
      else record.addedNodes.forEach(scan);
    }
  }).observe(document, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['src', 'href', 'data'],
  });
})();
