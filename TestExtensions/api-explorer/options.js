var diagEl = document.getElementById('diag');
function diag(msg) { diagEl.textContent += msg + '\n'; }

diag('chrome.storage exists: ' + (typeof chrome.storage));
diag('chrome.storage.local exists: ' + (typeof chrome.storage?.local));
diag('chrome.runtime.id: ' + (chrome.runtime?.id || '(empty)'));

// Load saved settings
try {
  chrome.storage.local.get('optionsDisplayName').then(function(result) {
    diag('storage.get resolved: ' + JSON.stringify(result));
    if (result.optionsDisplayName) {
      document.getElementById('display-name').value = result.optionsDisplayName;
    }
  }).catch(function(e) {
    diag('storage.get error: ' + e.message);
  });
} catch(e) {
  diag('storage.get threw: ' + e.message);
}

document.getElementById('save').addEventListener('click', function() {
  var name = document.getElementById('display-name').value;
  diag('Saving: ' + name);
  try {
    chrome.storage.local.set({ optionsDisplayName: name }).then(function() {
      diag('storage.set resolved');
      var status = document.getElementById('status');
      status.style.display = 'block';
      setTimeout(function() { status.style.display = 'none'; }, 2000);
    }).catch(function(e) {
      diag('storage.set error: ' + e.message);
    });
  } catch(e) {
    diag('storage.set threw: ' + e.message);
  }
});
