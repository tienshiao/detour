// API Explorer — side panel page (TASK-132.8).
// A page Detour hosts beside the tab. It is not a tab: tabs.getCurrent() is
// undefined here. `loadedAt` shows whether the page was loaded again (it must
// not be when its tab is switched away and back).

const loadedAt = new Date().toISOString();
const tabId = new URLSearchParams(location.search).get('tabId');

function show(data) {
  document.getElementById('panel-result').textContent =
    typeof data === 'string' ? data : JSON.stringify(data, null, 2);
}

document.getElementById('panel-kind').textContent =
  tabId ? `Tab panel for tab ${tabId}` : 'Window panel (side_panel.default_path)';

async function info() {
  const current = await chrome.tabs.getCurrent();
  const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
  return {
    url: location.href,
    loadedAt,
    'tabs.getCurrent()': current === undefined ? '(undefined: a panel is not a tab)' : (current === null ? '(null)' : current),
    activeTab: active ? { id: active.id, title: active.title } : null,
    options: tabId ? await chrome.sidePanel.getOptions({ tabId: Number(tabId) }) : await chrome.sidePanel.getOptions({}),
  };
}

document.getElementById('btn-panel-info').addEventListener('click', async () => {
  try { show(await info()); } catch (e) { show('error: ' + e.message); }
});

document.getElementById('btn-panel-contexts').addEventListener('click', async () => {
  try {
    show(await chrome.runtime.getContexts({ contextTypes: [chrome.runtime.ContextType.SIDE_PANEL] }));
  } catch (e) { show('error: ' + e.message); }
});

document.getElementById('btn-panel-close').addEventListener('click', () => window.close());

// The worker can ask a tab's panel to close itself, as the Claude extension does.
chrome.runtime.onMessage.addListener((message) => {
  if (message && message.type === 'close_side_panel' && String(message.tabId) === String(tabId)) window.close();
});

info().then(show, (e) => show('error: ' + e.message));
