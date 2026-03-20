// API Explorer — Background Service Worker
// Exercises: chrome.tabs, chrome.webNavigation, chrome.webRequest, chrome.storage,
//            chrome.scripting, chrome.i18n, chrome.contextMenus, chrome.offscreen,
//            chrome.runtime.onInstalled, chrome.runtime.onStartup, chrome.runtime.connect/onConnect,
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

chrome.runtime.onInstalled.addListener((details) => {
  console.log('[API Explorer] runtime.onInstalled', details.reason);
  appendLog({ event: 'runtime.onInstalled', reason: details.reason });

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

// --- Set uninstall URL ---

chrome.runtime.setUninstallURL('https://example.com/uninstalled');

// --- Alarms ---

chrome.alarms.onAlarm.addListener((alarm) => {
  console.log('[API Explorer] alarms.onAlarm', alarm.name);
  appendLog({ event: 'alarms.onAlarm', alarmName: alarm.name });
});

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
  console.log('[API Explorer] tabs.onActivated', activeInfo.tabId);
  appendLog({ event: 'tabs.onActivated', tabId: activeInfo.tabId });
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

// --- Message handling from popup ---

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handleMessage(message).then(sendResponse);
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

    case 'sendToTab': {
      const response = await chrome.tabs.sendMessage(message.tabId, message.message || { type: 'highlight' });
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

    default:
      return { error: 'Unknown message type: ' + message.type };
  }
}
