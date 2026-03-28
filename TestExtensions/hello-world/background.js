// Background service worker for Hello World extension

chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
    if (message.type === 'pageLoaded') {
        console.log('[Background] Page loaded:', message.url);

        (async () => {
            const result = await chrome.storage.local.get('visitCount');
            const count = (result.visitCount || 0) + 1;
            await chrome.storage.local.set({ visitCount: count });
            sendResponse({ greeting: 'Hello from background!', count: count });
        })();

        return true; // Keep message channel open for async response
    }
});
