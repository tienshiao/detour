// Read visit counter from chrome.storage.local and display it
chrome.storage.local.get('visitCount').then(function(result) {
    var count = result.visitCount || 0;
    document.getElementById('count').textContent = count.toString();
});
