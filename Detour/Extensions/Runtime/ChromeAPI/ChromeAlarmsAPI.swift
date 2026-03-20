import Foundation

/// Generates the `chrome.alarms` polyfill JavaScript for a given extension.
/// Implemented entirely in JS using setTimeout/setInterval since background hosts
/// run in persistent hidden WKWebViews (not true service workers that get suspended).
struct ChromeAlarmsAPI {
    static func generateJS(extensionID: String, isContentScript: Bool = true) -> String {
        return """
        (function() {
            if (!window.chrome) window.chrome = {};
            if (!window.chrome.alarms) window.chrome.alarms = {};

            let alarmTimers = {};
            const onAlarmListeners = [];

            function fireAlarm(name) {
                const alarm = alarmTimers[name];
                if (!alarm) return;
                const alarmInfo = {
                    name: name,
                    scheduledTime: alarm.scheduledTime,
                    periodInMinutes: alarm.periodInMinutes || undefined
                };
                for (let i = 0; i < onAlarmListeners.length; i++) {
                    try { onAlarmListeners[i](alarmInfo); } catch(e) {
                        console.error('[chrome.alarms.onAlarm] listener error:', e);
                    }
                }
                // If not periodic, clean up after firing
                if (!alarm.periodInMinutes) {
                    delete alarmTimers[name];
                } else {
                    // Update scheduledTime for next firing
                    alarm.scheduledTime = Date.now() + (alarm.periodInMinutes * 60000);
                }
            }

            chrome.alarms.create = function(nameOrInfo, alarmInfo) {
                let name = '';
                if (typeof nameOrInfo === 'string') {
                    name = nameOrInfo;
                } else if (typeof nameOrInfo === 'object' && nameOrInfo !== null) {
                    alarmInfo = nameOrInfo;
                    name = '';
                }
                if (!alarmInfo) alarmInfo = {};

                // Clear any existing alarm with this name
                if (alarmTimers[name]) {
                    if (alarmTimers[name].timeoutID) clearTimeout(alarmTimers[name].timeoutID);
                    if (alarmTimers[name].intervalID) clearInterval(alarmTimers[name].intervalID);
                }

                const entry = {
                    name: name,
                    scheduledTime: 0,
                    periodInMinutes: alarmInfo.periodInMinutes || null,
                    timeoutID: null,
                    intervalID: null
                };

                let delayMs;
                if (alarmInfo.when) {
                    delayMs = Math.max(0, alarmInfo.when - Date.now());
                } else if (alarmInfo.delayInMinutes !== undefined) {
                    delayMs = alarmInfo.delayInMinutes * 60000;
                } else if (alarmInfo.periodInMinutes) {
                    delayMs = alarmInfo.periodInMinutes * 60000;
                } else {
                    delayMs = 0;
                }

                entry.scheduledTime = Date.now() + delayMs;

                if (alarmInfo.periodInMinutes) {
                    entry.timeoutID = setTimeout(function() {
                        fireAlarm(name);
                        entry.intervalID = setInterval(function() {
                            fireAlarm(name);
                        }, alarmInfo.periodInMinutes * 60000);
                    }, delayMs);
                } else {
                    entry.timeoutID = setTimeout(function() {
                        fireAlarm(name);
                    }, delayMs);
                }

                alarmTimers[name] = entry;
                return Promise.resolve();
            };

            chrome.alarms.clear = function(name, callback) {
                if (typeof name === 'function') {
                    callback = name;
                    name = '';
                }
                name = name || '';
                let wasCleared = false;
                if (alarmTimers[name]) {
                    if (alarmTimers[name].timeoutID) clearTimeout(alarmTimers[name].timeoutID);
                    if (alarmTimers[name].intervalID) clearInterval(alarmTimers[name].intervalID);
                    delete alarmTimers[name];
                    wasCleared = true;
                }
                if (callback) { callback(wasCleared); return; }
                return Promise.resolve(wasCleared);
            };

            chrome.alarms.clearAll = function(callback) {
                for (const name in alarmTimers) {
                    if (alarmTimers[name].timeoutID) clearTimeout(alarmTimers[name].timeoutID);
                    if (alarmTimers[name].intervalID) clearInterval(alarmTimers[name].intervalID);
                }
                alarmTimers = {};
                if (callback) { callback(true); return; }
                return Promise.resolve(true);
            };

            chrome.alarms.get = function(name, callback) {
                if (typeof name === 'function') {
                    callback = name;
                    name = '';
                }
                name = name || '';
                const alarm = alarmTimers[name];
                const result = alarm ? {
                    name: alarm.name,
                    scheduledTime: alarm.scheduledTime,
                    periodInMinutes: alarm.periodInMinutes || undefined
                } : undefined;
                if (callback) { callback(result); return; }
                return Promise.resolve(result);
            };

            chrome.alarms.getAll = function(callback) {
                const all = [];
                for (const name in alarmTimers) {
                    const alarm = alarmTimers[name];
                    all.push({
                        name: alarm.name,
                        scheduledTime: alarm.scheduledTime,
                        periodInMinutes: alarm.periodInMinutes || undefined
                    });
                }
                if (callback) { callback(all); return; }
                return Promise.resolve(all);
            };

            chrome.alarms.onAlarm = {
                addListener: function(cb) { onAlarmListeners.push(cb); },
                removeListener: function(cb) {
                    const idx = onAlarmListeners.indexOf(cb);
                    if (idx !== -1) onAlarmListeners.splice(idx, 1);
                },
                hasListener: function(cb) { return onAlarmListeners.includes(cb); }
            };
        })();
        """
    }
}
