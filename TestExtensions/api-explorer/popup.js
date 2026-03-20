// API Explorer — Popup Script
// Tests both direct API calls and message-passing through the background.

function showResult(id, data, isError) {
  const el = document.getElementById(id);
  el.textContent = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
  el.classList.add('visible');
  el.classList.toggle('error', !!isError);
}

function sendBg(message) {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(message, (response) => {
      if (chrome.runtime.lastError) {
        reject(new Error(chrome.runtime.lastError.message));
      } else {
        resolve(response);
      }
    });
  });
}

function formatTabs(tabs) {
  return tabs.map(t =>
    `[${t.id}] ${t.active ? '●' : '○'} ${t.title || '(no title)'}\n    ${t.url || ''}`
  ).join('\n');
}

// --- i18n ---

document.getElementById('btn-i18n-info').addEventListener('click', async () => {
  try {
    const info = await sendBg({ type: 'getI18nInfo' });
    showResult('res-i18n', info);
  } catch (e) {
    showResult('res-i18n', e.message, true);
  }
});

document.getElementById('btn-i18n-local').addEventListener('click', () => {
  try {
    const result = {
      'getMessage("appName")': chrome.i18n.getMessage('appName'),
      'getMessage("greeting", ["You", "Detour"])': chrome.i18n.getMessage('greeting', ['You', 'Detour']),
      'getUILanguage()': chrome.i18n.getUILanguage(),
      'getMessage("unknown")': chrome.i18n.getMessage('unknown') || '(empty string)',
    };
    showResult('res-i18n', result);
  } catch (e) {
    showResult('res-i18n', e.message, true);
  }
});

// --- Query All Tabs ---

document.getElementById('btn-query-all').addEventListener('click', async () => {
  try {
    const { tabs } = await sendBg({ type: 'queryTabs', queryInfo: {} });
    showResult('res-query-all', formatTabs(tabs));
  } catch (e) {
    showResult('res-query-all', e.message, true);
  }
});

// --- Active Tab ---

document.getElementById('btn-active-tab').addEventListener('click', async () => {
  try {
    const { tabs } = await sendBg({ type: 'queryTabs', queryInfo: { active: true, currentWindow: true } });
    showResult('res-active-tab', formatTabs(tabs));
  } catch (e) {
    showResult('res-active-tab', e.message, true);
  }
});

// --- Create Tab ---

document.getElementById('btn-create-tab').addEventListener('click', async () => {
  try {
    const url = document.getElementById('input-create-url').value || 'https://example.com';
    const { tab } = await sendBg({ type: 'createTab', url });
    showResult('res-create-tab', `Created tab ${tab.id}: ${tab.url || url}`);
  } catch (e) {
    showResult('res-create-tab', e.message, true);
  }
});

// --- Close Tab ---

document.getElementById('btn-close-tab').addEventListener('click', async () => {
  try {
    const tabId = parseInt(document.getElementById('input-close-id').value, 10);
    if (isNaN(tabId)) throw new Error('Enter a valid tab ID');
    await sendBg({ type: 'closeTab', tabId });
    showResult('res-close-tab', `Closed tab ${tabId}`);
  } catch (e) {
    showResult('res-close-tab', e.message, true);
  }
});

// --- Detect Language ---

document.getElementById('btn-detect-lang').addEventListener('click', async () => {
  try {
    const tabId = parseInt(document.getElementById('input-detect-id').value, 10);
    if (isNaN(tabId)) throw new Error('Enter a valid tab ID');
    const { language } = await sendBg({ type: 'detectLanguage', tabId });
    showResult('res-detect-lang', `Language: ${language}`);
  } catch (e) {
    showResult('res-detect-lang', e.message, true);
  }
});

// --- Execute Script ---

document.getElementById('btn-exec-script').addEventListener('click', async () => {
  try {
    const tabId = parseInt(document.getElementById('input-exec-id').value, 10);
    if (isNaN(tabId)) throw new Error('Enter a valid tab ID');
    const { results } = await sendBg({ type: 'executeScript', tabId });
    showResult('res-exec-script', results);
  } catch (e) {
    showResult('res-exec-script', e.message, true);
  }
});

// --- Insert CSS ---

document.getElementById('btn-insert-css').addEventListener('click', async () => {
  try {
    const tabId = parseInt(document.getElementById('input-css-id').value, 10);
    if (isNaN(tabId)) throw new Error('Enter a valid tab ID');
    await sendBg({ type: 'insertCSS', tabId });
    showResult('res-insert-css', `Inserted inject.css into tab ${tabId}`);
  } catch (e) {
    showResult('res-insert-css', e.message, true);
  }
});

// --- Send to Tab ---

document.getElementById('btn-send-tab').addEventListener('click', async () => {
  try {
    const tabId = parseInt(document.getElementById('input-send-id').value, 10);
    if (isNaN(tabId)) throw new Error('Enter a valid tab ID');
    const { response } = await sendBg({ type: 'sendToTab', tabId, message: { type: 'highlight' } });
    showResult('res-send-tab', response);
  } catch (e) {
    showResult('res-send-tab', e.message, true);
  }
});

// --- Context Menus ---

document.getElementById('btn-create-menu').addEventListener('click', async () => {
  try {
    const title = document.getElementById('input-menu-title').value || 'Dynamic Item';
    const { menuItemId } = await sendBg({ type: 'createContextMenu', title, contexts: ['page', 'selection'] });
    showResult('res-context-menus', `Created menu item: ${menuItemId}`);
  } catch (e) {
    showResult('res-context-menus', e.message, true);
  }
});

document.getElementById('btn-remove-menus').addEventListener('click', async () => {
  try {
    await sendBg({ type: 'removeAllContextMenus' });
    showResult('res-context-menus', 'All context menu items removed');
  } catch (e) {
    showResult('res-context-menus', e.message, true);
  }
});

// --- Offscreen Document ---

document.getElementById('btn-offscreen-create').addEventListener('click', async () => {
  try {
    await sendBg({ type: 'createOffscreen' });
    showResult('res-offscreen', 'Offscreen document created');
  } catch (e) {
    showResult('res-offscreen', e.message, true);
  }
});

document.getElementById('btn-offscreen-has').addEventListener('click', async () => {
  try {
    const { hasDocument } = await sendBg({ type: 'hasOffscreen' });
    showResult('res-offscreen', `Has offscreen document: ${hasDocument}`);
  } catch (e) {
    showResult('res-offscreen', e.message, true);
  }
});

document.getElementById('btn-offscreen-close').addEventListener('click', async () => {
  try {
    await sendBg({ type: 'closeOffscreen' });
    showResult('res-offscreen', 'Offscreen document closed');
  } catch (e) {
    showResult('res-offscreen', e.message, true);
  }
});

// --- Port Messaging ---

document.getElementById('btn-port-send').addEventListener('click', () => {
  try {
    const msg = document.getElementById('input-port-msg').value || 'hello from popup';
    const port = chrome.runtime.connect({ name: 'explorer-port' });

    port.onMessage.addListener((response) => {
      showResult('res-port', response);
      port.disconnect();
    });

    port.onDisconnect.addListener(() => {
      console.log('[Popup] Port disconnected');
    });

    port.postMessage({ text: msg, from: 'popup', timestamp: Date.now() });
    showResult('res-port', 'Sent, waiting for response...');
  } catch (e) {
    showResult('res-port', e.message, true);
  }
});

// --- Runtime Info ---

document.getElementById('btn-platform-info').addEventListener('click', async () => {
  try {
    const { platformInfo } = await sendBg({ type: 'getPlatformInfo' });
    showResult('res-runtime-info', platformInfo);
  } catch (e) {
    showResult('res-runtime-info', e.message, true);
  }
});

document.getElementById('btn-bg-page').addEventListener('click', async () => {
  try {
    const { backgroundPage } = await sendBg({ type: 'getBackgroundPage' });
    showResult('res-runtime-info', `getBackgroundPage(): ${backgroundPage}`);
  } catch (e) {
    showResult('res-runtime-info', e.message, true);
  }
});

// --- Open Options Page ---

document.getElementById('btn-open-options').addEventListener('click', async () => {
  try {
    await chrome.runtime.openOptionsPage();
    showResult('res-options-page', 'Options page opened');
  } catch (e) {
    showResult('res-options-page', e.message, true);
  }
});

// --- Storage onChanged ---

document.getElementById('btn-storage-write').addEventListener('click', async () => {
  try {
    const val = document.getElementById('input-storage-val').value || 'test-' + Date.now();

    // Register a local onChanged listener to show the event in the popup
    let handled = false;
    chrome.storage.onChanged.addListener(function listener(changes, areaName) {
      if (handled) return;
      if (changes._testOnChanged) {
        handled = true;
        chrome.storage.onChanged.removeListener(listener);
        showResult('res-storage-changed',
          `storage.onChanged fired!\n` +
          `Area: ${areaName}\n` +
          `Key: _testOnChanged\n` +
          `New value: ${JSON.stringify(changes._testOnChanged.newValue)}\n` +
          `Old value: ${changes._testOnChanged.oldValue !== undefined ? JSON.stringify(changes._testOnChanged.oldValue) : '(none)'}`
        );
      }
    });

    await sendBg({ type: 'storageOnChangedTest', value: val });
    showResult('res-storage-changed', 'Wrote value, waiting for onChanged event...');
  } catch (e) {
    showResult('res-storage-changed', e.message, true);
  }
});

// --- Storage Sync ---

document.getElementById('btn-sync-set').addEventListener('click', async () => {
  try {
    const key = document.getElementById('input-sync-key').value || 'testKey';
    const val = document.getElementById('input-sync-val').value || 'testValue';
    await chrome.storage.sync.set({ [key]: val });
    showResult('res-storage-sync', `Set sync["${key}"] = "${val}"`);
  } catch (e) {
    showResult('res-storage-sync', e.message, true);
  }
});

document.getElementById('btn-sync-get').addEventListener('click', async () => {
  try {
    const key = document.getElementById('input-sync-key').value || 'testKey';
    const result = await chrome.storage.sync.get(key);
    showResult('res-storage-sync', result);
  } catch (e) {
    showResult('res-storage-sync', e.message, true);
  }
});

document.getElementById('btn-sync-getall').addEventListener('click', async () => {
  try {
    const result = await chrome.storage.sync.get(null);
    showResult('res-storage-sync', result);
  } catch (e) {
    showResult('res-storage-sync', e.message, true);
  }
});

// --- Alarms ---

document.getElementById('btn-alarm-create').addEventListener('click', async () => {
  try {
    const name = document.getElementById('input-alarm-name').value || 'test-alarm';
    await chrome.alarms.create(name, { delayInMinutes: 1 });
    showResult('res-alarms', `Created alarm "${name}" (fires in 1 min)`);
  } catch (e) {
    showResult('res-alarms', e.message, true);
  }
});

document.getElementById('btn-alarm-getall').addEventListener('click', async () => {
  try {
    const alarms = await chrome.alarms.getAll();
    if (alarms.length === 0) {
      showResult('res-alarms', '(no alarms)');
    } else {
      showResult('res-alarms', alarms);
    }
  } catch (e) {
    showResult('res-alarms', e.message, true);
  }
});

document.getElementById('btn-alarm-clearall').addEventListener('click', async () => {
  try {
    await chrome.alarms.clearAll();
    showResult('res-alarms', 'All alarms cleared');
  } catch (e) {
    showResult('res-alarms', e.message, true);
  }
});

// --- Action (Badge) ---

document.getElementById('btn-badge-set').addEventListener('click', async () => {
  try {
    const text = document.getElementById('input-badge-text').value || 'ON';
    await chrome.action.setBadgeText({ text });
    await chrome.action.setBadgeBackgroundColor({ color: [66, 133, 244, 255] });
    showResult('res-action', `Badge set to "${text}"`);
  } catch (e) {
    showResult('res-action', e.message, true);
  }
});

document.getElementById('btn-badge-get').addEventListener('click', async () => {
  try {
    const text = await chrome.action.getBadgeText({});
    showResult('res-action', `Current badge: "${text}"`);
  } catch (e) {
    showResult('res-action', e.message, true);
  }
});

document.getElementById('btn-badge-clear').addEventListener('click', async () => {
  try {
    await chrome.action.setBadgeText({ text: '' });
    showResult('res-action', 'Badge cleared');
  } catch (e) {
    showResult('res-action', e.message, true);
  }
});

// --- Commands ---

document.getElementById('btn-commands-getall').addEventListener('click', async () => {
  try {
    const commands = await chrome.commands.getAll();
    showResult('res-commands', commands);
  } catch (e) {
    showResult('res-commands', e.message, true);
  }
});

// --- Windows ---

document.getElementById('btn-windows-getall').addEventListener('click', async () => {
  try {
    const windows = await chrome.windows.getAll();
    showResult('res-windows', windows);
  } catch (e) {
    showResult('res-windows', e.message, true);
  }
});

document.getElementById('btn-windows-current').addEventListener('click', async () => {
  try {
    const win = await chrome.windows.getCurrent();
    showResult('res-windows', win);
  } catch (e) {
    showResult('res-windows', e.message, true);
  }
});

// --- Font Settings ---

document.getElementById('btn-fonts-list').addEventListener('click', async () => {
  try {
    const fonts = await chrome.fontSettings.getFontList();
    showResult('res-fonts', `${fonts.length} fonts: ${fonts.slice(0, 10).map(f => f.displayName).join(', ')}...`);
  } catch (e) {
    showResult('res-fonts', e.message, true);
  }
});

// --- Permissions ---

document.getElementById('btn-perm-contains').addEventListener('click', async () => {
  try {
    const perm = document.getElementById('input-perm-check').value || 'storage';
    const has = await chrome.permissions.contains({ permissions: [perm] });
    showResult('res-permissions', `permissions.contains("${perm}"): ${has}`);
  } catch (e) {
    showResult('res-permissions', e.message, true);
  }
});

document.getElementById('btn-perm-getall').addEventListener('click', async () => {
  try {
    const all = await chrome.permissions.getAll();
    showResult('res-permissions', all);
  } catch (e) {
    showResult('res-permissions', e.message, true);
  }
});

// --- Runtime Extras ---

document.getElementById('btn-file-access').addEventListener('click', async () => {
  try {
    const allowed = await chrome.extension.isAllowedFileSchemeAccess();
    showResult('res-runtime-extras', `File scheme access: ${allowed}`);
  } catch (e) {
    showResult('res-runtime-extras', e.message, true);
  }
});

document.getElementById('btn-incognito-access').addEventListener('click', async () => {
  try {
    const allowed = await chrome.extension.isAllowedIncognitoAccess();
    showResult('res-runtime-extras', `Incognito access: ${allowed}`);
  } catch (e) {
    showResult('res-runtime-extras', e.message, true);
  }
});

// --- Event Log ---

document.getElementById('btn-refresh-log').addEventListener('click', async () => {
  try {
    const { eventLog } = await chrome.storage.local.get('eventLog');
    if (!eventLog || eventLog.length === 0) {
      showResult('res-event-log', '(no events yet)');
      return;
    }
    const lines = eventLog.slice(-25).reverse().map(entry => {
      const time = new Date(entry.timestamp).toLocaleTimeString();
      const details = entry.url ? ` ${entry.url}` : '';
      const extra = entry.reason ? ` reason:${entry.reason}` : '';
      const lang = entry.language ? ` lang:${entry.language}` : '';
      const port = entry.portName ? ` port:${entry.portName}` : '';
      const menu = entry.menuItemId ? ` menu:${entry.menuItemId}` : '';
      const key = entry.key ? ` key:${entry.key}` : '';
      return `${time}  ${entry.event}  tab:${entry.tabId || '-'}${details}${extra}${lang}${port}${menu}${key}`;
    });
    showResult('res-event-log', lines.join('\n'));
  } catch (e) {
    showResult('res-event-log', e.message, true);
  }
});

// Auto-load the event log on popup open
document.getElementById('btn-refresh-log').click();
