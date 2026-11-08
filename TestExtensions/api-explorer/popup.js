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
    `[${t.id}] ${t.active ? '●' : '○'}${t.pinned ? ' 📌' : ''} ${t.title || '(no title)'}\n    ${t.url || ''}`
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

// Only the tabs in the sidebar's pinned section. Pinning, unpinning, or dragging
// a pinned tab onto the favourites bar changes this list without closing the tab
// (the pinned flag is announced on its own — TASK-59).
document.getElementById('btn-query-pinned').addEventListener('click', async () => {
  try {
    const { tabs } = await sendBg({ type: 'queryTabs', queryInfo: { pinned: true } });
    showResult('res-query-all', tabs.length ? formatTabs(tabs) : 'No pinned tabs');
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

// Chrome's new-tab page opens Detour's blank tab in the background, reported
// with its URL redacted to "" by WebKit (about: is no match-pattern scheme);
// any other chrome: URL typed above is refused (TASK-132.5).
document.getElementById('btn-create-newtab').addEventListener('click', async () => {
  try {
    const tab = await chrome.tabs.create({ url: 'chrome://newtab', active: false });
    showResult('res-create-tab', `Created tab ${tab.id}, url ${JSON.stringify(tab.url)}`);
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

// --- Remove CSS ---

document.getElementById('btn-remove-css').addEventListener('click', async () => {
  try {
    const tabId = parseInt(document.getElementById('input-css-id').value, 10);
    if (isNaN(tabId)) throw new Error('Enter a valid tab ID');
    await sendBg({ type: 'removeCSS', tabId });
    showResult('res-insert-css', `Removed inject.css from tab ${tabId}`);
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

// runtime.requestUpdateCheck: promise form, then the callback form — both
// hand back one {status, version?} result. Unpacked installs always answer
// 'no_update'; a second click within 5 minutes answers 'throttled'.
document.getElementById('btn-update-check').addEventListener('click', async () => {
  try {
    const result = await chrome.runtime.requestUpdateCheck();
    chrome.runtime.requestUpdateCheck((callbackResult) => {
      const err = chrome.runtime.lastError;
      showResult('res-runtime-info', {
        promise: result,
        callback: err ? { lastError: err.message } : callbackResult,
        onUpdateAvailable: typeof chrome.runtime.onUpdateAvailable?.addListener,
      });
    });
  } catch (e) {
    showResult('res-runtime-info', e.message, true);
  }
});

// runtime.reload: WebKit restarts the extension. Called within 15 s of an
// onUpdateAvailable delivery (see background.js) Detour installs the staged
// update on that restart. Either way this popup closes or goes stale, so the
// result line is written first.
document.getElementById('btn-runtime-reload').addEventListener('click', () => {
  try {
    showResult('res-runtime-info', 'runtime.reload() called');
    chrome.runtime.reload();
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

document.getElementById('btn-action-user-settings').addEventListener('click', async () => {
  try {
    const result = await sendBg({ type: 'actionGetUserSettings' });
    showResult('res-action', result);
  } catch (e) {
    showResult('res-action', e.message, true);
  }
});

// --- Notifications ---

const NOTIFICATION_ID = 'api-explorer-notification';

document.getElementById('btn-notif-create').addEventListener('click', async () => {
  try {
    const result = await sendBg({ type: 'createNotification', notificationId: NOTIFICATION_ID });
    showResult('res-notifications', result);
  } catch (e) { showResult('res-notifications', e.message, true); }
});

document.getElementById('btn-notif-getall').addEventListener('click', async () => {
  try {
    showResult('res-notifications', await sendBg({ type: 'getAllNotifications' }));
  } catch (e) { showResult('res-notifications', e.message, true); }
});

document.getElementById('btn-notif-clear').addEventListener('click', async () => {
  try {
    showResult('res-notifications',
      await sendBg({ type: 'clearNotification', notificationId: NOTIFICATION_ID }));
  } catch (e) { showResult('res-notifications', e.message, true); }
});

// update() with only a message keeps the title (TASK-240).
document.getElementById('btn-notif-update').addEventListener('click', async () => {
  try {
    showResult('res-notifications',
      await sendBg({ type: 'updateNotificationMessage', notificationId: NOTIFICATION_ID }));
  } catch (e) { showResult('res-notifications', e.message, true); }
});

// clear() answers whether the notification existed (TASK-240).
document.getElementById('btn-notif-clear-answers').addEventListener('click', async () => {
  try {
    showResult('res-notifications', await sendBg({ type: 'notificationClearAnswers' }));
  } catch (e) { showResult('res-notifications', e.message, true); }
});

// create() then clear() without awaiting the create (TASK-234): the clear must
// win, so no banner stays up and getAll() does not list the id.
document.getElementById('btn-notif-race-worker').addEventListener('click', async () => {
  try {
    showResult('res-notifications', await sendBg({ type: 'notificationCreateThenClear' }));
  } catch (e) { showResult('res-notifications', e.message, true); }
});

document.getElementById('btn-notif-race-popup').addEventListener('click', async () => {
  try {
    const id = 'api-explorer-race-popup';
    const created = chrome.notifications.create(id, {
      type: 'basic', title: 'Create then clear', message: 'Should never stay on screen',
      iconUrl: chrome.runtime.getURL('icon.png')
    });
    const wasCleared = await chrome.notifications.clear(id);
    const notificationId = await created;
    const all = await chrome.notifications.getAll();
    showResult('res-notifications', {
      from: 'popup', notificationId, wasCleared,
      listedAfterClear: Object.prototype.hasOwnProperty.call(all, id), notifications: all
    });
  } catch (e) { showResult('res-notifications', e.message, true); }
});

// create('') generates a fresh id each time, as Chrome's does for an id "not
// set or empty" (TASK-269): two calls are two notifications, none under ''.
document.getElementById('btn-notif-empty-id').addEventListener('click', async () => {
  try {
    const options = {
      type: 'basic', title: 'Empty id', message: 'Generated id',
      iconUrl: chrome.runtime.getURL('icon.png')
    };
    const first = await chrome.notifications.create('', options);
    const second = await chrome.notifications.create('', options);
    const all = await chrome.notifications.getAll();
    showResult('res-notifications', {
      first, second, distinct: first !== second && first !== '' && second !== '',
      listedUnderEmptyId: Object.prototype.hasOwnProperty.call(all, ''), notifications: all
    });
  } catch (e) { showResult('res-notifications', e.message, true); }
});

// --- Management ---

document.getElementById('btn-mgmt-self').addEventListener('click', async () => {
  try {
    const { extensionInfo } = await sendBg({ type: 'getManagementSelf' });
    showResult('res-management', extensionInfo);
  } catch (e) { showResult('res-management', e.message, true); }
});

document.getElementById('btn-mgmt-all').addEventListener('click', async () => {
  try {
    const { extensions } = await sendBg({ type: 'getManagementAll' });
    showResult('res-management', extensions);
  } catch (e) { showResult('res-management', e.message, true); }
});

async function setEnabled(enabled) {
  try {
    const id = document.getElementById('input-mgmt-id').value || undefined;
    const result = await sendBg({ type: 'managementSetEnabled', id, enabled });
    showResult('res-management', `setEnabled(${id || '(self)'}, ${enabled}) → ${JSON.stringify(result)}`);
  } catch (e) { showResult('res-management', e.message, true); }
}

// getPermissionWarningsByManifest and uninstallSelf need no `management`
// permission in Chrome (TASK-257). Warnings from the popup itself and from the
// worker; a bad manifest shows the rejection.
document.getElementById('btn-mgmt-warnings').addEventListener('click', async () => {
  try {
    const manifest = document.getElementById('input-mgmt-manifest').value;
    const warnings = await chrome.management.getPermissionWarningsByManifest(manifest);
    showResult('res-management', { from: 'popup', warnings });
  } catch (e) { showResult('res-management', e.message, true); }
});

document.getElementById('btn-mgmt-warnings-bg').addEventListener('click', async () => {
  try {
    const manifest = document.getElementById('input-mgmt-manifest').value;
    const { warnings } = await sendBg({ type: 'managementPermissionWarnings', manifest });
    showResult('res-management', { from: 'worker', warnings });
  } catch (e) { showResult('res-management', e.message, true); }
});

// Only ever with the confirmation dialog: confirming really uninstalls the
// explorer, and the reply may never arrive (its contexts are unloaded). After a
// Cancel, pressing it again within 10 minutes is refused at once with the
// cancel error and no dialog (TASK-267).
document.getElementById('btn-mgmt-uninstall-self').addEventListener('click', async () => {
  showResult('res-management', 'uninstallSelf({ showConfirmDialog: true }) — waiting for the dialog…');
  try {
    await chrome.management.uninstallSelf({ showConfirmDialog: true });
    showResult('res-management', 'uninstallSelf resolved: uninstalling');
  } catch (e) { showResult('res-management', e.message, true); }
});

document.getElementById('btn-mgmt-enable').addEventListener('click', () => setEnabled(true));
document.getElementById('btn-mgmt-disable').addEventListener('click', () => setEnabled(false));

// --- Storage Managed ---

document.getElementById('btn-managed-probe').addEventListener('click', async () => {
  try {
    showResult('res-storage-managed', await sendBg({ type: 'storageManagedProbe' }));
  } catch (e) { showResult('res-storage-managed', e.message, true); }
});

document.getElementById('btn-managed-probe-popup').addEventListener('click', async () => {
  try {
    const hasManaged = !!(chrome.storage && typeof chrome.storage.managed === 'object');
    const result = { hasManaged, install: globalThis.__detourStorageManagedInstall };
    if (hasManaged) result.getAll = await chrome.storage.managed.get(null);
    showResult('res-storage-managed', result);
  } catch (e) { showResult('res-storage-managed', e.message, true); }
});

// --- Privacy ---

document.getElementById('btn-privacy-get').addEventListener('click', async () => {
  try {
    const { settings } = await sendBg({ type: 'privacyGet' });
    showResult('res-privacy', settings);
  } catch (e) { showResult('res-privacy', e.message, true); }
});

async function setPasswordSaving(value) {
  try {
    const { settings } = await sendBg({ type: 'privacySet', value });
    showResult('res-privacy', settings);
  } catch (e) { showResult('res-privacy', e.message, true); }
}

document.getElementById('btn-privacy-set-on').addEventListener('click', () => setPasswordSaving(true));
document.getElementById('btn-privacy-set-off').addEventListener('click', () => setPasswordSaving(false));

// --- Web Request ---

document.getElementById('btn-webrequest-probe').addEventListener('click', async () => {
  try {
    const result = await sendBg({ type: 'webRequestProbe' });
    showResult('res-webrequest', result);
  } catch (e) { showResult('res-webrequest', e.message, true); }
});

// --- Declarative Net Request (TASK-132.4) ---
//
// A session rule of the shape the Claude extension sets at start-up:
// modifyHeaders on requests to one host, with a header name WebKit's own
// declarativeNetRequest refuses (x-api-explorer). Point the URL at a server
// that echoes request headers to see them arrive from the worker, from this
// popup's fetch, and from this popup's XMLHttpRequest.

function dnrTargetURL() {
  return document.getElementById('input-dnr-url').value.trim() || 'https://httpbin.org/headers';
}

function dnrReport(run) {
  return async () => {
    try {
      showResult('res-dnr', await run());
    } catch (e) {
      showResult('res-dnr', e.message, true);
    }
  };
}

document.getElementById('btn-dnr-probe').addEventListener('click', dnrReport(async () => {
  const dnr = chrome.declarativeNetRequest;
  return {
    popup: {
      namespace: typeof dnr,
      install: globalThis.__detourDeclarativeNetRequest,
      modifyHeaders: dnr && dnr.RuleActionType ? dnr.RuleActionType.MODIFY_HEADERS : '(no RuleActionType)',
      set: dnr && dnr.HeaderOperation ? dnr.HeaderOperation.SET : '(no HeaderOperation)',
      xmlhttprequest: dnr && dnr.ResourceType ? dnr.ResourceType.XMLHTTPREQUEST : '(no ResourceType)',
      onInstalledReason: chrome.runtime.OnInstalledReason || '(no runtime.OnInstalledReason)',
    },
    worker: await sendBg({ type: 'dnrProbe' }),
  };
}));

document.getElementById('btn-dnr-add').addEventListener('click', dnrReport(
  () => sendBg({ type: 'dnrAddRule', url: dnrTargetURL(), custom: true })));

document.getElementById('btn-dnr-add-native').addEventListener('click', dnrReport(
  () => sendBg({ type: 'dnrAddRule', url: dnrTargetURL(), custom: false })));

document.getElementById('btn-dnr-get').addEventListener('click', dnrReport(async () => ({
  popup: await chrome.declarativeNetRequest.getSessionRules(),
  worker: await sendBg({ type: 'dnrGetRules' }),
})));

document.getElementById('btn-dnr-remove').addEventListener('click', dnrReport(async () => {
  // The callback form, from the popup this time.
  await new Promise((resolve, reject) => {
    chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: [1] }, () => {
      if (chrome.runtime.lastError) reject(new Error(chrome.runtime.lastError.message));
      else resolve();
    });
  });
  return { removed: [1], rules: await chrome.declarativeNetRequest.getSessionRules() };
}));

document.getElementById('btn-dnr-fetch').addEventListener('click', dnrReport(async () => {
  const url = dnrTargetURL();
  const text = async (make) => {
    try { return (await make()).slice(0, 4000); } catch (e) { return 'failed: ' + e.message; }
  };
  // A header-echoing endpoint answers JSON like {"headers": {...}}: show it as
  // an object, not as a string full of escaped quotes.
  const parsed = (body) => {
    try { return JSON.parse(body); } catch (e) { return body; }
  };
  // The two headers the section's rules set, as each context's request carried
  // them — first, so they are visible without scrolling the result box.
  const sent = (response) => {
    const headers = response && typeof response === 'object' ? response.headers : null;
    if (!headers || typeof headers !== 'object') return '(the response is not {"headers": {...}})';
    const value = (name) => {
      const key = Object.keys(headers).find((k) => k.toLowerCase() === name);
      return key === undefined ? '(not sent)' : headers[key];
    };
    return { 'user-agent': value('user-agent'), 'x-api-explorer': value('x-api-explorer') };
  };
  const responses = {
    worker: parsed((await sendBg({ type: 'dnrFetch', url })).body),
    popupFetch: parsed(await text(async () => (await fetch(url, { cache: 'no-store' })).text())),
    popupXHR: parsed(await text(() => new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open('GET', url);
      xhr.onload = () => resolve(String(xhr.responseText));
      xhr.onerror = () => reject(new Error('XHR error'));
      xhr.send();
    }))),
  };
  return {
    url,
    sent: { worker: sent(responses.worker), popupFetch: sent(responses.popupFetch), popupXHR: sent(responses.popupXHR) },
    responses,
  };
}));

// --- Tab groups (TASK-132.12) ---
//
// tabs.group / tabs.ungroup on the popup's tab, chrome.tabGroups from the popup,
// and what the worker's tabGroups.on* and tabs.onUpdated({groupId}) listeners
// heard. The tab's groupId is read back after each call.

async function popupTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) throw new Error('no active tab in this window');
  return tab;
}

async function firstGroup() {
  const groups = await chrome.tabGroups.query({});
  if (!groups.length) throw new Error('no tab group: use Group This Tab first');
  return groups[0];
}

const tabGroupColors = ['grey', 'blue', 'red', 'yellow', 'green', 'pink', 'purple', 'cyan', 'orange'];

const tabGroupActions = {
  'btn-tg-group': async () => {
    const tab = await popupTab();
    const groupId = await chrome.tabs.group({ tabIds: tab.id });
    return { groupId, tab: { id: tab.id, groupId: (await chrome.tabs.get(tab.id)).groupId } };
  },
  'btn-tg-query': async () => ({
    popup: await chrome.tabGroups.query({}),
    worker: await sendBg({ type: 'tabGroupsQuery' }),
    membersOfFirst: await (async () => {
      const groups = await chrome.tabGroups.query({});
      return groups.length ? (await chrome.tabs.query({ groupId: groups[0].id })).map((t) => t.id) : [];
    })(),
  }),
  'btn-tg-update': async () => {
    const group = await firstGroup();
    const color = tabGroupColors[(tabGroupColors.indexOf(group.color) + 1) % tabGroupColors.length];
    return await chrome.tabGroups.update(group.id, { title: 'Explorer ' + new Date().toLocaleTimeString(), color });
  },
  'btn-tg-move': async () => chrome.tabGroups.move((await firstGroup()).id, { index: -1 }),
  'btn-tg-ungroup': async () => {
    const tab = await popupTab();
    await chrome.tabs.ungroup(tab.id);
    return { tab: { id: tab.id, groupId: (await chrome.tabs.get(tab.id)).groupId } };
  },
  'btn-tg-events': async () => sendBg({ type: 'tabGroupsEvents' }),
};

for (const [id, action] of Object.entries(tabGroupActions)) {
  document.getElementById(id).addEventListener('click', async () => {
    try {
      showResult('res-tg', await action());
    } catch (e) {
      showResult('res-tg', e.message, true);
    }
  });
}

// --- Debugger (TASK-132.13) ---
//
// Chrome's chrome.debugger, promise form: attach (protocol 1.3), detach,
// getTargets and sendCommand against one tab — the tabId field, or this
// window's active tab. With "via worker" ticked each call runs in the worker
// instead (debuggerOp in background.js, kept in step with debuggerOpHere).
// onEvent / onDetach are logged here while the popup is open, and by the
// worker all along.

async function debuggerTarget() {
  const typed = document.getElementById('dbg-tab-id').value.trim();
  if (typed) return { tabId: Number(typed) };
  return { tabId: (await popupTab()).id };
}

async function debuggerOpHere(op, target, args) {
  if (!chrome.debugger) throw new Error('no chrome.debugger in this context');
  switch (op) {
    case 'attach':
      await chrome.debugger.attach(target, '1.3');
      return { attached: target };
    case 'detach':
      await chrome.debugger.detach(target);
      return { detached: target };
    case 'getTargets':
      return await chrome.debugger.getTargets();
    case 'sendCommand':
      return await chrome.debugger.sendCommand(target, args.method, args.params);
  }
  throw new Error('unknown debugger op ' + op);
}

async function debuggerOp(op, args = {}) {
  const target = await debuggerTarget();
  if (!document.getElementById('chk-dbg-worker').checked) {
    return { from: 'popup', target, result: await debuggerOpHere(op, target, args) };
  }
  const response = await sendBg({ type: 'debuggerOp', op, target, args });
  if (response && response.error) throw new Error(response.error);
  return { from: 'worker', target, result: response };
}

// A result fit to print: a screenshot's base64 is replaced by its length.
function withoutImageData(value) {
  return JSON.parse(JSON.stringify(value, (key, field) =>
    key === 'data' && typeof field === 'string' && field.length > 200 ? `(${field.length} base64 chars)` : field));
}

function screenshotParams() {
  const format = document.getElementById('dbg-shot-format').value;
  const params = { format };
  const quality = document.getElementById('dbg-shot-quality').value.trim();
  if (quality) params.quality = Number(quality);
  if (document.getElementById('chk-dbg-clip').checked) {
    const number = (id) => Number(document.getElementById(id).value);
    params.clip = {
      x: number('dbg-clip-x'), y: number('dbg-clip-y'),
      width: number('dbg-clip-w'), height: number('dbg-clip-h'),
      scale: number('dbg-clip-scale'),
    };
  }
  return params;
}

// Shows the returned image and resolves with its decoded pixel size.
function showScreenshot(format, data) {
  const img = document.getElementById('dbg-shot-image');
  return new Promise((resolve) => {
    img.onload = () => resolve({ decodedWidth: img.naturalWidth, decodedHeight: img.naturalHeight });
    img.onerror = () => resolve({ decodeError: 'the data did not decode as ' + format });
    img.src = `data:image/${format};base64,${data}`;
    img.style.display = 'block';
  });
}

const debuggerActions = {
  'btn-dbg-attach': () => debuggerOp('attach'),
  'btn-dbg-detach': () => debuggerOp('detach'),
  'btn-dbg-targets': async () => {
    const response = await debuggerOp('getTargets');
    response.result = response.result.map(({ id, tabId, type, attached, extensionId, title, url }) =>
      ({ id, tabId, type, attached, extensionId, title, url }));
    return response;
  },
  'btn-dbg-page-enable': () => debuggerOp('sendCommand', { method: 'Page.enable', params: {} }),
  'btn-dbg-shot': async () => {
    const params = screenshotParams();
    const started = performance.now();
    const response = await debuggerOp('sendCommand', { method: 'Page.captureScreenshot', params });
    const elapsedMs = Math.round(performance.now() - started);
    const data = response.result && response.result.data;
    const decoded = typeof data === 'string' ? await showScreenshot(params.format, data) : { decodeError: 'no data' };
    return { ...withoutImageData(response), params, elapsedMs, ...decoded };
  },
  'btn-dbg-send': async () => {
    const method = document.getElementById('dbg-method').value.trim();
    const text = document.getElementById('dbg-params').value.trim();
    let params;
    try {
      params = text ? JSON.parse(text) : undefined;
    } catch (e) {
      throw new Error('params are not JSON: ' + e.message);
    }
    return withoutImageData(await debuggerOp('sendCommand', { method, params }));
  },
  // The callback form, which reports failure through chrome.runtime.lastError.
  'btn-dbg-bad-callback': async () => {
    const target = await debuggerTarget();
    return await new Promise((resolve) => {
      chrome.debugger.sendCommand(target, 'Explorer.noSuchMethod', {}, (result) => {
        resolve({
          target,
          result: result === undefined ? '(undefined)' : result,
          lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : '(none)',
        });
      });
    });
  },
};

for (const [id, action] of Object.entries(debuggerActions)) {
  document.getElementById(id).addEventListener('click', async () => {
    try {
      showResult('res-dbg', await action());
    } catch (e) {
      showResult('res-dbg', e.message, true);
    }
  });
}

// --- Debugger input (TASK-132.14) ---
//
// Input.dispatchMouseEvent / dispatchKeyEvent / insertText, shaped the way the
// Claude extension sends them: a click is mouseMoved, mousePressed and
// mouseReleased; a typed key is keyDown with text, then keyUp; Cmd+A carries
// the Mac editing command.

const inputPoint = () => ({
  x: Number(document.getElementById('dbg-in-x').value) || 0,
  y: Number(document.getElementById('dbg-in-y').value) || 0,
});

async function sendInput(method, params) {
  const response = await debuggerOp('sendCommand', { method, params });
  return response.result;
}

async function inputClick(button, count) {
  const { x, y } = inputPoint();
  const held = { left: 1, right: 2, middle: 4 }[button];
  const sent = [];
  await sendInput('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y, button: 'none', buttons: 0, modifiers: 0 });
  for (let n = 1; n <= count; n++) {
    await sendInput('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button, buttons: held, clickCount: n, modifiers: 0 });
    await sendInput('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button, buttons: 0, clickCount: n, modifiers: 0 });
    sent.push(`press+release ${n}`);
  }
  return { x, y, button, sent };
}

async function inputKey(key, code, text, keyCode, modifiers = 0, commands = []) {
  await sendInput('Input.dispatchKeyEvent', {
    type: text ? 'keyDown' : 'rawKeyDown', key, code, windowsVirtualKeyCode: keyCode, modifiers,
    text: text || '', unmodifiedText: text || '', commands,
  });
  await sendInput('Input.dispatchKeyEvent', { type: 'keyUp', key, code, windowsVirtualKeyCode: keyCode, modifiers });
}

const debuggerInputActions = {
  'btn-dbg-in-click': () => inputClick('left', 1),
  'btn-dbg-in-dblclick': () => inputClick('left', 2),
  'btn-dbg-in-rightclick': () => inputClick('right', 1),
  'btn-dbg-in-wheel': async () => {
    const { x, y } = inputPoint();
    await sendInput('Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: 0, deltaY: 300, modifiers: 0 });
    return { x, y, deltaY: 300 };
  },
  'btn-dbg-in-type': async () => {
    const text = document.getElementById('dbg-in-text').value;
    const typed = [];
    for (const ch of text) {
      const upper = ch.toUpperCase();
      if (/^[A-Za-z]$/.test(ch)) {
        await inputKey(ch, 'Key' + upper, ch, upper.charCodeAt(0), ch === upper ? 8 : 0);
        typed.push(ch);
      } else if (/^[0-9]$/.test(ch)) {
        await inputKey(ch, 'Digit' + ch, ch, ch.charCodeAt(0));
        typed.push(ch);
      } else if (ch === ' ') {
        await inputKey(' ', 'Space', ' ', 32);
        typed.push(ch);
      } else {
        // As the extension does for characters it has no key for.
        await sendInput('Input.insertText', { text: ch });
        typed.push(`insertText(${ch})`);
      }
    }
    return { typed };
  },
  'btn-dbg-in-insert': async () => {
    const text = document.getElementById('dbg-in-text').value;
    await sendInput('Input.insertText', { text });
    return { inserted: text };
  },
  'btn-dbg-in-selectall': async () => {
    await inputKey('a', 'KeyA', 'a', 65, 4, ['selectAll']);
    return { sent: 'Cmd+A', commands: ['selectAll'] };
  },
  'btn-dbg-in-enter': async () => {
    await inputKey('Enter', 'Enter', '\r', 13);
    return { sent: 'Enter' };
  },
};

for (const [id, action] of Object.entries(debuggerInputActions)) {
  document.getElementById(id).addEventListener('click', async () => {
    try {
      showResult('res-dbg', await action());
    } catch (e) {
      showResult('res-dbg', e.message, true);
    }
  });
}

// What the popup hears while it is open (the last 50).
const popupDebuggerEvents = [];
const recordPopupDebuggerEvent = (entry) => {
  popupDebuggerEvents.push({ at: new Date().toISOString(), ...entry });
  if (popupDebuggerEvents.length > 50) popupDebuggerEvents.shift();
};
if (chrome.debugger) {
  chrome.debugger.onEvent.addListener((source, method, params) => {
    const text = params === undefined ? undefined : JSON.stringify(withoutImageData(params));
    recordPopupDebuggerEvent({ event: 'onEvent', source, method, params: text && text.length > 300 ? text.slice(0, 300) + '…' : text });
  });
  chrome.debugger.onDetach.addListener((source, reason) => {
    recordPopupDebuggerEvent({ event: 'onDetach', source, reason });
  });
}

document.getElementById('btn-dbg-events').addEventListener('click', async () => {
  try {
    showResult('res-dbg-events', { popup: popupDebuggerEvents, worker: (await sendBg({ type: 'debuggerEvents' })).events });
  } catch (e) {
    showResult('res-dbg-events', e.message, true);
  }
});

document.getElementById('btn-dbg-events-clear').addEventListener('click', async () => {
  popupDebuggerEvents.length = 0;
  try {
    await sendBg({ type: 'debuggerEventsClear' });
    showResult('res-dbg-events', 'cleared');
  } catch (e) {
    showResult('res-dbg-events', e.message, true);
  }
});

// --- Side panel (TASK-132.8) ---
//
// chrome.sidePanel is Detour's polyfill (released WebKit has none): the panel is
// a page Detour hosts beside the tab. A tab panel (setOptions with a tabId)
// shows only with its tab; the window panel (side_panel.default_path) shows for
// every tab without one. Each button runs here in the popup, or in the worker.

async function sidePanelTarget() {
  // "currentWindow" is the focused window; a window that is not key has none,
  // so fall back to the first active tab WebKit lists.
  let [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) [tab] = await chrome.tabs.query({ active: true });
  if (!tab) throw new Error('no active tab');
  return { tabId: tab.id, windowId: tab.windowId };
}

async function sidePanelRun(op) {
  const target = await sidePanelTarget();
  if (document.getElementById('chk-sidepanel-worker').checked) {
    const reply = await sendBg({ type: 'sidePanelOp', op, target });
    if (reply && reply.error) throw new Error(reply.error);
    return { via: 'worker', target, result: reply };
  }
  return { via: 'popup', target, result: await sidePanelOp(op, target) };
}

// Kept in step with the worker's copy in background.js.
async function sidePanelOp(op, target) {
  const tabPath = `sidepanel.html?tabId=${encodeURIComponent(target.tabId)}`;
  switch (op) {
    case 'probe':
      return {
        type: typeof chrome.sidePanel,
        install: globalThis.__detourSidePanelInstall || '(no Detour polyfill)',
        methods: chrome.sidePanel ? Object.keys(chrome.sidePanel).sort() : [],
      };
    case 'openTab':
      // As the Claude extension does it: neither call awaited.
      chrome.sidePanel.setOptions({ tabId: target.tabId, path: tabPath, enabled: true });
      await chrome.sidePanel.open({ tabId: target.tabId });
      return { opened: tabPath };
    case 'openWindow':
      await chrome.sidePanel.open({ windowId: target.windowId });
      return { opened: 'window panel' };
    case 'closeTab':
      await chrome.sidePanel.close({ tabId: target.tabId });
      return { closed: 'tab' };
    case 'closeWindow':
      await chrome.sidePanel.close({ windowId: target.windowId });
      return { closed: 'window' };
    case 'disableTab':
      await chrome.sidePanel.setOptions({ tabId: target.tabId, enabled: false });
      return await chrome.sidePanel.getOptions({ tabId: target.tabId });
    case 'getOptions':
      return {
        tab: await chrome.sidePanel.getOptions({ tabId: target.tabId }),
        default: await chrome.sidePanel.getOptions({}),
        behavior: await chrome.sidePanel.getPanelBehavior(),
      };
    case 'toggleBehavior': {
      const { openPanelOnActionClick } = await chrome.sidePanel.getPanelBehavior();
      await chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: !openPanelOnActionClick });
      return await chrome.sidePanel.getPanelBehavior();
    }
  }
  throw new Error('unknown side panel op ' + op);
}

for (const [id, op] of [
  ['btn-sidepanel-probe', 'probe'], ['btn-sidepanel-open-tab', 'openTab'],
  ['btn-sidepanel-open-window', 'openWindow'], ['btn-sidepanel-close-tab', 'closeTab'],
  ['btn-sidepanel-close-window', 'closeWindow'], ['btn-sidepanel-disable-tab', 'disableTab'],
  ['btn-sidepanel-get-options', 'getOptions'], ['btn-sidepanel-behavior', 'toggleBehavior'],
]) {
  document.getElementById(id).addEventListener('click', async () => {
    try {
      showResult('res-sidepanel', await sidePanelRun(op));
    } catch (e) {
      showResult('res-sidepanel', e.message, true);
    }
  });
}

// --- runtime.getContexts (TASK-132.9) ---
//
// Also Detour's: the extension's open contexts in this profile — the worker,
// extension pages in tabs, this popup, the offscreen document, side panels.

async function showContexts(filter) {
  try {
    if (typeof chrome.runtime.getContexts !== 'function') throw new Error('chrome.runtime.getContexts is missing');
    showResult('res-contexts', {
      install: globalThis.__detourRuntimeGetContextsInstall || '(no Detour polyfill)',
      ContextType: chrome.runtime.ContextType,
      popup: await chrome.runtime.getContexts(filter),
      worker: await sendBg({ type: 'getContexts', filter }),
    });
  } catch (e) {
    showResult('res-contexts', e.message, true);
  }
}

document.getElementById('btn-contexts-all').addEventListener('click', () => showContexts({}));
document.getElementById('btn-contexts-panels').addEventListener('click',
  () => showContexts({ contextTypes: [chrome.runtime.ContextType.SIDE_PANEL] }));
document.getElementById('btn-contexts-window').addEventListener('click', async () => {
  try {
    const { windowId } = await sidePanelTarget();
    await showContexts({ windowIds: [windowId] });
  } catch (e) {
    showResult('res-contexts', e.message, true);
  }
});

// --- Externally connectable (TASK-132.6) ---
//
// The receiving side lives in the worker (runtime.onMessageExternal /
// onConnectExternal); the sending side is a web page on 127.0.0.1 or localhost
// (external-page/index.html). This section shows the id to send to and what
// the worker received from which origin and tab.

document.getElementById('input-external-id').value = chrome.runtime.id;

document.getElementById('btn-external-copy').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(chrome.runtime.id);
    showResult('res-external', 'Copied ' + chrome.runtime.id);
  } catch (e) {
    showResult('res-external', e.message, true);
  }
});

document.getElementById('btn-external-received').addEventListener('click', async () => {
  try {
    showResult('res-external', await sendBg({ type: 'externalReceived' }));
  } catch (e) {
    showResult('res-external', e.message, true);
  }
});

document.getElementById('btn-external-clear').addEventListener('click', async () => {
  try {
    showResult('res-external', await sendBg({ type: 'externalClear' }));
  } catch (e) {
    showResult('res-external', e.message, true);
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

// From a Private or quarantine window both buttons open a Private window:
// Detour cannot tell `incognito: false` from leaving it out (TASK-214).
// From a normal window, Create Private is refused, and the error shown, unless
// the extension is allowed in Private (Settings > Extensions, TASK-224).
async function createWindow(incognito) {
  try {
    const options = { url: 'https://example.com/' };
    if (incognito) options.incognito = true;
    const win = await chrome.windows.create(options);
    // A Private window is reported only to a context with access to Private
    // data; from an extension page WebKit resolves with null, not undefined.
    showResult('res-windows', win == null
      ? 'Opened (this context cannot see the new window)'
      : { id: win.id, incognito: win.incognito, type: win.type });
  } catch (e) {
    showResult('res-windows', e.message, true);
  }
}

document.getElementById('btn-windows-create').addEventListener('click', () => createWindow(false));
document.getElementById('btn-windows-create-private').addEventListener('click', () => createWindow(true));

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

document.getElementById('btn-perm-request').addEventListener('click', async () => {
  try {
    const granted = await chrome.permissions.request({ permissions: ['cookies'] });
    showResult('res-permissions', `permissions.request("cookies"): ${granted}`);
  } catch (e) {
    showResult('res-permissions', e.message, true);
  }
});

document.getElementById('btn-perm-remove').addEventListener('click', async () => {
  try {
    const removed = await chrome.permissions.remove({ permissions: ['cookies'] });
    showResult('res-permissions', `permissions.remove("cookies"): ${removed}`);
  } catch (e) {
    showResult('res-permissions', e.message, true);
  }
});

// TASK-260: `history` is optional here. WebKit refuses the name in
// permissions.request/contains/remove ("'history' is not a valid permission"),
// so Detour's polyfill answers for it: Detour's prompt, saved like the Settings
// switch. Until it is granted, History > Search reads "history permission is
// optional and has not been granted". The mixed request goes through WebKit's
// prompt for cookies first (inside the click's user gesture), then Detour's,
// and is granted whole or not at all.
async function requestAndReport(permissions) {
  try {
    const granted = await chrome.permissions.request({ permissions });
    const has = await chrome.permissions.contains({ permissions });
    showResult('res-permissions',
      `permissions.request(${JSON.stringify(permissions)}): ${granted}, contains: ${has}`);
  } catch (e) {
    showResult('res-permissions', e.message, true);
  }
}

document.getElementById('btn-perm-request-history').addEventListener('click', () => requestAndReport(['history']));
document.getElementById('btn-perm-request-history-cookies').addEventListener('click',
  () => requestAndReport(['history', 'cookies']));

document.getElementById('btn-perm-remove-history').addEventListener('click', async () => {
  try {
    const removed = await chrome.permissions.remove({ permissions: ['history'] });
    const has = await chrome.permissions.contains({ permissions: ['history'] });
    showResult('res-permissions', `permissions.remove("history"): ${removed}, contains: ${has}`);
  } catch (e) {
    showResult('res-permissions', e.message, true);
  }
});

// `https://example.org/*` is listed in optional_host_permissions, so Settings
// shows it as an Optional row whose switch writes the decision and applies it
// to the loaded context without a relaunch (TASK-25).
const EXAMPLE_ORIGIN = 'https://example.org/*';

document.getElementById('btn-perm-request-origin').addEventListener('click', async () => {
  try {
    const granted = await chrome.permissions.request({ origins: [EXAMPLE_ORIGIN] });
    const has = await chrome.permissions.contains({ origins: [EXAMPLE_ORIGIN] });
    showResult('res-permissions', `permissions.request(origins "${EXAMPLE_ORIGIN}"): ${granted}, contains: ${has}`);
  } catch (e) {
    showResult('res-permissions', e.message, true);
  }
});

document.getElementById('btn-perm-remove-origin').addEventListener('click', async () => {
  try {
    const removed = await chrome.permissions.remove({ origins: [EXAMPLE_ORIGIN] });
    showResult('res-permissions', `permissions.remove(origins "${EXAMPLE_ORIGIN}"): ${removed}`);
  } catch (e) {
    showResult('res-permissions', e.message, true);
  }
});

// TASK-75: Chrome's match patterns take a port, WebKit's do not — without
// Detour's polyfill wrapper this call throws "http://127.0.0.1:8471/* is not a
// valid pattern" instead of answering, which is what stopped 1Password on every
// site served from a non-default port. The wrapper drops the port and forwards,
// so this must print a boolean (true under `<all_urls>`), and the port-free
// twin must print the same answer. `contains._detourNative` is WebKit's own
// function, kept by the wrapper: it is expected to still throw.
const PORTED_ORIGIN = 'http://127.0.0.1:8471/*';

document.getElementById('btn-perm-contains-port').addEventListener('click', async () => {
  const lines = [];
  try {
    const ported = await chrome.permissions.contains({ origins: [PORTED_ORIGIN] });
    lines.push(`contains("${PORTED_ORIGIN}"): ${ported}`);
  } catch (e) {
    lines.push(`contains("${PORTED_ORIGIN}") THREW: ${e.message} — the TASK-75 wrapper is missing`);
  }
  try {
    const portless = await chrome.permissions.contains({ origins: ['http://127.0.0.1/*'] });
    lines.push(`contains("http://127.0.0.1/*"): ${portless} (must match the line above)`);
  } catch (e) {
    lines.push(`contains("http://127.0.0.1/*") THREW: ${e.message}`);
  }
  const native = chrome.permissions.contains._detourNative;
  if (typeof native !== 'function') {
    lines.push('no _detourNative on permissions.contains — nothing is wrapping it');
  } else {
    try {
      const answer = await native.call(chrome.permissions, { origins: [PORTED_ORIGIN] });
      lines.push(`WebKit's own contains answered ${answer} — it accepts ports now, the wrapper may be removable`);
    } catch (e) {
      lines.push(`WebKit's own contains threw (expected): ${e.message}`);
    }
  }
  showResult('res-permissions', lines.join('\n'));
});

// --- Native Messaging ---
// Probes a host that does not exist, to show the error shapes an extension sees.
// This extension does not declare `nativeMessaging`, so a real host is refused
// with "nativeMessaging permission not declared". In an extension that declares it,
// a saved denial in Settings refuses real hosts with Chrome's "Access to the
// specified native messaging host is forbidden." (TASK-25): a rejected
// sendNativeMessage promise, or a connectNative port disconnected with
// `port.error` set. Detour's built-in hosts (detourPolyfill, detourWebSocketRelay)
// are never affected by that decision.
const PROBE_HOST = 'com.detour.api_explorer_probe';

document.getElementById('btn-nm-send').addEventListener('click', async () => {
  if (typeof chrome.runtime.sendNativeMessage !== 'function') {
    showResult('res-native-messaging', 'runtime.sendNativeMessage is unavailable', true);
    return;
  }
  try {
    const reply = await chrome.runtime.sendNativeMessage(PROBE_HOST, { probe: true });
    showResult('res-native-messaging', { host: PROBE_HOST, reply });
  } catch (e) {
    showResult('res-native-messaging', `sendNativeMessage("${PROBE_HOST}") rejected: ${e.message || e}`, true);
  }
});

document.getElementById('btn-nm-connect').addEventListener('click', () => {
  if (typeof chrome.runtime.connectNative !== 'function') {
    showResult('res-native-messaging', 'runtime.connectNative is unavailable', true);
    return;
  }
  try {
    const port = chrome.runtime.connectNative(PROBE_HOST);
    port.onDisconnect.addListener((p) => {
      const lastError = chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
      const err = (p && p.error) || port.error;
      showResult('res-native-messaging', {
        host: PROBE_HOST,
        event: 'port.onDisconnect',
        lastError,
        portError: err ? String(err.message || err) : null
      }, !!(lastError || err));
    });
    showResult('res-native-messaging', `connectNative("${PROBE_HOST}") opened; waiting for onDisconnect...`);
  } catch (e) {
    showResult('res-native-messaging', `connectNative("${PROBE_HOST}") threw: ${e.message || e}`, true);
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

// --- runtime.onInstalled ---
// Every delivery the worker recorded (background.js keeps them in
// storage.local.onInstalledEvents), plus how the polyfill installed the event.
// Expected in Detour (TASK-22, TASK-29): one 'install' per profile after
// installing, one 'update' with previousVersion after a version change or a
// same-version reinstall, nothing for a reload, relaunch or disable/enable, and
// nothing ever in the Private profile. The popup itself listens too: in Detour
// its mode is 'suppressed' and it never receives the event — only the
// extension's background context does, whether that is a service worker
// (contextKind 'worker', as here) or an MV3 background page (TASK-43).
const popupOnInstalledEvents = [];
chrome.runtime.onInstalled.addListener((details) => {
  popupOnInstalledEvents.push({ reason: details.reason, previousVersion: details.previousVersion, timestamp: Date.now() });
});
document.getElementById('btn-oninstalled-history').addEventListener('click', async () => {
  try {
    const { onInstalledEvents = [], onInstalledWorkerMode = '(worker not started yet)' } =
      await chrome.storage.local.get(['onInstalledEvents', 'onInstalledWorkerMode']);
    const lines = onInstalledEvents.slice().reverse().map(e => {
      const time = new Date(e.timestamp).toLocaleString();
      const previous = e.previousVersion ? ` from ${e.previousVersion}` : '';
      return `${time}  ${e.reason}${previous} -> v${e.version}`;
    });
    const status = globalThis.__detourRuntimeOnInstalled;
    const popupMode = status
      ? `${status.mode} [${status.contextKind}]${status.detail ? ` (${status.detail})` : ''}`
      : 'no Detour polyfill';
    const popupReceived = popupOnInstalledEvents.length
      ? popupOnInstalledEvents.map(e => `${e.reason}${e.previousVersion ? ` from ${e.previousVersion}` : ''}`).join(', ')
      : 'nothing (expected)';
    showResult('res-oninstalled', [
      `worker polyfill mode: ${onInstalledWorkerMode}`,
      `popup polyfill mode: ${popupMode}; popup listener received: ${popupReceived}`,
      ...(lines.length ? lines : ['(no deliveries recorded)'])
    ].join('\n'));
  } catch (e) { showResult('res-oninstalled', e.message, true); }
});

// --- Callback form / runtime.lastError ---
// The promise-backed polyfill APIs (idle, notifications, history, management,
// fontSettings, search, offscreen) also take a trailing callback. In that form
// Chrome never rejects: on failure the callback runs with no result while
// `chrome.runtime.lastError` is `{ message }`, lastError is gone again once the
// callback returns, and a failure the callback never read is reported as
// "Unchecked runtime.lastError: ...". These buttons exercise that path
// (Detour: `__detourSettle` in ExtensionAPIPolyfill.swift).
//
// The failing calls pass `null` as a notification id: Detour's handler answers
// "notificationId required" for anything that is not a string, so the failure is
// deterministic and has no side effect. (`management.setEnabled` is NOT a failure
// case here — Detour deliberately answers it with a logged no-op success.)

function describeLastError() {
  const err = chrome.runtime.lastError;
  if (err === undefined) return 'undefined';
  if (err === null) return 'null';
  return err.message ? `{ message: "${err.message}" }` : String(err);
}

// Which path the polyfill took to set lastError: 'js' (redefined on the runtime
// object), 'native-relay' (bounced through sendNativeMessage) or 'console'.
function callbackSettleMode() {
  const status = globalThis.__detourCallbackLastError;
  return status ? status.lastMode : '(no Detour polyfill)';
}

document.getElementById('btn-lasterror-fail').addEventListener('click', () => {
  const lines = ['chrome.notifications.update(null, {...}, cb) — expected to fail'];
  const returned = chrome.notifications.update(null, { title: 'nope' }, function () {
    lines.push(`in callback: args=${arguments.length}, result=${String(arguments[0])}`);
    lines.push(`in callback: lastError = ${describeLastError()}`);
    // Queued for after the callback returns: the polyfill restores the original
    // lastError there, so this must no longer report a message.
    setTimeout(() => {
      lines.push(`after callback returned: lastError = ${describeLastError()}`);
      lines.push(`settle mode: ${callbackSettleMode()}`);
      showResult('res-lasterror', lines.join('\n'), true);
    }, 0);
  });
  lines.push(`returned with a callback: ${String(returned)} (Chrome returns undefined)`);
  showResult('res-lasterror', lines.join('\n'));
});

document.getElementById('btn-lasterror-unchecked').addEventListener('click', () => {
  let fired = false;
  let argsLength = -1;
  // Deliberately never reads chrome.runtime.lastError, so the failure is
  // unchecked and must be reported as a console warning.
  chrome.notifications.clear(null, function () {
    fired = true;
    argsLength = arguments.length;
  });
  showResult('res-lasterror', 'chrome.notifications.clear(null, cb) — waiting for the callback...');
  setTimeout(() => {
    showResult('res-lasterror', [
      'chrome.notifications.clear(null, cb) with a callback that ignores lastError',
      `callback fired: ${fired} (args=${argsLength})`,
      `lastError now: ${describeLastError()}`,
      `settle mode: ${callbackSettleMode()}`,
      'expected in the console: Unchecked runtime.lastError: notificationId required'
    ].join('\n'), true);
  }, 300);
});

document.getElementById('btn-lasterror-success').addEventListener('click', () => {
  const lines = ['chrome.management.getSelf(cb) — expected to succeed'];
  const returned = chrome.management.getSelf(function (info) {
    lines.push(`in callback: args=${arguments.length}, lastError = ${describeLastError()}`);
    lines.push(`result: ${info ? `${info.name} ${info.version} (${info.id})` : String(info)}`);
    showResult('res-lasterror', lines.join('\n'));
  });
  lines.push(`returned with a callback: ${String(returned)} (Chrome returns undefined)`);
  showResult('res-lasterror', lines.join('\n'));
});

document.getElementById('btn-lasterror-noresult').addEventListener('click', () => {
  // setEnabled is one of the `passResult: false` APIs: on success its callback
  // fires with no arguments at all, not with `undefined` passed in.
  const lines = ['chrome.management.setEnabled(<self>, true, cb) — no-op success, no result'];
  chrome.management.setEnabled(chrome.runtime.id, true, function () {
    lines.push(`in callback: args=${arguments.length} (expected 0), lastError = ${describeLastError()}`);
    showResult('res-lasterror', lines.join('\n'));
  });
  showResult('res-lasterror', lines.join('\n'));
});

document.getElementById('btn-lasterror-worker').addEventListener('click', async () => {
  try {
    const { probes, lastErrorAfter } = await sendBg({ type: 'callbackFormProbe' });
    const lines = probes.map(p => {
      if (p.threw) return `${p.label}\n    threw: ${p.threw}`;
      if (p.timedOut) return `${p.label}\n    ${p.timedOut}`;
      return `${p.label}\n    args=${p.argsLength}, result=${JSON.stringify(p.result)}`
        + `, lastError=${p.lastError}, mode=${p.mode}`;
    });
    lines.push(`after the callbacks returned: lastError = ${lastErrorAfter}`);
    showResult('res-lasterror', ['service worker:', ...lines].join('\n'));
  } catch (e) { showResult('res-lasterror', e.message, true); }
});

// --- History ---
document.getElementById('btn-history-search').addEventListener('click', async () => {
  try {
    const text = document.getElementById('input-history-query').value;
    // With no startTime a search covers the last 24 hours, as in Chrome
    // (TASK-153); startTime 0 asks for all of the history.
    const allTime = document.getElementById('input-history-all-time').checked;
    const { results } = await sendBg({ type: 'historySearch', text, allTime });
    // Counts and times are this profile's own (TASK-138): the same search from
    // another profile's popup must show that profile's URLs and numbers only.
    showResult('res-history', results.map(r =>
      `${r.title}\n  ${r.url}\n  visits: ${r.visitCount} (typed: ${r.typedCount}), last: ${new Date(r.lastVisitTime).toLocaleString()}`
    ).join('\n') || '(no results)');
  } catch (e) { showResult('res-history', e.message, true); }
});

// --- Bookmarks ---
document.getElementById('btn-bookmarks-tree').addEventListener('click', async () => {
  try {
    const { tree } = await sendBg({ type: 'bookmarksGetTree' });
    showResult('res-bookmarks', tree);
  } catch (e) { showResult('res-bookmarks', e.message, true); }
});

// --- Sessions ---
document.getElementById('btn-sessions-restore').addEventListener('click', async () => {
  try {
    const { session } = await sendBg({ type: 'sessionsRestore' });
    showResult('res-sessions', session);
  } catch (e) { showResult('res-sessions', e.message, true); }
});

// --- Search ---
document.getElementById('btn-search-query').addEventListener('click', async () => {
  try {
    const text = document.getElementById('input-search-text').value || 'test';
    await sendBg({ type: 'searchQuery', text });
    showResult('res-search', 'Search opened in new tab');
  } catch (e) { showResult('res-search', e.message, true); }
});

// --- Tab Ops ---
document.getElementById('btn-duplicate-tab').addEventListener('click', async () => {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const { tab: newTab } = await sendBg({ type: 'duplicateTab', tabId: tab.id });
    showResult('res-tab-ops', `Duplicated → tab ${newTab.id}`);
  } catch (e) { showResult('res-tab-ops', e.message, true); }
});

document.getElementById('btn-get-zoom').addEventListener('click', async () => {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const { zoom } = await sendBg({ type: 'getZoom', tabId: tab.id });
    showResult('res-tab-ops', `Zoom: ${zoom}`);
  } catch (e) { showResult('res-tab-ops', e.message, true); }
});

document.getElementById('btn-zoom-in').addEventListener('click', async () => {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const { zoom } = await sendBg({ type: 'getZoom', tabId: tab.id });
    await sendBg({ type: 'setZoom', tabId: tab.id, zoomFactor: zoom + 0.1 });
    showResult('res-tab-ops', `Zoom: ${(zoom + 0.1).toFixed(1)}`);
  } catch (e) { showResult('res-tab-ops', e.message, true); }
});

document.getElementById('btn-zoom-out').addEventListener('click', async () => {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const { zoom } = await sendBg({ type: 'getZoom', tabId: tab.id });
    await sendBg({ type: 'setZoom', tabId: tab.id, zoomFactor: zoom - 0.1 });
    showResult('res-tab-ops', `Zoom: ${(zoom - 0.1).toFixed(1)}`);
  } catch (e) { showResult('res-tab-ops', e.message, true); }
});

// --- Session Storage ---
document.getElementById('btn-session-test').addEventListener('click', async () => {
  try {
    const val = document.getElementById('input-session-value').value || 'hello';
    const { stored } = await sendBg({ type: 'sessionStorageTest', value: val });
    showResult('res-session-storage', `Stored and retrieved: "${stored}"`);
  } catch (e) { showResult('res-session-storage', e.message, true); }
});

// --- WebSocket relay ---
document.getElementById('btn-ws-probe').addEventListener('click', async () => {
  const url = document.getElementById('input-ws-url').value || 'wss://echo.websocket.org';
  showResult('res-websocket', `Connecting to ${url}...`);
  try {
    const result = await sendBg({ type: 'webSocketProbe', url });
    showResult('res-websocket', result, !!result.error || !result.opened);
  } catch (e) {
    showResult('res-websocket', e.message, true);
  }
});

// --- Favicon (_favicon) ---
// chrome.runtime.getURL('/_favicon/?pageUrl=…') answers from this profile's
// history only (TASK-152): a page visited in this profile shows its icon, and a
// page visited only in another profile gets the same 1×1 transparent pixel as a
// page nobody visited. The same URL from another profile's popup must show
// that profile's answer.
document.getElementById('btn-favicon-show').addEventListener('click', () => {
  const pageUrl = document.getElementById('input-favicon-url').value.trim();
  if (!pageUrl) { showResult('res-favicon', 'Enter a page URL', true); return; }
  const url = chrome.runtime.getURL('/_favicon/?pageUrl=' + encodeURIComponent(pageUrl) + '&size=32');
  const img = document.getElementById('img-favicon');
  img.onload = () => {
    const none = img.naturalWidth <= 1;
    showResult('res-favicon', none
      ? `no icon (1×1 transparent pixel): not visited in this profile, or no icon recorded\n${url}`
      : `icon ${img.naturalWidth}×${img.naturalHeight}\n${url}`, false);
  };
  img.onerror = () => showResult('res-favicon', `the image did not load\n${url}`, true);
  img.src = url;
});

// The favicon.lookup polyfill message used to hand any extension the icon URL
// of a page any profile had visited. It is gone, so the bridge must refuse it.
document.getElementById('btn-favicon-lookup-raw').addEventListener('click', async () => {
  const pageUrl = document.getElementById('input-favicon-url').value.trim() || 'https://example.com/';
  try {
    const reply = await webkit.messageHandlers.detourPolyfill.postMessage({
      type: 'favicon.lookup', extensionID: chrome.runtime.id, params: { pageUrl },
    });
    showResult('res-favicon', 'UNEXPECTED: favicon.lookup answered\n' + JSON.stringify(reply), true);
  } catch (e) {
    showResult('res-favicon', 'refused, as expected: ' + (e && e.message ? e.message : e), false);
  }
});

// Auto-load the event log on popup open
document.getElementById('btn-refresh-log').click();

// Auto-load polyfill diagnostics
(async () => {
  try {
    const { _polyfillDiag } = await chrome.storage.local.get('_polyfillDiag');
    if (_polyfillDiag) {
      // `apis` is a nested object; flatten it so each install marker is legible
      // instead of rendering as `apis: [object Object]`.
      const lines = Object.entries(_polyfillDiag).flatMap(([k, v]) =>
        (v && typeof v === 'object' && !Array.isArray(v))
          ? Object.entries(v).map(([k2, v2]) => `${k}.${k2}: ${typeof v2 === 'object' ? JSON.stringify(v2) : v2}`)
          : [`${k}: ${v}`]
      );
      const el = document.getElementById('res-event-log');
      if (el) {
        el.textContent = '--- Polyfill Diagnostics ---\n' + lines.join('\n') + '\n\n' + (el.textContent || '');
        el.classList.add('visible');
      }
    }
  } catch(e) {}
})();
