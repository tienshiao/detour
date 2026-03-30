// Read visit counter from chrome.storage.local and display it
function updateCount() {
    chrome.storage.local.get('visitCount').then(function(result) {
        var count = result.visitCount || 0;
        document.getElementById('count').textContent = count.toString();
    });
}

// Read on initial load
updateCount();

// Re-read when popup becomes visible (WKWebExtension may cache the popup WebView)
document.addEventListener('visibilitychange', function() {
    if (!document.hidden) updateCount();
});

// Live updates when storage changes
chrome.storage.onChanged.addListener(function(changes) {
    if (changes.visitCount) {
        document.getElementById('count').textContent = (changes.visitCount.newValue || 0).toString();
    }
});
