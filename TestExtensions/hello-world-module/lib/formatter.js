// Named export module in a subdirectory.
// Tests subdirectory import resolution and named export bundling.
export function formatGreeting(name, count) {
  const appName = globalThis.HW_CONSTANTS?.APP_NAME ?? 'Unknown';
  return `[${appName}] Hello ${name}, visit #${count}`;
}

export function formatError(message) {
  return `[Error] ${message}`;
}
