// API Explorer — Background Service Worker
// Exercises: chrome.tabs, chrome.webNavigation, chrome.webRequest, chrome.storage,
//            chrome.scripting, chrome.i18n, chrome.contextMenus, chrome.offscreen,
//            chrome.runtime.onInstalled, chrome.runtime.onStartup, chrome.runtime.onUpdateAvailable, chrome.runtime.connect/onConnect,
//            chrome.runtime.onMessageExternal/onConnectExternal (externally_connectable),
//            chrome.storage.onChanged, chrome.extension.getBackgroundPage,
//            chrome.alarms, chrome.action, chrome.commands, chrome.windows,
//            chrome.fontSettings, chrome.permissions

const MAX_LOG_ENTRIES = 50;

async function appendLog(entry) {
  const { eventLog = [] } = await chrome.storage.local.get('eventLog');
  eventLog.push({ ...entry, timestamp: Date.now() });
  if (eventLog.length > MAX_LOG_ENTRIES) {
    eventLog.splice(0, eventLog.length - MAX_LOG_ENTRIES);
  }
  await chrome.storage.local.set({ eventLog });
}

// --- runtime.onInstalled ---

// Every delivery is kept in storage.local (`onInstalledEvents`, newest last) so
// whether and when the event arrived can be read back after the worker that got
// it is gone: on install, on update (reason 'update' + previousVersion), and —
// wrongly, if it ever shows up — on a context reload or relaunch. Each worker
// start logs the stored history too, so a run can be audited from the log alone.
const MAX_INSTALL_EVENTS = 20;
const workerStartedAt = Date.now();

chrome.storage.local.get('onInstalledEvents').then(({ onInstalledEvents = [] }) => {
  console.log('[API Explorer] worker start v' + chrome.runtime.getManifest().version
    + ', onInstalled history: ' + JSON.stringify(onInstalledEvents));
});
// How Detour's polyfill installed the event in this context ('detour' when
// Detour delivers it, 'webkit (reason)' when WebKit's own event was left in
// place) and which context claimed it: 'worker' here, 'background-page' for an
// MV3 extension whose background content is scripts/a page, 'page' for any
// other extension page (which never claims).
{
  const status = globalThis.__detourRuntimeOnInstalled;
  chrome.storage.local.set({
    onInstalledWorkerMode: status
      ? status.mode + ' [' + status.contextKind + ']' + (status.detail ? ' (' + status.detail + ')' : '')
      : 'no Detour polyfill'
  });
}

chrome.runtime.onInstalled.addListener((details) => {
  const record = {
    reason: details.reason,
    previousVersion: details.previousVersion,
    version: chrome.runtime.getManifest().version,
    timestamp: Date.now(),
    msAfterWorkerStart: Date.now() - workerStartedAt
  };
  console.log('[API Explorer] runtime.onInstalled ' + JSON.stringify(record));
  appendLog({ event: 'runtime.onInstalled', reason: details.reason, previousVersion: details.previousVersion });
  chrome.storage.local.get('onInstalledEvents').then(({ onInstalledEvents = [] }) => {
    onInstalledEvents.push(record);
    if (onInstalledEvents.length > MAX_INSTALL_EVENTS) {
      onInstalledEvents.splice(0, onInstalledEvents.length - MAX_INSTALL_EVENTS);
    }
    return chrome.storage.local.set({ onInstalledEvents });
  });

  // Create context menu items on install
  chrome.contextMenus.create({
    id: 'api-explorer-detect-lang',
    title: chrome.i18n.getMessage('detectLang') || 'Detect Language',
    contexts: ['page']
  });

  chrome.contextMenus.create({
    id: 'api-explorer-translate',
    title: chrome.i18n.getMessage('translatePage') || 'Translate with API Explorer',
    contexts: ['selection']
  });

  chrome.contextMenus.create({
    id: 'api-explorer-separator',
    type: 'separator',
    contexts: ['page', 'selection']
  });

  chrome.contextMenus.create({
    id: 'api-explorer-info',
    title: 'API Explorer: ' + chrome.i18n.getMessage('appName'),
    contexts: ['page', 'selection']
  });
});

// --- runtime.onStartup ---

chrome.runtime.onStartup.addListener(() => {
  console.log('[API Explorer] runtime.onStartup');
  appendLog({ event: 'runtime.onStartup' });
});

// --- runtime.onUpdateAvailable ---
// Detour stages an update that arrives while the extension is busy (open
// pages, popup, live native hosts, recent background traffic) and fires this
// with {version}; a chrome.runtime.reload() that follows (the popup's button,
// within 15 s) installs it on the restart, as in Chrome.

chrome.runtime.onUpdateAvailable.addListener((details) => {
  console.log('[API Explorer] runtime.onUpdateAvailable ' + JSON.stringify(details));
  appendLog({ event: 'runtime.onUpdateAvailable', version: details && details.version });
});

// --- Set uninstall URL ---

chrome.runtime.setUninstallURL('https://example.com/uninstalled');

// --- Alarms ---

chrome.alarms.onAlarm.addListener((alarm) => {
  console.log('[API Explorer] alarms.onAlarm', alarm.name);
  appendLog({ event: 'alarms.onAlarm', alarmName: alarm.name });
});

// Periodic heartbeat: the canonical way to wake a service worker after WebKit
// unloads it when idle, so idle termination and restart can be observed in logs.
chrome.alarms.create('api-explorer-heartbeat', { periodInMinutes: 1 });

// --- Idle ---

if (chrome.idle) {
  chrome.idle.onStateChanged.addListener((newState) => {
    console.log('[API Explorer] idle.onStateChanged', newState);
    appendLog({ event: 'idle.onStateChanged', newState });
  });

  // Set detection interval to 60 seconds
  chrome.idle.setDetectionInterval(60);
}

// --- Notifications ---

if (chrome.notifications) {
  chrome.notifications.onClicked.addListener((notificationId) => {
    console.log('[API Explorer] notifications.onClicked', notificationId);
    appendLog({ event: 'notifications.onClicked', notificationId });
  });

  chrome.notifications.onClosed.addListener((notificationId, byUser) => {
    console.log('[API Explorer] notifications.onClosed', notificationId, byUser);
    appendLog({ event: 'notifications.onClosed', notificationId, byUser });
  });
}

// --- Commands ---

chrome.commands.onCommand.addListener((command) => {
  console.log('[API Explorer] commands.onCommand', command);
  appendLog({ event: 'commands.onCommand', command });
});

// --- Tab events ---

chrome.tabs.onCreated.addListener((tab) => {
  console.log('[API Explorer] tabs.onCreated', tab.id, tab.url);
  appendLog({ event: 'tabs.onCreated', tabId: tab.id, url: tab.url });
});

chrome.tabs.onRemoved.addListener((tabId, removeInfo) => {
  console.log('[API Explorer] tabs.onRemoved', tabId);
  appendLog({ event: 'tabs.onRemoved', tabId });
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  console.log('[API Explorer] tabs.onUpdated', tabId, changeInfo);
  appendLog({ event: 'tabs.onUpdated', tabId, changeInfo });
});

chrome.tabs.onActivated.addListener((activeInfo) => {
  console.log('[API Explorer] tabs.onActivated', activeInfo.tabId, 'previous:', activeInfo.previousTabId);
  appendLog({ event: 'tabs.onActivated', tabId: activeInfo.tabId, previousTabId: activeInfo.previousTabId });
});

// A tab changing space inside one profile: same window -> onMoved, a different
// one -> onDetached + onAttached (TASK-61).
chrome.tabs.onMoved.addListener((tabId, moveInfo) => {
  console.log('[API Explorer] tabs.onMoved', tabId, moveInfo.windowId, moveInfo.fromIndex, '->', moveInfo.toIndex);
  appendLog({
    event: 'tabs.onMoved',
    tabId,
    windowId: moveInfo.windowId,
    fromIndex: moveInfo.fromIndex,
    toIndex: moveInfo.toIndex,
  });
});

chrome.tabs.onDetached.addListener((tabId, detachInfo) => {
  console.log('[API Explorer] tabs.onDetached', tabId, detachInfo.oldWindowId, detachInfo.oldPosition);
  appendLog({
    event: 'tabs.onDetached',
    tabId,
    oldWindowId: detachInfo.oldWindowId,
    oldPosition: detachInfo.oldPosition,
  });
});

chrome.tabs.onAttached.addListener((tabId, attachInfo) => {
  console.log('[API Explorer] tabs.onAttached', tabId, attachInfo.newWindowId, attachInfo.newPosition);
  appendLog({
    event: 'tabs.onAttached',
    tabId,
    newWindowId: attachInfo.newWindowId,
    newPosition: attachInfo.newPosition,
  });
});

// --- WebNavigation events ---

chrome.webNavigation.onCommitted.addListener((details) => {
  console.log('[API Explorer] webNavigation.onCommitted', details.tabId, details.url);
  appendLog({ event: 'webNavigation.onCommitted', tabId: details.tabId, url: details.url });
});

chrome.webNavigation.onCompleted.addListener((details) => {
  console.log('[API Explorer] webNavigation.onCompleted', details.tabId, details.url);
  appendLog({ event: 'webNavigation.onCompleted', tabId: details.tabId, url: details.url });
});

// --- WebRequest (stub verification) ---

try {
  chrome.webRequest.onBeforeRequest.addListener(
    (details) => {},
    { urls: ['<all_urls>'] }
  );
  console.log('[API Explorer] webRequest.onBeforeRequest listener registered (stub)');
} catch (e) {
  console.warn('[API Explorer] webRequest.onBeforeRequest registration failed:', e);
}

// --- Context Menus ---

chrome.contextMenus.onClicked.addListener((info, tab) => {
  console.log('[API Explorer] contextMenus.onClicked', info.menuItemId, info);
  appendLog({ event: 'contextMenus.onClicked', menuItemId: info.menuItemId, tabId: tab ? tab.id : null });

  if (info.menuItemId === 'api-explorer-detect-lang' && tab) {
    chrome.tabs.detectLanguage(tab.id, (lang) => {
      console.log('[API Explorer] Detected language:', lang);
      appendLog({ event: 'tabs.detectLanguage', tabId: tab.id, language: lang });
    });
  }

  if (info.menuItemId === 'api-explorer-translate' && info.selectionText) {
    console.log('[API Explorer] Selected text for translation:', info.selectionText);
    appendLog({ event: 'contextMenus.translate', tabId: tab ? tab.id : null, text: info.selectionText });
  }
});

// --- storage.onChanged ---

chrome.storage.onChanged.addListener((changes, areaName) => {
  // Don't log changes to eventLog itself to avoid infinite loop
  if (changes.eventLog) return;
  console.log('[API Explorer] storage.onChanged', areaName, Object.keys(changes));
  const keys = Object.keys(changes);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    const change = changes[key];
    appendLog({
      event: 'storage.onChanged',
      area: areaName,
      key: key,
      oldValue: change.oldValue !== undefined ? JSON.stringify(change.oldValue) : '(none)',
      newValue: change.newValue !== undefined ? JSON.stringify(change.newValue) : '(removed)'
    });
  }
});

// --- runtime.connect / onConnect (port messaging) ---

chrome.runtime.onConnect.addListener((port) => {
  console.log('[API Explorer] runtime.onConnect, port:', port.name);
  appendLog({ event: 'runtime.onConnect', portName: port.name });

  port.onMessage.addListener((msg) => {
    console.log('[API Explorer] port.onMessage', port.name, msg);
    // Echo back with extra info
    port.postMessage({
      echo: msg,
      from: 'background',
      portName: port.name,
      timestamp: Date.now()
    });
  });

  port.onDisconnect.addListener(() => {
    console.log('[API Explorer] port.onDisconnect', port.name);
    appendLog({ event: 'port.onDisconnect', portName: port.name });
  });
});

// --- runtime.onMessageExternal / onConnectExternal (externally_connectable, TASK-132.6) ---
//
// The manifest lists http://127.0.0.1/* and http://localhost/*: a page served
// from either (external-page/index.html, see the popup's "Externally
// Connectable" section) can call chrome.runtime.sendMessage(<this id>, …) and
// chrome.runtime.connect(<this id>). What arrives is answered with how the
// sender looked and kept in storage.local (`externalMessages`, newest last) so
// the popup can show it.

const MAX_EXTERNAL_MESSAGES = 20;

function describeExternalSender(sender) {
  return {
    id: sender && sender.id,
    origin: sender && sender.origin,
    url: sender && sender.url,
    frameId: sender && sender.frameId,
    tabId: sender && sender.tab ? sender.tab.id : undefined,
  };
}

async function recordExternal(entry) {
  const { externalMessages = [] } = await chrome.storage.local.get('externalMessages');
  externalMessages.push({ ...entry, at: new Date().toISOString() });
  if (externalMessages.length > MAX_EXTERNAL_MESSAGES) {
    externalMessages.splice(0, externalMessages.length - MAX_EXTERNAL_MESSAGES);
  }
  await chrome.storage.local.set({ externalMessages });
}

chrome.runtime.onMessageExternal.addListener((message, sender, sendResponse) => {
  const from = describeExternalSender(sender);
  console.log('[API Explorer] runtime.onMessageExternal', JSON.stringify(message), JSON.stringify(from));
  recordExternal({ event: 'onMessageExternal', message, sender: from });
  // { type: 'silent' } is left unanswered, to show what a page gets then.
  if (message && message.type === 'silent') return false;
  sendResponse({
    ok: true,
    from: 'api-explorer',
    version: chrome.runtime.getManifest().version,
    echo: message,
    sender: from,
  });
  return false;
});

chrome.runtime.onConnectExternal.addListener((port) => {
  const from = describeExternalSender(port.sender);
  console.log('[API Explorer] runtime.onConnectExternal, port:', port.name, JSON.stringify(from));
  recordExternal({ event: 'onConnectExternal', portName: port.name, sender: from });
  port.onMessage.addListener((message) => {
    recordExternal({ event: 'external port message', portName: port.name, message });
    port.postMessage({ echo: message, from: 'api-explorer', portName: port.name, sender: from });
  });
});

// --- WebSocket relay probe ---
// A real WebSocket in an extension service worker would deadlock the worker, so
// Detour replaces it with a relay: the socket is opened natively and driven over
// a port to the 'detourWebSocketRelay' host (TASK-8). Without that host the
// pre-TASK-8 guard remains, failing the connection instead
// (`__detourWebSocketRelay.mode` says which). Log what an extension observes for
// a server that does not exist — the old guard-probe semantics.

function webSocketRelayMode() {
  const relay = globalThis.__detourWebSocketRelay;
  return relay ? relay.mode : 'none (native WebSocket)';
}

try {
  const ws = new WebSocket('wss://example.invalid/api-explorer');
  ws.addEventListener('error', () => appendLog({ event: 'websocket.error' }));
  ws.addEventListener('close', (e) => appendLog({
    event: 'websocket.close',
    code: e.code,
    wasClean: e.wasClean,
    mode: webSocketRelayMode(),
    relayed: WebSocket.__detourRelay === true
  }));
} catch (e) {
  appendLog({ event: 'websocket.unavailable', error: String(e) });
}

// --- Native port keep-alive probe ---
// In an extension that declares `nativeMessaging`, the polyfill opens one idle
// port to the 'detourPolyfill' host at background start and Detour arms it —
// `armed`/`active` flip to true — while a real native messaging host is connected
// for that extension (TASK-16). Since TASK-62 that is any background context, a
// service worker or a non-persistent background page, so `contextKind` is reported
// next to the decision: 'worker' and 'background-page' are eligible, 'page' gets
// installDetail 'not-a-background-context' and a persistent MV2 page
// 'persistent-background-page'. This extension does NOT declare the permission, so
// it can never have a host and the keep-alive installs nothing: expect installMode
// 'none' with installDetail 'no-nativeMessaging-permission'. This only reports that
// state; opening a 'detourPolyfill' port here would evict a keep-alive port if
// there were one, since Detour keeps one per extension.
// Since TASK-68 the pings are Detour's: while armed it sends
// {type:'keepalive-ping', seq} on that port every 30 s and the background context
// answers {type:'keepalive', seq} — that reply is the activity WebKit counts, and
// `repliesSent` is how many this context has sent (0 here, with no port to answer on).

const keepAlive = globalThis.__detourNativePortKeepAlive;
appendLog({
  event: 'nativePortKeepAlive',
  contextKind: globalThis.__detourContextKind,
  connectNativeType: typeof chrome.runtime.connectNative,
  keepAlive: keepAlive ? {
    installMode: keepAlive.installMode,
    installDetail: keepAlive.installDetail,
    armed: keepAlive.armed,
    active: keepAlive.active,
    repliesSent: keepAlive.repliesSent
  } : null
});

// --- Message handling from popup ---

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleMessage(message)
    .then(sendResponse)
    .catch(err => sendResponse({ error: err.message || String(err) }));
  return true; // keep channel open for async response
});

async function handleMessage(message) {
  switch (message.type) {
    case 'getLog': {
      const { eventLog = [] } = await chrome.storage.local.get('eventLog');
      return { log: eventLog };
    }

    case 'queryTabs': {
      const tabs = await chrome.tabs.query(message.queryInfo || {});
      return { tabs };
    }

    case 'createTab': {
      const tab = await chrome.tabs.create({ url: message.url || 'about:blank' });
      return { tab };
    }

    case 'closeTab': {
      await chrome.tabs.remove(message.tabId);
      return { success: true };
    }

    case 'executeScript': {
      if (message.code) {
        const results = await chrome.scripting.executeScript({
          target: { tabId: message.tabId },
          func: new Function(message.code),
        });
        return { results };
      } else {
        const results = await chrome.scripting.executeScript({
          target: { tabId: message.tabId },
          files: ['inject.js'],
        });
        return { results };
      }
    }

    case 'insertCSS': {
      await chrome.scripting.insertCSS({
        target: { tabId: message.tabId },
        files: ['inject.css'],
      });
      return { success: true };
    }

    case 'removeCSS': {
      await chrome.scripting.removeCSS({
        target: { tabId: message.tabId },
        files: ['inject.css'],
      });
      return { success: true };
    }

    case 'sendToTab': {
      const options = message.options || {};
      const response = await chrome.tabs.sendMessage(message.tabId, message.message || { type: 'highlight' }, options);
      return { response };
    }

    case 'sendToTabWithDocumentId': {
      // Tests tabs.sendMessage with documentId option for targeting specific document instances
      const response = await chrome.tabs.sendMessage(
        message.tabId,
        message.message || { type: 'docIdTest' },
        { documentId: message.documentId }
      );
      return { response };
    }

    case 'detectLanguage': {
      const lang = await chrome.tabs.detectLanguage(message.tabId);
      return { language: lang };
    }

    case 'getI18nInfo': {
      return {
        appName: chrome.i18n.getMessage('appName'),
        appDesc: chrome.i18n.getMessage('appDesc'),
        greeting: chrome.i18n.getMessage('greeting', ['World', 'API Explorer']),
        uiLanguage: chrome.i18n.getUILanguage(),
        unknownKey: chrome.i18n.getMessage('nonExistentKey'),
      };
    }

    case 'getPlatformInfo': {
      const info = await chrome.runtime.getPlatformInfo();
      return { platformInfo: info };
    }

    case 'getBackgroundPage': {
      const page = chrome.extension.getBackgroundPage();
      return { backgroundPage: page === null ? 'null (expected for MV3)' : String(page) };
    }

    case 'createContextMenu': {
      const id = await chrome.contextMenus.create({
        id: message.menuId || 'dynamic-' + Date.now(),
        title: message.title || 'Dynamic Menu Item',
        contexts: message.contexts || ['page']
      });
      return { menuItemId: id };
    }

    case 'removeAllContextMenus': {
      await chrome.contextMenus.removeAll();
      return { success: true };
    }

    case 'createOffscreen': {
      await chrome.offscreen.createDocument({
        url: 'offscreen.html',
        reasons: ['DOM_PARSER'],
        justification: 'Parse HTML fragments'
      });
      return { created: true };
    }

    case 'hasOffscreen': {
      const has = await chrome.offscreen.hasDocument();
      return { hasDocument: has };
    }

    case 'closeOffscreen': {
      await chrome.offscreen.closeDocument();
      return { closed: true };
    }

    case 'storageOnChangedTest': {
      // Write a test value — the onChanged listener above will log it
      await chrome.storage.local.set({ _testOnChanged: message.value || 'test-' + Date.now() });
      return { written: true };
    }

    case 'webSocketProbe': {
      // Open a socket from the worker, echo a text and a binary frame off it,
      // then close cleanly — the whole relay round trip (TASK-8).
      const url = message.url || 'wss://echo.websocket.org';
      const out = {
        url,
        mode: webSocketRelayMode(),
        relayed: WebSocket.__detourRelay === true,
        opened: false,
        protocol: null,
        messages: [],
        closeCode: null,
        closeReason: null,
        wasClean: null,
        error: null,
        timedOut: false
      };
      try {
        const socket = new WebSocket(url);
        socket.binaryType = 'arraybuffer';
        await new Promise((resolve) => {
          socket.onopen = () => {
            out.opened = true;
            out.protocol = socket.protocol;
            socket.send('detour-relay-hello');
            socket.send(new Uint8Array([1, 2, 3, 4]));
          };
          socket.onmessage = (e) => {
            out.messages.push(typeof e.data === 'string'
              ? { text: e.data }
              : { bytes: Array.from(new Uint8Array(e.data)) });
            if (out.messages.length >= 2) socket.close(1000, 'done');
          };
          socket.onerror = () => { out.error = 'error event'; };
          socket.onclose = (e) => {
            out.closeCode = e.code;
            out.closeReason = e.reason;
            out.wasClean = e.wasClean;
            resolve();
          };
          setTimeout(() => {
            out.timedOut = true;
            try { socket.close(1000, 'timeout'); } catch (e) {}
            resolve();
          }, 10000);
        });
      } catch (e) {
        out.error = String(e && e.message ? e.message : e);
      }
      out.mode = webSocketRelayMode();
      appendLog({ event: 'websocket.probe', url, opened: out.opened, closeCode: out.closeCode, mode: out.mode });
      return out;
    }

    case 'queryIdleState': {
      const state = await chrome.idle.queryState(message.detectionInterval || 60);
      return { idleState: state };
    }

    case 'setIdleDetectionInterval': {
      chrome.idle.setDetectionInterval(message.interval || 60);
      return { success: true };
    }

    case 'createNotification': {
      const id = await chrome.notifications.create(message.notificationId || null, {
        type: 'basic',
        title: message.title || 'Test Notification',
        message: message.message || 'This is a test notification from API Explorer',
        iconUrl: message.iconUrl || chrome.runtime.getURL('icon.png')
      });
      return { notificationId: id };
    }

    case 'clearNotification': {
      const cleared = await chrome.notifications.clear(message.notificationId);
      return { wasCleared: cleared };
    }

    case 'getAllNotifications': {
      const all = await chrome.notifications.getAll();
      return { notifications: all };
    }

    case 'getManagementSelf': {
      const info = await chrome.management.getSelf();
      return { extensionInfo: info };
    }

    case 'getManagementAll': {
      const all = await chrome.management.getAll();
      return { extensions: all };
    }

    case 'managementSetEnabled': {
      await chrome.management.setEnabled(message.id || chrome.runtime.id, message.enabled !== false);
      return { ok: true };
    }

    case 'privacyGet': {
      const services = chrome.privacy.services;
      const names = ['passwordSavingEnabled', 'autofillEnabled', 'autofillCreditCardEnabled', 'autofillAddressEnabled'];
      const settings = {};
      for (const name of names) {
        settings[name] = await services[name].get({});
      }
      return { settings };
    }

    case 'privacySet': {
      await chrome.privacy.services.passwordSavingEnabled.set({ value: message.value !== false });
      const settings = { passwordSavingEnabled: await chrome.privacy.services.passwordSavingEnabled.get({}) };
      return { settings };
    }

    case 'webRequestProbe': {
      const hasWebRequest = typeof chrome.webRequest === 'object';
      const hasOnAuthRequired = hasWebRequest && typeof chrome.webRequest.onAuthRequired === 'object';
      let registered = false;
      let removed = false;
      if (hasOnAuthRequired) {
        const listener = () => {};
        // Chrome's three-argument form — the one 1Password uses.
        chrome.webRequest.onAuthRequired.addListener(listener, { urls: ['<all_urls>'] }, ['asyncBlocking']);
        registered = chrome.webRequest.onAuthRequired.hasListener(listener);
        chrome.webRequest.onAuthRequired.removeListener(listener);
        removed = !chrome.webRequest.onAuthRequired.hasListener(listener);
      }
      return {
        hasWebRequest,
        hasOnAuthRequired,
        registered,
        removed,
        install: globalThis.__detourWebRequestInstall,
      };
    }

    // --- declarativeNetRequest session header rule (TASK-132.4) ---

    case 'dnrProbe': {
      const dnr = chrome.declarativeNetRequest;
      return {
        namespace: typeof dnr,
        install: globalThis.__detourDeclarativeNetRequest,
        updateSessionRules: dnr ? typeof dnr.updateSessionRules : 'n/a',
        modifyHeaders: dnr && dnr.RuleActionType ? dnr.RuleActionType.MODIFY_HEADERS : '(no RuleActionType)',
        set: dnr && dnr.HeaderOperation ? dnr.HeaderOperation.SET : '(no HeaderOperation)',
        xmlhttprequest: dnr && dnr.ResourceType ? dnr.ResourceType.XMLHTTPREQUEST : '(no ResourceType)',
        onInstalledReason: chrome.runtime.OnInstalledReason || '(no runtime.OnInstalledReason)',
        xmlHttpRequestInWorker: typeof XMLHttpRequest,
      };
    }

    case 'dnrAddRule': {
      // Rule 1, for every URL on the target's origin. `custom` adds a header
      // name WebKit's own declarativeNetRequest refuses, which Detour then
      // keeps and applies itself; without it WebKit holds the rule and Detour
      // applies it only where WebKit does not (this worker's fetch).
      const dnr = chrome.declarativeNetRequest;
      const origin = new URL(message.url).origin;
      const requestHeaders = [
        { header: 'User-Agent', operation: dnr.HeaderOperation.SET, value: `api-explorer/${chrome.runtime.getManifest().version} ${navigator.userAgent}` },
      ];
      if (message.custom) {
        requestHeaders.push({ header: 'x-api-explorer', operation: dnr.HeaderOperation.SET, value: 'session-rule' });
      }
      const rule = {
        id: 1,
        priority: 1,
        action: { type: dnr.RuleActionType.MODIFY_HEADERS, requestHeaders },
        condition: {
          urlFilter: `${origin}/*`,
          resourceTypes: [dnr.ResourceType.XMLHTTPREQUEST, dnr.ResourceType.OTHER],
        },
      };
      await dnr.updateSessionRules({ removeRuleIds: [1], addRules: [rule] });
      let heldByWebKit = '(no _detourNative)';
      const nativeGet = dnr.getSessionRules._detourNative;
      if (typeof nativeGet === 'function') {
        heldByWebKit = (await nativeGet.call(dnr)).some((r) => r.id === 1);
      }
      return { added: rule, heldByWebKit, rules: await dnr.getSessionRules() };
    }

    case 'dnrGetRules': {
      return await chrome.declarativeNetRequest.getSessionRules();
    }

    case 'dnrFetch': {
      try {
        const response = await fetch(message.url, { cache: 'no-store' });
        return { status: response.status, body: (await response.text()).slice(0, 4000) };
      } catch (e) {
        return { body: 'failed: ' + e.message };
      }
    }

    // --- tabGroups / debugger interim stand-ins (TASK-132.4) ---

    // --- externally_connectable (TASK-132.6) ---

    case 'externalReceived': {
      const { externalMessages = [] } = await chrome.storage.local.get('externalMessages');
      return {
        extensionId: chrome.runtime.id,
        listsPages: (chrome.runtime.getManifest().externally_connectable || {}).matches || [],
        onMessageExternal: typeof (chrome.runtime.onMessageExternal && chrome.runtime.onMessageExternal.addListener),
        onConnectExternal: typeof (chrome.runtime.onConnectExternal && chrome.runtime.onConnectExternal.addListener),
        received: externalMessages,
      };
    }

    case 'externalClear': {
      await chrome.storage.local.remove('externalMessages');
      return { cleared: true };
    }

    case 'sidePanelOp': {
      // The popup's side panel buttons, run here in the worker (TASK-132.8).
      // Kept in step with sidePanelOp in popup.js.
      const { op, target } = message;
      const tabPath = `sidepanel.html?tabId=${encodeURIComponent(target.tabId)}`;
      switch (op) {
        case 'probe':
          return {
            type: typeof chrome.sidePanel,
            install: globalThis.__detourSidePanelInstall || '(no Detour polyfill)',
            methods: chrome.sidePanel ? Object.keys(chrome.sidePanel).sort() : [],
          };
        case 'openTab':
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

    case 'getContexts': {
      // runtime.getContexts as the worker sees it (TASK-132.9).
      return await chrome.runtime.getContexts(message.filter || {});
    }

    case 'interimNamespacesProbe': {
      const tg = chrome.tabGroups;
      const dbg = chrome.debugger;
      const present = (object, names) => object ? names.filter((name) => object[name] !== undefined) : '(no namespace)';
      return {
        install: globalThis.__detourInterimNamespaces || '(no Detour polyfill)',
        tabGroups: tg ? { Color: tg.Color, TAB_GROUP_ID_NONE: tg.TAB_GROUP_ID_NONE } : '(no namespace)',
        tabGroupsMethodsPresent: present(tg, ['get', 'query', 'update', 'move', 'onCreated', 'onUpdated', 'onRemoved']),
        tabsGroup: typeof chrome.tabs.group,
        tabsUngroup: typeof chrome.tabs.ungroup,
        debuggerEvents: dbg ? { onEvent: typeof dbg.onEvent.addListener, onDetach: typeof dbg.onDetach.addListener } : '(no namespace)',
        debuggerMethodsPresent: present(dbg, ['attach', 'detach', 'sendCommand', 'getTargets']),
      };
    }

    case 'storageManagedProbe': {
      return await storageManagedProbe();
    }

    case 'actionGetUserSettings': {
      // Feature-detect before calling, so a missing method (polyfill dropped
      // after a collection, or `polyfill-not-visible`) still reports the
      // install marker instead of throwing it away with the TypeError.
      const hasAction = typeof chrome.action === 'object';
      const hasGetUserSettings = hasAction && typeof chrome.action.getUserSettings === 'function';
      const held = !!(globalThis.__detourHeldWrappers && globalThis.__detourHeldWrappers.action === chrome.action);
      const settings = hasGetUserSettings ? await chrome.action.getUserSettings() : null;
      return {
        hasAction,
        hasGetUserSettings,
        held,
        settings,
        install: globalThis.__detourActionUserSettingsInstall,
      };
    }

    case 'captureVisibleTab': {
      const dataUrl = await chrome.tabs.captureVisibleTab(null, { format: 'png' });
      return { dataUrl: dataUrl ? dataUrl.substring(0, 50) + '...' : null };
    }

    case 'reloadTab': {
      await chrome.tabs.reload(message.tabId);
      return { success: true };
    }

    case 'getAllFrames': {
      const frames = await chrome.webNavigation.getAllFrames({ tabId: message.tabId });
      return { frames: frames };
    }

    case 'historySearch': {
      const results = await chrome.history.search({ text: message.text || '', maxResults: message.maxResults || 10 });
      return { results };
    }

    case 'bookmarksGetTree': {
      const tree = await chrome.bookmarks.getTree();
      return { tree };
    }

    case 'sessionsRestore': {
      const session = await chrome.sessions.restore(message.sessionId);
      return { session };
    }

    case 'searchQuery': {
      await chrome.search.query({ text: message.text || 'test', disposition: message.disposition || 'NEW_TAB' });
      return { success: true };
    }

    case 'duplicateTab': {
      const tab = await chrome.tabs.duplicate(message.tabId);
      return { tab };
    }

    case 'moveTab': {
      const tab = await chrome.tabs.move(message.tabId, { index: message.index || 0 });
      return { tab };
    }

    case 'getZoom': {
      const zoom = await chrome.tabs.getZoom(message.tabId);
      return { zoom };
    }

    case 'setZoom': {
      await chrome.tabs.setZoom(message.tabId, message.zoomFactor || 1.0);
      return { success: true };
    }

    // Callback form / runtime.lastError, run in the service worker.
    // Same `__detourSettle` path the popup exercises, but on the worker's own
    // runtime object — which may take a different route to lastError (see
    // globalThis.__detourCallbackLastError.lastMode: 'js', 'native-relay' or
    // 'console'). chrome.offscreen is worker-only, so its `passResult: false`
    // callback (fires with zero arguments on success) can only be tried here.
    case 'callbackFormProbe': {
      const probe = (label, run) => new Promise((resolve) => {
        const timer = setTimeout(() => resolve({ label, timedOut: 'callback did not fire within 3s' }), 3000);
        try {
          run(function () {
            clearTimeout(timer);
            const err = chrome.runtime.lastError;
            resolve({
              label,
              argsLength: arguments.length,
              result: arguments.length ? arguments[0] : undefined,
              lastError: err ? (err.message || String(err)) : String(err),
              mode: globalThis.__detourCallbackLastError
                ? globalThis.__detourCallbackLastError.lastMode
                : '(no Detour polyfill)'
            });
          });
        } catch (e) {
          clearTimeout(timer);
          resolve({ label, threw: e.message || String(e) });
        }
      });

      const probes = [
        // Success, passResult: false — closing with no document open is a no-op.
        await probe('offscreen.closeDocument(cb)', (cb) => chrome.offscreen.closeDocument(cb)),
        // Deterministic failure: a null id is answered with "notificationId required".
        await probe('notifications.clear(null, cb)', (cb) => chrome.notifications.clear(null, cb))
      ];
      const err = chrome.runtime.lastError;
      return { probes, lastErrorAfter: err ? (err.message || String(err)) : String(err) };
    }

    case 'sessionStorageTest': {
      await chrome.storage.session.set({ testKey: message.value || 'hello' });
      const result = await chrome.storage.session.get('testKey');
      return { stored: result.testKey };
    }

    default:
      return { error: 'Unknown message type: ' + message.type };
  }
}

async function storageManagedProbe() {
  // The shape 1Password 8.12.37 relies on during background init (TASK-80):
  // onChanged.addListener and get() must not throw.
  const hasManaged = !!(chrome.storage && typeof chrome.storage.managed === 'object');
  const result = {
    hasManaged,
    install: globalThis.__detourStorageManagedInstall,
    held: !!(globalThis.__detourHeldWrappers && globalThis.__detourHeldWrappers.storage === chrome.storage),
  };
  if (!hasManaged) return result;
  const listener = () => {};
  chrome.storage.managed.onChanged.addListener(listener);
  result.listenerRegistered = chrome.storage.managed.onChanged.hasListener(listener);
  chrome.storage.managed.onChanged.removeListener(listener);
  result.getAll = await chrome.storage.managed.get(null);
  result.getWithDefaults = await chrome.storage.managed.get({ CredentialIntelligence: 'default' });
  result.bytesInUse = await chrome.storage.managed.getBytesInUse(null);
  try {
    await chrome.storage.managed.set({ probe: 1 });
    result.setError = null;
  } catch (e) {
    result.setError = e.message;
  }
  return result;
}
