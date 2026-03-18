(function() {
    // Create a small banner at the top of the page
    var banner = document.createElement('div');
    banner.id = 'detour-extension-banner';
    banner.style.cssText = 'position:fixed;top:0;left:0;right:0;z-index:999999;' +
        'background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);' +
        'color:white;padding:8px 16px;font-family:-apple-system,sans-serif;' +
        'font-size:13px;text-align:center;box-shadow:0 2px 8px rgba(0,0,0,0.2);';
    banner.textContent = 'Hello from Detour Extension!';
    document.body.appendChild(banner);

    // Auto-hide after 3 seconds
    setTimeout(function() {
        banner.style.transition = 'opacity 0.5s';
        banner.style.opacity = '0';
        setTimeout(function() { banner.remove(); }, 500);
    }, 3000);

    // Send a message to the background script
    chrome.runtime.sendMessage({ type: 'pageLoaded', url: location.href }).then(function(response) {
        if (response) {
            console.log('[Detour Extension] Background responded:', response);
        }
    });
})();
