// Service worker: reçoit les notifications même quand l'appli est fermée. Aucune mise en cache.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data.json(); } catch { d = { title: 'Habitudes', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Habitudes', {
    body: d.body || '',
    icon: 'icon-512.png',
    badge: 'icon-512.png',
    tag: d.tag,
    data: { url: d.url || './' },
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const open = wins.find(w => w.url.includes('/habitudes/'));
    return open ? open.focus() : self.clients.openWindow(e.notification.data.url);
  })());
});
