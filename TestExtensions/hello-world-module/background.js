// Side-effect import must run first to set globals
import './lib/constants.js';
import { incrementVisitCount } from './utils.js';
import * as fmt from './lib/index.js';

console.log('[HW Module] background.js loaded');
console.log('[HW Module] HW_CONSTANTS:', JSON.stringify(globalThis.HW_CONSTANTS));

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
            const greeting = fmt.formatGreeting('user', count);
            console.log('[HW Module] calling sendResponse');
            sendResponse({
                greeting: greeting,
                count: count,
                senderTabId: sender.tab ? sender.tab.id : null,
            });
        } catch (e) {
            console.error('[HW Module] async handler error:', e.message);
            sendResponse({ error: fmt.formatError(e.message) });
        }
    })();

    console.log('[HW Module] returning true');
    return true;
});
