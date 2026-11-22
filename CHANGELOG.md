# Changelog

## [0.1.0](https://github.com/jackh54/bamboo/compare/v0.1.0...v0.1.0) (2026-11-22)


### Features

* **agent:** add browser tools for agents and the MCP hub ([4d53fe8](https://github.com/jackh54/bamboo/commit/4d53fe8c120bc9dc4edb0f44c707664f5ca89e4a))
* **agent:** add MCP server, browser tool registry and stdio bridge ([de8170a](https://github.com/jackh54/bamboo/commit/de8170a0abc6a6c3efba5e675f4ab7b64c9d7edc))
* **app:** add assistant prompt, shields popover and password banner slots ([1c4afa5](https://github.com/jackh54/bamboo/commit/1c4afa55e501ca7cf00d7736c4d6c2170f2ebe88))
* **app:** add the Bamboo app icon ([6d57309](https://github.com/jackh54/bamboo/commit/6d57309624d6d30e6fce4d0a9395fc87b7dda597))
* **assistant:** add the Claude panel and Claude settings ([bd0d364](https://github.com/jackh54/bamboo/commit/bd0d364265cacaabfada74ac2f905c6bd8829e6d))
* **browser:** fetch and cache site favicons ([6ab6f6a](https://github.com/jackh54/bamboo/commit/6ab6f6a7eca3a27fe09baea8570bf28af5e8b228))
* **browser:** open links in new tabs and ask Claude from the page menu ([8e0c3d7](https://github.com/jackh54/bamboo/commit/8e0c3d70dc4a9cd4cb79df77490dc0eb9a0b5743))
* **import:** add Brave-style import dialog and store mapping ([e73b9d8](https://github.com/jackh54/bamboo/commit/e73b9d8240cc1a8206efca6271d20166ead4dd81))
* **import:** read Chromium, Firefox and Safari profiles ([5a23bae](https://github.com/jackh54/bamboo/commit/5a23bae86bec1235ec61d9d9931fa37119eecbd6))
* **passwords:** add keychain password manager, autofill and save offers ([865449a](https://github.com/jackh54/bamboo/commit/865449a988770ebd9856765ef2f5030c24048156))
* **privacy:** strip tracking parameters, add GPC, HTTPS-Only and data clearing ([d941554](https://github.com/jackh54/bamboo/commit/d9415549da3f162ad62cad718b60029bfea47804))
* scaffold Bamboo browser foundation ([640f15b](https://github.com/jackh54/bamboo/commit/640f15bd18749087be2c7ae6c4269b061bdd0918))
* **settings:** add the Settings window in Brave's sections ([e8ea567](https://github.com/jackh54/bamboo/commit/e8ea5674632b28f4ee92aa42a06263cb0212606f))
* **shields:** add scriptlet resources interface ([b6a0c24](https://github.com/jackh54/bamboo/commit/b6a0c24bbc862425c2b4fe83e9c341f3a6921d17))
* **shields:** compile rule lists, update them daily and apply per site ([4bcb478](https://github.com/jackh54/bamboo/commit/4bcb4781607f6373a17696f5521d0590cc308737))
* **shields:** implement filter list storage, WebKit rule conversion and cosmetic engine ([66371a8](https://github.com/jackh54/bamboo/commit/66371a84b943d5c9d2d1395528b4a636819bd230))
* **store:** implement the profile database ([c7bb3e9](https://github.com/jackh54/bamboo/commit/c7bb3e9957aef8950bb071309a4b42c7ba7a102e))
* **ui:** build the browser window in Brave's layout ([e1297d2](https://github.com/jackh54/bamboo/commit/e1297d27ecf60a8c023280ab4d1cee2c06841b9a))


### Bug Fixes

* **agent:** keep agents off the clipboard and the main thread ([027ff6d](https://github.com/jackh54/bamboo/commit/027ff6df3f2ddbb6b0c03abed47799c59ee16f9d))
* **agent:** never block callers on a slow MCP client ([4da327f](https://github.com/jackh54/bamboo/commit/4da327fed01acbc626c5130af69656dc56ec4b43))
* **app:** open one window when a link launches Bamboo ([3600cff](https://github.com/jackh54/bamboo/commit/3600cffa457ca792eb59702a3ee93e514f4055c5))
* **assistant:** keep page text out of the prompt and agent grants ([5361147](https://github.com/jackh54/bamboo/commit/5361147ef622d3e8b30098a664d7d6e4361604a9))
* **import:** keep saved logins instead of overwriting them on import ([4eac645](https://github.com/jackh54/bamboo/commit/4eac64541f7232ca8e1767eef7f969e14f2807ec))
* **passwords:** save offers for the submitting origin and export privately ([1439ce7](https://github.com/jackh54/bamboo/commit/1439ce7190cd2a0f5dc855a3e1792498cca7ecc7))
* **shields:** count blocked requests from WebKit's content blocker ([08050ea](https://github.com/jackh54/bamboo/commit/08050eaf9e9c608e07b3bf64dcf2c6dba1072acc))
* **shields:** keep generichide exceptions in the cosmetic-only engine ([bcdc430](https://github.com/jackh54/bamboo/commit/bcdc4308278df917eecc902c579cfbed1649fc8f))


### Performance

* **shields:** build filter lists in a short-lived helper process ([f472cf2](https://github.com/jackh54/bamboo/commit/f472cf2f57c87396cca06b52ca15e3dce24fefb9))
* **shields:** build the in-process engine from cosmetic filters only ([3fde62b](https://github.com/jackh54/bamboo/commit/3fde62bfe8566df2f409c25eded509b1768b235f))


### Documentation

* add README ([64ad0b3](https://github.com/jackh54/bamboo/commit/64ad0b36da3855dc2df9a2169aa4a3a1eb1f18ba))
* add releasing guide, contributing guide, security policy and templates ([816ef4f](https://github.com/jackh54/bamboo/commit/816ef4f868f55b83744bb2d219acde6dd179cb30))
