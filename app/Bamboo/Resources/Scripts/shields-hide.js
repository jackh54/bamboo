// Generic element hiding. Sends the classes and ids in the page to Bamboo, which answers
// with the generic hide selectors that match them, and hides those elements. Follows DOM
// changes, sending only names it hasn't sent before. Runs in Bamboo's shields world.
(() => {
  const handler = window.webkit.messageHandlers.bambooShieldsHide;
  const batchLimit = 2000;
  const sentClasses = new Set();
  const sentIds = new Set();
  let classes = [];
  let ids = [];
  let timer = 0;
  let style = null;

  const collect = (element) => {
    if (element.id && !sentIds.has(element.id)) {
      sentIds.add(element.id);
      ids.push(element.id);
    }
    for (const name of element.classList) {
      if (!sentClasses.has(name)) {
        sentClasses.add(name);
        classes.push(name);
      }
    }
  };

  const scan = (node) => {
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    collect(node);
    for (const element of node.querySelectorAll('[id], [class]')) collect(element);
  };

  const schedule = () => {
    if (!timer) timer = setTimeout(flush, 100);
  };

  const flush = async () => {
    timer = 0;
    if (classes.length === 0 && ids.length === 0) return;
    const batch = { classes: classes.splice(0, batchLimit), ids: ids.splice(0, batchLimit) };
    if (classes.length || ids.length) schedule();

    let selectors;
    try {
      selectors = await handler.postMessage(batch);
    } catch (error) {
      observer.disconnect();
      throw error;
    }
    // No answer: shields or generic hiding are off for this page.
    if (!Array.isArray(selectors)) {
      observer.disconnect();
      return;
    }
    if (selectors.length === 0) return;
    if (!style) {
      style = document.createElement('style');
      document.documentElement.appendChild(style);
    }
    style.append(selectors.map((selector) => `${selector} { display: none !important; }`).join('\n') + '\n');
  };

  const observer = new MutationObserver((records) => {
    for (const record of records) {
      if (record.type === 'attributes') collect(record.target);
      else record.addedNodes.forEach(scan);
    }
    schedule();
  });

  scan(document.documentElement);
  schedule();
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['class', 'id'],
  });
})();
