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
    const { results } = await sendBg({ type: 'historySearch', text });
    showResult('res-history', results.map(r => `${r.title}\n  ${r.url}`).join('\n') || '(no results)');
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
