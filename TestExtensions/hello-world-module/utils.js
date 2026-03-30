export async function incrementVisitCount() {
    const result = await chrome.storage.local.get('visitCount');
    const count = (result.visitCount || 0) + 1;
    await chrome.storage.local.set({ visitCount: count });
    return count;
}
