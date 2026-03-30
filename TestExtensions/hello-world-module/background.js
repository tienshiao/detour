import { incrementVisitCount } from './utils.js';

console.log('[HW Module] background.js loaded');

// Mimic Vimium's pattern: async IIFE + sendResponse + return true
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    console.log('[HW Module] onMessage received, type:', request.type);
    console.log('[HW Module] sender.tab:', sender.tab == null ? 'NULL' : 'id=' + sender.tab.id);

    if (request.type !== 'pageLoaded') {
        return false;
    }

    (async function() {
        try {
            console.log('[HW Module] async handler starting');
            const storageResult = await chrome.storage.sync.get(null);
            console.log('[HW Module] storage.sync.get returned, keys:', Object.keys(storageResult).join(',') || '(empty)');
            const count = await incrementVisitCount();
            console.log('[HW Module] calling sendResponse');
            sendResponse({
                greeting: 'Hello from module background!',
                count: count,
                senderTabId: sender.tab ? sender.tab.id : null,
            });
        } catch (e) {
            console.error('[HW Module] async handler error:', e.message);
            sendResponse({ error: e.message });
        }
    })();

    console.log('[HW Module] returning true');
    return true;
});
