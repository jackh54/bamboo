// Global Privacy Control (https://privacycg.github.io/gpc-spec/): asks sites not to sell or
// share the user's data. Runs in the page world so the page's own scripts can read it.
Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', {
  get: () => true,
  configurable: true,
  enumerable: true,
});
