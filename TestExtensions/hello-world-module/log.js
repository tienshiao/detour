// SW logging helper — bridges to native via sendNativeMessage('detourPolyfill').
// The polyfill bridge in ExtensionManager routes these before the manifest
// permission check, so it works for any extension.
const PREFIX = '[HW Module]';

function format(args) {
    const parts = [];
    for (let i = 0; i < args.length; i++) {
        const a = args[i];
        if (a === null) parts.push('null');
        else if (a === undefined) parts.push('undefined');
        else if (typeof a === 'object') try { parts.push(JSON.stringify(a)); } catch(e) { parts.push(String(a)); }
        else parts.push(String(a));
    }
    return parts.join(' ');
}

function sendNative(level, args) {
    const message = PREFIX + ' ' + format(args);
    try {
        chrome.runtime.sendNativeMessage(
            'detourPolyfill',
            { type: 'log', extensionID: chrome.runtime.id, params: { level: level, message: message } }
        );
    } catch(e) {}
}

export function log(...args) { console.log(PREFIX, ...args); sendNative('info', args); }
export function warn(...args) { console.warn(PREFIX, ...args); sendNative('warn', args); }
export function error(...args) { console.error(PREFIX, ...args); sendNative('error', args); }
