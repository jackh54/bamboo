// Password autofill. When the user focuses a login field, asks Bamboo to offer the site's
// saved logins; fills the one they pick; and reports submitted credentials so Bamboo can
// offer to save them. Runs in Bamboo's autofill world, so pages can't call it or read what
// it sends.
(() => {
  const handler = window.webkit.messageHandlers.bambooAutofill;
  const textTypes = new Set(['text', 'email', 'tel']);
  let userInteracted = false;
  let target = null;

  const isPassword = (element) => element instanceof HTMLInputElement && element.type === 'password';
  const isText = (element) => element instanceof HTMLInputElement && textTypes.has(element.type);
  const scopeOf = (field) => field.form || document;
  const isBefore = (a, b) => Boolean(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
  const passwordsIn = (scope) => [...scope.querySelectorAll('input[type=password]')];

  const usernameFor = (password) => {
    const fields = [...scopeOf(password).querySelectorAll('input')].filter(isText);
    const tagged = fields.find((field) => /\b(username|email)\b/.test(field.autocomplete));
    if (tagged) return tagged;
    return fields.filter((field) => isBefore(field, password)).pop() || null;
  };

  // The username and password fields `field` belongs to, or null when it isn't a login field.
  // Sign-in pages that ask for the username first have no password field yet.
  const loginFields = (field) => {
    if (isPassword(field)) return { username: usernameFor(field), password: field };
    if (!isText(field)) return null;
    const password = passwordsIn(scopeOf(field)).find((candidate) => isBefore(field, candidate));
    if (password && usernameFor(password) === field) return { username: field, password };
    if (/\busername\b/.test(field.autocomplete)) return { username: field, password: null };
    return null;
  };

  const setValue = (field, value) => {
    // Set from this world, the value bypasses the page's own setter overrides, so the
    // input and change events are what frameworks like React notice.
    field.value = value;
    field.dispatchEvent(new Event('input', { bubbles: true }));
    field.dispatchEvent(new Event('change', { bubbles: true }));
  };

  window.bambooAutofillFill = (origin, username, password) => {
    if (location.origin !== origin || !target) return false;
    if (target.username) setValue(target.username, username);
    if (target.password) setValue(target.password, password);
    return true;
  };

  const markInteraction = () => {
    userInteracted = true;
  };
  document.addEventListener('pointerdown', markInteraction, true);
  document.addEventListener('keydown', markInteraction, true);

  // Only after the user has interacted, so a field the page focuses on load doesn't open a menu.
  document.addEventListener('focusin', (event) => {
    const fields = loginFields(event.target);
    if (!fields || !userInteracted || event.target.value) return;
    target = fields;
    const rect = event.target.getBoundingClientRect();
    handler.postMessage({ type: 'focus', x: rect.left, y: rect.top, width: rect.width, height: rect.height });
  }, true);

  const report = (scope) => {
    const passwords = passwordsIn(scope).filter((field) => field.value);
    // On a change-password form the new password is the one to keep.
    const password = passwords.find((field) => field.autocomplete === 'new-password') || passwords[0];
    if (!password) return;
    const username = usernameFor(password);
    handler.postMessage({ type: 'submit', username: username ? username.value : '', password: password.value });
  };

  document.addEventListener('submit', (event) => report(event.target), true);
  document.addEventListener('click', (event) => {
    const button = event.target instanceof Element && event.target.closest('button, input[type=submit]');
    if (button && button.type === 'submit') report(button.form || document);
  }, true);
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && isPassword(event.target)) report(scopeOf(event.target));
  }, true);
})();
