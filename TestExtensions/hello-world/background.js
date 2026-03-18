// Background service worker for Hello World extension

chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
    if (message.type === 'pageLoaded') {
        console.log('[Background] Page loaded:', message.url);

        // Increment visit counter in storage
        chrome.storage.local.get('visitCount').then(function(result) {
            var count = (result.visitCount || 0) + 1;
            chrome.storage.local.set({ visitCount: count }).then(function() {
                sendResponse({ greeting: 'Hello from background!', count: count });
            });
        });

        return true; // Keep message channel open for async response
    }
});
