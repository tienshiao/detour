// Side-effect module: sets globals that later modules depend on.
// Tests that bundler respects import order for side-effect imports.
globalThis.HW_CONSTANTS = {
  APP_NAME: 'Hello World Module',
  VERSION: '1.0.0',
};
