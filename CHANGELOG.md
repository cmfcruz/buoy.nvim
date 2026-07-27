# Changelog

## [3.0.0](https://github.com/cmfcruz/buoy.nvim/compare/v2.0.0...v3.0.0) (2026-07-27)


### ⚠ BREAKING CHANGES

* buoy.nvim now requires Neovim 0.11 or newer; `window.width` accepts a fixed integer column count of at least 40 instead of a screen fraction; `window.style` defaults to `auto` instead of `float`; `keymaps.focus` and `keymaps.toggle` are replaced by `keymaps.primary` and `keymaps.secondary`; and an agent split now quits when it becomes the last ordinary window in its tabpage unless `window.stay = true`, exiting Neovim when that is the final tab.

### Features

* ship buoy v3 with adaptive layouts ([#22](https://github.com/cmfcruz/buoy.nvim/issues/22)) ([19824d5](https://github.com/cmfcruz/buoy.nvim/commit/19824d5e085c0cf20fdc30aa8faa70c6561b2f9f))

## [2.0.0](https://github.com/cmfcruz/buoy.nvim/compare/v1.3.0...v2.0.0) (2026-07-17)


### ⚠ BREAKING CHANGES

* Buoy no longer configures an MCP server. Live editor operations use the private CLI on Linux and macOS, Windows keeps terminal-only support, and the undocumented CODEX_NVIM_SOCKET alias is removed.

### Features

* replace MCP with a private agent CLI ([#19](https://github.com/cmfcruz/buoy.nvim/issues/19)) ([7ddb0ad](https://github.com/cmfcruz/buoy.nvim/commit/7ddb0ad850d721a6c51360f7d434f60f8d1bf16d))

## [1.3.0](https://github.com/cmfcruz/buoy.nvim/compare/v1.2.1...v1.3.0) (2026-07-08)


### Features

* keep the captured selection painted after leaving visual mode ([#17](https://github.com/cmfcruz/buoy.nvim/issues/17)) ([68383f3](https://github.com/cmfcruz/buoy.nvim/commit/68383f31b323806ba64d6e8a337a680e179a8fe7))

## [1.2.1](https://github.com/cmfcruz/buoy.nvim/compare/v1.2.0...v1.2.1) (2026-06-30)


### Bug Fixes

* clear cached visual selection when the buffer changed mid-select ([#15](https://github.com/cmfcruz/buoy.nvim/issues/15)) ([965f034](https://github.com/cmfcruz/buoy.nvim/commit/965f03488bc24401b7487bd1aa34ad09d2b690f1))

## [1.2.0](https://github.com/cmfcruz/buoy.nvim/compare/v1.1.0...v1.2.0) (2026-06-29)


### Features

* add set_cursor_position tool ([#13](https://github.com/cmfcruz/buoy.nvim/issues/13)) ([c5e8464](https://github.com/cmfcruz/buoy.nvim/commit/c5e846481ae455db991a647c85534564f5296a0c))

## [1.1.0](https://github.com/cmfcruz/buoy.nvim/compare/v1.0.2...v1.1.0) (2026-06-27)


### Features

* add get_buffer_range tool ([#11](https://github.com/cmfcruz/buoy.nvim/issues/11)) ([b3f0b9e](https://github.com/cmfcruz/buoy.nvim/commit/b3f0b9eb45c2a812bec5b95ce0ad693a976ce8b3))

## [1.0.2](https://github.com/cmfcruz/buoy.nvim/compare/v1.0.1...v1.0.2) (2026-06-26)


### Bug Fixes

* support visual mode for toggle keymap and commands ([#7](https://github.com/cmfcruz/buoy.nvim/issues/7)) ([ac70858](https://github.com/cmfcruz/buoy.nvim/commit/ac708588af0da2bbf1d11bb884210ffd9a9893e8))

## [1.0.1](https://github.com/cmfcruz/buoy.nvim/compare/v1.0.0...v1.0.1) (2026-06-26)


### Bug Fixes

* unify MCP server name to "buoy" and clarify two-part install ([#4](https://github.com/cmfcruz/buoy.nvim/issues/4)) ([1ff1020](https://github.com/cmfcruz/buoy.nvim/commit/1ff1020882be6a2af28d4892109c709c0c66ec02))

## [1.0.0](https://github.com/cmfcruz/buoy.nvim/compare/buoy.nvim-v0.1.0...buoy.nvim-v1.0.0) (2026-06-26)


### Features

* Add buoy.nvim -- a floating window for your AI coding agent ([0d39e23](https://github.com/cmfcruz/buoy.nvim/commit/0d39e23efb3ce5c7f40eb665da6cd4adff50cd9a))
* **setup:** work zero-config so a bare clone just runs ([d26a2f9](https://github.com/cmfcruz/buoy.nvim/commit/d26a2f94a35e3ff79e48e89eddad0ff4cc2385ee))


### Miscellaneous Chores

* release 1.0.0 ([f6cae9a](https://github.com/cmfcruz/buoy.nvim/commit/f6cae9a1761ac78d451f49c935ce9035b8d6f2b4))
